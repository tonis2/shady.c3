<*
 Storage images: `image2d<rgba8>` and its family, their formats and texel
 types, `load`/`store`/`size`, indexing, `InterlockedAdd` on a texel, and what
 a module with one in it declares.

 `test/conformance/storage_images.shady` hands every shape to `spirv-val`;
 these tests pin the instructions and capabilities, and the refusals the
 validator never sees because nothing was emitted - a format that disagrees
 with its texel type among them, which it would not catch even if it were.
*>
module image_test;

import std::core::test;
import shady;
import shady_support;

const String COMPUTE_IN = `
struct ComputeIn { uint3 id @builtin(global_invocation_id); }
`;

<*
 A compute shader with `declarations` at module level and `body` as its
 statements. `at.id` is in scope.
*>
fn String compute(String declarations, String body)
{
	return string::tformat(`%s
%s
fn void main(ComputeIn at) @compute @threads(8, 8, 1)
{
%s
}
`, COMPUTE_IN, declarations, body);
}

fn String rejection(String declarations, String body) => shady_support::compile_error(compute(declarations, body));

fn void expect_refusal(String declarations, String body, String needle)
{
	String error = rejection(declarations, body);
	test::@check(error.contains(needle), "expected a refusal mentioning '%s', got '%s'", needle, error);
}

<*
 The operands of the first `OpTypeImage`, after its result id: sampled type,
 dim, depth, arrayed, multisampled, sampled, format. All zero when there is
 none.
*>
fn uint[7] image_operands(char[] spirv)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint[7] operands;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)shady::Opcode.TYPE_IMAGE) continue;
		for (usz k = 0; k < 7; k++) operands[k] = words[i + 2 + k];
		return operands;
	}
	return operands;
}

<*
 The instruction that defines `id`, as its opcode and its first operand after
 the result: the width of an OpTypeFloat, or the width of an OpTypeInt.
 Signedness is the word after.
*>
fn uint[3] definition(char[] spirv, uint id)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		usz len = (usz)(words[i] >> 16);
		if (len < 2 || words[i + 1] != id) continue;
		return { words[i] & 0xffff, len > 2 ? words[i + 2] : 0, len > 3 ? words[i + 3] : 0 };
	}
	return { 0, 0, 0 };
}

<*
 The memory semantics an `OpControlBarrier` carries: the value of the constant
 its third operand names.
*>
fn uint barrier_semantics(char[] spirv)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)shady::Opcode.CONTROL_BARRIER) continue;
		uint id = words[i + 3];
		for (usz j = 5; j < count; j += (usz)(words[j] >> 16))
		{
			if ((words[j] & 0xffff) == (uint)shady::Opcode.CONSTANT && words[j + 2] == id) return words[j + 3];
		}
	}
	return 0xffff_ffff;
}

fn uint opcode_count(char[] spirv, shady::Opcode opcode)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint  found = 0;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) == (uint)opcode) found++;
	}
	return found;
}

// --- Types -------------------------------------------------------------------

fn void a_storage_image_is_an_image_with_a_format() @test
{
	char[] spirv = shady_support::build(compute("image2d<rgba8> output;", "output[at.id.xy] = float4(1.0);"));
	defer free(spirv);

	uint[7] image = image_operands(spirv);
	test::@check(image[1] == (uint)shady::Dim.D2, "a 2D image");
	test::@check(image[3] == 0, "not arrayed");
	test::@check(image[5] == 2, "Sampled 2 is a storage image, got %d", image[5]);
	test::@check(image[6] == (uint)shady::ImageFormat.RGBA8, "the format is Rgba8, got %d", image[6]);
	test::@check(definition(spirv, image[0])[0] == (uint)shady::Opcode.TYPE_FLOAT, "rgba8 texels are floats");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_WRITE), "the store is an OpImageWrite");
	test::@check(!shady_support::has_capability(spirv, shady::Capability.STORAGE_IMAGE_EXTENDED_FORMATS),
		"rgba8 is one of the formats every device stores");
}

