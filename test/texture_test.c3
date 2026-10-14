<*
 Texture methods beyond the plain sample: the comparison and gather families,
 texel fetches, the size queries, constant texel offsets, the cube, 3D and
 layered sampler types, and the checks that keep each method on the textures
 and samplers it means something for.

 `test/conformance/textures.shady` and `separate_textures.shady` hand every
 method to `spirv-val`; these tests pin the instruction each one lowers to and
 the refusals, which the validator cannot see because nothing was emitted.
*>
module texture_test;

import std::core::test;
import shady;
import shady_support;

const String RESOURCES = `
Sampler2D            albedo       @set(0) @binding(0);
Sampler3D            volume       @set(0) @binding(1);
SamplerCube          sky          @set(0) @binding(2);
Sampler2DArray       layers       @set(0) @binding(3);
SamplerCubeArray     probes       @set(0) @binding(4);
Sampler2DShadow      shadow       @set(0) @binding(5);
SamplerCubeShadow    point_shadow @set(0) @binding(6);
Sampler2DArrayShadow cascades     @set(0) @binding(7);

texture2d            image        @set(1) @binding(0);
texture3d            grid         @set(1) @binding(1);
texturecube          cube         @set(1) @binding(2);
sampler              linear       @set(1) @binding(3);
sampler_cmp          compare      @set(1) @binding(4);

struct FragmentIn { float4 position @position; float4 color; }
`;

<*
 A fragment shader over every texture type, with `body` as the statements
 before `return result;`. `uv` and `n` are in scope.
*>
fn String shader(String body)
{
	return string::tformat(`%s
fn float4 frag(FragmentIn input) @fragment
{
    float2 uv = input.color.xy;
    float3 n  = input.color.xyz;
    float4 result = float4(0.0);
%s
    return result;
}
`, RESOURCES, body);
}

fn String rejection(String body) => shady_support::compile_error(shader(body));

<*
 The image-operand mask on the first instruction with this opcode, which sits
 at `mask_word` words into it - after the result type, result id, image,
 coordinate, and the reference or component some instructions take. Zero when
 the instruction carries no mask.
*>
fn uint image_operand_mask(char[] spirv, shady::Opcode opcode, usz mask_word)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)opcode) continue;
		return (usz)(words[i] >> 16) > mask_word ? words[i + mask_word] : 0;
	}
	return 0;
}

// --- What each method lowers to ---------------------------------------------

fn void the_new_sampler_types_sample() @test
{
	String error = shady_support::compile_error(shader(`
    result += volume.Sample(float3(uv, 0.5));
    result += sky.Sample(n);
    result += layers.Sample(float3(uv, 2.0));
    result += probes.Sample(float4(n, 1.0));
`));

	test::@check(error == "", "the 3D, cube and layered sampler types should sample; got '%s'", error);
}

fn void a_comparison_samples_with_an_implicit_or_explicit_level() @test
{
	char[] spirv = shady_support::build(shader(`
    float lit = shadow.SampleCmp(uv, 0.5) + point_shadow.SampleCmpLevel(n, 0.5, 1.0)
        + cascades.SampleCmpLevelZero(float3(uv, 1.0), 0.5);
    result = float4(lit);
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_SAMPLE_DREF_IMPLICIT_LOD),
		"SampleCmp takes its level from derivatives");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_SAMPLE_DREF_EXPLICIT_LOD),
		"SampleCmpLevel and SampleCmpLevelZero name theirs");
}

fn void gather_reads_four_texels() @test
{
	char[] spirv = shady_support::build(shader(`
    result = albedo.Gather(uv) + albedo.GatherAlpha(uv) + albedo.gather(uv, 2) + sky.GatherGreen(n)
        + shadow.GatherCmp(uv, 0.5);
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_GATHER), "Gather is OpImageGather");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_DREF_GATHER), "GatherCmp is OpImageDrefGather");
}

