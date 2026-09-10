<*
 One module, many entry points.

 A shader file may hold as many stages as it likes, of any kind, and the host
 picks between them by name through `pName` in
 VkPipelineShaderStageCreateInfo. The name is the function's own unless the
 stage attribute gives one: `@fragment(main)`.
*>
module entry_point_test;

import std::io;
import shady;

const String VARIANTS = `
struct Uniforms @uniform { float4x4 mvp; }
Uniforms  uniforms;
texture2d tex;
sampler   samp;

struct VertexIn   { float3 position; float2 uv; }
struct FragmentIn { float4 position @position; float2 uv; }

fn FragmentIn stage_in(VertexIn input) @vertex(main)
{
    FragmentIn o;
    o.position = uniforms.mvp * float4(input.position, 1.0);
    o.uv       = input.uv;
    return o;
}

fn FragmentIn stage_in_shadow(VertexIn input) @vertex
{
    FragmentIn o;
    o.position = float4(input.position, 1.0);
    o.uv       = input.uv;
    return o;
}

fn float4 shade_textured(FragmentIn input) @fragment(opaque)
{
    return tex.sample(samp, input.uv);
}

fn float4 shade_solid(FragmentIn input) @fragment
{
    return float4(1.0, 0.0, 0.0, 1.0);
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

fn String rejection(String source)
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(source, &diagnostic);
	if (try spirv)
	{
		free(spirv);
		return "";
	}
	return diagnostic.message;
}

<*
 Four entry points, two of each stage, in one module.
*>
fn void one_module_holds_many_stages() @test
{
	char[] spirv = build(VARIANTS);
	defer free(spirv);

	file::save("build/shady/variants.spirv", spirv)!!;
	io::printfn("shady: 4 entry points in %d bytes of SPIR-V", spirv.len);
}

<*
 The stage attribute's argument becomes the published name; without one the
 function's own name is used.
*>
fn void the_attribute_argument_names_the_entry_point() @test
{
	char[] spirv = build(VARIANTS);
	defer free(spirv);

	// OpEntryPoint carries the name as an inline UTF-8 literal, so it is in
	// the words verbatim. Searching the bytes avoids a disassembler here.
	String words = (String)spirv;
	assert(words.contains("main"), "@vertex(main) should publish `main`");
	assert(words.contains("opaque"), "@fragment(opaque) should publish `opaque`");
	assert(words.contains("stage_in_shadow"), "a bare @vertex should publish the function name");
	assert(words.contains("shade_solid"), "a bare @fragment should publish the function name");

	// The function keeps its own name for debug info, separately from the
	// name the entry point is published under.
	assert(words.contains("stage_in"), "OpName should keep the function's name");
}

<*
 The host tells entry points apart by name, so two of them may not share one.
*>
fn void rejects_a_duplicate_entry_point_name() @test
{
	String message = rejection(`
struct VertexIn   { float3 position; }
struct FragmentIn { float4 position @position; }
fn FragmentIn v(VertexIn i) @vertex { FragmentIn o; o.position = float4(i.position, 1.0); return o; }
fn float4 a(FragmentIn i) @fragment(shade) { return float4(1.0, 1.0, 1.0, 1.0); }
fn float4 b(FragmentIn i) @fragment(shade) { return float4(0.0, 0.0, 0.0, 1.0); }
`);
	io::printfn("shady: %s", message);
	assert(message.contains("already an entry point"), "the message should say the name is taken");
}

fn void rejects_a_stage_argument_that_is_not_a_name() @test
{
	String message = rejection(`
struct VertexIn   { float3 position; }
struct FragmentIn { float4 position @position; }
fn FragmentIn v(VertexIn i) @vertex(1) { FragmentIn o; o.position = float4(i.position, 1.0); return o; }
`);
	io::printfn("shady: %s", message);
	assert(message.contains("one name"), "the message should say what the argument must be");
}
