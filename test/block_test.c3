<*
 Blocks are ordinary structs plus an attribute.

 `@uniform`, `@pushconstant` and `@address` decide a struct's layout, its
 storage class, and whether it takes a descriptor binding. There are no
 `uniform`, `push_constant` or `buffer` keywords - those words are ordinary
 identifiers now, and the old spellings get a migration message.
*>
module block_test;

import std::io;
import shady;

const String TAIL = `
struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = float4(0.0, 0.0, 0.0, 1.0); return o; }
`;

<*
 Compile `source` and return the diagnostic message, or "" when it compiled.
*>
fn String rejection(String source)
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(string::tformat("%s%s", source, TAIL), &diagnostic);
	if (try spirv)
	{
		free(spirv);
		return "";
	}
	return diagnostic.message;
}

fn void accepts_the_attribute_forms() @test
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(`
struct Uniforms @uniform { float4x4 mvp; }
struct Vertex @address { float4 position; }
struct Push @pushconstant { Vertex* vertices; }

Uniforms  uniforms;
Push      pc;
texture2d tex;
sampler   tex_sampler;

struct Out { float4 position @position; }

fn Out vert() @vertex
{
    Out o;
    o.position = uniforms.mvp * pc.vertices[0].position;
    return o;
}

fn float4 frag(Out input) @fragment { return tex.sample(tex_sampler, float2(0.0, 0.0)); }
`, &diagnostic);

	if (catch spirv)
	{
		io::printfn("shady error at %d:%d - %s", diagnostic.line, diagnostic.column, diagnostic.message);
		unreachable("the attribute forms should compile");
	}
	defer free(spirv);
	assert(((uint*)spirv.ptr)[0] == shady::MAGIC);
}

<*
 The words that used to be keywords are ordinary identifiers, so a member or a
 variable may be called `buffer`.
*>
fn void the_old_keywords_are_usable_as_names() @test
{
	assert(rejection(`
struct Data @address { float4 value; }
struct Push @pushconstant { Data* buffer; uint uniform; }
Push pc;
`) == "", "`buffer` and `uniform` should be usable as member names");
}

fn void rejects_the_old_keyword_spellings() @test
{
	String[3] sources = {
		"struct U { float4x4 m; }\nuniform U u;\n",
		"struct P { uint x; }\npush_constant P pc;\n",
		"buffer V { float4 p; }\n",
	};
	foreach (source : sources)
	{
		String message = rejection(source);
		assert(message.len > 0, "the old spelling should be rejected");
		assert(message.contains("not a keyword any more"), "the message should say what to write instead");
		io::printfn("shady: %s", message);
	}
}

<*
 A plain struct has no layout and no storage class, so it cannot be bound.
*>
fn void rejects_binding_a_plain_struct() @test
{
	String message = rejection("struct U { float4x4 m; }\nU u;\n");
	io::printfn("shady: %s", message);
	assert(message.contains("plain struct"), "the message should say the struct needs an attribute");
}

<*
 An `@address` struct is reached through a pointer, never bound directly.
*>
fn void rejects_binding_an_address_struct() @test
{
	String message = rejection("struct V @address { float4 p; }\nV v;\n");
	io::printfn("shady: %s", message);
	assert(message.contains("@address"), "the message should name the attribute");
}

fn void rejects_two_block_attributes() @test
{
	String message = rejection("struct U @uniform @pushconstant { float4x4 m; }\nU u;\n");
	io::printfn("shady: %s", message);
	assert(message.contains("cannot also be"), "the message should say the attributes conflict");
}

<*
 The attribute decides the layout: std140 for a uniform block, std430 for a
 push constant block and for anything behind a device address.
*>
fn void the_attribute_decides_the_layout() @test
{
	assert(shady::BlockKind.UNIFORM.layout() == shady::Layout.STD140);
	assert(shady::BlockKind.PUSH_CONSTANT.layout() == shady::Layout.STD430);
	assert(shady::BlockKind.ADDRESS.layout() == shady::Layout.STD430);
}