fn void load_fetches_a_texel_without_a_sampler() @test
{
	char[] spirv = shady_support::build(shader(`
    result = albedo.load(int2(1, 2), 0) + layers.Load(int4(1, 2, 3, 0)) + image.load(int2(0, 0), 1);
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_FETCH), "load is OpImageFetch");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE),
		"a combined sampler gives up its image through OpImage before a fetch");
}

fn void size_and_levels_query_the_image() @test
{
	char[] spirv = shady_support::build(shader(`
    int2 extent = albedo.size(0);
    int3 stack  = layers.size();
    int2 face   = sky.size(1);
    int  mips   = image.levels();
    result = float4(float(extent.x + stack.z + face.y + mips));
`));
	defer free(spirv);

	test::@check(shady_support::has_capability(spirv, shady::Capability.IMAGE_QUERY), "a query needs ImageQuery");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_QUERY_SIZE_LOD), "size is OpImageQuerySizeLod");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_QUERY_LEVELS), "levels is OpImageQueryLevels");
}

fn void a_texel_offset_is_a_constant_operand() @test
{
	char[] spirv = shady_support::build(shader(`
    result = albedo.SampleLevel(uv, 0.0, int2(1, -1));
`));
	defer free(spirv);

	uint mask = image_operand_mask(spirv, shady::Opcode.IMAGE_SAMPLE_EXPLICIT_LOD, 5);
	test::@check(mask == ((uint)shady::ImageOperand.LOD | (uint)shady::ImageOperand.CONST_OFFSET),
		"the level and the offset should share one mask; got %x", mask);
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.CONSTANT_COMPOSITE),
		"the offset is a constant, not a constructor run at draw time");
}

fn void the_separate_path_has_the_whole_set() @test
{
	char[] spirv = shady_support::build(shader(`
    result = image.sample_grad(linear, uv, ddx(uv), ddy(uv)) + image.sample_bias(linear, uv, 0.5)
        + image.gather(linear, uv, 0) + float4(image.sample_cmp(compare, uv, 0.5))
        + image.gather_cmp(compare, uv, 0.5);
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_SAMPLE_DREF_IMPLICIT_LOD),
		"a sampler_cmp compares a separate texture");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_DREF_GATHER),
		"and gathers comparisons from it");
}

