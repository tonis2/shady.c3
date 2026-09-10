<*
 Recursive descent parser for the shady shader language (see LANGUAGE.md).

 Pure syntax: names are not resolved and types are not checked, so anything
 this rejects is a genuine syntax error. Errors are faults carrying a message
 and a position, never an exit.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

faultdef PARSE_ERROR;

struct Parser
{
	Token[]   tokens;
	usz       at;
	Allocator allocator;

	String error;
	uint   error_line;
	uint   error_column;
}

alias StmtPtrList = List{Stmt*};
alias ExprPtrList = List{Expr*};
alias DeclPtrList = List{Decl*};
alias MemberList  = List{Member};
alias ParamList   = List{Param};
alias AttrList    = List{Attribute};
alias AttrArgList = List{AttrArg};

// --- Token access ------------------------------------------------------------

fn Token Parser.peek(&self, usz ahead = 0)
{
	usz index = self.at + ahead;
	return index < self.tokens.len ? self.tokens[index] : self.tokens[self.tokens.len - 1];
}

fn bool Parser.check(&self, TokenKind kind) => self.peek().kind == kind;

fn Token Parser.advance(&self)
{
	Token token = self.peek();
	if (self.at < self.tokens.len - 1) self.at++;
	return token;
}

fn bool Parser.match(&self, TokenKind kind)
{
	if (!self.check(kind)) return false;
	self.advance();
	return true;
}

fn void Parser.fail(&self, String message)
{
	// Keep the first error: later ones are usually noise from the same cause.
	if (self.error.len) return;
	Token token       = self.peek();
	self.error        = message;
	self.error_line   = token.line;
	self.error_column = token.column;
}

fn Token? Parser.expect(&self, TokenKind kind, String message)
{
	if (!self.check(kind))
	{
		self.fail(message);
		return PARSE_ERROR~;
	}
	return self.advance();
}

// --- Node allocation ---------------------------------------------------------

fn Expr* Parser.new_expr(&self, ExprKind kind, Token token)
{
	Expr* node = alloc::new(self.allocator, Expr);
	*node = { .kind = kind, .line = token.line, .column = token.column };
	return node;
}

fn Stmt* Parser.new_stmt(&self, StmtKind kind, Token token)
{
	Stmt* node = alloc::new(self.allocator, Stmt);
	*node = { .kind = kind, .line = token.line, .column = token.column };
	return node;
}

// --- Types and attributes ----------------------------------------------------

<*
 A type reference: an identifier, optionally followed by `[n]`, optionally
 followed by `*`.

 `T*` is a buffer device address. There is no pointer arithmetic on it beyond
 indexing, and no `&` operator to make one, so a single trailing `*` is the
 whole of the pointer grammar.
*>
fn TypeRef? Parser.type_ref(&self)
{
	Token name = self.expect(IDENT, "expected a type name")!;

	TypeRef type = { .name = name.text, .line = name.line, .column = name.column };

	if (self.match(LBRACKET))
	{
		Token size = self.expect(INTEGER, "expected an array length")!;
		type.is_array   = true;
		type.array_size = (uint)size.number;
		self.expect(RBRACKET, "expected `]` after the array length")!;
	}

	if (self.match(STAR)) type.is_pointer = true;

	return type;
}

<*
 Zero or more postfix attributes: `@vertex`, `@location(0)`, `@threads(8,8,1)`.

 Attributes are postfix, as in C3 - `fn void f() @inline`, not `@inline fn`.
*>
fn Attribute[]? Parser.attributes(&self)
{
	AttrList attributes;
	attributes.init(self.allocator, 4);

	while (self.check(AT))
	{
		Token at   = self.advance();
		Token name = self.expect(IDENT, "expected an attribute name after `@`")!;

		Attribute attribute = { .name = name.text, .line = at.line, .column = at.column };

		if (self.match(LPAREN))
		{
			AttrArgList args;
			args.init(self.allocator, 4);

			if (!self.check(RPAREN))
			{
				do
				{
					Token arg = self.peek();
					switch (arg.kind)
					{
						case IDENT:
							args.push({ .is_name = true, .name = arg.text });
							self.advance();
						case INTEGER:
						case FLOAT:
							args.push({ .number = arg.number });
							self.advance();
						default:
							self.fail("expected a name or a number as an attribute argument");
							return PARSE_ERROR~;
					}
				}
				while (self.match(COMMA));
			}

			self.expect(RPAREN, "expected `)` closing the attribute arguments")!;
			attribute.args = args.array_view();
		}

		attributes.push(attribute);
	}

	return attributes.array_view();
}

