# Design: `OP_EXTRA_ARG` prefix for wide operands

## Problem

Today the instruction set has two variants of every opcode whose operand can
grow past one byte:

| short form         | long form               |
| ------------------ | ----------------------- |
| `OP_CONSTANT  u8`  | `OP_CONSTANT_LONG  u24` |
| `OP_GET_GLOBAL u8` | `OP_GET_GLOBAL_LONG u24`|
| `OP_POPN u8`       | `OP_POPN_LONG u24`      |
| ...                | ...                     |

That's 10 pairs (`METHOD`, `GET_PROPERTY`, `SET_PROPERTY`, `CLASS`, `ARRAY`,
`CONSTANT`, `INVOKE`, `CLOSURE`, `POPN`, `DEFINE/GET/SET_GLOBAL`). Each pair
needs two enum tags, two VM cases (or one case with an `if` on the opcode),
two disassembler branches, and the compiler has to pick the right one.

A third group goes the other way: `OP_GET_LOCAL`, `OP_SET_LOCAL`,
`OP_GET_UPVALUE` and `OP_SET_UPVALUE` *always* use a 3-byte operand, so even
`GET_LOCAL 0` takes 4 bytes.

## Proposal

Every operand-carrying instruction gets exactly **one byte** of operand. To
encode a bigger number, put one or more `OP_EXTRA_ARG` prefix instructions in
front of it. Each prefix holds one more byte, high byte first.

```
OP_EXTRA_ARG <b0>
OP_EXTRA_ARG <b1>
OP_CONSTANT  <b2>        ; constant index = b0 << 16 | b1 << 8 | b2
```

Examples:

| index    | encoding                                              | bytes |
| -------- | ----------------------------------------------------- | ----- |
| `7`      | `OP_CONSTANT 07`                                      | 2     |
| `300`    | `OP_EXTRA_ARG 01, OP_CONSTANT 2C`                     | 4     |
| `70_000` | `OP_EXTRA_ARG 01, OP_EXTRA_ARG 11, OP_CONSTANT 70`    | 6     |

The rule for the VM is: *the operand of an instruction is its own byte, plus
any bytes collected by `OP_EXTRA_ARG` instructions immediately before it.*
Once an instruction consumes the collected bytes they're cleared.

### What you get

- **One opcode per operation.** The `_LONG` variants go away, and so does
  every "short or long?" branch in the VM, the disassembler and the compiler.
- **Smaller code for locals and upvalues.** `GET_LOCAL 3` drops from 4 bytes
  to 2. Local access happens a lot, so this is likely the biggest practical
  win.
- **Uniform width.** Every instruction is `opcode + operand byte`, or just
  `opcode`. That makes the instruction stream easier to reason about.
- **Room to grow.** The prefix doesn't care which opcode follows it, so new
  opcodes get wide operands without extra work.

### What it costs

- **An extra dispatch for each prefix.** A wide operand now takes 1–2 more
  trips through the dispatch loop. Since wide operands are rare (more than
  256 constants or locals in one function), this should barely matter, but
  it's worth checking with `zig build bench`.
- **The prefix and its instruction belong together.** A jump must never land
  between an `OP_EXTRA_ARG` and the instruction it extends, or the operand
  gets misread. In practice this holds as long as jump targets are only taken
  at instruction boundaries, which is what the compiler already does.
- **Instruction start ≠ opcode position.** For a wide instruction, the
  "instruction" starts at the first prefix, not at the opcode byte. Tooling
  (disassembler, traces, runtime error line lookup) has to keep that in mind.

### Prior art

- **CPython `EXTENDED_ARG`**: almost the same idea. Every instruction has a
  1-byte argument and `EXTENDED_ARG` prefixes add the high bytes. Worth
  reading as a reference (`Python/ceval.c`, `Python/bytecodes.c`).
- **Lua 5.x `OP_EXTRAARG`**: a similar idea, but the extra word comes
  *after* the instruction that needs it, and only a few opcodes use it.
- **JVM `wide`**: one prefix that switches the next instruction to 16-bit
  operands.

## Scope

**In scope.** Every instruction whose operand is an index or count that could
go past 255:

- Constant-table indices: `CONSTANT`, `DEFINE/GET/SET_GLOBAL`, `CLASS`,
  `METHOD`, `GET/SET_PROPERTY`, `INVOKE` (method name), `CLOSURE` (function).
- Counts: `POPN`, `ARRAY`.
- Stack/upvalue slots: `GET/SET_LOCAL`, `GET/SET_UPVALUE`.

**Out of scope (proposed).** Things that can stay as they are for now; see the
questions below.

- Jump offsets (`JUMP`, `JUMP_IF_FALSE`, `LOOP`) keep their fixed 2-byte
  operand.
- `CALL`'s argument count and `INVOKE`'s argument count are already capped
  at 255 by the language.
- The upvalue descriptors that follow `OP_CLOSURE` are inline data, not
  instructions.

## Operand width limit

The current limit is 2²⁴ constants (`u24`). This design keeps that limit:
**at most two** `OP_EXTRA_ARG` prefixes per instruction. Nothing in the
encoding itself forces this limit, but keeping it means the constant table,
`addValue`, and the error messages don't change.

## Clarifying questions

1. **Jumps.** Should `JUMP`/`JUMP_IF_FALSE`/`LOOP` also move to the prefix
   scheme, or keep their fixed 2-byte operand? Forward jumps are emitted
   *before* their distance is known and patched later, so a variable-width
   encoding would mean either reserving space up front (which defeats the
   point) or re-laying out code. My recommendation: leave jumps out.

   Jumps can remain the same.

2. **`OP_INVOKE` has two operands** (name index + arg count). The proposal
   says prefixes extend the *first* operand (the name index), and arg count
   stays a plain trailing byte. Is that OK, or do you want "an instruction
   has at most one operand" as a hard rule? In that case `INVOKE` would need
   another shape, e.g. putting the arg count on the stack or in a second
   instruction.

    No it is ok to just apply it to the first operand.

3. **Closure upvalue descriptors.** These are currently `isLocal: u8` +
   `index: u24` per upvalue, i.e. 4 bytes each. Leave them alone (they're
   data, not instructions), or shrink them to `isLocal + u8` and cap captured
   local slots at 255?

   Keep this for now, we have to look into it after.

4. **Maximum prefix count.** Keep the hard limit of two prefixes (24-bit
   operands), or allow three (32-bit) now that it costs nothing in the
   encoding?

   Yes let's go to 32-bit.

5. **Should the compiler reject a stray prefix?** E.g. `OP_EXTRA_ARG`
   followed by `OP_ADD`, which takes no operand. The compiler never emits
   this, so the question is whether the VM should catch it (runtime check,
   costs a little) or treat it as undefined (only asserted in debug builds).

   The VM should trust the compiler to never emit illegal byte code sequences.

6. **Name.** `OP_EXTRA_ARG` (Lua-ish) or `OP_EXTENDED_ARG` (CPython-ish)?
   Purely cosmetic; this doc uses `OP_EXTRA_ARG`.

   OP_EXTRA_ARG

7. **Disassembly.** Should the disassembler print the prefixes as their own
   lines, or fold them into one line like `CONSTANT [70000]`? Folding is
   easier to read; separate lines show what's really in the bytecode.

   Fold them into 1 line.
