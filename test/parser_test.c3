module parser_test;

import std::io;
import shady;

<*
 Turn a parse failure into a readable test failure rather than a bare fault.
*>
fn shady::Ast report(shady::Parser* parser)
{
	io::printfn("parse error at %d:%d - %s", parser.error_line, parser.error_column, parser.error);
	unreachable("the shader should parse");
}

<*
 The cube shader, in shady rather than Kongruent syntax. This is the target the
 whole compiler is aimed at, so the parser is checked against it directly.
*>
const String CUBE = `
struct VertexIn
{
    float3 position;
    float4 color;
    float2 uv;
}

struct FragmentIn
{
    float4 position @position;
    float4 color;
    float2 uv;
}

struct Uniforms @uniform {
    float4x4 projection;
    float4x4 view;
}

Uniforms uniforms;
texture2d tex;
sampler tex_sampler;

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.projection * uniforms.view * float4(input.position, 1.0);
    output.color = input.color;
    output.uv = input.uv;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    return tex.sample(tex_sampler, input.uv) * input.color;
}
`;

fn void parses_the_cube_shader() @test
{
	shady::Parser parser;
	shady::Ast ast = shady::parse(CUBE, &parser) ?? report(&parser);
	defer ast.free();

	assert(ast.decls.len == 8, "3 structs + 3 resources + 2 functions");

	shady::Decl* vertex_in = ast.find("VertexIn");
	assert(vertex_in.kind == shady::DeclKind.STRUCT);
	assert(vertex_in.struct_decl.members.len == 3);
	assert(vertex_in.struct_decl.members[0].type.name == "float3");
	assert(vertex_in.struct_decl.members[0].name == "position");

	// @position must survive onto the member.
	shady::Decl* fragment_in = ast.find("FragmentIn");
	shady::Member* position  = &fragment_in.struct_decl.members[0];
	assert(position.attributes.find("position") != null, "@position lost");
	assert(fragment_in.struct_decl.members[1].attributes.find("position") == null);

	// A module-level variable is just `Type name;`. What kind of resource it
	// is comes from the type, which the parser does not resolve.
	shady::Decl* uniforms = ast.find("uniforms");
	assert(uniforms.kind == shady::DeclKind.RESOURCE);
	assert(uniforms.resource.type.name == "Uniforms");

	// The block kind rides on the struct, not on the variable.
	shady::Decl* uniforms_type = ast.find("Uniforms");
	assert(uniforms_type.attributes.find("uniform") != null, "@uniform lost");

	shady::Decl* tex = ast.find("tex");
	assert(tex.kind == shady::DeclKind.RESOURCE);
	assert(tex.resource.type.name == "texture2d");

	shady::Decl* vert = ast.find("vert");
	assert(vert.kind == shady::DeclKind.FUNCTION);
	assert(vert.attributes.find("vertex") != null, "@vertex lost");
	assert(vert.function.return_type.name == "FragmentIn");
	assert(vert.function.params.len == 1);
	assert(vert.function.params[0].type.name == "VertexIn");
	assert(vert.function.body.block.statements.len == 5, "1 decl + 3 assignments + return");

	io::printfn("parser: %d declarations from %d bytes", ast.decls.len, CUBE.len);
}

<*
 `a * b * c` must group left, and `p * v * x` must therefore apply v first -
 the convention the emitter and the host matrices both assume.
*>
fn void matrix_chain_groups_left() @test
{
	shady::Ast ast = shady::parse(`fn float4 f() { return a * b * c; }`)!!;
	defer ast.free();

	shady::Stmt* ret  = ast.find("f").function.body.block.statements[0];
	shady::Expr* expr = ret.ret.value;

	assert(expr.kind == shady::ExprKind.BINARY && expr.binary.op == shady::TokenKind.STAR);
	assert(expr.binary.left.kind == shady::ExprKind.BINARY, "left-associative: (a * b) * c");
	assert(expr.binary.right.kind == shady::ExprKind.IDENT && expr.binary.right.ident.name == "c");
}