fn void an_integer_format_has_an_integer_texel() @test
{
	char[] spirv = shady_support::build(compute("image2d<r32ui> counts;", "uint c = counts[at.id.xy];"));
	defer free(spirv);

	uint[7] image = image_operands(spirv);
	uint[3] scalar = definition(spirv, image[0]);
	test::@check(image[6] == (uint)shady::ImageFormat.R32UI, "the format is R32ui");
	test::@check(scalar[0] == (uint)shady::Opcode.TYPE_INT && scalar[2] == 0, "r32ui texels are uints");

	char[] signed = shady_support::build(compute("image2d<rgba16i> deltas;", "int4 d = deltas[at.id.xy];"));
	defer free(signed);
	uint[3] signed_scalar = definition(signed, image_operands(signed)[0]);
	test::@check(signed_scalar[0] == (uint)shady::Opcode.TYPE_INT && signed_scalar[2] == 1, "rgba16i texels are ints");
}

fn void each_family_has_its_shape() @test
{
	char[] volume = shady_support::build(compute("image3d<rgba16f> volume;", "volume[at.id] = float4(0.0);"));
	defer free(volume);
	test::@check(image_operands(volume)[1] == (uint)shady::Dim.D3, "image3d is 3D");
	test::@check(image_operands(volume)[6] == (uint)shady::ImageFormat.RGBA16F, "the format is Rgba16f");

	char[] layers = shady_support::build(compute("image2d_array<rgba8> layers;", "layers[int3(0, 0, 2)] = float4(0.0);"));
	defer free(layers);
	test::@check(image_operands(layers)[3] == 1, "image2d_array is arrayed");

	char[] line = shady_support::build(compute("image1d<r32f> line;", "line[3] = 1.0;"));
	defer free(line);
	test::@check(shady_support::has_capability(line, shady::Capability.IMAGE_1D), "a 1D storage image needs Image1D");

	char[] cubes = shady_support::build(compute("imagecube_array<rgba8> cubes;", "cubes[int3(0, 0, 7)] = float4(0.0);"));
	defer free(cubes);
	test::@check(shady_support::has_capability(cubes, shady::Capability.IMAGE_CUBE_ARRAY),
		"a cube-array storage image needs ImageCubeArray");

	char[] cube = shady_support::build(compute("imagecube<rgba8> cube;", "cube[int3(0, 0, 5)] = float4(0.0);"));
	defer free(cube);
	test::@check(image_operands(cube)[1] == (uint)shady::Dim.CUBE, "imagecube is a cube");
	test::@check(!shady_support::has_capability(cube, shady::Capability.IMAGE_CUBE_ARRAY), "a single cube needs no array capability");
}

fn void an_extended_format_asks_for_its_capability() @test
{
	char[] spirv = shady_support::build(compute("image2d<rg16f> motion;", "motion[at.id.xy] = float2(0.0);"));
	defer free(spirv);
	test::@check(shady_support::has_capability(spirv, shady::Capability.STORAGE_IMAGE_EXTENDED_FORMATS),
		"rg16f is outside the base formats");
}

fn void a_host_format_costs_a_capability_per_direction() @test
{
	char[] written = shady_support::build(compute("image2d<float4> any;", "any.store(at.id.xy, float4(1.0));"));
	defer free(written);
	test::@check(image_operands(written)[6] == (uint)shady::ImageFormat.UNKNOWN, "the format is Unknown");
	test::@check(shady_support::has_capability(written, shady::Capability.STORAGE_IMAGE_WRITE_WITHOUT_FORMAT),
		"writing an Unknown format needs StorageImageWriteWithoutFormat");
	test::@check(!shady_support::has_capability(written, shady::Capability.STORAGE_IMAGE_READ_WITHOUT_FORMAT),
		"an image only written asks nothing about reading");

	char[] read = shady_support::build(compute("image2d<float4> any; float4 sums[];", "sums[at.id.x] = any.load(at.id.xy);"));
	defer free(read);
	test::@check(shady_support::has_capability(read, shady::Capability.STORAGE_IMAGE_READ_WITHOUT_FORMAT),
		"reading an Unknown format needs StorageImageReadWithoutFormat");
	test::@check(!shady_support::has_capability(read, shady::Capability.STORAGE_IMAGE_WRITE_WITHOUT_FORMAT),
		"an image only read asks nothing about writing");

	String error = rejection("image2d<uint2> any;", "any[at.id.xy] = uint2(1, 2);");
	test::@check(error == "", "a host-picked format takes any 32-bit texel type; got '%s'", error);
}

// --- Methods -----------------------------------------------------------------

