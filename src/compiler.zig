const std = @import("std");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");

const Scanner = scanner_mod.Scanner;
const TokenType = scanner_mod.TokenType;
const Token = scanner_mod.Token;

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const ChunkErrors = chunk_mod.ChunkErrors;
const Value = chunk_mod.Value;

const CompilerError = error{ParseError};

const Precedence = enum { NONE, ASSIGNMENT, OR, AND, EQUALITY, COMPARISON, TERM, FACTOR, UNARY, CALL, PRIMARY };

const ParseFn = *const fn (self: *Compiler) void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

const ParseRules = std.EnumArray(TokenType, ParseRule);

const DEBUG_PRINT_CODE = false;

pub const Compiler = struct {
    scanner: *Scanner,
    previous: Token = undefined,
    current: Token = undefined,
    hadError: bool = false,
    chunk: *Chunk = undefined,
    rules: ParseRules = undefined,

    pub fn init(scanner: *Scanner) Compiler {
        var compiler = Compiler{ .scanner = scanner };

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
        compiler.rules.set(TokenType.TOKEN_BANG, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_BANG_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EQUAL_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_GREATER, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_GREATER_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_LESS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_LESS_EQUAL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_IDENTIFIER, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_STRING, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NUMBER, ParseRule{ .prefix = number, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_AND, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_CLASS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ELSE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FALSE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FOR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FUN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_IF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NIL, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_OR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_PRINT, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RETURN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_SUPER, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_THIS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_TRUE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_VAR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_WHILE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ERROR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EOF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });

        return compiler;
    }

    pub fn compile(self: *Compiler, chunk: *Chunk) (CompilerError || std.mem.Allocator.Error)!void {
        self.chunk = chunk;

        self.advance();
        self.expression();
        self.consume(TokenType.TOKEN_EOF, "Expect end of expression.");

        self.end();

        if (self.hadError) {
            return CompilerError.ParseError;
        } else if (comptime DEBUG_PRINT_CODE) {
            self.chunk.disassemble("code");
        }
    }

    fn advance(self: *Compiler) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scan();

            if (self.current.type != TokenType.TOKEN_ERROR) break;

            self.errorAtCurrent("Error");
        }
    }

    fn parsePrecedence(self: *Compiler, precedence: Precedence) void {
        self.advance();

        const prefixRule = self.rules.get(self.previous.type).prefix;

        if (prefixRule == null) {
            self.errorAtCurrent("Expect expression.");
            return;
        }

        prefixRule.?(self);

        while (@intFromEnum(precedence) <= @intFromEnum(self.rules.get(self.current.type).precedence)) {
            self.advance();
            const infixRule = self.rules.get(self.previous.type).infix;
            infixRule.?(self);
        }
    }

    fn expression(self: *Compiler) void {
        self.parsePrecedence(Precedence.ASSIGNMENT);
    }

    fn number(self: *Compiler) void {
        // Panic in case we cannot parse float. The lexer should NEVER return unparseable lexemes.
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch unreachable;

        self.emitConstant(value) catch self.errorAtCurrent("Out of constant slots.");
    }

    fn grouping(self: *Compiler) void {
        self.expression();
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after expression.");
    }

    fn binary(self: *Compiler) void {
        const operatorType = self.previous.type;
        const rule = self.rules.get(operatorType);

        self.parsePrecedence(nextPrecedence(rule.precedence));

        switch (operatorType) {
            TokenType.TOKEN_PLUS => self.emitByte(@intFromEnum(OpCode.OP_ADD)) catch self.errorAtCurrent("OOO"),
            TokenType.TOKEN_MINUS => self.emitByte(@intFromEnum(OpCode.OP_SUBTRACT)) catch self.errorAtCurrent("OOO"),
            TokenType.TOKEN_STAR => self.emitByte(@intFromEnum(OpCode.OP_MULTIPLY)) catch self.errorAtCurrent("OOO"),
            TokenType.TOKEN_SLASH => self.emitByte(@intFromEnum(OpCode.OP_DIVIDE)) catch self.errorAtCurrent("OOO"),
            else => unreachable,
        }
    }

    fn unary(self: *Compiler) void {
        const operator = self.previous.type;

        self.parsePrecedence(Precedence.UNARY);

        switch (operator) {
            TokenType.TOKEN_MINUS => self.emitByte(@intFromEnum(OpCode.OP_NEGATE)) catch self.errorAtCurrent("OOO"),
            else => unreachable,
        }
    }

    fn consume(self: *Compiler, t: TokenType, msg: []const u8) void {
        if (self.current.type == t) {
            self.advance();
        } else {
            self.errorAtCurrent(msg);
        }
    }

    fn end(self: *Compiler) void {
        self.emitByte(@intFromEnum(OpCode.OP_RETURN)) catch self.errorAtCurrent("OOO");
    }

    fn emitConstant(self: *Compiler, value: Value) !void {
        try self.emitBytes(@intFromEnum(OpCode.OP_CONSTANT), try self.makeConstant(value));
    }

    fn emitBytes(self: *Compiler, b1: u8, b2: u8) std.mem.Allocator.Error!void {
        try self.emitByte(b1);
        try self.emitByte(b2);
    }

    fn emitByte(self: *Compiler, b: u8) std.mem.Allocator.Error!void {
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
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    var scanner = Scanner.init("(1 + 2) * (3 + 4)");
    var compiler = Compiler.init(&scanner);

    try compiler.compile(&chunk);
}

test "compiler complex expression" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    const source = "(-1 + 2) * 3 - -4";
    var scanner = Scanner.init(source);
    var compiler = Compiler.init(&scanner);

    std.debug.print("{s}\n", .{source});

    try compiler.compile(&chunk);
}
