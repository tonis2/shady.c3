<*
 Descriptors and samplers: combined image-and-samplers, runtime-sized descriptor
 arrays indexed non-uniformly, comparison samplers, the sample variants, and two
 sets in one module.
*>
module sampler_test;

import std::core::test;
import shady;
import shady_support;

fn void a_combined_sampler_samples_directly() @test
{
	String error = shady_support::compile_error(`
Sampler2D scene @set(0) @binding(0);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    float2 uv = input.color.xy;
    return scene.Sample(uv) + scene.SampleLevel(uv, 1.0);
}
`);

	test::@check(error == "", "a Sampler2D is one descriptor and needs no sampler argument; got '%s'", error);
}

fn void the_sample_variants_compile() @test
{
	String error = shady_support::compile_error(`
Sampler2D scene @set(0) @binding(0);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    float2 uv = input.color.xy;
    return scene.Sample(uv)
         + scene.SampleLevel(uv, 2.0)
         + scene.SampleBias(uv, 0.5)
         + scene.SampleGrad(uv, float2(1.0, 0.0), float2(0.0, 1.0));
}
`);

	test::@check(error == "", "SampleLevel, SampleBias and SampleGrad should all lower; got '%s'", error);
}

fn void a_comparison_sampler_compares() @test
{
	String error = shady_support::compile_error(`
Sampler2DShadow shadow_atlas @set(0) @binding(17);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    float shadow = shadow_atlas.SampleCmpLevelZero(input.color.xy, input.color.z);
    return float4(shadow, shadow, shadow, 1.0);
}
`);

	test::@check(error == "", "a Sampler2DShadow should compare against a reference; got '%s'", error);
}

fn void comparison_needs_a_shadow_sampler() @test
{
	String error = shady_support::compile_error(`
Sampler2D scene @set(0) @binding(0);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    float shadow = scene.SampleCmpLevelZero(input.color.xy, input.color.z);
    return float4(shadow, shadow, shadow, 1.0);
}
`);

	test::@check(error.contains("Sampler2DShadow"),
		"a comparison sample on a plain Sampler2D should name what it needs; got '%s'", error);
}

<*
 The bindless table: a runtime-sized array of combined samplers, indexed by a
 value that is not uniform across the wave. Both the extension and the
 NonUniform decoration are what make that legal and correct.
*>
fn void a_runtime_descriptor_array_is_indexed_non_uniformly() @test
{
	char[] spirv = shady_support::build(`
struct Push @pushconstant { uint texture_index[24]; }
Push push;

Sampler2D       three_textures[] @set(1) @binding(0);
Sampler2DShadow shadow_atlas     @set(0) @binding(17);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    uint slot = push.texture_index[0];
    float4 color = three_textures[NonUniformResourceIndex(slot)].Sample(input.color.xy);
    float shadow = shadow_atlas.SampleCmpLevelZero(input.color.xy, color.x);
    return color + float4(shadow, shadow, shadow, 0.0);
}
`);
	defer free(spirv);

	test::@check(shady_support::has_capability(spirv, shady::Capability.RUNTIME_DESCRIPTOR_ARRAY),
		"a runtime-sized descriptor array needs RuntimeDescriptorArray");
	test::@check(shady_support::has_capability(spirv, shady::Capability.SHADER_NON_UNIFORM),
		"a non-uniform index needs ShaderNonUniform");
	test::@check(shady_support::has_capability(spirv, shady::Capability.SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING),
		"a non-uniformly indexed sampler array needs SampledImageArrayNonUniformIndexing");
	// The index, the access chain and the loaded descriptor: Vulkan wants the
	// decoration on what the image instruction reads, not only on the index.
	uint marks = shady_support::decoration_count(spirv, shady::Decoration.NON_UNIFORM);
	test::@check(marks >= 3, "NonUniform should reach the descriptor, not stop at the index; found %d", marks);
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.DESCRIPTOR_SET, 0)
		&& shady_support::has_decoration_value(spirv, shady::Decoration.DESCRIPTOR_SET, 1),
		"the module should use both set 0 and set 1");
}

<*
 A separate texture picked non-uniformly is paired with its sampler at the point
 of use, and the sampled image that pairing makes is what the image instruction
 reads - so it is decorated as well.
*>
fn void a_separate_texture_array_is_indexed_non_uniformly() @test
{
	char[] spirv = shady_support::build(`
texture2d maps[]  @set(0) @binding(0);
sampler   linear  @set(0) @binding(1);

struct FragmentIn { float4 position @position; float4 color; uint slot @flat; }

fn float4 frag(FragmentIn input) @fragment
{
    return maps[NonUniformResourceIndex(input.slot)].sample(linear, input.color.xy);
}
`);
	defer free(spirv);

	// The index, the access chain, the loaded image and the sampled image.
	uint marks = shady_support::decoration_count(spirv, shady::Decoration.NON_UNIFORM);
	test::@check(marks >= 4, "NonUniform should reach the sampled image; found %d", marks);
}

fn void a_fixed_size_descriptor_array_indexes_by_a_constant() @test
{
	String error = shady_support::compile_error(`
Sampler2D four[4] @set(0) @binding(0);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    return four[2].Sample(input.color.xy);
}
`);

	test::@check(error == "", "a fixed-size descriptor array is indexed without the extension; got '%s'", error);
}

fn void a_runtime_array_is_not_a_local() @test
{
	String error = shady_support::compile_error(`
Sampler2D scene @set(0) @binding(0);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    Sampler2D local[];
    return scene.Sample(input.color.xy);
}
`);

	test::@check(error.contains("runtime-sized array"),
		"a runtime-sized array is only a module-level resource; got '%s'", error);
}

<*
 The layered textures: a 2D array and a cube array, each sampled with the layer
 as the coordinate's last component. A cube array needs SampledCubeArray, which
 `spirv-val` does not check - this test is the only thing that does.
*>
fn void the_array_textures_exist() @test
{
	char[] spirv = shady_support::build(`
texture2d_array   layers @set(0) @binding(0);
texturecube_array probes @set(0) @binding(1);
sampler           linear @set(0) @binding(2);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    float4 a = layers.sample(linear, float3(input.color.xy, 2.0));
    float4 b = probes.sample_lod(linear, float4(input.color.xyz, 1.0), 0.0);
    return a + b;
}
`);
	defer free(spirv);

	test::@check(shady_support::has_capability(spirv, shady::Capability.SAMPLED_CUBE_ARRAY),
		"a cube array texture needs SampledCubeArray");
	test::@check(!shady_support::has_capability(spirv, shady::Capability.SAMPLED_1D),
		"nothing here is a 1D texture");
}

fn void a_1d_texture_declares_sampled_1d() @test
{
	char[] spirv = shady_support::build(`
texture1d ramp @set(0) @binding(0);
sampler   linear @set(0) @binding(1);

struct FragmentIn { float4 position @position; float4 color; }

fn float4 frag(FragmentIn input) @fragment
{
    return ramp.sample(linear, input.color.x);
}
`);
	defer free(spirv);

	test::@check(shady_support::has_capability(spirv, shady::Capability.SAMPLED_1D),
		"a 1D texture needs the Sampled1D capability");
}
