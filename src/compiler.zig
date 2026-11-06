const std = @import("std");
const config = @import("config");
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
const ObjFunction = value_mod.ObjFunction;
const UpvalueDescriptor = value_mod.UpvalueDescriptor;

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const ChunkErrors = chunk_mod.ChunkErrors;

const CompilerError = error{ ParseError, TooManyUpvalues };

const Precedence = enum { NONE, ASSIGNMENT, TERNARY, OR, AND, EQUALITY, COMPARISON, TERM, FACTOR, UNARY, CALL, PRIMARY };

const PrefixParseFn = *const fn (self: *Compiler, canAssign: bool) (ChunkErrors || std.mem.Allocator.Error)!void;
const InfixParseFn = *const fn (self: *Compiler, canAssign: bool) (ChunkErrors || std.mem.Allocator.Error)!void;

const ParseRule = struct {
    prefix: ?PrefixParseFn,
    infix: ?InfixParseFn,
    precedence: Precedence,
};

const ParseTrace = struct {
    token_type: TokenType,
    precedence: Precedence,
    line: u32,
};

const ParseTraceKind = enum { prefix, infix };

pub const FunctionType = enum { FUNCTION, SCRIPT, METHOD, INITIALIZER };

const EmitTrace = struct {
    op: OpCode,
    operand: ?u32 = null,
    line: u32,
};

const LocalTrace = struct {
    index: usize,
    name: []const u8,
    line: u32,
};

const CompilerTrace = union(enum) {
    prefix: ParseTrace,
    infix: ParseTrace,
    emit: EmitTrace,
    local: LocalTrace,

    pub fn format(self: CompilerTrace, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .prefix => |trace| {
                const token_name = @tagName(trace.token_type)["TOKEN_".len..];
                try writer.print(
                    "[compiler] line {d: >4} | prefix | {s: <13} | minimum precedence {s}\n",
                    .{ trace.line, token_name, @tagName(trace.precedence) },
                );
            },
            .infix => |trace| {
                const token_name = @tagName(trace.token_type)["TOKEN_".len..];
                try writer.print(
                    "[compiler] line {d: >4} | infix  | {s: <13} | precedence {s}\n",
                    .{ trace.line, token_name, @tagName(trace.precedence) },
                );
            },
            .emit => |trace| {
                const op_name = @tagName(trace.op)["OP_".len..];
                if (trace.operand) |operand| {
                    try writer.print(
                        "[compiler] line {d: >4} | emit   | {s: <13} | operand {d}\n",
                        .{ trace.line, op_name, operand },
                    );
                } else {
                    try writer.print(
                        "[compiler] line {d: >4} | emit   | {s}\n",
                        .{ trace.line, op_name },
                    );
                }
            },
            .local => |trace| {
                try writer.print("[compiler] line {d: >4} | local  | {s} slot={d}\n", .{ trace.line, trace.name, trace.index });
            },
        }
    }
};

const ParseRules = std.EnumArray(TokenType, ParseRule);

const Local = struct {
    name: []const u8,
    depth: ?usize,
    isCaptured: bool,
};

const ClassCompiler = struct {
    enclosing: ?*ClassCompiler = null,
    hasSuper: bool = false,
};

const LoopStart = struct {
    scopeDepth: usize = 0,
    loopStart: usize = 0,
    localCount: usize = 0,
};