fn void a_level_given_as_an_integer_is_converted() @test
{
	char[] spirv = shady_support::build(shader(`
    result = albedo.SampleLevel(uv, 0);
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.CONVERT_S_TO_F),
		"a sample's level is a float, so `0` is converted rather than passed as an int");
}

// --- What each method refuses -----------------------------------------------

fn void a_coordinate_must_be_as_wide_as_the_texture() @test
{
	String error = rejection("    result = layers.Sample(uv);");
	test::@check(error.contains("float3 coordinate") && error.contains("array layer"),
		"a 2D array coordinate carries the layer; got '%s'", error);

	error = rejection("    result = sky.Sample(uv);");
	test::@check(error.contains("float3 coordinate"), "a cube is sampled by direction; got '%s'", error);
}

fn void a_shadow_type_only_compares() @test
{
	String error = rejection("    result = shadow.Sample(uv);");
	test::@check(error.contains("compares"), "a plain sample of a shadow type should be refused; got '%s'", error);

	error = rejection("    result = albedo.GatherCmp(uv, 0.5);");
	test::@check(error.contains("Sampler2DShadow"), "a compare on a plain type should name a shadow one; got '%s'", error);
}

fn void the_separate_samplers_are_not_interchangeable() @test
{
	String error = rejection("    result = float4(image.sample_cmp(linear, uv, 0.5));");
	test::@check(error.contains("sampler_cmp"), "a comparison takes a sampler_cmp; got '%s'", error);

	error = rejection("    result = image.sample(compare, uv);");
	test::@check(error.contains("only compares"), "a sampler_cmp serves only comparisons; got '%s'", error);

	error = rejection("    result = image.sample(uv);");
	test::@check(error.contains("sampler first"), "a separate texture is sampled through a sampler; got '%s'", error);
}

fn void a_3d_texture_has_no_comparison() @test
{
	String error = rejection("    result = float4(grid.sample_cmp(compare, n, 0.5));");
	test::@check(error.contains("3D texture has no depth comparison"), "got '%s'", error);
}

fn void gather_is_for_2d_and_cube_textures() @test
{
	String error = rejection("    result = volume.Gather(float3(uv, 0.5));");
	test::@check(error.contains("2D or cube"), "a 3D gather should be refused; got '%s'", error);
}

fn void a_gather_component_is_a_literal() @test
{
	String error = rejection("    int c = 1;\n    result = albedo.gather(uv, c);");
	test::@check(error.contains("literal from 0 to 3"), "a variable component should be refused; got '%s'", error);

	error = rejection("    result = albedo.gather(uv, 4);");
	test::@check(error.contains("literal from 0 to 3"), "component 4 should be refused; got '%s'", error);
}

fn void a_texel_offset_must_be_constant() @test
{
	String error = rejection("    int2 o = int2(1, 0);\n    result = albedo.Sample(uv, o);");
	test::@check(error.contains("texel offset is a constant"), "a variable offset should be refused; got '%s'", error);

	error = rejection("    result = sky.Sample(n, int2(1, 0));");
	test::@check(error.contains("no texel offset"), "a cube takes no offset; got '%s'", error);
}

fn void a_cube_map_has_no_texel_addresses() @test
{
	String error = rejection("    result = sky.load(int3(0, 0, 0), 0);");
	test::@check(error.contains("no texel addresses"), "a cube fetch should be refused; got '%s'", error);
}

fn void a_fetch_level_is_an_integer() @test
{
	String error = rejection("    result = albedo.load(int2(0, 0), 1.0);");
	test::@check(error.contains("mip level is an integer"), "a float level should be refused; got '%s'", error);
}

fn void a_size_is_as_wide_as_the_texture() @test
{
	String error = rejection("    int2 s = layers.size(0);");
	test::@check(error.len > 0, "a 2D array's size is an int3, so an int2 should not take it");
}

fn void get_dimensions_points_at_size_and_levels() @test
{
	String error = rejection("    uint w; uint h;\n    albedo.GetDimensions(w, h);");
	test::@check(error.contains("size(") && error.contains("levels()"), "got '%s'", error);
}

fn void implicit_levels_are_fragment_only() @test
{
	String error = shady_support::compile_error(`
Sampler2D albedo @set(0) @binding(0);
struct VertexOut { float4 position @position; }
fn VertexOut vert() @vertex
{
    VertexOut o;
    o.position = albedo.Sample(float2(0.5));
    return o;
}
`);
	test::@check(error.contains("only a fragment shader") && error.contains("sample_lod"),
		"an implicit level in a vertex shader should be refused, pointing at sample_lod; got '%s'", error);

	error = shady_support::compile_error(`
struct VertexIn { float2 uv; }
struct VertexOut { float4 position @position; }
fn VertexOut vert(VertexIn input) @vertex
{
    VertexOut o;
    o.position = float4(ddx(input.uv), 0.0, 1.0);
    return o;
}
`);
	test::@check(error.contains("screen-space derivative"), "ddx in a vertex shader should be refused; got '%s'", error);
}

fn void an_offset_outside_the_guaranteed_range_warns() @test
{
	shady::DiagnosticList warnings;
	warnings.init(tmem, 4);
	shady::Diagnostic diagnostic;

	char[]? spirv = shady::compile(shader("    result = albedo.Sample(uv, int2(9, 0));"), &diagnostic, tmem, warnings: &warnings);
	test::@check(@ok(spirv), "an offset outside [-8, 7] compiles; got '%s'", diagnostic.to_string(tmem));
	test::@check(warnings.len() == 1 && warnings[0].message.contains("[-8, 7]"),
		"and warns that a device may not support it");
}

<*
 A helper is emitted once and runs in every entry point that calls it, so an
 implicit level inside one is asked of each of them - not only of the first,
 which used to decide alone.
*>
fn void a_helper_answers_to_every_stage_that_calls_it() @test
{
	String helper = `
Sampler2D albedo @set(0) @binding(0);
struct VertexOut { float4 position @position; }
fn float4 shade(float2 uv)
{
    return albedo.Sample(uv);
}
fn float4 frag(VertexOut input) @fragment
{
    return shade(input.position.xy);
}
`;
	test::@check(shady_support::compile_error(helper) == "", "a fragment shader may call it");

	String error = shady_support::compile_error(string::tformat(`%s
fn VertexOut vert() @vertex
{
    VertexOut o;
    o.position = shade(float2(0.5));
    return o;
}
`, helper));
	test::@check(error.starts_with("6:") && error.contains("only a fragment shader")
		&& error.contains("`shade` is reached from `vert`, a vertex shader"),
		"a vertex shader may not, and the message says which entry point broke it; got '%s'", error);
}
