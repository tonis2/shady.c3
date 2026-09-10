<*
 End to end: shady source in, SPIR-V out, in one process with no temporary
 files and no external tools.
*>
module compile_test;

import std::io;
import std::io::path;
import shady;

const String OUT_DIR = "build/shady";

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

struct Uniforms
{
    float4x4 projection;
    float4x4 view;
}

uniform Uniforms uniforms;
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

fn char[] build(String source)
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(source, &diagnostic);
	if (catch spirv)
	{
		io::printfn("shady error at %d:%d - %s", diagnostic.line, diagnostic.column, diagnostic.message);
		unreachable("the shader should compile");
	}
	return spirv;
}

fn void compiles_the_cube_shader() @test
{
	char[] spirv = build(CUBE);
	defer free(spirv);

	assert(spirv.len % 4 == 0);
	assert(((uint*)spirv.ptr)[0] == shady::MAGIC, "bad magic");

	path::mkdir(OUT_DIR, recursive: true)!!;
	file::save(string::tformat("%s/compiled.spirv", OUT_DIR), spirv)!!;

	io::printfn("shady: compiled the cube shader to %d bytes of SPIR-V", spirv.len);
}

<*
 Errors are faults with a position, not exits. This is the property that makes
 the compiler safe to run inside the app it renders for.
*>
fn void reports_unknown_names() @test
{
	shady::Diagnostic diagnostic;
	if (catch shady::compile(`
fn float4 frag(VertexIn input) @fragment
{
    return nonesuch;
}
`, &diagnostic))
	{
		io::printfn("shady: %s", diagnostic.to_string(tmem));
		assert(diagnostic.message.len > 0, "a diagnostic should be filled in");
		return;
	}
	assert(false, "an unknown name should fail");
}

fn void reports_bad_swizzle() @test
{
	shady::Diagnostic diagnostic;
	if (catch shady::compile(`
struct Out { float4 position @position; }
fn Out vert(Out input) @vertex
{
    Out output;
    output.position = input.position.xg;
    return output;
}
`, &diagnostic))
	{
		io::printfn("shady: %s", diagnostic.to_string(tmem));
		return;
	}
	assert(false, "mixing xyzw with rgba should fail");
}

fn void vertex_stage_needs_a_position() @test
{
	shady::Diagnostic diagnostic;
	if (catch shady::compile(`
struct Out { float4 color; }
fn Out vert(Out input) @vertex { Out output; output.color = input.color; return output; }
`, &diagnostic))
	{
		io::printfn("shady: %s", diagnostic.to_string(tmem));
		return;
	}
	assert(false, "a vertex stage with no @position should fail");
}
