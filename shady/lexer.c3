<*
 Tokenizer for the shady shader language (see LANGUAGE.md).

 Tokens hold slices into the original source rather than copies, so the source
 string must outlive the token list. Errors are reported as a fault plus a
 message and position on the Lexer - never by exiting, which is the whole point
 of not shelling out to somebody else's compiler.
*>
module shady;

import std::collections::list;

enum TokenKind : char
{
	EOF,

	// Literals and names
	IDENT,
	INTEGER,
	FLOAT,

	// Keywords
	FN,
	STRUCT,
	CONST,
	RETURN,
	IF,
	ELSE,
	WHILE,
	FOR,
	BREAK,
	CONTINUE,
	DISCARD,
	TRUE,
	FALSE,
	// Reserved: parsed as keywords so using one as a name is a clear error
	// rather than a confusing syntax error later.
	IN,
	OUT,
	SWITCH,
	CASE,
	DEFAULT,
	DO,

	// Punctuation
	LPAREN,
	RPAREN,
	LBRACE,
	RBRACE,
	LBRACKET,
	RBRACKET,
	SEMICOLON,
	COMMA,
	DOT,
	AT,
	QUESTION,
	COLON,

	// Operators
	PLUS,
	MINUS,
	STAR,
	SLASH,
	PERCENT,
	PLUS_PLUS,
	MINUS_MINUS,
	PLUS_EQ,
	MINUS_EQ,
	STAR_EQ,
	SLASH_EQ,
	PERCENT_EQ,
	AMP_EQ,
	PIPE_EQ,
	CARET_EQ,
	SHL_EQ,
	SHR_EQ,
	EQ,
	EQ_EQ,
	BANG,
	BANG_EQ,
	LT,
	LT_EQ,
	GT,
	GT_EQ,
	SHL,
	SHR,
	AMP,
	PIPE,
	CARET,
	AMP_AMP,
	PIPE_PIPE,
}

struct Token
{
	TokenKind kind;
	String    text;   // slice of the source
	uint      line;   // 1-based
	uint      column; // 1-based, in bytes
	double    number; // INTEGER and FLOAT only
	bool      is_unsigned;
}

alias TokenList = List{Token};

faultdef UNTERMINATED_COMMENT, UNEXPECTED_CHARACTER, MALFORMED_NUMBER;

struct Lexer
{
	String source;
	usz    offset;
	uint   line;
	uint   column;

	// Set when a fault is returned, so the caller can report something useful.
	String error;
	uint   error_line;
	uint   error_column;
}

fn Lexer* Lexer.init(&self, String source)
{
	*self = { .source = source, .offset = 0, .line = 1, .column = 1 };
	return self;
}

fn char Lexer.peek(&self, usz ahead = 0)
{
	usz at = self.offset + ahead;
	return at < self.source.len ? self.source[at] : 0;
}

fn char Lexer.advance(&self)
{
	char c = self.source[self.offset++];
	if (c == '\n')
	{
		self.line++;
		self.column = 1;
	}
	else
	{
		self.column++;
	}
	return c;
}

fn bool is_ident_start(char c) @local => c.is_alpha() || c == '_';
fn bool is_ident_part(char c) @local => c.is_alnum() || c == '_';

fn void Lexer.fail(&self, String message)
{
	self.error        = message;
	self.error_line   = self.line;
	self.error_column = self.column;
}

<*
 Skip whitespace and comments. Block comments do not nest, matching C3.
*>
fn void? Lexer.skip_trivia(&self)
{
	while (self.offset < self.source.len)
	{
		char c = self.peek();

		if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
		{
			self.advance();
			continue;
		}

		if (c == '/' && self.peek(1) == '/')
		{
			while (self.offset < self.source.len && self.peek() != '\n') self.advance();
			continue;
		}

		if (c == '/' && self.peek(1) == '*')
		{
			uint start_line   = self.line;
			uint start_column = self.column;
			self.advance();
			self.advance();

			while (true)
			{
				if (self.offset >= self.source.len)
				{
					self.error        = "unterminated block comment";
					self.error_line   = start_line;
					self.error_column = start_column;
					return UNTERMINATED_COMMENT~;
				}
				if (self.peek() == '*' && self.peek(1) == '/')
				{
					self.advance();
					self.advance();
					break;
				}
				self.advance();
			}
			continue;
		}

		return;
	}
}

