const std = @import("std");

const DEBUG_SCANNER = true;

pub const TokenType = enum {
    // Single-character tokens.
    TOKEN_LEFT_PAREN,
    TOKEN_RIGHT_PAREN,
    TOKEN_LEFT_BRACE,
    TOKEN_RIGHT_BRACE,
    TOKEN_COMMA,
    TOKEN_DOT,
    TOKEN_MINUS,
    TOKEN_PLUS,
    TOKEN_SEMICOLON,
    TOKEN_SLASH,
    TOKEN_STAR,
    // One or two character tokens.
    TOKEN_BANG,
    TOKEN_BANG_EQUAL,
    TOKEN_EQUAL,
    TOKEN_EQUAL_EQUAL,
    TOKEN_GREATER,
    TOKEN_GREATER_EQUAL,
    TOKEN_LESS,
    TOKEN_LESS_EQUAL,
    // Literals.
    TOKEN_IDENTIFIER,
    TOKEN_STRING,
    TOKEN_NUMBER,
    // Keywords.
    TOKEN_AND,
    TOKEN_CLASS,
    TOKEN_ELSE,
    TOKEN_FALSE,
    TOKEN_FOR,
    TOKEN_FUN,
    TOKEN_IF,
    TOKEN_NIL,
    TOKEN_OR,
    TOKEN_PRINT,
    TOKEN_RETURN,
    TOKEN_SUPER,
    TOKEN_THIS,
    TOKEN_TRUE,
    TOKEN_VAR,
    TOKEN_WHILE,

    TOKEN_ERROR,
    TOKEN_EOF,
};

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: u32,
};