const UINT8_COUNT = std.math.maxInt(u8) + 1;
const UINT16_MAX = std.math.maxInt(u16);
const DEBUG_COMPILER = config.debug_compiler;

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
    functionObject: *ObjFunction = undefined,
    type: FunctionType = undefined,
    locals: std.ArrayList(Local) = undefined,
    scopeDepth: usize = 0,
    loopStartStack: std.ArrayList(LoopStart) = .empty,
    enclosing: ?*Compiler = null,
    currentClass: ?*ClassCompiler = null,
    upvalues: [UINT8_COUNT]UpvalueDescriptor = .{UpvalueDescriptor{ .index = 0, .isLocal = false }} ** UINT8_COUNT,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, scanner: *Scanner, vm: *VM, enclosing: ?*Compiler, fnType: FunctionType) !Compiler {
        var compiler = Compiler{ .io = io, .allocator = allocator, .scanner = scanner, .vm = vm };

        compiler.type = fnType;
        if (enclosing != null) {
            compiler.enclosing = enclosing.?;
            compiler.current = enclosing.?.current;
            compiler.previous = enclosing.?.previous;
            compiler.currentClass = enclosing.?.currentClass;
        }

        const name = if (fnType != FunctionType.SCRIPT)
            compiler.previous.lexeme
        else
            "<script>";
        const nameObject = try vm.heap.copyString(name);
        try vm.pushRoot(value_mod.stringValue(nameObject));
        defer vm.popRoot();
        compiler.functionObject = try vm.heap.createFunction(nameObject);

        compiler.locals = std.ArrayList(Local).empty;
        // The first slot in the locals stack is reserved for the VM.
        try compiler.locals.append(allocator, Local{
            .name = if (fnType == .METHOD or fnType == .INITIALIZER) "this" else "",
            .depth = 0,
            .isCaptured = false,
        });

        compiler.rules = ParseRules.initUndefined();

        compiler.rules.set(TokenType.TOKEN_LEFT_PAREN, ParseRule{ .prefix = grouping, .infix = call, .precedence = Precedence.CALL });
        compiler.rules.set(TokenType.TOKEN_RIGHT_PAREN, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_LEFT_BRACE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RIGHT_BRACE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_LEFT_BRACKET, ParseRule{ .prefix = array, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_RIGHT_BRACKET, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_COMMA, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_DOT, ParseRule{ .prefix = null, .infix = dot, .precedence = Precedence.CALL });
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
        compiler.rules.set(TokenType.TOKEN_QUESTION_MARK, ParseRule{ .prefix = null, .infix = ternary, .precedence = Precedence.TERNARY });
        compiler.rules.set(TokenType.TOKEN_COLON, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
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
        compiler.rules.set(TokenType.TOKEN_SUPER, ParseRule{ .prefix = _super, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_THIS, ParseRule{ .prefix = this, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_TRUE, ParseRule{ .prefix = literal, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_VAR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_WHILE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_SWITCH, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_CASE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_DEFAULT, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_CONTINUE, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_ERROR, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });
        compiler.rules.set(TokenType.TOKEN_EOF, ParseRule{ .prefix = null, .infix = null, .precedence = Precedence.NONE });

        return compiler;
    }

    pub fn deinit(self: *Compiler) void {
        self.locals.deinit(self.allocator);
        self.loopStartStack.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler) !*ObjFunction {
        const previousCompiler = self.vm.heap.compiler;
        self.vm.heap.compiler = self;
        defer self.vm.heap.compiler = previousCompiler;

        self.advance();

        while (!self.match(TokenType.TOKEN_EOF)) {
            try self.declaration();
        }

        try self.end();

        if (self.hadError) {
            return CompilerError.ParseError;
        } else if (comptime DEBUG_COMPILER) {
            var currentObj = self.vm.heap.objects;
            while (currentObj != null) {
                if (currentObj.?.kind == .function) {
                    const func: *ObjFunction = @fieldParentPtr("obj", currentObj.?);
                    std.debug.print("\n", .{});
                    func.chunk.disassemble(func.name.chars);
                }
                currentObj = currentObj.?.next;
            }
            std.debug.print("\n", .{});
        }

        return self.functionObject;
    }

    fn declaration(self: *Compiler) anyerror!void {
        if (self.match(TokenType.TOKEN_CLASS)) {
            try self.classDeclaration();
        } else if (self.match(TokenType.TOKEN_FUN)) {
            try self.funDeclaration();
        } else if (self.match(TokenType.TOKEN_VAR)) {
            try self.varDecl();
        } else {
            try self.statement();
        }
    }

    fn classDeclaration(self: *Compiler) !void {
        self.consume(TokenType.TOKEN_IDENTIFIER, "Expect class name.");
        const className = self.previous;
        const idx = try self.identifierConstant();
        try self.declareVariable();
        try self.emitOpWithOperand(OpCode.OP_CLASS, idx);
        try self.defineVariable(idx);

        var classCompiler = ClassCompiler{ .enclosing = self.currentClass, .hasSuper = false };
        self.currentClass = &classCompiler;
        defer self.currentClass = self.currentClass.?.enclosing;

        if (self.match(TokenType.TOKEN_LESS)) {
            self.consume(TokenType.TOKEN_IDENTIFIER, "Expect super class name.");
            try self.variable(false);

            if (identifiersEqual(className.lexeme, self.previous.lexeme)) {
                self.errorAtCurrent("A class can't inherit from itself");
            }

            self.beginScope();
            try self.addLocal("super");
            try self.defineVariable(0);
            self.currentClass.?.hasSuper = true;

            try self.namedVariable(false, className.lexeme);
            try self.emitOp(OpCode.OP_INHERIT);
        }

        try self.namedVariable(false, className.lexeme);

        self.consume(TokenType.TOKEN_LEFT_BRACE, "Expect '{' before class body.");

        while (!self.check(TokenType.TOKEN_RIGHT_BRACE) and !self.check(TokenType.TOKEN_EOF)) {
            try self.method();
        }
        self.consume(TokenType.TOKEN_RIGHT_BRACE, "Expect '}' after class body.");

        try self.emitOp(OpCode.OP_POP);

        if (self.currentClass.?.hasSuper) {
            try self.endScope();
        }
    }

    fn method(self: *Compiler) !void {
        self.consume(TokenType.TOKEN_IDENTIFIER, "Expect method name.");
        const fType = if (std.mem.eql(u8, self.previous.lexeme, "init")) FunctionType.INITIALIZER else FunctionType.METHOD;
        const name = try self.identifierConstant();
        try self.function(fType);
        try self.emitOpWithOperand(OpCode.OP_METHOD, name);
    }

    fn funDeclaration(self: *Compiler) !void {
        const global = try self.parseVariable("Expect function name.");
        try self.function(FunctionType.FUNCTION);
        try self.defineVariable(global);
    }

    fn function(self: *Compiler, fType: FunctionType) !void {
        var inner = try Compiler.init(self.io, self.allocator, self.scanner, self.vm, self, fType);
        try inner._function();
        const functionObject = inner.endCompiler();
        // The upvalue descriptors live on the function object, not in the bytecode, so
        // OP_CLOSURE is a plain opcode + operand instruction. The heap's allocator owns
        // them, like the rest of the function, and `ObjFunction.destroy` frees them.
        functionObject.upvalues = try self.vm.heap.allocator.dupe(UpvalueDescriptor, inner.upvalues[0..functionObject.upvalueCount]);
        try self.emitOpWithOperand(OpCode.OP_CLOSURE, try self.makeConstant(value_mod.functionValue(functionObject)));
    }

    fn _function(self: *Compiler) !void {
        // TODO: There must be some more elegant way to supply the current compiler to the heap.
        const previousCompiler = self.vm.heap.compiler;
        self.vm.heap.compiler = self;
        defer self.vm.heap.compiler = previousCompiler;

        self.beginScope();
        self.consume(TokenType.TOKEN_LEFT_PAREN, "Expect '(' after function name.");

        if (!self.check(TokenType.TOKEN_RIGHT_PAREN)) {
            while (true) {
                self.currentFunction().arity += 1;
                if (self.currentFunction().arity > 0xFF) {
                    self.errorAtCurrent("Can't have more than 255 parameters");
                }
                const constant = try self.parseVariable("Expect parameter name.");
                try self.defineVariable(constant);

                if (!self.match(TokenType.TOKEN_COMMA)) {
                    break;
                }
            }
        }

        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after parameters.");
        self.consume(TokenType.TOKEN_LEFT_BRACE, "Expect '{' before function body.");

        try self.block();
        try self.emitReturn();
    }

    fn endCompiler(self: *Compiler) *ObjFunction {
        defer self.deinit();
        if (self.enclosing != null) {
            self.enclosing.?.current = self.current;
            self.enclosing.?.previous = self.previous;
            self.enclosing.?.hadError = self.enclosing.?.hadError or self.hadError;
        }
        return self.functionObject;
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
        } else if (self.match(TokenType.TOKEN_SWITCH)) {
            try self.switchStatement();
        } else if (self.match(TokenType.TOKEN_CONTINUE)) {
            try self.continueStatement();
        } else if (self.match(TokenType.TOKEN_RETURN)) {
            try self.returnStatement();
        } else {
            try self.expressionStatement();
        }
    }

    fn continueStatement(self: *Compiler) !void {
        if (self.loopStartStack.items.len == 0) {
            self.errorAtCurrent("Continue cannot be used outside of loop.");
        } else {
            const loopStart = self.loopStartStack.getLast();

            try self.cleanLocalsFromStack(self.loopStartStack.getLast().scopeDepth, true);

            try self.emitLoop(loopStart.loopStart);
        }
        self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';' after value.");
    }

    fn returnStatement(self: *Compiler) !void {
        if (self.type == FunctionType.SCRIPT) {
            self.errorAtCurrent("Can't return from top-level code.");
        }
        if (self.match(TokenType.TOKEN_SEMICOLON)) {
            try self.emitReturn();
        } else {
            if (self.type == .INITIALIZER) {
                self.errorAtCurrent("Can't return from class initializer.");
            }
            try self.expression();
            self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';' after value.");
            try self.emitOp(OpCode.OP_RETURN);
        }
    }

    fn beginScope(self: *Compiler) void {
        self.scopeDepth += 1;
    }

    fn endScope(self: *Compiler) !void {
        self.scopeDepth -= 1;

        try self.cleanLocalsFromStack(self.scopeDepth, false);
    }

    fn cleanLocalsFromStack(self: *Compiler, afterDepth: usize, retainLocals: bool) !void {
        var scopeStart = self.locals.items.len;

        while (self.locals.items[scopeStart - 1].depth.? > afterDepth) {
            scopeStart -= 1;
        }

        var n: u32 = 0;
        for (scopeStart..self.locals.items.len) |i| {
            const local = if (retainLocals) self.locals.items[i] else self.locals.pop().?;

            if (local.isCaptured) {
                if (n == 1) try self.emitOp(OpCode.OP_POP) else if (n > 1) try self.emitOpWithOperand(OpCode.OP_POPN, n);
                try self.emitOp(OpCode.OP_CLOSE_UPVALUE);
                n = 0;
            } else {
                n += 1;
            }
        }

        if (n == 1) try self.emitOp(OpCode.OP_POP) else if (n > 1) try self.emitOpWithOperand(OpCode.OP_POPN, n);
    }

    fn block(self: *Compiler) !void {
        while (!self.check(TokenType.TOKEN_RIGHT_BRACE) and !self.check(TokenType.TOKEN_EOF)) {
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
            try self.varDecl(); // initializer
        } else {
            try self.expressionStatement();
        }

        var loopStart = self.currentChunk().code.items.len;
        try self.loopStartStack.append(self.allocator, .{ .loopStart = loopStart, .scopeDepth = self.scopeDepth, .localCount = self.locals.items.len });
        defer _ = self.loopStartStack.pop();

        var exitJump: ?usize = null;
        if (!self.match(TokenType.TOKEN_SEMICOLON)) {
            try self.expression(); // condition
            self.consume(TokenType.TOKEN_SEMICOLON, "Expect ';'.");

            exitJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
            try self.emitOp(OpCode.OP_POP);
        }

        if (!self.match(TokenType.TOKEN_RIGHT_PAREN)) {
            const bodyJump = try self.emitJump(OpCode.OP_JUMP);
            const incrementStart = self.currentChunk().code.items.len;

            try self.expression(); // increment
            try self.emitOp(OpCode.OP_POP);
            self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after for clauses.");

            try self.emitLoop(loopStart);
            loopStart = incrementStart;
            self.loopStartStack.items[self.loopStartStack.items.len - 1].loopStart = incrementStart;
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
        const loopStart = self.currentChunk().code.items.len;
        try self.loopStartStack.append(self.allocator, .{ .loopStart = loopStart, .scopeDepth = self.scopeDepth, .localCount = self.locals.items.len });
        defer _ = self.loopStartStack.pop();

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

    fn switchStatement(self: *Compiler) !void {
        self.consume(TokenType.TOKEN_LEFT_PAREN, "Expect '(' after switch.");
        try self.expression(); // stack: [...., selector]
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after condition.");
        self.consume(TokenType.TOKEN_LEFT_BRACE, "Expect '{' to open switch clause.");

        var exitJumps = std.ArrayList(usize).empty;
        defer exitJumps.deinit(self.allocator);

        while (self.match(TokenType.TOKEN_CASE) and !self.match(TokenType.TOKEN_EOF)) {
            const exitJump = try self.caseClause();
            try exitJumps.append(self.allocator, exitJump);
        }

        // No case matched, drop the selector.
        try self.emitOp(OpCode.OP_POP);

        if (self.match(TokenType.TOKEN_DEFAULT)) {
            self.consume(TokenType.TOKEN_COLON, "Expect ':'.");
            try self.switchArmBody();
        }

        self.consume(TokenType.TOKEN_RIGHT_BRACE, "Expect '}' after switch statement.");

        for (exitJumps.items) |item| {
            try self.patchJump(item);
        }
    }

    fn caseClause(self: *Compiler) !usize {
        try self.emitOp(OpCode.OP_DUP); // [..., selector, selector]
        try self.expression(); // [..., selector, selector, expr]
        self.consume(TokenType.TOKEN_COLON, "Expect ':' after case.");
        try self.emitOp(OpCode.OP_EQUALS); // [..., selector, bool]
        const noMatchJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
        // We remove both the equals result and the selector.
        // This is safe since we don't need the selector anymore because only 1 case can match.
        try self.emitOpWithOperand(OpCode.OP_POPN, 2); // [...]
        try self.switchArmBody();
        const exitJump = try self.emitJump(OpCode.OP_JUMP);

        try self.patchJump(noMatchJump); // [..., selector, bool]
        try self.emitOp(OpCode.OP_POP); // [..., selector]
        //
        return exitJump;
    }

    fn switchArmBody(self: *Compiler) !void {
        self.beginScope();

        while (!self.atSwitchBoundary()) {
            try self.declaration();
        }

        try self.endScope();
    }

    fn atSwitchBoundary(self: *Compiler) bool {
        return self.check(TokenType.TOKEN_CASE) or self.check(TokenType.TOKEN_DEFAULT) or self.check(TokenType.TOKEN_RIGHT_BRACE) or self.check(TokenType.TOKEN_EOF);
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

    fn parseVariable(self: *Compiler, errorMessage: []const u8) !u32 {
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
        try self.addLocal(name);
    }

    fn addLocal(self: *Compiler, name: []const u8) !void {
        if (self.locals.items.len > 0) {
            var i = self.locals.items.len;
            while (i > 0) : (i -= 1) {
                const local = self.locals.items[i - 1];
                if (local.depth != null and local.depth.? < self.scopeDepth) {
                    break;
                }

                if (identifiersEqual(local.name, name)) {
                    self.errorAtCurrent("Already a variable with this name in this scope");
                }
            }
        }

        self.traceLocal(name, self.locals.items.len);
        try self.locals.append(self.allocator, Local{ .name = name, .depth = null, .isCaptured = false });
    }

    fn identifierConstant(self: *Compiler) !u32 {
        const obj = try self.vm.heap.copyString(self.previous.lexeme);
        const constant = self.currentChunk().findValue(obj.chars);
        if (constant != null) {
            return constant.?;
        }

        return try self.makeConstant(value_mod.stringValue(obj));
    }

    fn defineVariable(self: *Compiler, global: u32) !void {
        if (self.scopeDepth > 0) {
            self.locals.items[self.locals.items.len - 1].depth = self.scopeDepth;
            return;
        }
        try self.emitOpWithOperand(.OP_DEFINE_GLOBAL, global);
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

        const prefixRule = self.rules.get(self.previous.type).prefix;

        if (prefixRule == null) {
            self.errorAtCurrent("Expect expression.");
            return;
        }

        self.traceParse(.prefix, self.previous, precedence);

        const canAssign = @intFromEnum(precedence) <= @intFromEnum(Precedence.ASSIGNMENT);

        try prefixRule.?(self, canAssign);

        while (@intFromEnum(precedence) <= @intFromEnum(self.rules.get(self.current.type).precedence)) {
            self.advance();
            const infixRule = self.rules.get(self.previous.type).infix;
            self.traceParse(.infix, self.previous, self.rules.get(self.previous.type).precedence);
            try infixRule.?(self, canAssign);
        }

        if (canAssign and self.match(TokenType.TOKEN_EQUAL)) {
            self.errorAtCurrent("Invalid assignment target.");
        }
    }

    fn array(self: *Compiler, _: bool) !void {
        var len: u32 = 0;
        if (!self.check(TokenType.TOKEN_RIGHT_BRACKET)) {
            while (true) {
                try self.expression();
                len += 1;
                if (!self.match(TokenType.TOKEN_COMMA)) break;
            }
        }

        self.consume(TokenType.TOKEN_RIGHT_BRACKET, "Expect ']' after list.");

        try self.emitOpWithOperand(OpCode.OP_ARRAY, len);
    }

    fn number(self: *Compiler, _: bool) !void {
        // Panic in case we cannot parse float. The lexer should NEVER return unparseable lexemes.
        const value = std.fmt.parseFloat(f64, self.previous.lexeme) catch unreachable;

        try self.emitConstant(numberValue(value));
    }

    fn _super(self: *Compiler, _: bool) !void {
        if (self.currentClass == null) {
            self.errorAtCurrent("Can't use super outside of a class.");
        } else if (self.currentClass.?.hasSuper == false) {
            self.errorAtCurrent("Can't use super in a class with no super class.");
        }

        self.consume(TokenType.TOKEN_DOT, "Expect '.' after super.");
        self.consume(TokenType.TOKEN_IDENTIFIER, "Expect superclass method name.");
        const name = try self.identifierConstant();

        try self.namedVariable(false, "this");

        if (self.match(TokenType.TOKEN_LEFT_PAREN)) {
            const argCount = try self.argumentList();
            try self.namedVariable(false, "super");
            try self.emitOpWithOperand(OpCode.OP_SUPER_INVOKE, name);
            try self.emitByte(argCount);
        } else {
            try self.namedVariable(false, "super");
            try self.emitOpWithOperand(OpCode.OP_GET_SUPER, name);
        }
    }

    fn this(self: *Compiler, _: bool) !void {
        if (self.currentClass == null) {
            self.errorAtCurrent("Can't use 'this' outside of a class.");
            return;
        }
        try self.variable(false);
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
        // Local slots and upvalue indices are narrower than constant indices; they widen into `arg`.
        var arg: ?u32 = null;

        if (self.resolveLocal(name)) |local| {
            arg = local;
        } else {
            if (try self.resolveUpvalue(name)) |a| {
                arg = a;
                getOp = OpCode.OP_GET_UPVALUE;
                setOp = OpCode.OP_SET_UPVALUE;
            } else {
                const internedName = try self.vm.heap.copyString(name);
                arg = self.currentChunk().findValue(internedName.chars) orelse try self.makeConstant(value_mod.stringValue(internedName));
                getOp = OpCode.OP_GET_GLOBAL;
                setOp = OpCode.OP_SET_GLOBAL;
            }
        }

        const op = if (canAssign and self.match(TokenType.TOKEN_EQUAL)) op: {
            try self.expression();
            break :op setOp;
        } else getOp;

        try self.emitOpWithOperand(op, arg.?);
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u24 {
        if (self.locals.items.len == 0) return null;
        var i = self.locals.items.len;
        while (i > 0) : (i -= 1) {
            if (identifiersEqual(self.locals.items[i - 1].name, name)) {
                if (self.locals.items[i - 1].depth == null) {
                    self.errorAtCurrent("Can't read a local variable in its own initializer.");
                }
                return @intCast(i - 1);
            }
        }

        return null;
    }

    fn resolveUpvalue(self: *Compiler, name: []const u8) !?u8 {
        if (self.enclosing == null) return null;

        if (self.enclosing.?.resolveLocal(name)) |local| {
            self.enclosing.?.locals.items[local].isCaptured = true;
            return try self.addUpvalue(local, true);
        }

        if (try self.enclosing.?.resolveUpvalue(name)) |index| {
            return try self.addUpvalue(index, false);
        }

        return null;
    }

    fn addUpvalue(self: *Compiler, index: u24, isLocal: bool) !u8 {
        const upvalueCount = self.functionObject.upvalueCount;

        if (upvalueCount == UINT8_COUNT) {
            self.errorAtCurrent("Too many upvalues in closure.");
            return CompilerError.TooManyUpvalues;
        }

        for (0..upvalueCount) |i| {
            const upvalue = self.upvalues[i];
            if (upvalue.isLocal == isLocal and upvalue.index == index) return @intCast(i);
        }

        self.upvalues[upvalueCount].isLocal = isLocal;
        self.upvalues[upvalueCount].index = index;
        self.functionObject.upvalueCount += 1;
        return self.functionObject.upvalueCount - 1;
    }

    fn string(self: *Compiler, _: bool) !void {
        const input = self.previous.lexeme[1 .. self.previous.lexeme.len - 1];
        const object = try self.vm.heap.copyString(input);
        try self.emitConstant(value_mod.stringValue(object));
    }

    fn grouping(self: *Compiler, _: bool) !void {
        try self.expression();
        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after expression.");
    }

    fn call(self: *Compiler, _: bool) !void {
        const argCount = try self.argumentList();
        try self.emitOpWithOperand(OpCode.OP_CALL, argCount);
    }

    fn argumentList(self: *Compiler) !u8 {
        var argCount: u8 = 0;
        if (!self.check(TokenType.TOKEN_RIGHT_PAREN)) {
            while (true) {
                try self.expression();
                if (argCount == 255) {
                    self.errorAtCurrent("Can't have more than 255 arguments.");
                    return argCount;
                }
                argCount += 1;
                if (!self.match(TokenType.TOKEN_COMMA)) break;
            }
        }

        self.consume(TokenType.TOKEN_RIGHT_PAREN, "Expect ')' after argument list.");
        return argCount;
    }

    fn dot(self: *Compiler, canAssign: bool) !void {
        self.consume(TokenType.TOKEN_IDENTIFIER, "Expect property name after '.'.");
        const name = try self.identifierConstant();

        if (canAssign and self.match(TokenType.TOKEN_EQUAL)) {
            try self.expression();
            try self.emitOpWithOperand(OpCode.OP_SET_PROPERTY, name);
        } else if (self.match(TokenType.TOKEN_LEFT_PAREN)) {
            const argCount = try self.argumentList();
            try self.emitOpWithOperand(OpCode.OP_INVOKE, name);
            try self.emitByte(argCount);
        } else {
            try self.emitOpWithOperand(OpCode.OP_GET_PROPERTY, name);
        }
    }

    fn binary(self: *Compiler, _: bool) !void {
        const operatorType = self.previous.type;
        const rule = self.rules.get(operatorType);

        try self.parsePrecedence(nextPrecedence(rule.precedence));

        try switch (operatorType) {
            TokenType.TOKEN_PLUS => self.emitOp(OpCode.OP_ADD),
            TokenType.TOKEN_MINUS => self.emitOp(OpCode.OP_SUBTRACT),
            TokenType.TOKEN_STAR => self.emitOp(OpCode.OP_MULTIPLY),
            TokenType.TOKEN_SLASH => self.emitOp(OpCode.OP_DIVIDE),
            TokenType.TOKEN_EQUAL_EQUAL => self.emitOp(OpCode.OP_EQUALS),
            TokenType.TOKEN_BANG_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_EQUALS), @intFromEnum(OpCode.OP_NOT)),
            TokenType.TOKEN_LESS => self.emitOp(OpCode.OP_LESS),
            TokenType.TOKEN_GREATER => self.emitOp(OpCode.OP_GREATER),
            TokenType.TOKEN_LESS_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_GREATER), @intFromEnum(OpCode.OP_NOT)),
            TokenType.TOKEN_GREATER_EQUAL => self.emitBytes(@intFromEnum(OpCode.OP_LESS), @intFromEnum(OpCode.OP_NOT)),
            else => unreachable,
        };
    }

    fn ternary(self: *Compiler, _: bool) !void {
        // if
        const thenJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);
        try self.emitOp(OpCode.OP_POP);

        // then
        try self.parsePrecedence(Precedence.ASSIGNMENT);

        self.consume(TokenType.TOKEN_COLON, "Expect ':' in ternary expression.");

        const elseJump = try self.emitJump(OpCode.OP_JUMP);
        try self.patchJump(thenJump);
        try self.emitOp(OpCode.OP_POP);

        // else
        try self.parsePrecedence(Precedence.TERNARY);

        try self.patchJump(elseJump);
    }

    fn and_(self: *Compiler, _: bool) !void {
        const endJump = try self.emitJump(OpCode.OP_JUMP_IF_FALSE);

        try self.emitOp(OpCode.OP_POP);
        try self.parsePrecedence(Precedence.AND);

        try self.patchJump(endJump);
    }

    fn or_(self: *Compiler, _: bool) !void {
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
        try self.emitOp(OpCode.OP_NIL);
        try self.emitOp(OpCode.OP_RETURN);
    }

    fn emitReturn(self: *Compiler) !void {
        if (self.type == .INITIALIZER) {
            // We implicitly return the instance from a class initializer method.
            try self.emitOpWithOperand(OpCode.OP_GET_LOCAL, 0);
        } else {
            // We emit nil because that is the implicit return value in case this function doesn't return anything.
            try self.emitOp(OpCode.OP_NIL);
        }
        try self.emitOp(OpCode.OP_RETURN);
    }

    fn emitConstant(self: *Compiler, value: Value) !void {
        const index = try self.makeConstant(value);
        try self.emitOpWithOperand(.OP_CONSTANT, index);
    }

    fn emitBytes(self: *Compiler, b1: u8, b2: u8) !void {
        try self.emitOp(@enumFromInt(b1));
        try self.emitOp(@enumFromInt(b2));
    }

    fn emitLoop(self: *Compiler, loopStart: usize) !void {
        try self.emitOp(OpCode.OP_LOOP);

        const offset = self.currentChunk().code.items.len - loopStart + 2;
        if (offset > UINT16_MAX) self.errorAtCurrent("Loop body too large.");

        try self.emitByte(@intCast((offset >> 8) & 0xFF));
        try self.emitByte(@intCast(offset & 0xFF));
    }

    fn emitJump(self: *Compiler, op: OpCode) !usize {
        try self.emitOp(op);
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return self.currentChunk().code.items.len - 2;
    }

    fn patchJump(self: *Compiler, offset: usize) !void {
        // -2 to adjust for the bytecode for the jump offset itself.
        // (this offset is already handled by the VM)
        const jump = self.currentChunk().code.items.len - offset - 2;

        if (jump > UINT16_MAX) {
            self.errorAtCurrent("Too much code to jump over.");
        }

        self.currentChunk().code.items[offset] = @intCast((jump >> 8) & 0xFF);
        self.currentChunk().code.items[offset + 1] = @intCast(jump & 0xFF);
    }

    fn emitOp(self: *Compiler, op: OpCode) !void {
        self.traceEmit(op, null);
        try self.emitByte(@intFromEnum(op));
    }

    /// Emit `op` with a one-byte operand, preceded by as many OP_EXTRA_ARG prefixes
    /// as needed to hold the high bytes (high byte first). The encoding is minimal:
    /// the first prefix byte is never 0, which the VM's debug trace relies on.
    /// This is the only place that emits OP_EXTRA_ARG, so prefixes only ever
    /// precede an operand-carrying opcode.
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

    fn emitByte(self: *Compiler, b: u8) !void {
        try self.currentChunk().writeChunk(b, self.previous.line);
    }

    fn makeConstant(self: *Compiler, v: Value) !u32 {
        return self.currentChunk().addValue(v);
    }

    fn traceParse(_: *Compiler, kind: ParseTraceKind, token: Token, precedence: Precedence) void {
        if (comptime !DEBUG_COMPILER) return;

        const details = ParseTrace{
            .token_type = token.type,
            .precedence = precedence,
            .line = token.line,
        };
        const trace: CompilerTrace = switch (kind) {
            .prefix => .{ .prefix = details },
            .infix => .{ .infix = details },
        };
        std.debug.print("{f}", .{trace});
    }

    fn traceEmit(self: *Compiler, op: OpCode, operand: ?u32) void {
        if (comptime !DEBUG_COMPILER) return;

        std.debug.print("{f}", .{CompilerTrace{ .emit = .{
            .op = op,
            .operand = operand,
            .line = self.previous.line,
        } }});
    }

    fn traceLocal(self: *Compiler, name: []const u8, index: usize) void {
        if (comptime !DEBUG_COMPILER) return;

        std.debug.print("{f}", .{CompilerTrace{ .local = .{ .name = name, .line = self.previous.line, .index = index } }});
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

    fn currentFunction(self: *Compiler) *ObjFunction {
        return self.functionObject;
    }

    fn currentChunk(self: *Compiler) *Chunk {
        return &self.currentFunction().chunk;
    }
};

fn identifiersEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, a, b);
}

