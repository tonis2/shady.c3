module lexer_test;

import std::core::test;
import std::io;
import shady;

const String SHADER = `
// a shady shader
struct VertexIn
{
    float3 position;
    float4 color;
    float2 uv;
}

Uniforms uniforms;
texture2d tex @set(0) @binding(1);

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.projection * uniforms.view * float4(input.position, 1.0);
    output.color = input.color;
    return output;
}
`;

fn void lexes_a_shader() @test
{
	shady::TokenList tokens = shady::tokenize(SHADER)!!;
	defer tokens.free();

	// Spot-check the shape rather than every token.
	test::@check(tokens[0].kind == shady::TokenKind.STRUCT,
		"the first token should be `struct`, with the comment skipped; got %d", (int)tokens[0].kind);
	test::@check(tokens[1].kind == shady::TokenKind.IDENT && tokens[1].text == "VertexIn",
		"the second token should be the name VertexIn; got %d '%s'", (int)tokens[1].kind, tokens[1].text);
	test::@check(tokens[tokens.len() - 1].kind == shady::TokenKind.EOF,
		"the last token should be EOF; got %d", (int)tokens[tokens.len() - 1].kind);

	// `@set(0)` must come out as AT IDENT LPAREN INTEGER RPAREN.
	sz at = 0;
	foreach (i, token : tokens)
	{
		if (token.kind == shady::TokenKind.AT && tokens[(sz)i + 1].text == "set") { at = (sz)i; break; }
	}
	test::@check(at != 0, "no @set attribute found in %d tokens", tokens.len());
	test::@check(tokens[at + 1].kind == shady::TokenKind.IDENT, "the attribute name should be an identifier");
	test::@check(tokens[at + 2].kind == shady::TokenKind.LPAREN, "the attribute should open its arguments");
	test::@check(tokens[at + 3].kind == shady::TokenKind.INTEGER, "the attribute argument should be an integer");
	test::@check(tokens[at + 4].kind == shady::TokenKind.RPAREN, "the attribute should close its arguments");

	io::printfn("lexer: %d tokens from %d bytes of shader", tokens.len(), SHADER.len);
}

fn void lexes_numbers() @test
{
	shady::TokenList tokens = shady::tokenize("1 1.0 .5 2.5f 1e3 1.5e-2 0x7f 0b1010 1_000 7u")!!;
	defer tokens.free();

	test::@check(tokens[0].kind == shady::TokenKind.INTEGER && tokens[0].number == 1.0,
		"`1` should be an integer; got %d %f", (int)tokens[0].kind, tokens[0].number);
	test::@check(tokens[1].kind == shady::TokenKind.FLOAT && tokens[1].number == 1.0,
		"`1.0` should be a float; got %d %f", (int)tokens[1].kind, tokens[1].number);
	test::@check(tokens[2].kind == shady::TokenKind.FLOAT && tokens[2].number == 0.5,
		"`.5` should be 0.5; got %f", tokens[2].number);
	test::@check(tokens[3].kind == shady::TokenKind.FLOAT && tokens[3].number == 2.5,
		"`2.5f` should be 2.5; got %f", tokens[3].number);
	test::@check(tokens[4].kind == shady::TokenKind.FLOAT && tokens[4].number == 1000.0,
		"`1e3` should be 1000; got %f", tokens[4].number);
	test::@check(tokens[5].kind == shady::TokenKind.FLOAT && tokens[5].number > 0.0149 && tokens[5].number < 0.0151,
		"`1.5e-2` should be 0.015; got %f", tokens[5].number);
	test::@check(tokens[6].kind == shady::TokenKind.INTEGER && tokens[6].number == 127.0,
		"`0x7f` should be 127; got %f", tokens[6].number);
	test::@check(tokens[7].kind == shady::TokenKind.INTEGER && tokens[7].number == 10.0,
		"`0b1010` should be 10; got %f", tokens[7].number);
	test::@check(tokens[8].kind == shady::TokenKind.INTEGER && tokens[8].number == 1000.0,
		"`1_000` should be 1000; got %f", tokens[8].number);
	test::@check(tokens[9].kind == shady::TokenKind.INTEGER && tokens[9].is_unsigned,
		"`7u` should be an unsigned integer");
}

