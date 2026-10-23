# Repository Guidelines

## Purpose

This is a repository I use for learning how to build interpreters. As such when you make suggestions to me, or propose code changes keep the scope as minimal as possible. I need to easily understand any code changes and proposals you make so I can learn from them. Also keep in mind this isn't a production grade virtual machine implementation. We do care about performance, but mainly to learn how these performance optimizations work.

## Project Structure & Module Organization

ZLox is a Zig implementation of the bytecode interpreter from *Crafting Interpreters*. Production code lives in `src/`: `main.zig` provides the CLI/REPL, `engine.zig` coordinates compilation and execution, `scanner.zig` tokenizes source, `compiler.zig` emits bytecode, and `vm.zig`, `chunk.zig`, and `value.zig` implement runtime storage and evaluation. Numbered programs in `samples/` act as integration fixtures. Build metadata is in `build.zig` and `build.zig.zon`; `flake.nix` and `flake.lock` define the optional Nix development environment.

## Build, Test, and Development Commands

- `nix develop` enters a shell with Zig, ZLS, LLDB, and `nixfmt`.
- `zig build` compiles and installs the `zlox` executable under `zig-out/bin/`.
- `zig build run` starts the interactive REPL.
- `zig build run -- samples/023_for.lox` runs a Lox source file.
- `zig build test` runs all tests reachable from `src/main.zig`.
- `zig build bench` runs the benchmarks in `bench/lox` against a ReleaseFast build; `zig build bench -- fib loop` runs only benchmarks whose name contains one of the filters.
- `zig fmt src build.zig build.zig.zon` formats Zig sources and build files.

Run commands from the repository root because integration tests resolve fixtures through `samples/`.

## Coding Style & Naming Conventions

Use `zig fmt` as the source of truth; do not hand-align formatting. Follow existing conventions: four-space indentation, `PascalCase` for types, `camelCase` for functions and locals, `UPPER_SNAKE_CASE` for opcode/token tags, and lowercase filenames such as `scanner.zig`. Keep components small and pass allocators explicitly. Pair owned allocations with `defer` cleanup near their creation. Add new opcodes and compiler/VM handling together so bytecode remains internally consistent.

## Testing Guidelines

Tests use Zig's built-in `test` blocks and `std.testing`; there is no separate test directory or stated coverage threshold. Place focused unit tests beside the implementation. For language behavior, add a numbered `samples/NNN_description.lox` fixture and a matching descriptive test in `engine.zig`. Cover successful execution and expected compile/runtime failures. Run `zig build test` and `zig fmt --check src build.zig build.zig.zon` before submitting.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects, for example `Add while statement` or `Optimize the OP_NEGATE implementation`. Keep each commit focused and explain non-obvious VM or bytecode choices in the body. Pull requests should summarize user-visible behavior, identify affected interpreter layers, list validation commands, and link relevant issues. Include a minimal Lox example or terminal output when semantics or diagnostics change; screenshots are generally unnecessary for this CLI project.
