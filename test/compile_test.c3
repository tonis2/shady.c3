<*
 End to end: shady source in, SPIR-V out, in one process with no temporary
 files and no external tools.
*>
module compile_test;

import std::core::test;
import std::io;
import std::io::path;
import shady;
import shady_support;

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

fn void compiles_the_cube_shader() @test
{
	char[] spirv = shady_support::build(CUBE);
	defer free(spirv);

	test::@check(spirv.len % 4 == 0, "SPIR-V must be a whole number of words, got %d bytes", spirv.len);
	test::@check(((uint*)spirv.ptr)[0] == shady::MAGIC,
		"the header should start with the SPIR-V magic; got %x", ((uint*)spirv.ptr)[0]);

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
	String error = shady_support::compile_error(`
struct VertexIn   { float3 position; }
struct FragmentIn { float4 position @position; float4 color; }
fn float4 frag(FragmentIn input) @fragment
{
    return nonesuch;
}
`);

	test::@check(error.contains("unknown name `nonesuch`"),
		"the diagnostic should name the unknown identifier; got '%s'", error);
}

fn void reports_bad_swizzle() @test
{
	String error = shady_support::compile_error(`
struct Out { float4 position @position; }
fn Out vert(Out input) @vertex
{
    Out output;
    output.position = input.position.xg;
    return output;
}
`);

	test::@check(error.len > 0, "mixing xyzw with rgba should fail; got '%s'", error);
}

fn void vertex_stage_needs_a_position() @test
{
	String error = shady_support::compile_error(`
struct Out { float4 color; }
fn Out vert(Out input) @vertex { Out output; output.color = input.color; return output; }
`);

	test::@check(error.contains("position"),
		"a vertex stage with no @position should say which member is missing; got '%s'", error);
}
