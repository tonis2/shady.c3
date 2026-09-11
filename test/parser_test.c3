module parser_test;

import std::core::test;
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

	test::@check(ast.decls.len == 8, "3 structs + 3 resources + 2 functions is 8 declarations, got %d", ast.decls.len);

	shady::Decl* vertex_in = ast.find("VertexIn");
	test::@check(vertex_in.kind == shady::DeclKind.STRUCT, "VertexIn should be a struct");
	test::@check(vertex_in.struct_decl.members.len == 3,
		"VertexIn should have three members, got %d", vertex_in.struct_decl.members.len);
	test::@check(vertex_in.struct_decl.members[0].type.name == "float3",
		"the first member should be a float3, got %s", vertex_in.struct_decl.members[0].type.name);
	test::@check(vertex_in.struct_decl.members[0].name == "position",
		"the first member should be named position, got %s", vertex_in.struct_decl.members[0].name);

	// @position must survive onto the member.
	shady::Decl* fragment_in = ast.find("FragmentIn");
	shady::Member* position  = &fragment_in.struct_decl.members[0];
	test::@check(position.attributes.find("position") != null, "@position was lost");
	test::@check(fragment_in.struct_decl.members[1].attributes.find("position") == null,
		"@position should not have spread to the next member");

	// A module-level variable is just `Type name;`. What kind of resource it
	// is comes from the type, which the parser does not resolve.
	shady::Decl* uniforms = ast.find("uniforms");
	test::@check(uniforms.kind == shady::DeclKind.RESOURCE, "uniforms should be a resource");
	test::@check(uniforms.resource.type.name == "Uniforms",
		"the resource should name the Uniforms type, got %s", uniforms.resource.type.name);

	// The block kind rides on the struct, not on the variable.
	shady::Decl* uniforms_type = ast.find("Uniforms");
	test::@check(uniforms_type.attributes.find("uniform") != null, "@uniform was lost");

	shady::Decl* tex = ast.find("tex");
	test::@check(tex.kind == shady::DeclKind.RESOURCE, "tex should be a resource");
	test::@check(tex.resource.type.name == "texture2d", "tex should be a texture2d, got %s", tex.resource.type.name);

	shady::Decl* vert = ast.find("vert");
	test::@check(vert.kind == shady::DeclKind.FUNCTION, "vert should be a function");
	test::@check(vert.attributes.find("vertex") != null, "@vertex was lost");
	test::@check(vert.function.return_type.name == "FragmentIn",
		"vert should return FragmentIn, got %s", vert.function.return_type.name);
	test::@check(vert.function.params.len == 1, "vert should take one parameter, got %d", vert.function.params.len);
	test::@check(vert.function.params[0].type.name == "VertexIn",
		"vert should take a VertexIn, got %s", vert.function.params[0].type.name);
	test::@check(vert.function.body.block.statements.len == 5,
		"1 decl + 3 assignments + return is 5 statements, got %d", vert.function.body.block.statements.len);

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

	test::@check(expr.kind == shady::ExprKind.BINARY && expr.binary.op == shady::TokenKind.STAR,
		"the outermost node should be a `*`");
	test::@check(expr.binary.left.kind == shady::ExprKind.BINARY,
		"the chain should group left: (a * b) * c");
	test::@check(expr.binary.right.kind == shady::ExprKind.IDENT && expr.binary.right.ident.name == "c",
		"the right operand should be c");
}

<*
 The two places shady's precedence departs from C, per LANGUAGE.md section 5.1.
*>
fn void bitwise_binds_tighter_than_comparison() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return a & b == c; }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	test::@check(expr.kind == shady::ExprKind.BINARY && expr.binary.op == shady::TokenKind.EQ_EQ,
		"`a & b == c` should be `(a & b) == c`, not C's `a & (b == c)`");
	test::@check(expr.binary.left.binary.op == shady::TokenKind.AMP,
		"the left side of the comparison should be the `&`");
}

fn void bitwise_binds_tighter_than_additive() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return a + b & c; }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	test::@check(expr.binary.op == shady::TokenKind.PLUS, "`a + b & c` should be `a + (b & c)`");
	test::@check(expr.binary.right.binary.op == shady::TokenKind.AMP,
		"the right operand of the `+` should be the `&`");
}

fn void mixed_bitwise_needs_parens() @test
{
	shady::Parser parser;
	if (catch f = shady::parse(`fn int f() { return a & b | c; }`, &parser))
	{
		test::@check(f == shady::PARSE_ERROR, "mixing should be PARSE_ERROR, got %s", f);
		io::printfn("parser: rejected `a & b | c` - %s", parser.error);
		free(parser.error);
		return;
	}
	test::@check(false, "mixing & and | without parens should be rejected");
}

fn void parenthesised_bitwise_is_fine() @test
{
	shady::Ast ast = shady::parse(`fn int f() { return (a & b) | c; }`)!!;
	defer ast.free();

	shady::Expr* expr = ast.find("f").function.body.block.statements[0].ret.value;
	test::@check(expr.binary.op == shady::TokenKind.PIPE, "the outermost node should be the `|`");
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
	test::@check(body.len == 4, "if, for, while and return is 4 statements, got %d", body.len);
	test::@check(body[0].kind == shady::StmtKind.IF && body[0].if_stmt.else_branch != null,
		"the first statement should be an if with an else");
	test::@check(body[1].kind == shady::StmtKind.FOR, "the second statement should be a for");
	test::@check(body[1].for_stmt.init.kind == shady::StmtKind.DECL, "`int i = 0` should be a declaration");
	test::@check(body[2].kind == shady::StmtKind.WHILE, "the third statement should be a while");
	test::@check(body[3].kind == shady::StmtKind.RETURN, "the fourth statement should be a return");
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
	test::@check(expr.kind == shady::ExprKind.CALL, "the outermost node should be a call");
	test::@check(expr.call.callee.kind == shady::ExprKind.MEMBER, "the callee should be a member access");
	test::@check(expr.call.callee.member.name == "sample", "the member should be named sample");
	test::@check(expr.call.args.len == 2, "the call should take two arguments, got %d", expr.call.args.len);
}

fn void attribute_arguments() @test
{
	shady::Ast ast = shady::parse(`texture2d shadow @set(1) @binding(2);`)!!;
	defer ast.free();

	shady::Decl* shadow = ast.find("shadow");
	shady::Attribute* set = shadow.attributes.find("set");
	test::@check(set.args.len == 1 && set.args[0].number == 1.0, "@set should carry the argument 1");
	shady::Attribute* binding = shadow.attributes.find("binding");
	test::@check(binding.args[0].number == 2.0, "@binding should carry the argument 2");
}

fn void reports_position_of_syntax_errors() @test
{
	shady::Parser parser;
	if (catch f = shady::parse("fn float4 f() { return 1.0 }", &parser))
	{
		test::@check(f == shady::PARSE_ERROR, "a missing semicolon should be PARSE_ERROR, got %s", f);
		test::@check(parser.error_line == 1, "one line of input, got line %d", parser.error_line);
		test::@check(parser.error_column == 28,
			"the error should point at the `}` where `;` should have been, got column %d", parser.error_column);
		io::printfn("parser: %d:%d - %s", parser.error_line, parser.error_column, parser.error);
		free(parser.error);
		return;
	}
	test::@check(false, "a missing semicolon should be an error");
}