// --- Expressions -------------------------------------------------------------

fn Expr*? Parser.expression(&self) => self.assignment();

fn Expr*? Parser.assignment(&self)
{
	Expr* left = self.logical_or()!;

	TokenKind op = self.peek().kind;
	switch (op)
	{
		case EQ:
		case PLUS_EQ:
		case MINUS_EQ:
		case STAR_EQ:
		case SLASH_EQ:
		case PERCENT_EQ:
			Token token = self.advance();
			// Right-associative, so recurse rather than loop.
			Expr* value = self.assignment()!;
			Expr* node  = self.new_expr(ASSIGN, token);
			node.assign = { .op = op, .target = left, .value = value };
			return node;
		default:
			return left;
	}
}

alias BinaryParseFn = fn Expr*?(Parser*);

<*
 One left-associative binary level. `kinds` are the operators at this level and
 `next` parses the tighter one, so the precedence table in LANGUAGE.md maps
 one-to-one onto the chain of calls below.
*>
fn Expr*? Parser.binary_level(&self, BinaryParseFn next, TokenKind[] kinds)
{
	Expr* left = next(self)!;

	while (true)
	{
		TokenKind op    = self.peek().kind;
		bool      found = false;
		foreach (kind : kinds) if (kind == op) { found = true; break; }
		if (!found) return left;

		Token token = self.advance();
		Expr* right = next(self)!;
		Expr* node  = self.new_expr(BINARY, token);
		node.binary = { .op = op, .left = left, .right = right };
		left = node;
	}
}

fn Expr*? Parser.logical_or(&self)  => self.binary_level(&Parser.logical_and, (TokenKind[]) { PIPE_PIPE });
fn Expr*? Parser.logical_and(&self) => self.binary_level(&Parser.equality, (TokenKind[]) { AMP_AMP });
fn Expr*? Parser.equality(&self)    => self.binary_level(&Parser.relational, (TokenKind[]) { EQ_EQ, BANG_EQ });
fn Expr*? Parser.relational(&self)  => self.binary_level(&Parser.additive, (TokenKind[]) { LT, LT_EQ, GT, GT_EQ });
fn Expr*? Parser.additive(&self)    => self.binary_level(&Parser.bitwise, (TokenKind[]) { PLUS, MINUS });

<*
 The bitwise level. `&`, `^` and `|` share a precedence, and mixing two of them
 without parentheses is rejected rather than silently grouped - the same call
 c3c makes.
*>
fn Expr*? Parser.bitwise(&self)
{
	Expr*     left  = self.shift()!;
	TokenKind first = EOF;

	while (true)
	{
		TokenKind op = self.peek().kind;
		if (op != AMP && op != CARET && op != PIPE) return left;

		if (first == EOF)
		{
			first = op;
		}
		else if (op != first)
		{
			self.fail("mixing `&`, `^` and `|` needs parentheses to say which binds first");
			return PARSE_ERROR~;
		}

		Token token = self.advance();
		Expr* right = self.shift()!;
		Expr* node  = self.new_expr(BINARY, token);
		node.binary = { .op = op, .left = left, .right = right };
		left = node;
	}
}

fn Expr*? Parser.shift(&self)          => self.binary_level(&Parser.multiplicative, (TokenKind[]) { SHL, SHR });
fn Expr*? Parser.multiplicative(&self) => self.binary_level(&Parser.unary, (TokenKind[]) { STAR, SLASH, PERCENT });

fn Expr*? Parser.unary(&self)
{
	TokenKind op = self.peek().kind;
	if (op == MINUS || op == BANG || op == PLUS)
	{
		Token token   = self.advance();
		Expr* operand = self.unary()!;
		// Unary plus is a no-op; drop it rather than carry a useless node.
		if (op == PLUS) return operand;
		Expr* node = self.new_expr(UNARY, token);
		node.unary = { .op = op, .operand = operand };
		return node;
	}
	return self.postfix();
}