fn void load_and_store_move_the_texel_type() @test
{
	String error = rejection("image2d<r32f> depth;", "float d = depth.load(at.id.xy); depth.store(at.id.xy, d + 1.0);");
	test::@check(error == "", "an r32f image reads and writes floats; got '%s'", error);

	char[] spirv = shady_support::build(compute("image2d<rg16f> motion;", "float2 m = motion.load(at.id.xy); motion.store(at.id.xy, m * 0.5);"));
	defer free(spirv);
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_READ), "load is an OpImageRead");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.VECTOR_SHUFFLE),
		"the four components read are cut down to the texel, and the texel padded to four");

	expect_refusal("image2d<rgba8> color;", "float c = color.load(at.id.xy);", "cannot use a float4 where a float is expected");
	expect_refusal("image2d<rgba8> color;", "color.store(at.id.xy, int4(1));", "cannot use a int4 where a float4 is expected");
	expect_refusal("image2d<rgba8> color;", "float4 c = color.load(at.id.xy, 0);", "takes one argument");
	expect_refusal("image2d<rgba8> color;", "color.store(at.id.xy);", "takes the texel address and the texel");
}

fn void a_texel_address_is_integer_and_exactly_wide() @test
{
	String error = rejection("image2d<rgba8> color;", "color[at.id.xy] = float4(1.0); color[int2(at.id.xy)] = float4(0.0);");
	test::@check(error == "", "an int2 or a uint2 addresses a 2D image; got '%s'", error);

	expect_refusal("image2d<rgba8> color;", "color[float2(0.5)] = float4(1.0);", "addressed by texel, not by uv");
	expect_refusal("image2d<rgba8> color;", "color[at.id] = float4(1.0);", "an int2 or a uint2 texel address, got a uint3");
	expect_refusal("image2d_array<rgba8> layers;", "float4 c = layers.load(int2(0));", "the last component is the array layer");
	expect_refusal("imagecube<rgba8> cube;", "cube[int2(0)] = float4(0.0);", "(x, y, face)");
}

fn void size_queries_the_one_level() @test
{
	char[] spirv = shady_support::build(compute("image2d<rgba8> color; int2 sizes[];", "sizes[0] = color.size();"));
	defer free(spirv);
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IMAGE_QUERY_SIZE), "size is OpImageQuerySize, without a level");
	test::@check(shady_support::has_capability(spirv, shady::Capability.IMAGE_QUERY), "a size query needs ImageQuery");

	String error = rejection("image2d_array<rgba8> layers; imagecube<rgba8> cube;",
		"int3 l = layers.size(); int2 c = cube.size();");
	test::@check(error == "", "an array's size counts its layers, a cube's is its face; got '%s'", error);

	expect_refusal("image2d<rgba8> color;", "int2 s = color.size(0);", "takes no arguments");
	expect_refusal("image2d<rgba8> color;", "int l = color.levels();", "no `levels()`");
	expect_refusal("image2d<rgba8> color;", "color.GetDimensions();", "spelled `size()`");
	expect_refusal("image2d<rgba8> color;", "color.frob();", "has no method `frob`");
}

// --- Indexing ----------------------------------------------------------------

fn void indexing_reads_and_writes_texels() @test
{
	char[] spirv = shady_support::build(compute("image2d<rgba8> color;", "color[at.id.xy] += float4(0.25);"));
	defer free(spirv);
	test::@check(opcode_count(spirv, shady::Opcode.IMAGE_READ) == 1, "a compound assignment reads the texel once");
	test::@check(opcode_count(spirv, shady::Opcode.IMAGE_WRITE) == 1, "and writes it once");

	String error = rejection("image2d<rgba8> color; float sums[];",
		"float4 c = color[at.id.xy]; sums[0] = color[at.id.xy].a + c.r; float4 d = (color[at.id.xy] = c);");
	test::@check(error == "", "an indexed texel is a value, and an assignment yields one; got '%s'", error);

	expect_refusal("image2d<rgba8> color;", "color[at.id.xy].x = 1.0;", "a texel is written whole");
}

