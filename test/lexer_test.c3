module lexer_test;

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
	assert(tokens[0].kind == shady::TokenKind.STRUCT, "first token should be `struct`, comment skipped");
	assert(tokens[1].kind == shady::TokenKind.IDENT && tokens[1].text == "VertexIn");
	assert(tokens[tokens.len() - 1].kind == shady::TokenKind.EOF);

	// `@set(0)` must come out as AT IDENT LPAREN INTEGER RPAREN.
	sz at = 0;
	foreach (i, token : tokens)
	{
		if (token.kind == shady::TokenKind.AT && tokens[(sz)i + 1].text == "set") { at = (sz)i; break; }
	}
	assert(at != 0, "no @set attribute found");
	assert(tokens[at + 1].kind == shady::TokenKind.IDENT);
	assert(tokens[at + 2].kind == shady::TokenKind.LPAREN);
	assert(tokens[at + 3].kind == shady::TokenKind.INTEGER);
	assert(tokens[at + 4].kind == shady::TokenKind.RPAREN);

	io::printfn("lexer: %d tokens from %d bytes of shader", tokens.len(), SHADER.len);
}

fn void lexes_numbers() @test
{
	shady::TokenList tokens = shady::tokenize("1 1.0 .5 2.5f 1e3 1.5e-2 0x7f 0b1010 1_000 7u")!!;
	defer tokens.free();

	assert(tokens[0].kind == shady::TokenKind.INTEGER && tokens[0].number == 1.0);
	assert(tokens[1].kind == shady::TokenKind.FLOAT   && tokens[1].number == 1.0);
	assert(tokens[2].kind == shady::TokenKind.FLOAT   && tokens[2].number == 0.5);
	assert(tokens[3].kind == shady::TokenKind.FLOAT   && tokens[3].number == 2.5);
	assert(tokens[4].kind == shady::TokenKind.FLOAT   && tokens[4].number == 1000.0);
	assert(tokens[5].kind == shady::TokenKind.FLOAT   && tokens[5].number > 0.0149 && tokens[5].number < 0.0151);
	assert(tokens[6].kind == shady::TokenKind.INTEGER && tokens[6].number == 127.0);
	assert(tokens[7].kind == shady::TokenKind.INTEGER && tokens[7].number == 10.0);
	assert(tokens[8].kind == shady::TokenKind.INTEGER && tokens[8].number == 1000.0);
	assert(tokens[9].kind == shady::TokenKind.INTEGER && tokens[9].is_unsigned);
}

<*
 A '.' followed by a digit only starts a fraction inside a number, never after
 a value - otherwise `v.0` or a swizzle would lex wrong.
*>
fn void dot_after_value_is_member_access() @test
{
	shady::TokenList tokens = shady::tokenize("v.xyz")!!;
	defer tokens.free();
	assert(tokens[0].kind == shady::TokenKind.IDENT && tokens[0].text == "v");
	assert(tokens[1].kind == shady::TokenKind.DOT);
	assert(tokens[2].kind == shady::TokenKind.IDENT && tokens[2].text == "xyz");
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
	foreach (i, kind : expected) assert(tokens[i].kind == kind, "operator mismatch");
}

fn void tracks_line_and_column() @test
{
	shady::TokenList tokens = shady::tokenize("fn\n  float4 x")!!;
	defer tokens.free();
	assert(tokens[0].line == 1 && tokens[0].column == 1);
	assert(tokens[1].line == 2 && tokens[1].column == 3, "second line, third column");
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
			assert(f == shady::UNEXPECTED_CHARACTER);
			assert(lexer.error_line == 1 && lexer.error_column == 17, "position of the bad character");
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
		assert(f == shady::UNTERMINATED_COMMENT);
		assert(lexer.error_line == 1 && lexer.error_column == 4, "points at the comment opener");
		return;
	}
	assert(false, "expected a fault");
}