fn nextPrecedence(precedence: Precedence) Precedence {
    return @enumFromInt(@intFromEnum(precedence) + 1);
}

fn expectScopeCleanup(count: usize, captured: ?usize, expected: []const u8) !void {
    var scanner = Scanner.init("".ptr);
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.io, std.testing.allocator, &scanner, &vm, null, FunctionType.SCRIPT);
    defer compiler.deinit();
    compiler.previous.line = 1;
    compiler.beginScope();
    for (0..count) |i| {
        try compiler.locals.append(std.testing.allocator, .{
            .name = "",
            .depth = compiler.scopeDepth,
            .isCaptured = captured != null and captured.? == i,
        });
    }

    try compiler.endScope();

    try std.testing.expectEqualSlices(u8, expected, compiler.currentChunk().code.items);
    try std.testing.expectEqual(1, compiler.locals.items.len);
    try std.testing.expectEqual(0, compiler.scopeDepth);
}

test "scope cleanup batches uncaptured locals" {
    try expectScopeCleanup(0, null, &.{});
    try expectScopeCleanup(1, null, &.{@intFromEnum(OpCode.OP_POP)});
    try expectScopeCleanup(255, null, &.{ @intFromEnum(OpCode.OP_POPN), 255 });
    try expectScopeCleanup(256, null, &.{ @intFromEnum(OpCode.OP_EXTRA_ARG), 1, @intFromEnum(OpCode.OP_POPN), 0 });
}