<*
 The two places shady's precedence departs from C, per LANGUAGE.md section 5.1.
*>
fn void bitwise_binds_tighter_than_comparison() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return a & b == c; }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	assert(expr.kind == shady::ExprKind.BINARY && expr.binary.op == shady::TokenKind.EQ_EQ,
		"`a & b == c` is `(a & b) == c`, not C's `a & (b == c)`");
	assert(expr.binary.left.binary.op == shady::TokenKind.AMP);
}

fn void bitwise_binds_tighter_than_additive() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return a + b & c; }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	assert(expr.binary.op == shady::TokenKind.PLUS, "`a + b & c` is `a + (b & c)`");
	assert(expr.binary.right.binary.op == shady::TokenKind.AMP);
}

fn void mixed_bitwise_needs_parens() @test
{
	shady::Parser parser;
	if (catch f = shady::parse(`fn int f() { return a & b | c; }`, &parser))
	{
		assert(f == shady::PARSE_ERROR);
		io::printfn("parser: rejected `a & b | c` - %s", parser.error);
		return;
	}
	assert(false, "mixing & and | without parens should be rejected");
}

fn void parenthesised_bitwise_is_fine() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return (a & b) | c; }`)!!;
	defer ast.free();
	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	assert(expr.binary.op == shady::TokenKind.PIPE);
}

fn void parses_control_flow() @test
{
	shady::Ast ast = shady::parse(`
fn float4 f(float4 c) @fragment
{
    if (c.a < 0.5) { discard; } else { c.a = 1.0; }
    for (int i = 0; i < 4; i += 1) { c.r += 0.1; }
    while (c.g > 1.0) { c.g -= 1.0; }
    return c;
}
`)!!;
	defer ast.free();

	shady::Stmt*[] body = ast.find("f").function.body.block.statements;
	assert(body.len == 4);
	assert(body[0].kind == shady::StmtKind.IF && body[0].if_stmt.else_branch != null);
	assert(body[1].kind == shady::StmtKind.FOR);
	assert(body[1].for_stmt.init.kind == shady::StmtKind.DECL, "`int i = 0` is a declaration");
	assert(body[2].kind == shady::StmtKind.WHILE);
	assert(body[3].kind == shady::StmtKind.RETURN);
}

<*
 A method call is a CALL whose callee is a MEMBER, so `tex.sample(...)` needs
 no special case in the grammar.
*>
fn void method_call_is_call_of_member() @test
{
	shady::Ast ast = shady::parse(`fn float4 f() { return tex.sample(s, uv); }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	assert(expr.kind == shady::ExprKind.CALL);
	assert(expr.call.callee.kind == shady::ExprKind.MEMBER);
	assert(expr.call.callee.member.name == "sample");
	assert(expr.call.args.len == 2);
}

fn void attribute_arguments() @test
{
	shady::Ast ast = shady::parse(`texture2d shadow @set(1) @binding(2);`)!!;
	defer ast.free();

	shady::Decl* shadow = ast.find("shadow");
	shady::Attribute* set = shadow.attributes.find("set");
	assert(set.args.len == 1 && set.args[0].number == 1.0);
	shady::Attribute* binding = shadow.attributes.find("binding");
	assert(binding.args[0].number == 2.0);
}

fn void reports_position_of_syntax_errors() @test
{
	shady::Parser parser;
	if (catch f = shady::parse("fn float4 f() { return 1.0 }", &parser))
	{
		assert(f == shady::PARSE_ERROR);
		assert(parser.error_line == 1, "one line of input");
		assert(parser.error_column == 28, "points at the `}` where `;` should have been");
		io::printfn("parser: %d:%d - %s", parser.error_line, parser.error_column, parser.error);
		return;
	}
	assert(false, "missing semicolon should be an error");
}
