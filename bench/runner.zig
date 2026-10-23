//! Benchmark driver for zlox, invoked via `zig build bench`.
//!
//! Usage: runner <zlox-exe> <lox-dir> <expected-dir> [filter...]
//!
//! Every `<name>.lox` in `<lox-dir>` is run as a child process. A benchmark
//! prints its result followed by its own elapsed time in milliseconds (from
//! `clock()`) as the last line. The result lines are checked against
//! `<expected-dir>/<name>.txt`. When filters are given, only benchmarks whose
//! name contains one of them are run.

const std = @import("std");
const Io = std.Io;

const warmup_runs = 1;
const measured_runs = 5;

const Sample = struct {
    wall_ms: f64,
    vm_ms: f64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) {
        std.debug.print("usage: {s} <zlox-exe> <lox-dir> <expected-dir> [filter...]\n", .{args[0]});
        return error.InvalidArguments;
    }
    const zlox_path = args[1];
    const lox_dir_path = args[2];
    const expected_dir_path = args[3];
    const filters = args[4..];

    const names = try listBenchmarks(io, arena, lox_dir_path);

    var selected: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (matchesFilters(name, filters)) try selected.append(arena, name);
    }
    if (selected.items.len == 0) {
        std.debug.print("No benchmarks match the given filters. Available:\n", .{});
        for (names) |name| std.debug.print("  {s}\n", .{name});
        return error.NoBenchmarksSelected;
    }

    const expected_dir = try Io.Dir.cwd().openDir(io, expected_dir_path, .{});
    defer expected_dir.close(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("zlox benchmarks ({d} warmup, {d} measured runs)\n\n", .{ warmup_runs, measured_runs });
    try out.print("{s: <20} {s: >12} {s: >12} {s: >12}\n", .{ "benchmark", "wall median", "wall min", "vm median" });
    try out.flush();

    var failures: usize = 0;
    for (selected.items) |name| {
        const lox_path = try std.fmt.allocPrint(arena, "{s}/{s}.lox", .{ lox_dir_path, name });
        const expected_name = try std.fmt.allocPrint(arena, "{s}.txt", .{name});
        const expected = expected_dir.readFileAlloc(io, expected_name, arena, .limited(1024 * 1024)) catch |err| {
            try out.print("{s: <20} FAILED: cannot read expected output {s}: {t}\n", .{ name, expected_name, err });
            try out.flush();
            failures += 1;
            continue;
        };

        var samples: [measured_runs]Sample = undefined;
        const ok = runBenchmark(io, init.gpa, zlox_path, lox_path, expected, &samples) catch |err| {
            try out.print("{s: <20} FAILED: {t}\n", .{ name, err });
            try out.flush();
            failures += 1;
            continue;
        };
        if (!ok) {
            failures += 1;
            continue;
        }

        var wall: [measured_runs]f64 = undefined;
        var vm: [measured_runs]f64 = undefined;
        for (samples, 0..) |s, i| {
            wall[i] = s.wall_ms;
            vm[i] = s.vm_ms;
        }
        std.mem.sort(f64, &wall, {}, std.sort.asc(f64));
        std.mem.sort(f64, &vm, {}, std.sort.asc(f64));

        try out.print("{s: <20} {d: >9.1} ms {d: >9.1} ms {d: >9.1} ms\n", .{
            name,
            median(&wall),
            wall[0],
            median(&vm),
        });
        try out.flush();
    }

    if (failures > 0) {
        std.debug.print("\n{d} benchmark(s) failed\n", .{failures});
        return error.BenchmarkFailed;
    }
}

/// Returns the sorted names (without `.lox`) of all benchmarks in `dir_path`.
fn listBenchmarks(io: Io, arena: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    const dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".lox")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - ".lox".len]));
    }

    std.mem.sort([]const u8, names.items, {}, lessThanString);
    return names.items;
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn matchesFilters(name: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |filter| {
        if (std.mem.indexOf(u8, name, filter) != null) return true;
    }
    return false;
}

/// Runs one benchmark `warmup_runs + measured_runs` times, filling `samples`
/// with the measured runs. Returns false (after reporting) when the output
/// does not match `expected`.
fn runBenchmark(
    io: Io,
    gpa: std.mem.Allocator,
    zlox_path: []const u8,
    lox_path: []const u8,
    expected: []const u8,
    samples: *[measured_runs]Sample,
) !bool {
    for (0..warmup_runs + measured_runs) |run| {
        const start = Io.Timestamp.now(io, .awake);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ zlox_path, lox_path } });
        const elapsed = start.untilNow(io, .awake);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        const exited_cleanly = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };

        // The last line is the self-reported time; everything before it is the result.
        const trimmed = std.mem.trimEnd(u8, result.stdout, "\n");
        const split = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
        const output = if (split) |i| trimmed[0 .. i + 1] else "";
        const vm_line = if (split) |i| trimmed[i + 1 ..] else trimmed;
        const vm_ms = std.fmt.parseFloat(f64, vm_line) catch null;

        if (!exited_cleanly or result.stderr.len > 0 or vm_ms == null or !std.mem.eql(u8, output, expected)) {
            std.debug.print(
                "{s}: FAILED\n  term: {any}\n  expected:\n{s}  stdout:\n{s}\n  stderr:\n{s}\n",
                .{ lox_path, result.term, expected, result.stdout, result.stderr },
            );
            return false;
        }

        if (run >= warmup_runs) {
            samples[run - warmup_runs] = .{
                .wall_ms = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / std.time.ns_per_ms,
                .vm_ms = vm_ms.?,
            };
        }
    }
    return true;
}

fn median(sorted: []const f64) f64 {
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
}