fn Expr*? Parser.postfix(&self)
{
	Expr* value = self.primary()!;

	while (true)
	{
		if (self.match(DOT))
		{
			Token name = self.expect(IDENT, "expected a member or swizzle after `.`")!;
			Expr* node = self.new_expr(MEMBER, name);
			node.member = { .value = value, .name = name.text };
			value = node;
			continue;
		}

		if (self.check(LBRACKET))
		{
			Token bracket = self.advance();
			Expr* index   = self.expression()!;
			self.expect(RBRACKET, "expected `]` closing the index")!;
			Expr* node = self.new_expr(INDEX, bracket);
			node.index = { .value = value, .index = index };
			value = node;
			continue;
		}

		if (self.check(LPAREN))
		{
			Token paren = self.advance();
			ExprPtrList args;
			args.init(self.allocator, 4);

			if (!self.check(RPAREN))
			{
				do
				{
					args.push(self.expression()!);
				}
				while (self.match(COMMA));
			}
			self.expect(RPAREN, "expected `)` closing the argument list")!;

			Expr* node = self.new_expr(CALL, paren);
			node.call  = { .callee = value, .args = args.array_view() };
			value = node;
			continue;
		}

		return value;
	}
}

fn Expr*? Parser.primary(&self)
{
	Token token = self.peek();

	switch (token.kind)
	{
		case INTEGER:
			self.advance();
			Expr* node = self.new_expr(INT_LITERAL, token);
			node.literal = { .value = token.number, .is_unsigned = token.is_unsigned };
			return node;

		case FLOAT:
			self.advance();
			Expr* node = self.new_expr(FLOAT_LITERAL, token);
			node.literal = { .value = token.number };
			return node;

		case TRUE:
		case FALSE:
			self.advance();
			Expr* node = self.new_expr(BOOL_LITERAL, token);
			node.boolean = { .value = token.kind == TRUE };
			return node;

		case IDENT:
			self.advance();
			Expr* node = self.new_expr(IDENT, token);
			node.ident = { .name = token.text };
			return node;

		case LPAREN:
			self.advance();
			Expr* inner = self.expression()!;
			self.expect(RPAREN, "expected `)` closing the expression")!;
			return inner;

		default:
			self.fail("expected an expression");
			return PARSE_ERROR~;
	}
}

// --- Statements --------------------------------------------------------------

<*
 Does a statement start a local declaration rather than an expression?

 Distinguishes `float4 x = ...;` from `x = ...;`: a declaration is an
 identifier followed by another identifier, optionally with an array length
 between them.

 `T name` and `T[n] name` are unambiguous. `T* name` is not: `a * b` is also
 three tokens of that shape. The parser has no type table to settle it - it is
 a pure syntax transform - so it uses what follows instead. A declaration is
 followed by `=` or `;`, and `a * b;` as a whole statement computes a value
 nothing reads, so treating that shape as a declaration costs nothing real.
*>
fn bool Parser.at_declaration(&self)
{
	if (!self.check(IDENT)) return false;
	if (self.peek(1).kind == IDENT) return true;

	if (self.peek(1).kind == LBRACKET && self.peek(2).kind == INTEGER
		&& self.peek(3).kind == RBRACKET && self.peek(4).kind == IDENT)
	{
		return true;
	}

	if (self.peek(1).kind == STAR && self.peek(2).kind == IDENT
		&& (self.peek(3).kind == EQ || self.peek(3).kind == SEMICOLON))
	{
		return true;
	}
	return false;
}

fn Stmt*? Parser.block(&self)
{
	Token brace = self.expect(LBRACE, "expected `{`")!;

	StmtPtrList statements;
	statements.init(self.allocator, 8);

	while (!self.check(RBRACE) && !self.check(EOF))
	{
		statements.push(self.statement()!);
	}
	self.expect(RBRACE, "expected `}` closing the block")!;

	Stmt* node = self.new_stmt(BLOCK, brace);
	node.block = { .statements = statements.array_view() };
	return node;
}

