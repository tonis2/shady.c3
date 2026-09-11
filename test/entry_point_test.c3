<*
 One module, many entry points.

 A shader file may hold as many stages as it likes, of any kind, and the host
 picks between them by name through `pName` in
 VkPipelineShaderStageCreateInfo. The name is the function's own unless the
 stage attribute gives one: `@fragment(main)`.
*>
module entry_point_test;

import std::core::test;
import std::io;
import shady_support;

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

<*
 Four entry points, two of each stage, in one module.
*>
fn void one_module_holds_many_stages() @test
{
	char[] spirv = shady_support::build(VARIANTS);
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
	char[] spirv = shady_support::build(VARIANTS);
	defer free(spirv);

	// OpEntryPoint carries the name as an inline UTF-8 literal, so it is in
	// the words verbatim. Searching the bytes avoids a disassembler here.
	String words = (String)spirv;
	test::@check(words.contains("main"), "@vertex(main) should publish `main`");
	test::@check(words.contains("opaque"), "@fragment(opaque) should publish `opaque`");
	test::@check(words.contains("stage_in_shadow"), "a bare @vertex should publish the function name");
	test::@check(words.contains("shade_solid"), "a bare @fragment should publish the function name");

	// The function keeps its own name for debug info, separately from the
	// name the entry point is published under.
	test::@check(words.contains("stage_in"), "OpName should keep the function's name");
}

<*
 The host tells entry points apart by name, so two of them may not share one.
*>
fn void rejects_a_duplicate_entry_point_name() @test
{
	String error = shady_support::compile_error(
		`
struct VertexIn   { float3 position; }
struct FragmentIn { float4 position @position; }
fn FragmentIn v(VertexIn i) @vertex { FragmentIn o; o.position = float4(i.position, 1.0); return o; }
fn float4 a(FragmentIn i) @fragment(shade) { return float4(1.0, 1.0, 1.0, 1.0); }
fn float4 b(FragmentIn i) @fragment(shade) { return float4(0.0, 0.0, 0.0, 1.0); }
`
	);

	test::@check(error.contains("already an entry point"), "the message should say the name is taken; got '%s'", error);
}

fn void rejects_a_stage_argument_that_is_not_a_name() @test
{
	String error = shady_support::compile_error(
		`
struct VertexIn   { float3 position; }
struct FragmentIn { float4 position @position; }
fn FragmentIn v(VertexIn i) @vertex(1) { FragmentIn o; o.position = float4(i.position, 1.0); return o; }
`
	);

	test::@check(error.contains("one name"), "the message should say what the argument must be; got '%s'", error);
}