pub const Scanner = struct {
    start: [*]const u8 = undefined,
    current: [*]const u8 = undefined,
    line: u32 = 1,

    pub fn init(source: [*]const u8) Scanner {
        return Scanner{
            .start = source,
            .current = source,
            .line = 1,
        };
    }

    pub fn scan(self: *Scanner) Token {
        self.skipWhitespace();

        self.start = self.current;

        if (self.atEnd()) return self.createToken(TokenType.TOKEN_EOF);

        const ch = self.advance();

        if (isAlpha(ch)) return self.identifier();
        if (isDigit(ch)) return self.number();

        return switch (ch) {
            '{' => self.createToken(TokenType.TOKEN_LEFT_BRACE),
            '}' => self.createToken(TokenType.TOKEN_RIGHT_BRACE),
            '(' => self.createToken(TokenType.TOKEN_LEFT_PAREN),
            ')' => self.createToken(TokenType.TOKEN_RIGHT_PAREN),
            ';' => self.createToken(TokenType.TOKEN_SEMICOLON),
            ',' => self.createToken(TokenType.TOKEN_COMMA),
            '.' => self.createToken(TokenType.TOKEN_DOT),
            '-' => self.createToken(TokenType.TOKEN_MINUS),
            '+' => self.createToken(TokenType.TOKEN_PLUS),
            '*' => self.createToken(TokenType.TOKEN_STAR),
            '/' => self.createToken(TokenType.TOKEN_SLASH),
            '!' => if (self.match('=')) self.createToken(TokenType.TOKEN_BANG_EQUAL) else self.createToken(TokenType.TOKEN_BANG),
            '=' => if (self.match('=')) self.createToken(TokenType.TOKEN_EQUAL_EQUAL) else self.createToken(TokenType.TOKEN_EQUAL),
            '<' => if (self.match('=')) self.createToken(TokenType.TOKEN_LESS_EQUAL) else self.createToken(TokenType.TOKEN_LESS),
            '>' => if (self.match('=')) self.createToken(TokenType.TOKEN_GREATER_EQUAL) else self.createToken(TokenType.TOKEN_GREATER),
            '"' => self.string(),
            0 => self.createToken(TokenType.TOKEN_EOF),
            else => {
                if (comptime DEBUG_SCANNER) {
                    std.debug.print("SCANNER  > Illegal character='{d}'\n", .{ch});
                }
                return self.errorToken("Illegal character.");
            },
        };
    }

    fn createToken(self: *Scanner, tokenType: TokenType) Token {
        if (comptime DEBUG_SCANNER) {
            std.debug.print("SCANNER  > Emit type='{s}' lexeme='{s}'\n", .{ @tagName(tokenType), createSlice(self.start, self.current) });
        }
        return Token{
            .type = tokenType,
            .lexeme = createSlice(self.start, self.current),
            .line = self.line,
        };
    }

    fn errorToken(self: *Scanner, msg: []const u8) Token {
        return Token{
            .type = TokenType.TOKEN_ERROR,
            .lexeme = msg,
            .line = self.line,
        };
    }

    fn skipWhitespace(self: *Scanner) void {
        while (true) {
            switch (self.peek()) {
                ' ', '\t', '\r' => self.current += 1,
                '/' => if (self.peekNext() == '/') {
                    while (self.peek() != '\n' and !self.atEnd()) _ = self.advance();
                } else {
                    break;
                },
                '\n' => {
                    self.line += 1;
                    self.current += 1;
                },
                else => break,
            }
        }
    }

    fn string(self: *Scanner) Token {
        while (self.peek() != '"' and !self.atEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }

        if (self.atEnd()) return self.errorToken("Unterminated string.");

        _ = self.advance(); // consume the closing quote.

        return self.createToken(TokenType.TOKEN_STRING);
    }

    fn identifier(self: *Scanner) Token {
        while (isDigit(self.current[0]) or isAlpha(self.current[0])) {
            _ = self.advance();
        }

        return self.createToken(self.identifierType());
    }

    fn identifierType(self: *Scanner) TokenType {
        return switch (self.start[0]) {
            'a' => return self.checkKeyword(1, 2, "nd", TokenType.TOKEN_AND),
            'c' => return self.checkKeyword(1, 4, "lass", TokenType.TOKEN_CLASS),
            'e' => return self.checkKeyword(1, 3, "lse", TokenType.TOKEN_ELSE),
            'i' => return self.checkKeyword(1, 1, "f", TokenType.TOKEN_IF),
            'n' => return self.checkKeyword(1, 2, "il", TokenType.TOKEN_NIL),
            'o' => return self.checkKeyword(1, 1, "r", TokenType.TOKEN_OR),
            'p' => return self.checkKeyword(1, 4, "rint", TokenType.TOKEN_PRINT),
            'r' => return self.checkKeyword(1, 5, "eturn", TokenType.TOKEN_RETURN),
            's' => return self.checkKeyword(1, 4, "uper", TokenType.TOKEN_SUPER),
            'v' => return self.checkKeyword(1, 2, "ar", TokenType.TOKEN_VAR),
            'w' => return self.checkKeyword(1, 4, "hile", TokenType.TOKEN_WHILE),
            't' => return self.checkKeyword(1, 3, "rue", TokenType.TOKEN_TRUE),
            'f' => return self.checkKeyword(1, 4, "alse", TokenType.TOKEN_FALSE),
            else => TokenType.TOKEN_IDENTIFIER,
        };
    }

    fn checkKeyword(self: *Scanner, start: usize, length: usize, rest: []const u8, t: TokenType) TokenType {
        if (std.mem.eql(u8, self.start[start..(start + length)], rest)) return t;
        return TokenType.TOKEN_IDENTIFIER;
    }

    fn number(self: *Scanner) Token {
        while (isDigit(self.peek())) {
            _ = self.advance();
        }

        // Optional fractional part of a number.
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance(); // consume the .
            while (isDigit(self.peek())) _ = self.advance();
        }

        return self.createToken(TokenType.TOKEN_NUMBER);
    }

    fn match(self: *Scanner, ch: u8) bool {
        if (self.atEnd()) return false;
        if (self.current[0] == ch) {
            self.current += 1;
            return true;
        }
        return false;
    }

    fn peek(self: *Scanner) u8 {
        return self.current[0];
    }

    fn peekNext(self: *Scanner) u8 {
        if (self.atEnd()) return 0;
        return self.current[1];
    }

    fn advance(self: *Scanner) u8 {
        const ch = self.current[0];
        self.current += 1;
        return ch;
    }

    fn atEnd(self: *Scanner) bool {
        return self.current[0] == 0;
    }
};

inline fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

inline fn isAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn createSlice(start: [*]const u8, end: [*]const u8) []const u8 {
    const len = @intFromPtr(end) - @intFromPtr(start);
    return start[0..len];
}

test "slice from pointers" {
    const text = "Hello, World!";
    const start: [*:0]const u8 = text.ptr;
    const end: [*:0]const u8 = text.ptr + 5; // Points to the comma

    const slice = createSlice(start, end);
    try std.testing.expectEqualStrings("Hello", slice);
}

