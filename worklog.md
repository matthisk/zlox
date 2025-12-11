# ZLox Development Worklog

This worklog tracks progress on the ZLox bytecode interpreter implementation. Use this to get back up to speed when returning to the project.

## Format
Each entry includes:
- **Date**: When the work was done
- **What I Did**: Summary of changes
- **Key Commits**: Related commit hashes
- **Next Steps**: What to work on next (optional)

---

## October 2025

### 2025-10-14
**What I Did:**
- Implemented local variables and if statements
- Added jump instructions for if/else control flow
- Implemented logical operators (and, or) with short-circuit evaluation
- Added while loop support
- Implemented for loop syntax

**Key Commits:**
- `36b3bc4` - Local variables + If statements
- `2a46d71` - Implement jump for if/else
- `0b26eea` - Add logical and & or
- `5a30cec` - Add while statement
- `1d5320a` - Add for loop

**Next Steps:**
- Consider adding function support
- Implement closures if needed

---

## September 2025

### 2025-09-30
**What I Did:**
- Added assignment support for global variables
- Optimized constant table by reusing slots for recurring identifiers
- Refactored engine architecture to support persistent state

**Key Commits:**
- `f137435` - Add assignments to global variables
- `9219cd3` - Reuse constant table slots for recurring identifiers
- `beb38a5` - Refactor engine to support persistent state

### 2025-09-19
**What I Did:**
- Implemented OP_GET_GLOBAL bytecode instruction for reading global variables

**Key Commits:**
- `5ac2fdf` - Implement OP_GET_GLOBAL bytecode

### 2025-09-16
**What I Did:**
- Added global variable definition to compiler and VM
- Cleaned up repository (removed zig binary)
- Improved compiler error handling for out-of-order errors

**Key Commits:**
- `4d3a64b` - Add global variable definition to compiler and VM
- `e126e4c` - Remove zig binary
- `6de4ffd` - Change compiler error handling of OOO errors

### 2025-09-10
**What I Did:**
- Implemented string interning for efficient string handling
- Added comprehensive engine test suite

**Key Commits:**
- `f72ec43` - Add string interning and engine test suite

### 2025-09-09
**What I Did:**
- Implemented equality operators (==, !=)
- Added simple garbage collection that runs after each VM execution

**Key Commits:**
- `076e122` - Support equality operators
- `e1369bb` - Add simple garbage collection after each VM run

### 2025-09-08
**What I Did:**
- Fixed boolean operator support
- Improved debug logging and trace output

**Key Commits:**
- `ee7b223` - Fix boolean operator support and improve debug logging

### 2025-09-04
**What I Did:**
- Added opcodes for BOOLEAN types and negation operator
- Implemented 'not' operator support for non-boolean types (truthiness rules)

**Key Commits:**
- `7864311` - Add opcodes for BOOLEANs and negation
- `9a99828` - Add not operator support for non boolean types

### 2025-09-03
**What I Did:**
- Introduced Value union type to support more than just f64 values
- This was a major refactor enabling booleans, nil, and other future types

**Key Commits:**
- `41dc1c2` - Add support for a Value union introducing more than f64 types

### 2025-09-02
**What I Did:**
- Built complete bytecode VM with compiler and engine
- Added stack tracing for execution debugging
- Created sample Lox files for testing

**Key Commits:**
- `7bb9f9f` - Add complete bytecode VM with compiler and engine
- `5635e3c` - Print the stack while tracing execution + add some sample lox files

---

## August 2025

### 2025-08-26
**What I Did:**
- Enhanced scanner with string literal and number literal support
- Added initial compiler implementation

**Key Commits:**
- `cd580e7` - Enhance scanner with string/number support and add compiler

### 2025-08-24
**What I Did:**
- Initial project setup
- Created basic Lox bytecode interpreter in Zig
- Set up project structure and build configuration

**Key Commits:**
- `a1fb749` - Initial commit: Lox bytecode interpreter in Zig

---

## Current Status (as of latest commit)

**Working Features:**
-  Complete bytecode VM with stack-based execution
-  Scanner with string/number literal support
-  Compiler from Lox source to bytecode
-  Value types: numbers, booleans, nil, strings
-  Arithmetic operators: +, -, *, /
-  Comparison operators: <, >, <=, >=, ==, !=
-  Logical operators: and, or, !
-  Global variables (definition, reading, assignment)
-  Local variables with block scoping
-  Control flow: if/else statements
-  Loops: while and for loops
-  String interning
-  Simple garbage collection
-  Debug tracing and disassembler

**Known Limitations:**
- No function support yet
- No closures
- No classes/objects
- No standard library

**Next Major Milestones:**
- Functions and function calls
- Closures
- Classes and object-oriented features