test "emitOpWithOperand adds the minimal number of OP_EXTRA_ARG prefixes" {
    const X = @intFromEnum(OpCode.OP_EXTRA_ARG);
    const C = @intFromEnum(OpCode.OP_CONSTANT);
    const cases = [_]struct { operand: u32, bytes: []const u8 }{
        .{ .operand = 0xFF, .bytes = &.{ C, 0xFF } },
        .{ .operand = 0x100, .bytes = &.{ X, 0x01, C, 0x00 } },
        .{ .operand = 0xFFFF, .bytes = &.{ X, 0xFF, C, 0xFF } },
        .{ .operand = 0x10000, .bytes = &.{ X, 0x01, X, 0x00, C, 0x00 } },
        .{ .operand = 0xFFFFFF, .bytes = &.{ X, 0xFF, X, 0xFF, C, 0xFF } },
        .{ .operand = 0x1000000, .bytes = &.{ X, 0x01, X, 0x00, X, 0x00, C, 0x00 } },
        .{ .operand = 0xFFFFFFFF, .bytes = &.{ X, 0xFF, X, 0xFF, X, 0xFF, C, 0xFF } },
    };

    for (cases) |case| {
        var scanner = Scanner.init("".ptr);
        var vm = try VM.init(std.testing.io, std.testing.allocator);
        defer vm.deinit();
        var compiler = try Compiler.init(std.testing.io, std.testing.allocator, &scanner, &vm, null, FunctionType.SCRIPT);
        defer compiler.deinit();
        compiler.previous.line = 1;

        try compiler.emitOpWithOperand(OpCode.OP_CONSTANT, case.operand);

        const chunk = compiler.currentChunk();
        try std.testing.expectEqualSlices(u8, case.bytes, chunk.code.items);
        const d = chunk.decode(0);
        try std.testing.expectEqual(OpCode.OP_CONSTANT, d.op);
        try std.testing.expectEqual(case.operand, d.operand);
    }
}