fn TokenKind keyword_kind(String word) @local
{
	switch (word)
	{
		case "fn":            return FN;
		case "struct":        return STRUCT;
		case "const":         return CONST;
		case "return":        return RETURN;
		case "if":            return IF;
		case "else":          return ELSE;
		case "while":         return WHILE;
		case "for":           return FOR;
		case "break":         return BREAK;
		case "continue":      return CONTINUE;
		case "discard":       return DISCARD;
		case "true":          return TRUE;
		case "false":         return FALSE;
		case "in":            return IN;
		case "out":           return OUT;
		case "switch":        return SWITCH;
		case "case":          return CASE;
		case "default":       return DEFAULT;
		case "do":            return DO;
		default:              return IDENT;
	}
}

<*
 A number literal. Integers may be decimal, 0x hex or 0b binary, and may use _
 as a separator. A float needs a digit before any exponent, so `1e5` is a float
 and `.5` is too, but `1.` is not.
*>
fn Token? Lexer.number(&self)
{
	usz  start        = self.offset;
	uint start_line   = self.line;
	uint start_column = self.column;

	bool is_float = false;
	uint base     = 10;

	if (self.peek() == '0' && (self.peek(1) == 'x' || self.peek(1) == 'X'))
	{
		base = 16;
		self.advance();
		self.advance();
		while (self.peek().is_xdigit() || self.peek() == '_') self.advance();
	}
	else if (self.peek() == '0' && (self.peek(1) == 'b' || self.peek(1) == 'B'))
	{
		base = 2;
		self.advance();
		self.advance();
		while (self.peek() == '0' || self.peek() == '1' || self.peek() == '_') self.advance();
	}
	else
	{
		while (self.peek().is_digit() || self.peek() == '_') self.advance();

		// A '.' only starts a fraction when a digit follows, so `v.0` stays a
		// member access and `1..2` would not lex as one number.
		if (self.peek() == '.' && self.peek(1).is_digit())
		{
			is_float = true;
			self.advance();
			while (self.peek().is_digit() || self.peek() == '_') self.advance();
		}

		if (self.peek() == 'e' || self.peek() == 'E')
		{
			char next = self.peek(1);
			if (next.is_digit() || ((next == '+' || next == '-') && self.peek(2).is_digit()))
			{
				is_float = true;
				self.advance();
				if (self.peek() == '+' || self.peek() == '-') self.advance();
				while (self.peek().is_digit()) self.advance();
			}
		}
	}

	bool is_unsigned = false;
	if (base == 10 && (self.peek() == 'f' || self.peek() == 'F'))
	{
		is_float = true;
		self.advance();
	}
	else if (!is_float && (self.peek() == 'u' || self.peek() == 'U'))
	{
		is_unsigned = true;
		self.advance();
	}

	if (is_ident_part(self.peek()))
	{
		self.fail("malformed number literal");
		return MALFORMED_NUMBER~;
	}

	String text = self.source[start..self.offset - 1];
	return (Token) {
		.kind        = is_float ? FLOAT : INTEGER,
		.text        = text,
		.line        = start_line,
		.column      = start_column,
		.number      = parse_number(text, base, is_float),
		.is_unsigned = is_unsigned,
	};
}

<*
 Parse a literal's value. Separators and the type suffix are skipped here
 rather than in the scanner, so the token keeps its original spelling.