test "test single char tokens" {
    const source = "  { (\t)   \n} ";
    var scanner = Scanner.init(source);

    const expected = [4]TokenType{
        TokenType.TOKEN_LEFT_BRACE,
        TokenType.TOKEN_LEFT_PAREN,
        TokenType.TOKEN_RIGHT_PAREN,
        TokenType.TOKEN_RIGHT_BRACE,
    };

    for (0..expected.len) |index| {
        const t = scanner.scan();
        try std.testing.expectEqual(expected[index], t.type);
    }
}

test "test all single character tokens" {
    const source = "(){},.-+;/*";
    var scanner = Scanner.init(source);

    const expected = [_]TokenType{
        TokenType.TOKEN_LEFT_PAREN,
        TokenType.TOKEN_RIGHT_PAREN,
        TokenType.TOKEN_LEFT_BRACE,
        TokenType.TOKEN_RIGHT_BRACE,
        TokenType.TOKEN_COMMA,
        TokenType.TOKEN_DOT,
        TokenType.TOKEN_MINUS,
        TokenType.TOKEN_PLUS,
        TokenType.TOKEN_SEMICOLON,
        TokenType.TOKEN_SLASH,
        TokenType.TOKEN_STAR,
    };

    for (expected) |expected_type| {
        const token = scanner.scan();
        try std.testing.expectEqual(expected_type, token.type);
    }
}

test "test two character tokens" {
    const source = "! != = == < <= > >=";
    var scanner = Scanner.init(source);

    const expected = [_]TokenType{
        TokenType.TOKEN_BANG,
        TokenType.TOKEN_BANG_EQUAL,
        TokenType.TOKEN_EQUAL,
        TokenType.TOKEN_EQUAL_EQUAL,
        TokenType.TOKEN_LESS,
        TokenType.TOKEN_LESS_EQUAL,
        TokenType.TOKEN_GREATER,
        TokenType.TOKEN_GREATER_EQUAL,
    };

    for (expected) |expected_type| {
        const token = scanner.scan();
        try std.testing.expectEqual(expected_type, token.type);
    }
}

test "test whitespace handling" {
    const source = "  \t\r\n  {  \n  }  ";
    var scanner = Scanner.init(source);

    // Should skip whitespace and only return the tokens
    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_LEFT_BRACE, token1.type);
    try std.testing.expectEqual(@as(u32, 2), token1.line); // Should be on line 2

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_RIGHT_BRACE, token2.type);
    try std.testing.expectEqual(@as(u32, 3), token2.line); // Should be on line 3
}

test "test EOF token" {
    const source = "";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_EOF, token.type);
}

test "test line tracking" {
    const source = "{\n\n}";
    var scanner = Scanner.init(source);

    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_LEFT_BRACE, token1.type);
    try std.testing.expectEqual(@as(u32, 1), token1.line);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_RIGHT_BRACE, token2.type);
    try std.testing.expectEqual(@as(u32, 3), token2.line);
}

test "test lexeme content" {
    const source = "!=";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_BANG_EQUAL, token.type);
    try std.testing.expectEqualStrings("!=", token.lexeme);
}

test "reserved identifiers" {
    const source = "if else and or class while print nil super var";
    var scanner = Scanner.init(source);

    try std.testing.expectEqual(TokenType.TOKEN_IF, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_ELSE, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_AND, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_OR, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_CLASS, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_WHILE, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_PRINT, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_NIL, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_SUPER, scanner.scan().type);
    try std.testing.expectEqual(TokenType.TOKEN_VAR, scanner.scan().type);
}

test "test error token for illegal character" {
    const source = "@";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_ERROR, token.type);
    try std.testing.expectEqualStrings("Illegal character.", token.lexeme);
}

// Tests for number literals
test "test integer numbers" {
    const source = "123 0 999";
    var scanner = Scanner.init(source);

    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token1.type);
    try std.testing.expectEqualStrings("123", token1.lexeme);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token2.type);
    try std.testing.expectEqualStrings("0", token2.lexeme);

    const token3 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token3.type);
    try std.testing.expectEqualStrings("999", token3.lexeme);
}

test "test decimal numbers" {
    const source = "123.456 0.1 999.0";
    var scanner = Scanner.init(source);

    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token1.type);
    try std.testing.expectEqualStrings("123.456", token1.lexeme);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token2.type);
    try std.testing.expectEqualStrings("0.1", token2.lexeme);

    const token3 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token3.type);
    try std.testing.expectEqualStrings("999.0", token3.lexeme);
}

