# Implementation: `OP_EXTRA_ARG`

Companion to [extra-arg-design.md](extra-arg-design.md). This plan follows the
answers given there:

| question                 | decision                                                         |
| ------------------------ | ---------------------------------------------------------------- |
| 1. Jumps                 | Unchanged, fixed 2-byte offset.                                  |
| 2. `OP_INVOKE`           | Prefixes extend the name index; arg count stays a trailing byte. |
| 3. Upvalue descriptors   | Unchanged (`isLocal: u8` + `index: u24`). Revisit later.         |
| 4. Operand width         | **32-bit**: up to three prefixes.                                |
| 5. Stray prefixes        | VM trusts the compiler: no runtime check, no assert.             |
| 6. Name                  | `OP_EXTRA_ARG`.                                                  |
| 7. Disassembly           | One folded line per instruction.                                 |

> Note: the "Operand width limit" section in the design doc still says 24
> bits; answer 4 supersedes it.

## Overview of changes

| file           | change                                                                           |
| -------------- | -------------------------------------------------------------------------------- |
| `chunk.zig`    | Remove `_LONG` opcodes, add `OP_EXTRA_ARG`, add `decode`, widen constant indices to `u32`. |
| `compiler.zig` | Merge three emit helpers into one `emitOpWithOperand(op, u32)`; widen constant index types. |
| `vm.zig`       | Add a `u32` `extra` accumulator, an `OP_EXTRA_ARG` case, and `readOperand`.     |
| `engine.zig`   | Update the wide-global test to expect prefixes instead of `_LONG` ops.           |

## 0. What changes from 24 to 32 bits (and what doesn't)

Moving to 32-bit operands affects only the **constant table**: it's the only
thing that can realistically pass 2²⁴ entries.

- **Widen to `u32`:** `Chunk.addValue` (the limit check becomes
  `maxInt(u32)`), `Chunk.findValue`, `Compiler.makeConstant`,
  `identifierConstant`, `parseVariable`, `defineVariable`, and
  `EmitTrace.operand`. Also the `array` length counter, since `ARRAY`'s count
  is now allowed up to `u32`.
- **Stay `u24`:** local slots and upvalue indices (`resolveLocal`,
  `addUpvalue`, `Upvalue.index`, the closure descriptors). The VM stack holds
  at most `STACK_MAX = 64 * 255 = 16_320` values, so a local slot can never
  get close to 2²⁴. Keeping them `u24` means the closure descriptor format
  (decision 3) doesn't change. When passed to `emitOpWithOperand` they widen
  to `u32` implicitly.

## 1. `chunk.zig`

### Opcode enum

Remove the 10 `_LONG` tags and add one:

```zig
pub const OpCode = enum(u8) {
    OP_EXTRA_ARG,
    OP_METHOD,
    OP_GET_PROPERTY,
    // ... no more *_LONG
};
```

Every opcode's numeric value changes. That's fine, since bytecode is never
saved to disk.

### Decoding an instruction that may have prefixes

Right now the disassembler, `instructionLength` and the engine test all assume
the opcode sits at `offset` and its operand at `offset + 1`. With prefixes
that's only true for narrow instructions. Put the prefix logic in one helper
so nothing else has to know about it:

```zig
pub const Decoded = struct {
    op: OpCode,
    operand: u32,      // prefixes folded in; 0 for operand-less ops
    op_offset: usize,  // where the real opcode byte sits
};

/// `offset` must be an instruction start (first prefix, or the opcode itself).
pub fn decode(self: *const Chunk, offset: usize) Decoded {
    var extra: u32 = 0;
    var i = offset;
    while (self.code.items[i] == @intFromEnum(OpCode.OP_EXTRA_ARG)) : (i += 2) {
        extra = (extra << 8) | self.code.items[i + 1];
    }
    const op = std.enums.fromInt(OpCode, self.code.items[i]) orelse .ILLEGAL;
    const operand = if (hasOperand(op)) (extra << 8) | self.code.items[i + 1] else 0;
    return .{ .op = op, .operand = operand, .op_offset = i };
}
```

`hasOperand(op)` is a small `switch` listing the operand-carrying opcodes.
The loop doesn't cap the prefix count: following decision 5, it trusts the
compiler to emit at most three.

Why decode *forward from the start*? You can't scan backwards from an opcode
to find its prefixes, because an operand byte can have the same value as
`OP_EXTRA_ARG`. So every caller has to start at an instruction boundary,
which they already do.

### `instructionLength`

This becomes "prefix bytes + base length":

```zig
pub fn instructionLength(self: *const Chunk, offset: usize) usize {
    const d = self.decode(offset);
    const prefix = d.op_offset - offset;
    const base: usize = switch (d.op) {
        .OP_JUMP, .OP_JUMP_IF_FALSE, .OP_LOOP, .OP_INVOKE => 3,
        .OP_CLOSURE => 2 + asFunction(self.data.items[d.operand]).upvalueCount * 4,
        else => if (hasOperand(d.op)) 2 else 1,
    };
    return prefix + base;
}
```