fn void interlocked_add_reaches_an_r32ui_texel() @test
{
	char[] spirv = shady_support::build(compute("image2d<r32ui> counts; uint olds[];",
		"olds[0] = InterlockedAdd(counts[at.id.xy], 1u); InterlockedAdd(counts[int2(0)], 1);"));
	defer free(spirv);
	test::@check(opcode_count(spirv, shady::Opcode.IMAGE_TEXEL_POINTER) == 2, "each add takes the texel's address");
	test::@check(opcode_count(spirv, shady::Opcode.ATOMIC_I_ADD) == 2, "and adds through it");
	test::@check(!shady_support::has_opcode(spirv, shady::Opcode.IMAGE_READ), "an atomic add reads nothing else");

	expect_refusal("image2d<rgba8> color;", "InterlockedAdd(color[at.id.xy], 1u);", "needs the `r32ui` format");
	expect_refusal("image2d<uint> counts;", "InterlockedAdd(counts[at.id.xy], 1u);", "needs the `r32ui` format");
	expect_refusal("image2d<r32ui> counts;", "InterlockedAdd(counts[at.id.xy], 1.0);", "32-bit uints");
}

fn void a_bindless_image_array_indexes_non_uniformly() @test
{
	char[] spirv = shady_support::build(compute("image2d<rgba8> targets[];",
		"targets[NonUniformResourceIndex(at.id.x)][at.id.xy] = float4(1.0);"));
	defer free(spirv);
	test::@check(shady_support::has_capability(spirv, shady::Capability.RUNTIME_DESCRIPTOR_ARRAY), "a runtime-sized array of images");
	test::@check(shady_support::has_capability(spirv, shady::Capability.STORAGE_IMAGE_ARRAY_NON_UNIFORM_INDEXING),
		"a storage image picked non-uniformly needs the storage capability");
	test::@check(!shady_support::has_capability(spirv, shady::Capability.SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING),
		"not the sampled one");
	test::@check(shady_support::decoration_count(spirv, shady::Decoration.NON_UNIFORM) >= 2,
		"the access chain and the loaded image are NonUniform");
}

// --- Refusals ----------------------------------------------------------------

fn void the_type_says_what_it_needs() @test
{
	expect_refusal("image2d bare;", "", "`image2d` names its format");
	expect_refusal("image2d<rgb8> color;", "", "write `rgba8`");
	expect_refusal("image2d<rgbx> color;", "", "`rgbx` is not a storage-image format");
	expect_refusal("image2d<half> color;", "", "texels are 32-bit");
	expect_refusal("image2d<float4x4> color;", "", "texels are 32-bit");

	// A family name without brackets is still an ordinary name.
	String error = rejection("struct image2d @uniform { float x; } image2d settings; float results[];", "results[0] = settings.x;");
	test::@check(error == "", "a struct named image2d keeps working; got '%s'", error);
}

fn void an_image_is_a_handle() @test
{
	expect_refusal("", "image2d<rgba8> local;", "cannot be a local");
	expect_refusal("struct Frame { image2d<rgba8> target; }", "", "a handle is not data");
	expect_refusal("image2d<rgba8> a; image2d<rgba8> b;", "a = b;", "cannot be assigned");

	String param = shady_support::compile_error(string::tformat(`%s
image2d<rgba8> color;
fn void paint(image2d<rgba8> target) {}
fn void main(ComputeIn at) @compute @threads(1, 1, 1) { paint(color); }
`, COMPUTE_IN));
	test::@check(param.contains("cannot be a parameter"), "an image parameter is refused; got '%s'", param);

	String helper = shady_support::compile_error(string::tformat(`%s
image2d<rgba8> color;
fn image2d<rgba8> pick() { return color; }
fn void main(ComputeIn at) @compute @threads(1, 1, 1) {}
`, COMPUTE_IN));
	test::@check(helper.contains("cannot return an image2d<rgba8>"), "an image return is refused; got '%s'", helper);
}

fn void a_storage_image_is_not_sampled_and_a_texture_is_not_written() @test
{
	expect_refusal("image2d<rgba8> color; sampler linear;", "float4 c = color.sample_lod(linear, float2(0.5), 0.0);",
		"bind the image as a `texture2d` to sample it");
	expect_refusal("texture2d_array layers;", "layers.store(int3(0), float4(1.0));",
		"declare an `image2d_array<format>` to write texels");
	expect_refusal("texture2d tex;", "float4 c = tex[int2(0)];", "only a storage image such as `image2d<rgba8>` is indexed");
}

// --- Module-level effects ----------------------------------------------------

