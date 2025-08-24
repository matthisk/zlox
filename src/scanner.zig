const std = @import("std");

const TokenType = enum {
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

const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: u32,
};

const Scanner = struct {
    start: [*:0]const u8 = undefined,
    current: [*:0]const u8 = undefined,
    line: u32 = 1,

    fn init(self: *Scanner, source: [*:0]const u8) void {
        self.start = source;
        self.current = source;
        self.line = 1;
    }

    fn scan(self: *Scanner) Token {
        self.start = self.current;

        if (self.atEnd()) return self.createToken(TokenType.TOKEN_EOF);

        self.skipWhitespace();

        const ch = self.advance();

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
            else => self.errorToken("Illegal character."),
        };
    }

    fn createToken(self: *Scanner, tokenType: TokenType) Token {
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
                '\n' => {
                    self.line += 1;
                    self.current += 1;
                },
                else => break,
            }
        }
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

    fn advance(self: *Scanner) u8 {
        const ch = self.current[0];
        self.current += 1;
        return ch;
    }

    fn atEnd(self: *Scanner) bool {
        return self.current[0] == 0;
    }
};

fn createSlice(start: [*:0]const u8, end: [*:0]const u8) []const u8 {
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
    var scanner = Scanner{};

    scanner.init(source);

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