fn Stmt*? Parser.statement(&self)
{
	Token token = self.peek();

	switch (token.kind)
	{
		case LBRACE:
			return self.block();

		case RETURN:
			self.advance();
			Stmt* node = self.new_stmt(RETURN, token);
			if (!self.check(SEMICOLON)) node.ret = { .value = self.expression()! };
			self.expect(SEMICOLON, "expected `;` after `return`")!;
			return node;

		case IF:
			self.advance();
			self.expect(LPAREN, "expected `(` after `if`")!;
			Expr* condition = self.expression()!;
			self.expect(RPAREN, "expected `)` after the condition")!;
			Stmt* then_branch = self.statement()!;
			Stmt* else_branch = null;
			if (self.match(ELSE)) else_branch = self.statement()!;
			Stmt* node = self.new_stmt(IF, token);
			node.if_stmt = { .condition = condition, .then_branch = then_branch, .else_branch = else_branch };
			return node;

		case WHILE:
			self.advance();
			self.expect(LPAREN, "expected `(` after `while`")!;
			Expr* condition = self.expression()!;
			self.expect(RPAREN, "expected `)` after the condition")!;
			Stmt* body = self.statement()!;
			Stmt* node = self.new_stmt(WHILE, token);
			node.while_stmt = { .condition = condition, .body = body };
			return node;

		case FOR:
			self.advance();
			self.expect(LPAREN, "expected `(` after `for`")!;

			Stmt* init = null;
			if (!self.check(SEMICOLON))
			{
				init = self.declaration_or_expression()!;
			}
			else
			{
				self.advance();
			}

			Expr* condition = null;
			if (!self.check(SEMICOLON)) condition = self.expression()!;
			self.expect(SEMICOLON, "expected `;` after the loop condition")!;

			Expr* step = null;
			if (!self.check(RPAREN)) step = self.expression()!;
			self.expect(RPAREN, "expected `)` after the loop clauses")!;

			Stmt* body = self.statement()!;
			Stmt* node = self.new_stmt(FOR, token);
			node.for_stmt = { .init = init, .condition = condition, .step = step, .body = body };
			return node;

		case BREAK:
			self.advance();
			self.expect(SEMICOLON, "expected `;` after `break`")!;
			return self.new_stmt(BREAK, token);

		case CONTINUE:
			self.advance();
			self.expect(SEMICOLON, "expected `;` after `continue`")!;
			return self.new_stmt(CONTINUE, token);

		case DISCARD:
			self.advance();
			self.expect(SEMICOLON, "expected `;` after `discard`")!;
			return self.new_stmt(DISCARD, token);

		default:
			return self.declaration_or_expression();
	}
}

<*
 A local declaration or an expression statement, both terminated by `;`.
*>
fn Stmt*? Parser.declaration_or_expression(&self)
{
	Token token = self.peek();

	if (self.at_declaration())
	{
		TypeRef type = self.type_ref()!;
		Token   name = self.expect(IDENT, "expected a variable name")!;

		Expr* value = null;
		if (self.match(EQ)) value = self.expression()!;
		self.expect(SEMICOLON, "expected `;` after the declaration")!;

		Stmt* node = self.new_stmt(DECL, token);
		node.decl  = { .type = type, .name = name.text, .value = value };
		return node;
	}

	Expr* value = self.expression()!;
	self.expect(SEMICOLON, "expected `;` after the expression")!;

	Stmt* node = self.new_stmt(EXPR, token);
	node.expr  = { .value = value };
	return node;
}

// --- Declarations ------------------------------------------------------------

