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

const PrefixParseFn = *const fn (self: *Compiler, canAssign: bool) (ChunkErrors || std.mem.Allocator.Error)!void;
const InfixParseFn = *const fn (self: *Compiler) (ChunkErrors || std.mem.Allocator.Error)!void;

const ParseRule = struct {
    prefix: ?PrefixParseFn,
    infix: ?InfixParseFn,
    precedence: Precedence,
};

const ParseRules = std.EnumArray(TokenType, ParseRule);

const Local = struct {
    name: []const u8,
    depth: usize,
};

const UINT8_COUNT = std.math.maxInt(u8) + 1;
const UINT16_MAX = std.math.maxInt(u16);
const DEBUG_PRINT_CODE = true;

pub const Compiler = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    scanner: *Scanner,
    vm: *VM,
    previous: Token = undefined,
    current: Token = undefined,
    hadError: bool = false,
    chunk: *Chunk = undefined,
    rules: ParseRules = undefined,
    locals: [UINT8_COUNT]Local = undefined,
    localCount: u8 = 0,
    scopeDepth: usize = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, scanner: *Scanner, vm: *VM) Compiler {
        var compiler = Compiler{ .io = io, .allocator = allocator, .scanner = scanner, .vm = vm };

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
        compiler.rules.set(TokenType.TOKEN_IDENTIFIER, ParseRule{ .prefix = variable, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_STRING, ParseRule{ .prefix = string, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NUMBER, ParseRule{ .prefix = number, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_AND, ParseRule{ .prefix = null, .infix = and_, .precedence = Precedence.AND });
        compiler.rules.set(TokenType.TOKEN_CLASS, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ELSE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FALSE, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FOR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_FUN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_IF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_NIL, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_OR, ParseRule{ .prefix = null, .infix = or_, .precedence = Precedence.OR });
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

    fn declaration(self: *Compiler) anyerror!void {
        if (self.match(TokenType.TOKEN_VAR)) {
            try self.varDecl();
        } else {
            try self.statement();
        }
    }

    fn statement(self: *Compiler) anyerror!void {
        if (self.match(TokenType.TOKEN_PRINT)) {
            try self.printStatement();
        } else if (self.match(TokenType.TOKEN_LEFT_BRACE)) {
            self.beginScope();
            try self.block();
            try self.endScope();
        } else if (self.match(TokenType.TOKEN_IF)) {
            try self.ifStatement();
        } else if (self.match(TokenType.TOKEN_WHILE)) {
            try self.whileStatement();
        } else if (self.match(TokenType.TOKEN_FOR)) {
            try self.forStatement();
        } else {
            try self.expressionStatement();
        }
    }

    fn beginScope(self: *Compiler) void {
        self.scopeDepth += 1;
    }

    fn endScope(self: *Compiler) !void {
        self.scopeDepth -= 1;

        // Pop all variables from this scope, as they are no longer available after scope end.
        while (self.localCount >= 1 and self.locals[self.localCount - 1].depth > self.scopeDepth) {
            try self.emitByte(@intFromEnum(OpCode.OP_POP));
            self.localCount -= 1;
        }
    }

    fn block(self: *Compiler) !void {
        while (!self.check(TokenType.TOKEN_RIGHT_BRACE)) {
            try self.declaration();
        }

        self.consume(TokenType.TOKEN_RIGHT_BRACE, "Expect '}' after block.");
    }

    fn forStatement(self: *Compiler) !void {
        self.beginScope();

        self.consume(TokenType.TOKEN_LEFT_PAREN, "Expect '(' after for.");
        if (self.match(TokenType.TOKEN_SEMICOLON)) {
            // no initializer
        } else if (self.match(TokenType.TOKEN_VAR)) {
            try self.varDecl();
        } else {
            try self.expressionStatement();
        }

        var loopStart = self.chunk.code.items.len;
        var exitJump: ?usize = null;
        if (!self.match(TokenType.TOKEN_SEMICOLON)) {
            try self.expression();
            self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';'.");

            exitJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
            try self.emitOp(OpCode.OP_POP);
        }

        if (!self.match(TokenType.TOKEN_RIGHT_PAREN)) {
            const bodyJump = try self.emitJump(OpCode.OP_JUMP);
            const incrementStart = self.chunk.code.items.len;

            try self.expression();
            try self.emitOp(OpCode.OP_POP);
            self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after for clauses.");

            try self.emitLoop(loopStart);
            loopStart = incrementStart;
            try self.patchJump(bodyJump);
        }

        try self.statement();
        try self.emitLoop(loopStart);

        if (exitJump != null) {
            try self.patchJump(exitJump.?);
            try self.emitOp(OpCode.OP_POP);
        }

        try self.endScope();
    }

    fn whileStatement(self: *Compiler) !void {
        const loopStart = self.chunk.code.items.len;

        self.consume(TokenType.TOKEN_LEFT_PAREN, "Expect '(' after while.");
        try self.expression();
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after condition.");

        const exitJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
        try self.emitOp(OpCode.OP_POP);

        try self.statement();
        try self.emitLoop(loopStart);

        try self.patchJump(exitJump);
        try self.emitOp(OpCode.OP_POP);
    }

    fn ifStatement(self: *Compiler) !void {
        self.consume(TokenType.TOKEN_LEFT_PAREN, "Expect '(' after if.");
        try self.expression();
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after condition.");

        const thenJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);

        try self.emitOp(OpCode.OP_POP);
        try self.statement();

        const elseJump = try self.emitJump(OpCode.OP_JUMP); // 0008
        try self.patchJump(thenJump);
        try self.emitOp(OpCode.OP_POP); // 0011

        if (self.match(TokenType.TOKEN_ELSE)) {
            try self.statement(); // 0012 - 0014
        }

        try self.patchJump(elseJump);
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
        try self.declareVariable();
        if (self.scopeDepth > 0) {
            return 0;
        }
        return try self.identifierConstant();
    }

    fn declareVariable(self: *Compiler) !void {
        if (self.scopeDepth == 0) return;

        const name = self.previous.lexeme;
        self.addLocal(name);
    }

    fn addLocal(self: *Compiler, name: []const u8) void {
        if (self.localCount == UINT8_COUNT) {
            self.errorAtCurrent("Too many variables in function");
            return;
        }

        if (self.localCount > 0) {
            var i: isize = self.localCount - 1;
            while (i >= 0) : (i -= 1) {
                const local = self.locals[@intCast(i)];
                if (local.depth != -1 and local.depth < self.scopeDepth) {
                    break;
                }

                if (std.mem.eql(u8, local.name, name)) {
                    self.errorAtCurrent("Already a variable with this name in this scope");
                }
            }
        }

        var local = &self.locals[self.localCount];
        local.name = name;
        local.depth = self.scopeDepth;

        self.localCount += 1;
    }

    fn identifierConstant(self: *Compiler) !u8 {
        const obj = try value_mod.copyString(self.allocator, self.vm, self.previous.lexeme);
        const constant = self.chunk.findValue(obj.data.str.chars);
        if (constant != null) {
            return constant.?;
        }

        return try self.makeConstant(value_mod.objValue(obj));
    }

    fn defineVariable(self: *Compiler, global: u8) !void {
        if (self.scopeDepth > 0) {
            return;
        }
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

    fn expression(self: *Compiler) !void {
        try self.parsePrecedence(Precedence.ASSIGNMENT);
    }

    fn parsePrecedence(self: *Compiler, precedence: Precedence) !void {
        self.advance();

        if (comptime DEBUG_PRINT_CODE) {
            std.debug.print("COMPILER > token='{s}'\n", .{@tagName(self.previous.type)});
        }

        const prefixRule = self.rules.get(self.previous.type).prefix;

        if (prefixRule == null) {
            self.errorAtCurrent("Expect expression.");
            return;
        }

        if (comptime DEBUG_PRINT_CODE) {
            std.debug.print("COMPILER > Prefix token='{s}' with precedence='{s}' until precendence='{s}'\n", .{ @tagName(self.previous.type), @tagName(precedence), @tagName(self.rules.get(self.current.type).precedence) });
        }

        const canAssign = @intFromEnum(precedence) <= @intFromEnum(Precedence.ASSIGNMENT);

        try prefixRule.?(self, canAssign);

        while (@intFromEnum(precedence) <= @intFromEnum(self.rules.get(self.current.type).precedence)) {
            self.advance();
            const infixRule = self.rules.get(self.previous.type).infix;
            if (comptime DEBUG_PRINT_CODE) {
                std.debug.print("COMPILER > Infix token='{s}'\n", .{@tagName(self.previous.type)});
            }
            try infixRule.?(self);
        }

        if (canAssign and self.match(TokenType.TOKEN_EQUAL)) {
            self.errorAtCurrent("Invalid assignment target.");
        }
    }

    fn number(self: *Compiler, _: bool) !void {
        // Panic in case we cannot parse float. The lexer should NEVER return unparseable lexemes.
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch unreachable;

        try self.emitConstant(numberValue(value));
    }

    fn literal(self: *Compiler, _: bool) !void {
        try switch (self.previous.type) {
            TokenType.TOKEN_FALSE => self.emitOp(OpCode.OP_FALSE),
            TokenType.TOKEN_TRUE => self.emitOp(OpCode.OP_TRUE),
            TokenType.TOKEN_NIL => self.emitOp(OpCode.OP_NIL),
            else => {},
        };
    }

    fn variable(self: *Compiler, canAssign: bool) !void {
        try self.namedVariable(canAssign, self.previous.lexeme);
    }

    fn namedVariable(self: *Compiler, canAssign: bool, name: []const u8) !void {
        var getOp: OpCode = OpCode.OP_GET_LOCAL;
        var setOp: OpCode = OpCode.OP_SET_LOCAL;
        var arg = self.resolveLocal(name);

        if (arg == null) {
            arg = try self.identifierConstant();
            getOp = OpCode.OP_GET_GLOBAL;
            setOp = OpCode.OP_SET_GLOBAL;
        }

        if (canAssign and self.match(TokenType.TOKEN_EQUAL)) {
            try self.expression();
            try self.emitBytes(@intFromEnum(setOp), arg.?);
        } else {
            try self.emitBytes(@intFromEnum(getOp), arg.?);
        }
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        if (self.localCount == 0) return null;
        var i: isize = self.localCount - 1;
        while (i >= 0) : (i -= 1) {
            if (std.mem.eql(u8, self.locals[@intCast(i)].name, name)) {
                return @intCast(i);
            }
        }

        return null;
    }

    fn string(self: *Compiler, _: bool) !void {
        const input = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const value = value_mod.objValue(try value_mod.copyString(self.allocator, self.vm, input));
        try self.emitConstant(value);
    }

    fn grouping(self: *Compiler, _: bool) !void {
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

    fn and_(self: *Compiler) !void {
        const endJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);

        try self.emitOp(OpCode.OP_POP);
        try self.parsePrecedence(Precedence.AND);

        try self.patchJump(endJump);
    }

    fn or_(self: *Compiler) !void {
        const elseJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
        const endJump = try self.emitJump(OpCode.OP_JUMP);

        try self.patchJump(elseJump);
        try self.emitOp(OpCode.OP_POP);

        try self.parsePrecedence(Precedence.OR);
        try self.patchJump(endJump);
    }

    fn unary(self: *Compiler, _: bool) !void {
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

    fn advance(self: *Compiler) void {
        self.previous = self.current;

        while (true) {
            self.current = self.scanner.scan();

            if (self.current.type != TokenType.TOKEN_ERROR) break;

            self.errorAtCurrent("Scanner error");
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
        if (comptime DEBUG_PRINT_CODE) {
            const op: OpCode = @enumFromInt(b1);
            std.debug.print("COMPILER > Emit op='{s}' byte='{d}'\n", .{ @tagName(op), b2 });
        }
        try self.emitByte(b1);
        try self.emitByte(b2);
    }

    fn emitLoop(self: *Compiler, loopStart: usize) !void {
        try self.emitOp(OpCode.OP_LOOP);

        const offset = self.chunk.code.items.len - loopStart + 2;
        if (offset > UINT16_MAX) self.errorAtCurrent("Loop body too large.");

        try self.emitByte(@intCast((offset >> 8) & 0xFF));
        try self.emitByte(@intCast(offset & 0xFF));
    }

    fn emitJump(self: *Compiler, op: OpCode) !usize {
        try self.emitOp(op);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.chunk.code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) !void {
        // -2 to adjust for the bytecode for the jump offset itself.
        // (this offset is already handled by the VM)
        const jump = self.chunk.code.items.len - offset - 2;

        if (jump > UINT16_MAX) {
            self.errorAtCurrent("Too much code to jump over.");
        }

        self.chunk.code.items[offset] = @intCast((jump >> 8) & 0xFF);
        self.chunk.code.items[offset + 1] = @intCast(jump & 0xFF);
    }

    fn emitOp(self: *Compiler, op: OpCode) !void {
        if (comptime DEBUG_PRINT_CODE) {
            std.debug.print("COMPILER > Emit op='{s}'\n", .{@tagName(op)});
        }
        try self.emitByte(@intFromEnum(op));
    }

    fn emitByte(self: *Compiler, b: u8) !void {
        try self.chunk.writeChunk(b, self.previous.line);
    }

    fn makeConstant(self: *Compiler, v: Value) !u8 {
        return self.chunk.addValue(v);
    }

    fn errorAtCurrent(self: *Compiler, msg: []const u8) void {
        self.errorAt(self.current, msg);
    }

    fn errorAt(self: *Compiler, token: Token, msg: []const u8) void {
        std.debug.print("[line {d}] Error", .{token.line});

        if (token.type == TokenType.TOKEN_EOF) {
            std.debug.print(" at end", .{});
        } else if (token.type == TokenType.TOKEN_ERROR) {
            // nothing.
        } else {
            std.debug.print(" at '{s}'", .{token.lexeme});
        }

        std.debug.print(": {s}\n", .{msg});
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