test "scope cleanup closes captured locals in stack order" {
    try expectScopeCleanup(1, 0, &.{@intFromEnum(OpCode.OP_CLOSE_UPVALUE)});
    try expectScopeCleanup(3, 1, &.{
        @intFromEnum(OpCode.OP_POP),
        @intFromEnum(OpCode.OP_CLOSE_UPVALUE),
        @intFromEnum(OpCode.OP_POP),
    });
}

test "compiler trace is compact and readable" {
    try std.testing.expectFmt(
        "[compiler] line    2 | prefix | NUMBER        | minimum precedence ASSIGNMENT\n",
        "{f}",
        .{CompilerTrace{ .prefix = .{
            .token_type = TokenType.TOKEN_NUMBER,
            .precedence = Precedence.ASSIGNMENT,
            .line = 2,
        } }},
    );
    try std.testing.expectFmt(
        "[compiler] line    2 | infix  | PLUS          | precedence TERM\n",
        "{f}",
        .{CompilerTrace{ .infix = .{
            .token_type = TokenType.TOKEN_PLUS,
            .precedence = Precedence.TERM,
            .line = 2,
        } }},
    );
    try std.testing.expectFmt(
        "[compiler] line    2 | emit   | CONSTANT      | operand 7\n",
        "{f}",
        .{CompilerTrace{ .emit = .{
            .op = OpCode.OP_CONSTANT,
            .operand = 7,
            .line = 2,
        } }},
    );
    try std.testing.expectFmt(
        "[compiler] line    2 | emit   | ADD\n",
        "{f}",
        .{CompilerTrace{ .emit = .{
            .op = OpCode.OP_ADD,
            .line = 2,
        } }},
    );
}