<*
 A '.' followed by a digit only starts a fraction inside a number, never after
 a value - otherwise `v.0` or a swizzle would lex wrong.
*>
fn void dot_after_value_is_member_access() @test
{
	shady::TokenList tokens = shady::tokenize("v.xyz")!!;
	defer tokens.free();

	test::@check(tokens[0].kind == shady::TokenKind.IDENT && tokens[0].text == "v",
		"`v` should be an identifier");
	test::@check(tokens[1].kind == shady::TokenKind.DOT, "the dot should be member access, not a fraction");
	test::@check(tokens[2].kind == shady::TokenKind.IDENT && tokens[2].text == "xyz",
		"`xyz` should be an identifier");
}

fn void lexes_operators() @test
{
	shady::TokenList tokens = shady::tokenize("+= -= *= /= == != <= >= << >> && || ! & | ^ %")!!;
	defer tokens.free();

	shady::TokenKind[] expected = {
		shady::TokenKind.PLUS_EQ, shady::TokenKind.MINUS_EQ, shady::TokenKind.STAR_EQ, shady::TokenKind.SLASH_EQ,
		shady::TokenKind.EQ_EQ, shady::TokenKind.BANG_EQ, shady::TokenKind.LT_EQ, shady::TokenKind.GT_EQ,
		shady::TokenKind.SHL, shady::TokenKind.SHR, shady::TokenKind.AMP_AMP, shady::TokenKind.PIPE_PIPE,
		shady::TokenKind.BANG, shady::TokenKind.AMP, shady::TokenKind.PIPE, shady::TokenKind.CARET,
		shady::TokenKind.PERCENT,
	};
	foreach (i, kind : expected)
	{
		test::@check(tokens[i].kind == kind, "token %d lexed as %d, expected %d",
			(int)i, (int)tokens[i].kind, (int)kind);
	}
}

fn void tracks_line_and_column() @test
{
	shady::TokenList tokens = shady::tokenize("fn\n  float4 x")!!;
	defer tokens.free();

	test::@check(tokens[0].line == 1 && tokens[0].column == 1,
		"`fn` should be at 1:1, got %d:%d", tokens[0].line, tokens[0].column);
	test::@check(tokens[1].line == 2 && tokens[1].column == 3,
		"`float4` should be at 2:3, got %d:%d", tokens[1].line, tokens[1].column);
}

fn void reports_errors_instead_of_dying() @test
{
	// The whole point of not shelling out to another compiler: a bad shader is
	// a fault, not an exit(1).
	shady::Lexer lexer;
	lexer.init("float4 x = 1.0; $");
	while (true)
	{
		if (catch f = lexer.next())
		{
			test::@check(f == shady::UNEXPECTED_CHARACTER,
				"`$` should be UNEXPECTED_CHARACTER, got %s", f);
			test::@check(lexer.error_line == 1 && lexer.error_column == 17,
				"the position should be 1:17, got %d:%d", lexer.error_line, lexer.error_column);
			io::printfn("lexer: rejected `$` at %d:%d - %s", lexer.error_line, lexer.error_column, lexer.error);
			return;
		}
	}
}

fn void reports_unterminated_comment() @test
{
	shady::Lexer lexer;
	lexer.init("fn /* never closed");
	lexer.next()!!;                     // fn
	if (catch f = lexer.next())
	{
		test::@check(f == shady::UNTERMINATED_COMMENT,
			"an open comment should be UNTERMINATED_COMMENT, got %s", f);
		test::@check(lexer.error_line == 1 && lexer.error_column == 4,
			"the position should point at the comment opener, got %d:%d",
			lexer.error_line, lexer.error_column);
		return;
	}
	test::@check(false, "an unterminated comment should be a fault");
}