fn void use_decides_readonly_and_writeonly() @test
{
	char[] written = shady_support::build(compute("image2d<rgba8> output;", "output[at.id.xy] = float4(1.0);"));
	defer free(written);
	test::@check(shady_support::has_decoration(written, shady::Decoration.NON_READABLE), "an image only written is NonReadable");
	test::@check(!shady_support::has_decoration(written, shady::Decoration.NON_WRITABLE), "but not NonWritable");

	char[] read = shady_support::build(compute("image2d<rgba8> source; float4 results[];", "results[0] = source.load(at.id.xy);"));
	defer free(read);
	test::@check(shady_support::has_decoration(read, shady::Decoration.NON_WRITABLE), "an image only read is NonWritable");
	test::@check(!shady_support::has_decoration(read, shady::Decoration.NON_READABLE), "but not NonReadable");

	char[] both = shady_support::build(compute("image2d<rgba8> accumulated;", "accumulated[at.id.xy] += float4(1.0);"));
	defer free(both);
	test::@check(!shady_support::has_decoration(both, shady::Decoration.NON_READABLE)
		&& !shady_support::has_decoration(both, shady::Decoration.NON_WRITABLE), "an image read and written is neither");

	char[] counted = shady_support::build(compute("image2d<r32ui> counts;", "InterlockedAdd(counts[at.id.xy], 1u);"));
	defer free(counted);
	test::@check(!shady_support::has_decoration(counted, shady::Decoration.NON_READABLE)
		&& !shady_support::has_decoration(counted, shady::Decoration.NON_WRITABLE), "an atomic reads and writes");
}

fn void a_barrier_orders_image_memory_when_there_are_images() @test
{
	uint acquire_release = (uint)shady::MemorySemantics.ACQUIRE_RELEASE;
	uint buffers = acquire_release | (uint)shady::MemorySemantics.WORKGROUP_MEMORY | (uint)shady::MemorySemantics.UNIFORM_MEMORY;

	char[] with = shady_support::build(compute("image2d<rgba8> color;", "color[at.id.xy] = float4(1.0); barrier();"));
	defer free(with);
	test::@check(barrier_semantics(with) == buffers | (uint)shady::MemorySemantics.IMAGE_MEMORY,
		"a module with an image orders image memory at a barrier, got 0x%x", barrier_semantics(with));

	char[] without = shady_support::build(compute("float data[];", "data[at.id.x] = 1.0; barrier();"));
	defer free(without);
	test::@check(barrier_semantics(without) == buffers, "a module without one keeps the barrier it had, got 0x%x", barrier_semantics(without));
}

fn void images_bind_in_declaration_order() @test
{
	char[] spirv = shady_support::build(compute(
		"texture2d tex; image2d<rgba8> color; sampler linear; image2d<r32f> depth @set(2) @binding(5);",
		"color[at.id.xy] = tex.sample_lod(linear, float2(0.5), 0.0); depth[at.id.xy] = 1.0;"));
	defer free(spirv);
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.BINDING, 1), "the image after a texture takes binding 1");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.DESCRIPTOR_SET, 2), "an explicit set is kept");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.BINDING, 5), "an explicit binding is kept");
}

fn void a_raygen_lists_the_image_it_writes() @test
{
	char[] spirv = shady_support::build(`
accel scene;
image2d<rgba8> output;
struct Payload { float3 color; }
struct RayGenIn { uint3 id @builtin(launch_id); }

fn void gen(RayGenIn at) @raygen
{
    Payload p;
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, float3(0.0), 0.001, float3(0.0, 0.0, 1.0), 1000.0, p);
    output[at.id.xy] = float4(p.color, 1.0);
}

fn void miss(inout Payload p) @miss { p.color = float3(0.0); }
`);
	defer free(spirv);
	test::@check(shady_support::version(spirv) == shady::VERSION_1_4, "a ray-tracing module is SPIR-V 1.4");
	test::@check(shady_support::interface_count(spirv, "gen", shady::StorageClass.UNIFORM_CONSTANT) == 2,
		"the raygen's interface lists the scene and the image it writes");
	test::@check(shady_support::interface_count(spirv, "miss", shady::StorageClass.UNIFORM_CONSTANT) == 0,
		"the miss shader reaches neither");
}

fn void a_fragment_shader_writes_an_image() @test
{
	String error = shady_support::compile_error(`
image2d<rgba8> splat;
struct FragmentIn { float4 position @position; float2 uv; }

fn float4 frag(FragmentIn input) @fragment
{
    splat[int2(input.position.xy)] = float4(input.uv, 0.0, 1.0);
    return float4(1.0);
}
`);
	test::@check(error == "", "any stage writes a storage image; got '%s'", error);
}