test "test number followed by dot" {
    const source = "123.";
    var scanner = Scanner.init(source);

    // Should be number "123" followed by dot token
    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token1.type);
    try std.testing.expectEqualStrings("123", token1.lexeme);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_DOT, token2.type);
}

// Tests for string literals
test "test string literals" {
    const source = "\"hello\" \"world\" \"\"";
    var scanner = Scanner.init(source);

    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token1.type);
    try std.testing.expectEqualStrings("\"hello\"", token1.lexeme);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token2.type);
    try std.testing.expectEqualStrings("\"world\"", token2.lexeme);

    const token3 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token3.type);
    try std.testing.expectEqualStrings("\"\"", token3.lexeme);
}

test "test multiline string" {
    const source = "\"hello\nworld\"";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token.type);
    try std.testing.expectEqualStrings("\"hello\nworld\"", token.lexeme);
    try std.testing.expectEqual(@as(u32, 2), token.line); // Should be on line 2 after the newline
}

test "test string with special characters" {
    const source = "\"Hello,\\nWorld!\\t\"";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token.type);
    try std.testing.expectEqualStrings("\"Hello,\\nWorld!\\t\"", token.lexeme);
}

test "test unterminated string" {
    const source = "\"unterminated string";
    var scanner = Scanner.init(source);

    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_ERROR, token.type);
    try std.testing.expectEqualStrings("Unterminated string.", token.lexeme);
}

// Tests for single line comments
test "test single line comments" {
    const source = "// this is a comment\n{";
    var scanner = Scanner.init(source);

    // Comments should be ignored, so we should get the brace directly
    const token = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_LEFT_BRACE, token.type);
    try std.testing.expectEqual(@as(u32, 2), token.line); // Should be on line 2
}

test "test comment at end of file" {
    const source = "{ // comment at end";
    var scanner = Scanner.init(source);

    const token1 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_LEFT_BRACE, token1.type);

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_EOF, token2.type);
}

test "test comment with tokens before" {
    const source = "var x = 123; // assign value";
    var scanner = Scanner.init(source);

    // Skip the first two for now since identifiers aren't implemented
    _ = scanner.scan(); // skip first (var)
    _ = scanner.scan(); // skip second (x)

    const token3 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_EQUAL, token3.type);

    const token4 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token4.type);
    try std.testing.expectEqualStrings("123", token4.lexeme);

    const token5 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_SEMICOLON, token5.type);

    const token6 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_EOF, token6.type);
}

// Integration tests with numbers, strings, and comments
test "test mixed tokens with numbers and strings" {
    const source = "print \"The answer is \" + 42.0;";
    var scanner = Scanner.init(source);

    // Skip first token (print - identifier not implemented yet)
    _ = scanner.scan();

    const token2 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_STRING, token2.type);
    try std.testing.expectEqualStrings("\"The answer is \"", token2.lexeme);

    const token3 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_PLUS, token3.type);

    const token4 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_NUMBER, token4.type);
    try std.testing.expectEqualStrings("42.0", token4.lexeme);

    const token5 = scanner.scan();
    try std.testing.expectEqual(TokenType.TOKEN_SEMICOLON, token5.type);
}

test "test numbers with operators" {
    const source = "1 + 2.5 * 3 / 4 - 0.1";
    var scanner = Scanner.init(source);

    const expected_tokens = [_]struct { type: TokenType, lexeme: []const u8 }{
        .{ .type = TokenType.TOKEN_NUMBER, .lexeme = "1" },
        .{ .type = TokenType.TOKEN_PLUS, .lexeme = "+" },
        .{ .type = TokenType.TOKEN_NUMBER, .lexeme = "2.5" },
        .{ .type = TokenType.TOKEN_STAR, .lexeme = "*" },
        .{ .type = TokenType.TOKEN_NUMBER, .lexeme = "3" },
        .{ .type = TokenType.TOKEN_SLASH, .lexeme = "/" },
        .{ .type = TokenType.TOKEN_NUMBER, .lexeme = "4" },
        .{ .type = TokenType.TOKEN_MINUS, .lexeme = "-" },
        .{ .type = TokenType.TOKEN_NUMBER, .lexeme = "0.1" },
    };

    for (expected_tokens) |expected| {
        const token = scanner.scan();
        try std.testing.expectEqual(expected.type, token.type);
        try std.testing.expectEqualStrings(expected.lexeme, token.lexeme);
    }
}
