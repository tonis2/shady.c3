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
	// A quoted file name, and nothing else: `import "lighting.shady";` is the
	// only place the language has a string. No escapes - a name has no quotes.
	STRING,

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
	INTERFACE,
	IMPORT,
	MODULE,
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

faultdef UNTERMINATED_COMMENT, UNEXPECTED_CHARACTER, MALFORMED_NUMBER, MALFORMED_DIRECTIVE, UNTERMINATED_STRING;

struct Lexer
{
	String source;
	usz    offset;
	uint   line;
	uint   column;

	// Where `#line` directives are recorded. Null is legal - a caller that only
	// wants tokens gets them skipped rather than mapped - and the map itself
	// belongs to whoever passed it in.
	LineMap* map;

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

fn void Lexer.fail_at(&self, uint line, uint column, String message)
{
	self.error        = message;
	self.error_line   = line;
	self.error_column = column;
}

fn void Lexer.fail(&self, String message)
{
	self.fail_at(self.line, self.column, message);
}

<*
 Whether only blanks stand between here and the previous newline.

 That is what makes `#line` a line directive rather than an operator nobody
 defined: a `#` in the middle of an expression is still an unexpected character.
*>
fn bool Lexer.at_line_start(&self)
{
	usz at = self.offset;
	while (at > 0 && self.source[at - 1] != '\n')
	{
		char c = self.source[at - 1];
		if (c != ' ' && c != '\t') return false;
		at--;
	}
	return true;
}

fn bool Lexer.take_text(&self, String text)
{
	for (usz i = 0; i < text.len; i++)
	{
		if (self.peek(i) != text[i]) return false;
	}
	for (usz i = 0; i < text.len; i++) self.advance();
	return true;
}

fn void Lexer.skip_blanks(&self)
{
	while (self.peek() == ' ' || self.peek() == '\t') self.advance();
}

<*
 One `#line <n> "<name>"` directive, recorded in the map when there is one.

 The directive numbers the line that *follows* it, so the offset is computed
 against the next physical line rather than the directive's own. Everything
 after the name must be blanks: a directive is generated, and one with junk on
 the end is a bug in whoever generated it, not something to guess at.
*>
fn void? Lexer.directive(&self)
{
	const String SHAPE = "malformed `#line` directive; expected `#line <number> \"<name>\"`";

	uint start_line   = self.line;
	uint start_column = self.column;

	self.advance(); // '#'
	self.skip_blanks();

	if (!self.take_text("line"))
	{
		self.fail_at(start_line, start_column,
			"only `#line` is understood - shady has no preprocessor");
		return MALFORMED_DIRECTIVE~;
	}

	if (self.peek() != ' ' && self.peek() != '\t')
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}
	self.skip_blanks();

	if (!self.peek().is_digit())
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}
	uint number = 0;
	while (self.peek().is_digit())
	{
		number = number * 10 + (uint)(self.peek() - '0');
		self.advance();
	}

	if (self.peek() != ' ' && self.peek() != '\t')
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}
	self.skip_blanks();

	if (self.peek() != '"')
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}
	self.advance();

	usz name_start = self.offset;
	while (self.peek() != '"' && self.peek() != '\n' && self.peek() != 0) self.advance();
	if (self.peek() != '"')
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}
	String name = self.source[name_start..self.offset - 1];
	self.advance(); // closing quote

	self.skip_blanks();
	// `\r` is allowed so a directive that came through a CRLF file still reads.
	if (self.offset < self.source.len && self.peek() != '\n' && self.peek() != '\r')
	{
		self.fail_at(start_line, start_column, SHAPE);
		return MALFORMED_DIRECTIVE~;
	}

	if (self.map) self.map.add(start_line, (int)number - (int)(start_line + 1), name);
}

<*
 Skip whitespace, comments and `#line` directives. Block comments do not nest,
 matching C3.
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

		// A directive owns its whole line, so it is trivia: the token after it
		// is the one the map renumbers.
		if (c == '#' && self.at_line_start())
		{
			self.directive()!;
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
		case "interface":     return INTERFACE;
		case "import":        return IMPORT;
		case "module":        return MODULE;
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
 A quoted name, for `import "file.shady";`. The token's text is what is between
 the quotes; there are no escapes, because an import names a file and a file
 name with a quote in it has no spelling on disk worth supporting.
*>
fn Token? Lexer.string(&self)
{
	uint start_line   = self.line;
	uint start_column = self.column;

	self.advance(); // the opening quote
	usz start = self.offset;
	while (self.peek() != '"' && self.peek() != '\n' && self.peek() != 0) self.advance();

	if (self.peek() != '"')
	{
		self.error        = "unterminated string";
		self.error_line   = start_line;
		self.error_column = start_column;
		return UNTERMINATED_STRING~;
	}

	String text = self.source[start..self.offset - 1];
	self.advance(); // the closing quote
	return (Token) { .kind = STRING, .text = text, .line = start_line, .column = start_column };
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

	if (c == '"') return self.string();

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

 A `#line` directive is recorded in `map` when one is passed, and skipped
 either way; see `Lexer.directive`.

 On failure the fault carries nothing, but the lexer that raised it is copied
 to `failed` when one is passed - the message and the position are what a
 caller reports, and a fault is not a value that can hold them.
*>
fn TokenList? tokenize(String source, Allocator allocator = mem, LineMap* map = null, Lexer* failed = null)
{
	Lexer lexer;
	lexer.init(source);
	lexer.map = map;

	TokenList tokens;
	tokens.init(allocator, 256);

	while (true)
	{
		Token? token = lexer.next();
		if (catch err = token)
		{
			if (failed) *failed = lexer;
			tokens.free();
			return err~;
		}
		tokens.push(token);
		if (token.kind == EOF) break;
	}

	return tokens;
}