`OP_CLOSURE` is why the decoded operand matters here: its length depends on
the function's upvalue count, and the function index may itself be wide.

### `InstructionFormatter`: one folded line

Call `decode(self.offset)` once at the top and switch on `d.op`, using
`d.operand` and `d.op_offset`. The short/long branch pairs merge, e.g.:

```zig
.OP_CONSTANT, .OP_DEFINE_GLOBAL, .OP_GET_GLOBAL, ... => {
    try writer.print("{s} [{d}] {f}", .{ name, d.operand, format(data[d.operand]) });
},
```

So `EXTRA_ARG 01, EXTRA_ARG 11, CONSTANT 70` prints as `CONSTANT [70000] ...`
(decision 7). The offset column still shows where the first prefix starts, and
`disassemble` moves on by `instructionLength`, which includes the prefixes.

Byte offsets inside the instruction (the `OP_CLOSURE` upvalue descriptors,
`OP_INVOKE`'s arg count, the jump "next" position) must be computed from
`d.op_offset`, not `self.offset`.

`OP_EXTRA_ARG` itself never needs a formatter case, because `decode` always
skips past it.

## 2. `compiler.zig`

### One emit helper

Replace `emitConstantOperand(short, long, idx)`, `emitOpWithMediumOperand`
and `emitOpWithByteOperand` with:

```zig
fn emitOpWithOperand(self: *Compiler, op: OpCode, operand: u32) !void {
    self.traceEmit(op, operand);
    if (operand > 0xFFFFFF) try self.emitExtraArg(@truncate(operand >> 24));
    if (operand > 0xFFFF) try self.emitExtraArg(@truncate(operand >> 16));
    if (operand > 0xFF) try self.emitExtraArg(@truncate(operand >> 8));
    try self.emitByte(@intFromEnum(op));
    try self.emitByte(@truncate(operand));
}

fn emitExtraArg(self: *Compiler, b: u8) !void {
    try self.emitByte(@intFromEnum(OpCode.OP_EXTRA_ARG));
    try self.emitByte(b);
}
```

The encoding is *minimal*: we only emit as many prefixes as needed, so the
first prefix byte is never `0`. The VM trace relies on this (see below).

Since the VM doesn't validate anything (decision 5), this helper is the one
place that guarantees prefixes only ever come before an operand-carrying
opcode. Nothing else in the compiler should emit `OP_EXTRA_ARG`.

### Call sites

Each of these becomes one `emitOpWithOperand(op, n)` call, with the
short/long `if` removed:

- `classDeclaration` (`OP_CLASS`), `method` (`OP_METHOD`)
- `function`: `OP_CLOSURE`. The upvalue loop after it stays the same and
  still uses `emitMedium` (decision 3).
- `endScope`: the `n < UINT8_COUNT` branch for `OP_POPN` goes away.
- `defineVariable` (`OP_DEFINE_GLOBAL`)
- `array`: the `len < 0xFF` branch goes away; `len` becomes `u32`.
- `namedVariable`: the `switch (op)` becomes one call, because locals,
  upvalues and globals all go through the same path now. `arg` becomes
  `?u32`; local/upvalue results widen into it.
- `dot`: `OP_SET_PROPERTY`, `OP_INVOKE` (still followed by
  `emitByte(argCount)`, decision 2), `OP_GET_PROPERTY`.
- `emitConstant`: `OP_CONSTANT`
- `emitReturn`: `OP_GET_LOCAL 0`
- `call`: `OP_CALL argCount`. This can use the same helper; `argCount` is
  `u8`, so it never gets a prefix.

### Jumps

Unchanged (decision 1). `emitJump`/`patchJump`/`emitLoop` count raw bytes, so
they don't care how wide the instructions in between are. `loopStart` is
recorded as `code.items.len` before any instruction is emitted, so it's
always an instruction boundary and never points between a prefix and its
opcode.

### Line numbers

A prefix and its opcode are emitted in the same helper call, so they always
share `self.previous.line`. Nothing to do.

## 3. `vm.zig`

### Accumulator

Add a local in `runInstructions`, next to `ip`:

```zig
var extra: u32 = 0;
```

A local (rather than a `VM` field) keeps it in a register. It doesn't have to
survive calls or returns, because a prefix and its opcode always run
back-to-back in the same frame.

### The prefix instruction

```zig
OpCode.OP_EXTRA_ARG => {
    extra = (extra << 8) | self.readByte(&ip);
},
```

No overflow check or prefix count check (decision 5). The compiler never emits
more than three, so `extra` never shifts bits out.

### Reading an operand

```zig
inline fn readOperand(self: *VM, ip: *[*]u8, extra: *u32) u32 {
    const operand = (extra.* << 8) | self.readByte(ip);
    extra.* = 0;
    return operand;
}
```

Resetting `extra` here is what makes the "prefixes belong to the next
operand-carrying instruction" rule work. Every case that takes an operand
must call `readOperand`, or a later instruction will pick up stale bytes.
That's the main correctness risk in this change.

`readConstant` / `readLongConstant` collapse into one:

```zig
inline fn readConstant(self: *VM, ip: *[*]u8, extra: *u32, constants: []Value) Value {
    return constants[self.readOperand(ip, extra)];
}
```

`readMedium` stays (for the closure upvalue descriptors). `readShort` stays
(for jumps).

### Cases

Every `OpCode.OP_X, OpCode.OP_X_LONG => { const v = if (...) ... else ...; }`
becomes `OpCode.OP_X => { const v = self.readConstant(&ip, &extra, constants); }`.
Specifically:

- `CONSTANT`, `DEFINE/GET/SET_GLOBAL`, `CLASS`, `METHOD`,
  `GET/SET_PROPERTY`: `readConstant`
- `INVOKE`: `readConstant` for the name, then a plain `readByte` for arg count
- `CLOSURE`: `readConstant` for the function; the upvalue loop is unchanged
- `POPN`, `ARRAY`, `GET/SET_LOCAL`, `GET/SET_UPVALUE`: `readOperand`
  (`readMedium` for the last four today)
- `CALL`: can stay `readByte`, since it never gets a prefix

### Debug trace

`ExecutionTrace` prints the instruction at `instruction_offset` on every
dispatch. With prefixes it would print `EXTRA_ARG` and then try to format the
real opcode from the middle of a wide instruction, which goes wrong for
`OP_CLOSURE`. The simple fix is to only trace when `extra == 0`, i.e. at an
instruction start. Because the encoding is minimal, the first prefix byte is
never 0, so `extra` is non-zero exactly while we're inside a wide instruction.
The trace then prints the folded instruction once, via `decode`, which also
matches the disassembler (decision 7).

### Runtime errors

`runtimeError` uses `ip - 1` to look up a line. That points at the
just-read operand byte, which is on the same line as the opcode, so this
doesn't change.

### Optional alternative: dispatch from inside the prefix

CPython-style: `OP_EXTRA_ARG` reads its byte, then immediately reads and
dispatches the next opcode itself (with Zig's labeled `switch` +
`continue :dispatch next_op`). This keeps the trace and the instruction count
"one per real instruction", but it means converting the loop to a labeled
switch. That's a bigger refactor, and probably a nice follow-up experiment
on its own (it's also the "threaded dispatch" optimization).

## 4. Tests

Existing tests to update:

- `chunk.zig`, `"instruction length includes POPN operands"`: replace the
  `OP_POPN_LONG` bytes with `OP_EXTRA_ARG 01, OP_POPN 00` and expect length 4.
- `compiler.zig`, `"scope cleanup batches uncaptured locals"`: the 256 case
  expects `{ OP_EXTRA_ARG, 1, OP_POPN, 0 }`.
- `engine.zig`, wide-globals test: instead of expecting `_LONG` opcodes,
  walk the chunk with `decode` and check that `d.op` is the narrow opcode and
  `d.operand == index` (for both the 255 and 256 cases).

New tests worth adding:

- `chunk.zig` unit test for `decode`, covering 0, 1, 2 and 3 prefixes, and a
  middle prefix byte of `0` (e.g. operand `0x01_00_00_05`).
- A unit test for `emitOpWithOperand` at every boundary: `0xFF`, `0x100`,
  `0xFFFF`, `0x10000`, `0xFFFFFF`, `0x1000000`, `0xFFFFFFFF`. Check both the
  emitted bytes and that `decode` gets the same value back.
- A disassembler test showing that a wide instruction formats as one line.
- An engine/sample test with more than 256 locals in one function, so
  `GET_LOCAL` gets a prefix end-to-end. Locals are the newly variable-width
  path, so they're the most likely place for a bug.

An end-to-end test with more than 2²⁴ constants isn't practical (too slow and
memory hungry). The 3-prefix path is covered by the unit tests above, and it
runs through exactly the same VM code as the 1-prefix path.

## 5. Suggested order

Each step should build and pass `zig build test`:

1. Add `OP_EXTRA_ARG`, `decode`, `emitOpWithOperand` (32-bit) and
   `readOperand`, and handle the prefix in the VM, *without* removing anything
   yet. Switch `OP_CONSTANT` over end to end and remove `OP_CONSTANT_LONG`.
2. Move the remaining constant-index opcodes over one at a time, deleting
   each `_LONG` variant as you go.
3. Move `POPN` and `ARRAY`.
4. Move `GET/SET_LOCAL` and `GET/SET_UPVALUE` from fixed `u24` to
   operand + prefix. This one actually changes code size, so run
   `zig build bench` before and after.
5. Widen the constant-table index types from `u24` to `u32` (section 0). This
   is a separate step because it's only a type change and touches no
   encoding logic.
6. Delete the now-unused emit helpers and `readLongConstant`.