fn Decl*? Parser.declaration(&self)
{
	Token token = self.peek();

	Decl* decl = alloc::new(self.allocator, Decl);
	*decl = { .line = token.line, .column = token.column };

	switch (token.kind)
	{
		case STRUCT:
		case BUFFER:
			bool is_buffer = token.kind == BUFFER;
			self.advance();
			Token name = self.expect(IDENT, is_buffer ? "expected a buffer name" : "expected a struct name")!;
			decl.kind       = DeclKind.STRUCT;
			decl.name       = name.text;
			decl.attributes = self.attributes()!;
			self.expect(LBRACE, "expected `{` opening the struct body")!;

			MemberList members;
			members.init(self.allocator, 8);
			while (!self.check(RBRACE) && !self.check(EOF))
			{
				Token   member_token = self.peek();
				TypeRef type         = self.type_ref()!;
				Token   member_name  = self.expect(IDENT, "expected a member name")!;
				Attribute[] attributes = self.attributes()!;
				self.expect(SEMICOLON, "expected `;` after the member")!;
				members.push({
					.type       = type,
					.name       = member_name.text,
					.attributes = attributes,
					.line       = member_token.line,
					.column     = member_token.column,
				});
			}
			self.expect(RBRACE, "expected `}` closing the struct body")!;
			decl.struct_decl = { .members = members.array_view(), .is_buffer = is_buffer };
			return decl;

		case FN:
			self.advance();
			TypeRef return_type = self.type_ref()!;
			Token   name        = self.expect(IDENT, "expected a function name")!;
			self.expect(LPAREN, "expected `(` after the function name")!;

			ParamList params;
			params.init(self.allocator, 4);
			if (!self.check(RPAREN))
			{
				do
				{
					Token   param_token = self.peek();
					TypeRef type        = self.type_ref()!;
					Token   param_name  = self.expect(IDENT, "expected a parameter name")!;
					Attribute[] attributes = self.attributes()!;
					params.push({
						.type       = type,
						.name       = param_name.text,
						.attributes = attributes,
						.line       = param_token.line,
						.column     = param_token.column,
					});
				}
				while (self.match(COMMA));
			}
			self.expect(RPAREN, "expected `)` closing the parameter list")!;

			decl.kind       = DeclKind.FUNCTION;
			decl.name       = name.text;
			decl.attributes = self.attributes()!;
			Stmt* body      = self.block()!;
			decl.function   = { .return_type = return_type, .params = params.array_view(), .body = body };
			return decl;

		case UNIFORM:
		case PUSH_CONSTANT:
			bool is_push_constant = token.kind == PUSH_CONSTANT;
			self.advance();
			TypeRef type = self.type_ref()!;
			Token   name = self.expect(IDENT,
				is_push_constant ? "expected a name for the push constant block" : "expected a name for the uniform")!;
			decl.kind       = DeclKind.RESOURCE;
			decl.name       = name.text;
			decl.attributes = self.attributes()!;
			decl.resource   = { .type = type, .is_uniform = !is_push_constant, .is_push_constant = is_push_constant };
			self.expect(SEMICOLON, "expected `;` after the block")!;
			return decl;

		case CONST:
			self.advance();
			TypeRef type = self.type_ref()!;
			Token   name = self.expect(IDENT, "expected a name for the constant")!;
			decl.kind       = DeclKind.CONSTANT;
			decl.name       = name.text;
			decl.attributes = self.attributes()!;
			self.expect(EQ, "a constant needs an initialiser")!;
			Expr* value = self.expression()!;
			self.expect(SEMICOLON, "expected `;` after the constant")!;
			decl.constant = { .type = type, .value = value };
			return decl;

		case IDENT:
			// The remaining form is a resource: `texture2d tex @binding(1);`
			TypeRef type = self.type_ref()!;
			Token   name = self.expect(IDENT, "expected a name for the resource")!;
			decl.kind       = DeclKind.RESOURCE;
			decl.name       = name.text;
			decl.attributes = self.attributes()!;
			decl.resource   = { .type = type, .is_uniform = false };
			self.expect(SEMICOLON, "expected `;` after the resource")!;
			return decl;

		default:
			self.fail("expected a declaration: `fn`, `struct`, `buffer`, `uniform`, `push_constant`, `const`, or a resource");
			return PARSE_ERROR~;
	}
}

// --- Entry point -------------------------------------------------------------

<*
 Parse a whole shader.

 On success the returned Ast owns an arena holding every node; free it with
 `ast.free()`. String slices point into `source`, which must outlive the Ast.

 On failure the fault carries nothing, but `parser` is filled in with a message
 and a position - pass one in to report a useful error.
*>
fn Ast? parse(String source, Parser* parser = null)
{
	Parser local;
	if (!parser) parser = &local;

	TokenList tokens = tokenize(source, mem)!;
	defer tokens.free();

	Ast ast;
	ast.arena.init(mem, 64 * 1024);
	// The arena outlives this call; on failure it is released before returning.
	bool ok = false;
	defer if (!ok) ast.arena.free();

	parser.tokens    = tokens.array_view();
	parser.at        = 0;
	parser.allocator = &ast.arena;

	DeclPtrList decls;
	decls.init(&ast.arena, 16);

	while (!parser.check(EOF))
	{
		decls.push(parser.declaration()!);
	}

	ast.decls = decls.array_view();
	ok = true;
	return ast;
}
