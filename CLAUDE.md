# ZLox - Bytecode Interpreter for Lox in Zig

This project is a bytecode interpreter for the Lox programming language (from "Crafting Interpreters") implemented in Zig 0.15.

## Project Overview

ZLox is a bytecode virtual machine implementation of the Lox language. The project includes:

- **Virtual Machine**: A stack-based bytecode interpreter with opcodes for basic arithmetic operations
- **Scanner/Lexer**: A tokenizer that converts Lox source code into tokens
- **Bytecode Format**: Custom bytecode format with constant pool and line number tracking

## Project Structure

```
zlox/
├── src/
│   ├── main.zig          # Main VM implementation with bytecode interpreter
│   └── scanner.zig       # Lexical analyzer for Lox source code
├── build.zig             # Zig build configuration
├── build.zig.zon         # Package metadata and dependencies
```

## Current Implementation Status

### ✅ Completed Features

- **Basic VM Architecture**: Stack-based virtual machine with instruction pointer
- **Opcodes**: Support for basic arithmetic operations (ADD, SUBTRACT, MULTIPLY, DIVIDE, NEGATE)
- **Constant Pool**: Value storage and retrieval system
- **Disassembler**: Debug output for bytecode instructions
- **Scanner**: Tokenizes single-character operators and basic tokens
- **Error Handling**: Basic error types for compile and runtime errors

### 🚧 Current Limitations

- Scanner is incomplete (missing string/number literals, identifiers, keywords)
- No compiler (parser/code generation) yet
- No support for variables, functions, or control flow
- Limited to basic arithmetic expressions

## Build Commands

```bash
# Build the project
zig build

# Run the interpreter
zig build run

# Run tests
zig build test

# Run benchmarks (optionally filtered by name)
zig build bench
zig build bench -- fib loop

# Run test of specific file
zig test {filepath}
```

## VM Architecture

The VM uses:
- **Value Type**: `f64` for all values
- **Stack**: Dynamic array for operand stack
- **Instruction Pointer**: Raw pointer for efficient bytecode traversal
- **Debug Mode**: Controllable trace execution via `DEBUG_TRACE_EXECUTION`

### Supported Opcodes

- `OP_RETURN`: Exit execution
- `OP_CONSTANT`: Load constant from pool
- `OP_NEGATE`: Negate top stack value
- `OP_ADD`, `OP_SUBTRACT`, `OP_MULTIPLY`, `OP_DIVIDE`: Binary arithmetic

## Testing

The project includes unit tests for:
- Scanner token recognition
- Utility functions (slice creation from pointers)

Run tests with `zig build test`.

## Development Notes

- Project uses Zig 0.15 with minimum version 0.14.1
- Follow the "Crafting Interpreters" book structure
- Currently focused on Part III (bytecode interpreter)
- Debug tracing can be toggled via compile-time constant