*>
fn double parse_number(String text, uint base, bool is_float) @local
{
	double value = 0;

	if (base != 10)
	{
		foreach (i, c : text)
		{
			if (i < 2 || c == '_') continue; // skip the 0x / 0b prefix
			uint digit;
			if (c.is_digit())            { digit = (uint)(c - '0'); }
			else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a') + 10; }
			else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A') + 10; }
			else                         { continue; } // the u suffix
			value = value * base + digit;
		}
		return value;
	}

	bool   seen_dot  = false;
	double fraction  = 0.1;
	usz    exp_at    = 0;
	bool   has_exp   = false;

	foreach (i, c : text)
	{
		if (c == '_') continue;
		if (c == 'e' || c == 'E') { has_exp = true; exp_at = (usz)i + 1; break; }
		if (c == 'f' || c == 'F' || c == 'u' || c == 'U') break;
		if (c == '.') { seen_dot = true; continue; }
		if (!c.is_digit()) continue;

		if (seen_dot)
		{
			value += (double)(c - '0') * fraction;
			fraction *= 0.1;
		}
		else
		{
			value = value * 10 + (double)(c - '0');
		}
	}

	if (has_exp)
	{
		bool negative = false;
		int  exponent = 0;
		for (usz i = exp_at; i < text.len; i++)
		{
			char c = text[i];
			if (c == '+') continue;
			if (c == '-') { negative = true; continue; }
			if (!c.is_digit()) break;
			exponent = exponent * 10 + (int)(c - '0');
		}
		for (int i = 0; i < exponent; i++) value = negative ? value / 10 : value * 10;
	}

	return value;
}

<*
 Produce the next token. Returns an EOF token forever once the source runs out.
*>
fn Token? Lexer.next(&self)
{
	self.skip_trivia()!;

	uint start_line   = self.line;
	uint start_column = self.column;
	usz  start        = self.offset;

	if (self.offset >= self.source.len)
	{
		return (Token) { .kind = EOF, .text = "", .line = start_line, .column = start_column };
	}

	char c = self.peek();

	if (c.is_digit() || (c == '.' && self.peek(1).is_digit())) return self.number();

	if (is_ident_start(c))
	{
		while (is_ident_part(self.peek())) self.advance();
		String word = self.source[start..self.offset - 1];
		return (Token) { .kind = keyword_kind(word), .text = word, .line = start_line, .column = start_column };
	}

	self.advance();

	TokenKind kind;
	switch (c)
	{
		case '(': kind = LPAREN;
		case ')': kind = RPAREN;
		case '{': kind = LBRACE;
		case '}': kind = RBRACE;
		case '[': kind = LBRACKET;
		case ']': kind = RBRACKET;
		case ';': kind = SEMICOLON;
		case ',': kind = COMMA;
		case '.': kind = DOT;
		case '@': kind = AT;
		case '?': kind = QUESTION;
		case ':': kind = COLON;
		case '^': kind = self.take('=') ? CARET_EQ : CARET;
		case '+': kind = self.take('+') ? PLUS_PLUS : (self.take('=') ? PLUS_EQ : PLUS);
		case '-': kind = self.take('-') ? MINUS_MINUS : (self.take('=') ? MINUS_EQ : MINUS);
		case '*': kind = self.take('=') ? STAR_EQ : STAR;
		case '/': kind = self.take('=') ? SLASH_EQ : SLASH;
		case '%': kind = self.take('=') ? PERCENT_EQ : PERCENT;
		case '=': kind = self.take('=') ? EQ_EQ : EQ;
		case '!': kind = self.take('=') ? BANG_EQ : BANG;
		case '<':
			if (self.take('<')) { kind = self.take('=') ? SHL_EQ : SHL; }
			else { kind = self.take('=') ? LT_EQ : LT; }
		case '>':
			if (self.take('>')) { kind = self.take('=') ? SHR_EQ : SHR; }
			else { kind = self.take('=') ? GT_EQ : GT; }
		case '&': kind = self.take('&') ? AMP_AMP : (self.take('=') ? AMP_EQ : AMP);
		case '|': kind = self.take('|') ? PIPE_PIPE : (self.take('=') ? PIPE_EQ : PIPE);
		default:
			self.error        = "unexpected character";
			self.error_line   = start_line;
			self.error_column = start_column;
			return UNEXPECTED_CHARACTER~;
	}

	return (Token) {
		.kind   = kind,
		.text   = self.source[start..self.offset - 1],
		.line   = start_line,
		.column = start_column,
	};
}

fn bool Lexer.take(&self, char expected)
{
	if (self.peek() != expected) return false;
	self.advance();
	return true;
}

<*
 Tokenize a whole source string, ending with one EOF token.
*>
fn TokenList? tokenize(String source, Allocator allocator = mem)
{
	Lexer lexer;
	lexer.init(source);

	TokenList tokens;
	tokens.init(allocator, 256);

	while (true)
	{
		Token token = lexer.next()!;
		tokens.push(token);
		if (token.kind == EOF) break;
	}

	return tokens;
}
