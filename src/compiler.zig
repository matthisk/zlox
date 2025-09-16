const std = @import("std");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");

const VM = vm_mod.VM;
const Scanner = scanner_mod.Scanner;
const TokenType = scanner_mod.TokenType;
const Token = scanner_mod.Token;
const Value = value_mod.Value;
const numberValue = value_mod.numberValue;

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const ChunkErrors = chunk_mod.ChunkErrors;

const CompilerError = error{ParseError};

const Precedence = enum { NONE, ASSIGNMENT, OR, AND, EQUALITY, COMPARISON, TERM, FACTOR, UNARY, CALL, PRIMARY };

const ParseFn = *const fn (self: *Compiler) (ChunkErrors || std.mem.Allocator.Error)!void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

const ParseRules = std.EnumArray(TokenType, ParseRule);

const DEBUG_PRINT_CODE = false;

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    scanner: *Scanner,
    vm: *VM,
    previous: Token = undefined,
    current: Token = undefined,
    hadError: bool = false,
    chunk: *Chunk = undefined,
    rules: ParseRules = undefined,

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner, vm: *VM) Compiler {
        var compiler = Compiler{ .allocator = allocator, .scanner = scanner, .vm = vm };

        compiler.rules = ParseRules.initUndefined();

        compiler.rules.set(TokenType.TOKEN_LEFT_PAREN, ParseRule{ .prefix = grouping, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RIGHT_PAREN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_LEFT_BRACE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RIGHT_BRACE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_COMMA, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_DOT, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_MINUS, ParseRule{ .prefix = unary, .infix = binary, .precedence = Precedence.TERM });
        compiler.rules.set(TokenType.TOKEN_PLUS, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.TERM });
        compiler.rules.set(TokenType.TOKEN_SEMICOLON, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_SLASH, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.FACTOR });
        compiler.rules.set(TokenType.TOKEN_STAR, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.FACTOR });
        compiler.rules.set(TokenType.TOKEN_BANG, ParseRule{ .prefix = unary, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_BANG_EQUAL, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.EQUALITY });
        compiler.rules.set(TokenType.TOKEN_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EQUAL_EQUAL, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.EQUALITY });
        compiler.rules.set(TokenType.TOKEN_GREATER, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.COMPARISON });
        compiler.rules.set(TokenType.TOKEN_GREATER_EQUAL, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.COMPARISON });
        compiler.rules.set(TokenType.TOKEN_LESS, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.COMPARISON });
        compiler.rules.set(TokenType.TOKEN_LESS_EQUAL, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.COMPARISON });
        compiler.rules.set(TokenType.TOKEN_IDENTIFIER, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_STRING, ParseRule{ .prefix = string, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NUMBER, ParseRule{ .prefix = number, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_AND, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.AND });
        compiler.rules.set(TokenType.TOKEN_CLASS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ELSE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FALSE, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FOR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FUN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_IF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NIL, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_OR, ParseRule{ .prefix = null, .infix = binary, .precedence = Precedence.OR });
        compiler.rules.set(TokenType.TOKEN_PRINT, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RETURN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_SUPER, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_THIS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_TRUE, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_VAR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_WHILE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ERROR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EOF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });

        return compiler;
    }

    pub fn compile(self: *Compiler, chunk: *Chunk) !void {
        self.chunk = chunk;

        self.advance();

        while (!self.match(TokenType.TOKEN_EOF)) {
            try self.declaration();
        }

        try self.end();

        if (self.hadError) {
            return CompilerError.ParseError;
        } else if (comptime DEBUG_PRINT_CODE) {
            std.debug.print("\n", .{});
            self.chunk.disassemble("code");
            std.debug.print("\n", .{});
        }
    }

    fn declaration(self: *Compiler) !void {
        if (self.match(TokenType.TOKEN_VAR)) {
            try self.varDecl();
        } else {
            try self.statement();
        }
    }

    fn statement(self: *Compiler) !void {
        if (self.match(TokenType.TOKEN_PRINT)) {
            try self.printStatement();
        } else {
            try self.expressionStatement();
        }
    }

    fn varDecl(self: *Compiler) !void {
        const global = try self.parseVariable("Expect variable name");

        if (self.match(TokenType.TOKEN_EQUAL)) {
            try self.expression();
        } else {
            try self.emitOp(OpCode.OP_NIL);
        }
        self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';' after statement");

        try self.defineVariable(global);
    }

    fn parseVariable(self: *Compiler, errorMessage: []const u8) !u8 {
        self.consume(TokenType.TOKEN_IDENTIFIER, errorMessage);
        return try self.identifierConstant();
    }

    fn identifierConstant(self: *Compiler) !u8 {
        return try self.makeConstant(value_mod.objValue(try value_mod.copyString(self.allocator, self.vm, self.previous.lexeme)));
    }

    fn defineVariable(self: *Compiler, global: u8) !void {
        try self.emitBytes(@intFromEnum(OpCode.OP_DEFINE_GLOBAL), global);
    }

    fn printStatement(self: *Compiler) !void {
        try self.expression();
        try self.emitOp(OpCode.OP_PRINT);
        self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';' after value.");
    }

    fn expressionStatement(self: *Compiler) !void {
        try self.expression();
        self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';' after expression.");
        try self.emitOp(OpCode.OP_POP);
    }

    fn advance(self: *Compiler) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scan();

            if (self.current.type != TokenType.TOKEN_ERROR) break;

            self.errorAtCurrent("Scanner error");
        }
    }

    fn expression(self: *Compiler) !void {
        try self.parsePrecedence(Precedence.ASSIGNMENT);
    }

    fn parsePrecedence(self: *Compiler, precedence: Precedence) !void {
        self.advance();

        const prefixRule = self.rules.get(self.previous.type).prefix;

        if (prefixRule == null) {
            self.errorAtCurrent("Expect expression.");
            return;
        }

        if (comptime DEBUG_PRINT_CODE) {
            std.debug.print("COMPILER > Prefix token='{s}' with precedence='{s}' until precendence='{s}'\n", .{ @tagName(self.previous.type), @tagName(precedence), @tagName(self.rules.get(self.current.type).precedence) });
        }

        try prefixRule.?(self);

        while (@intFromEnum(precedence) <= @intFromEnum(self.rules.get(self.current.type).precedence)) {
            self.advance();
            const infixRule = self.rules.get(self.previous.type).infix;
            if (comptime DEBUG_PRINT_CODE) {
                std.debug.print("COMPILER > Infix token='{s}'\n", .{@tagName(self.previous.type)});
            }
            try infixRule.?(self);
        }
    }

    fn number(self: *Compiler) !void {
        // Panic in case we cannot parse float. The lexer should NEVER return unparseable lexemes.
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch unreachable;

        try self.emitConstant(numberValue(value));
    }

    fn literal(self: *Compiler) !void {
        try switch (self.previous.type) {
            TokenType.TOKEN_FALSE => self.emitOp(OpCode.OP_FALSE),
            TokenType.TOKEN_TRUE => self.emitOp(OpCode.OP_TRUE),
            TokenType.TOKEN_NIL => self.emitOp(OpCode.OP_NIL),
            else => {},
        };
    }

    fn string(self: *Compiler) !void {
        const input = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const value = value_mod.objValue(try value_mod.copyString(self.allocator, self.vm, input));
        try self.emitConstant(value);
    }

    fn grouping(self: *Compiler) !void {
        try self.expression();
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after expression.");
    }

    fn binary(self: *Compiler) !void {
        const operatorType = self.previous.type;
        const rule = self.rules.get(operatorType);

        try self.parsePrecedence(nextPrecedence(rule.precedence));

        try switch (operatorType) {
            TokenType.TOKEN_PLUS => self.emitOp(OpCode.OP_ADD),
            TokenType.TOKEN_MINUS => self.emitOp(OpCode.OP_SUBTRACT),
            TokenType.TOKEN_STAR => self.emitOp(OpCode.OP_MULTIPLY),
            TokenType.TOKEN_SLASH => self.emitOp(OpCode.OP_DIVIDE),
            TokenType.TOKEN_AND => self.emitOp(OpCode.OP_AND),
            TokenType.TOKEN_OR => self.emitOp(OpCode.OP_OR),
            TokenType.TOKEN_EQUAL_EQUAL => self.emitOp(OpCode.OP_EQUALS),
            TokenType.TOKEN_BANG_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_EQUALS), @intFromEnum(OpCode.OP_NOT)),
            TokenType.TOKEN_LESS => self.emitOp(OpCode.OP_LESS),
            TokenType.TOKEN_GREATER => self.emitOp(OpCode.OP_GREATER),
            TokenType.TOKEN_LESS_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_GREATER), @intFromEnum(OpCode.OP_NOT)),
            TokenType.TOKEN_GREATER_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_LESS), @intFromEnum(OpCode.OP_NOT)),
            else => unreachable,
        };
    }

    fn unary(self: *Compiler) !void {
        const operator = self.previous.type;

        try self.parsePrecedence(Precedence.UNARY);

        try switch (operator) {
            TokenType.TOKEN_MINUS => self.emitOp(OpCode.OP_NEGATE),
            TokenType.TOKEN_BANG => self.emitOp(OpCode.OP_NOT),
            else => unreachable,
        };
    }

    fn match(self: *Compiler, t: TokenType) bool {
        if (self.check(t)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *Compiler, t: TokenType, msg: []const u8) void {
        if (self.check(t)) {
            self.advance();
        } else {
            self.errorAtCurrent(msg);
        }
    }

    fn check(self: *Compiler, t: TokenType) bool {
        return self.current.type == t;
    }

    fn end(self: *Compiler) !void {
        try self.emitOp(OpCode.OP_RETURN);
    }

    fn emitConstant(self: *Compiler, value: Value) !void {
        try self.emitBytes(@intFromEnum(OpCode.OP_CONSTANT), try self.makeConstant(value));
    }

    fn emitBytes(self: *Compiler, b1: u8, b2: u8) !void {
        try self.emitByte(b1);
        try self.emitByte(b2);
    }

    fn emitOp(self: *Compiler, op: OpCode) !void {
        try self.emitByte(@intFromEnum(op));
    }

    fn emitByte(self: *Compiler, b: u8) !void {
        if (comptime DEBUG_PRINT_CODE) {
            const op: OpCode = @enumFromInt(b);
            std.debug.print("COMPILER > Emit op='{s}'\n", .{@tagName(op)});
        }
        try self.chunk.writeChunk(b, self.previous.line);
    }

    fn makeConstant(self: *Compiler, v: Value) !u8 {
        return self.chunk.addValue(v);
    }

    fn errorAtCurrent(self: *Compiler, msg: []const u8) void {
        self.errorAt(self.current, msg);
    }

    fn errorAt(self: *Compiler, token: Token, msg: []const u8) void {
        var writer = std.io.getStdErr().writer();

        writer.print("[line {d}] Error", .{token.line}) catch {};

        if (token.type == TokenType.TOKEN_EOF) {
            writer.print(" at end", .{}) catch {};
        } else if (token.type == TokenType.TOKEN_ERROR) {
            // nothing.
        } else {
            writer.print(" at '{s}'", .{token.lexeme}) catch {};
        }

        writer.print(": {s}\n", .{msg}) catch {};
        self.hadError = true;
    }
};

fn nextPrecedence(precedence: Precedence) Precedence {
    return @enumFromInt(@intFromEnum(precedence) + 1);
}

test "compiler" {
    try testCompile("(1 + 2) * (3 + 4)");
}

test "compiler complex expression" {
    const source = "(-1 + 2) * 3 - -4";
    try testCompile(source);
}

test "compiler boolean logic" {
    try testCompile("true or false");
}

test "compiler strings" {
    try testCompile("\"hello world\"");
}

fn testCompile(source: [*]const u8) !void {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    var vm = VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    var scanner = Scanner.init(source);
    var compiler = Compiler.init(std.testing.allocator, &scanner, &vm);

    try compiler.compile(&chunk);
}
