<*
 Builds, by hand through the shady API, the same shader the Kongruent path
 produces for the cube - textured, tinted, with a two-matrix UBO - and writes
 it out for spirv-val.

 The point of the exercise: one module carrying BOTH entry points, named after
 their functions. Kongruent needs spirv-link and an entry-point rewrite to get
 there; here it falls out of the emitter.
*>
module shady_test;

import std::core::test;
import std::io;
import std::io::path;
import shady;

const String OUT_DIR = "build/shady";

fn void build_triangle_module() @test
{
	shady::Module mod;
	mod.init(mem);
	defer mod.free();

	mod.capability(shady::Capability.SHADER);
	mod.ext_inst_import("GLSL.std.450");
	mod.set_memory_model();

	// --- types ---
	shady::Id void_t  = mod.type_void();
	shady::Id float_t = mod.type_float();
	shady::Id int_t   = mod.type_int();
	shady::Id vec2    = mod.type_vector(float_t, 2);
	shady::Id vec3    = mod.type_vector(float_t, 3);
	shady::Id vec4    = mod.type_vector(float_t, 4);
	shady::Id mat4    = mod.type_matrix(vec4, 4);
	shady::Id fn_void = mod.type_function(void_t);

	shady::Id one   = mod.const_f32(float_t, 1.0);
	shady::Id idx0  = mod.const_i32(int_t, 0);
	shady::Id idx1  = mod.const_i32(int_t, 1);

	// --- uniform block: { mat4 projection; mat4 view; } at set 0, binding 0 ---
	shady::Id ubo_struct = mod.type_struct({ mat4, mat4 });
	mod.decorate(ubo_struct, shady::Decoration.BLOCK);
	mod.member_decorate(ubo_struct, 0, shady::Decoration.OFFSET, 0);
	mod.member_decorate(ubo_struct, 0, shady::Decoration.COL_MAJOR);
	mod.member_decorate(ubo_struct, 0, shady::Decoration.MATRIX_STRIDE, 16);
	mod.member_decorate(ubo_struct, 1, shady::Decoration.OFFSET, 64);
	mod.member_decorate(ubo_struct, 1, shady::Decoration.COL_MAJOR);
	mod.member_decorate(ubo_struct, 1, shady::Decoration.MATRIX_STRIDE, 16);
	mod.name(ubo_struct, "Uniforms");
	mod.member_name(ubo_struct, 0, "projection");
	mod.member_name(ubo_struct, 1, "view");

	shady::Id ubo_ptr = mod.type_pointer(shady::StorageClass.UNIFORM, ubo_struct);
	shady::Id ubo     = mod.global_var(ubo_ptr, shady::StorageClass.UNIFORM);
	mod.decorate(ubo, shady::Decoration.DESCRIPTOR_SET, 0);
	mod.decorate(ubo, shady::Decoration.BINDING, 0);
	mod.name(ubo, "uniforms");

	shady::Id mat4_uniform_ptr = mod.type_pointer(shady::StorageClass.UNIFORM, mat4);

	// --- texture + sampler at bindings 1 and 2 ---
	shady::Id image_t   = mod.type_image(float_t);
	shady::Id sampler_t = mod.type_sampler();
	shady::Id sampled_t = mod.type_sampled_image(image_t);

	shady::Id image_ptr   = mod.type_pointer(shady::StorageClass.UNIFORM_CONSTANT, image_t);
	shady::Id sampler_ptr = mod.type_pointer(shady::StorageClass.UNIFORM_CONSTANT, sampler_t);

	shady::Id tex = mod.global_var(image_ptr, shady::StorageClass.UNIFORM_CONSTANT);
	mod.decorate(tex, shady::Decoration.DESCRIPTOR_SET, 0);
	mod.decorate(tex, shady::Decoration.BINDING, 1);
	mod.name(tex, "tex");

	shady::Id samp = mod.global_var(sampler_ptr, shady::StorageClass.UNIFORM_CONSTANT);
	mod.decorate(samp, shady::Decoration.DESCRIPTOR_SET, 0);
	mod.decorate(samp, shady::Decoration.BINDING, 2);
	mod.name(samp, "tex_sampler");

	// --- vertex stage interface ---
	shady::Id in_vec3_ptr  = mod.type_pointer(shady::StorageClass.INPUT, vec3);
	shady::Id in_vec4_ptr  = mod.type_pointer(shady::StorageClass.INPUT, vec4);
	shady::Id in_vec2_ptr  = mod.type_pointer(shady::StorageClass.INPUT, vec2);
	shady::Id out_vec4_ptr = mod.type_pointer(shady::StorageClass.OUTPUT, vec4);
	shady::Id out_vec2_ptr = mod.type_pointer(shady::StorageClass.OUTPUT, vec2);

	shady::Id in_position = mod.global_var(in_vec3_ptr, shady::StorageClass.INPUT);
	mod.decorate(in_position, shady::Decoration.LOCATION, 0);
	shady::Id in_color = mod.global_var(in_vec4_ptr, shady::StorageClass.INPUT);
	mod.decorate(in_color, shady::Decoration.LOCATION, 1);
	shady::Id in_uv = mod.global_var(in_vec2_ptr, shady::StorageClass.INPUT);
	mod.decorate(in_uv, shady::Decoration.LOCATION, 2);

	// A bare variable decorated BuiltIn Position, rather than a gl_PerVertex
	// block. Both are valid; this one is less machinery.
	shady::Id gl_position = mod.global_var(out_vec4_ptr, shady::StorageClass.OUTPUT);
	mod.decorate(gl_position, shady::Decoration.BUILTIN, (Id)shady::Builtin.POSITION);

	shady::Id out_color = mod.global_var(out_vec4_ptr, shady::StorageClass.OUTPUT);
	mod.decorate(out_color, shady::Decoration.LOCATION, 0);
	shady::Id out_uv = mod.global_var(out_vec2_ptr, shady::StorageClass.OUTPUT);
	mod.decorate(out_uv, shady::Decoration.LOCATION, 1);

	// --- fragment stage interface ---
	shady::Id frag_color = mod.global_var(in_vec4_ptr, shady::StorageClass.INPUT);
	mod.decorate(frag_color, shady::Decoration.LOCATION, 0);
	shady::Id frag_uv = mod.global_var(in_vec2_ptr, shady::StorageClass.INPUT);
	mod.decorate(frag_uv, shady::Decoration.LOCATION, 1);
	shady::Id frag_out = mod.global_var(out_vec4_ptr, shady::StorageClass.OUTPUT);
	mod.decorate(frag_out, shady::Decoration.LOCATION, 0);

	// --- vertex shader ---
	shady::Function vs = mod.begin_function(void_t, fn_void);
	{
		shady::Id position = vs.load(vec3, in_position);
		shady::Id x = vs.composite_extract(float_t, position, 0);
		shady::Id y = vs.composite_extract(float_t, position, 1);
		shady::Id z = vs.composite_extract(float_t, position, 2);
		shady::Id local = vs.composite_construct(vec4, { x, y, z, one });

		shady::Id projection = vs.load(mat4, vs.access_chain(mat4_uniform_ptr, ubo, { idx0 }));
		shady::Id view       = vs.load(mat4, vs.access_chain(mat4_uniform_ptr, ubo, { idx1 }));

		shady::Id view_projection = vs.binop(shady::Opcode.MATRIX_TIMES_MATRIX, mat4, projection, view);
		shady::Id clip            = vs.binop(shady::Opcode.MATRIX_TIMES_VECTOR, vec4, view_projection, local);

		vs.store(gl_position, clip);
		vs.store(out_color, vs.load(vec4, in_color));
		vs.store(out_uv, vs.load(vec2, in_uv));
		vs.ret();
	}
	vs.end();
	mod.name(vs.id, "vert");
	mod.entry_point(shady::ExecutionModel.VERTEX, vs.id, "vert",
		{ in_position, in_color, in_uv, gl_position, out_color, out_uv });

	// --- fragment shader ---
	shady::Function fs = mod.begin_function(void_t, fn_void);
	{
		shady::Id image   = fs.load(image_t, tex);
		shady::Id sampler = fs.load(sampler_t, samp);
		shady::Id texel   = fs.image_sample(vec4, fs.sampled_image(sampled_t, image, sampler), fs.load(vec2, frag_uv));
		shady::Id tinted  = fs.binop(shady::Opcode.F_MUL, vec4, texel, fs.load(vec4, frag_color));
		fs.store(frag_out, tinted);
		fs.ret();
	}
	fs.end();
	mod.name(fs.id, "frag");
	mod.entry_point(shady::ExecutionModel.FRAGMENT, fs.id, "frag", { frag_color, frag_uv, frag_out });
	mod.execution_mode(fs.id, shady::ExecutionMode.ORIGIN_UPPER_LEFT);

	// --- emit ---
	char[] spirv = mod.build(mem);
	defer free(spirv);

	test::@check(spirv.len % 4 == 0, "SPIR-V must be a whole number of words, got %d bytes", spirv.len);
	test::@check(((uint*)spirv.ptr)[0] == shady::MAGIC, "the header should start with the SPIR-V magic");
	test::@check(((uint*)spirv.ptr)[3] == mod.next_id,
		"the bound should be the next unused id: header says %d, module says %d",
		((uint*)spirv.ptr)[3], mod.next_id);

	path::mkdir(OUT_DIR, recursive: true)!!;
	file::save(string::tformat("%s/cube.spirv", OUT_DIR), spirv)!!;
	io::printfn("shady: wrote %s/cube.spirv, %d bytes, bound %d", OUT_DIR, spirv.len, mod.next_id);
}

// --- The module builder's version and memory model ----------------------------

<*
 Each feature asks for the version it needs, in whatever order the shader
 reaches them, so a later, smaller request must not undo an earlier one: a
 ray-tracing module that also uses device addresses is 1.4, not 1.3.
*>
fn void require_version_never_lowers() @test
{
	shady::Module mod;
	mod.init(mem);
	defer mod.free();

	test::@check(mod.version == shady::VERSION_1_0, "mod.version");
	mod.require_version(shady::VERSION_1_4);
	mod.require_version(shady::VERSION_1_3);
	mod.require_version(shady::VERSION_1_1);
	test::@check(mod.version == shady::VERSION_1_4, "mod.version");
}

<*
 Device addresses change the addressing model after a cooperative matrix may
 already have made the module a Vulkan-memory-model one; the second half of
 the instruction has to survive the first changing.
*>
fn void changing_the_addressing_model_keeps_the_memory_model() @test
{
	shady::Module mod;
	mod.init(mem);
	defer mod.free();

	mod.set_memory_model(shady::AddressingModel.LOGICAL, shady::MemoryModel.VULKAN);
	mod.set_addressing_model(shady::AddressingModel.PHYSICAL_STORAGE_BUFFER64);

	uint[] words = mod.memory_model.array_view();
	test::@check(words.len == 3, "words.len");
	test::@check(words[1] == (uint)shady::AddressingModel.PHYSICAL_STORAGE_BUFFER64, "words[1]");
	test::@check(words[2] == (uint)shady::MemoryModel.VULKAN, "words[2]");
}

fn void has_capability_reads_the_section() @test
{
	shady::Module mod;
	mod.init(mem);
	defer mod.free();

	mod.capability(shady::Capability.SHADER);
	mod.capability(shady::Capability.RAY_QUERY_KHR);
	test::@check(mod.has_capability(shady::Capability.RAY_QUERY_KHR), "the capability was declared");
	test::@check(!mod.has_capability(shady::Capability.RAY_TRACING_KHR), "this one was not");
}

<*
 The ray-tracing vocabulary, spot-checked against the SPIR-V grammar: one
 value from each numbering space, since a wrong number here is a module that
 means something else rather than one that fails to build.
*>
fn void the_ray_tracing_numbers_match_the_grammar() @test
{
	test::@check((uint)shady::Opcode.TRACE_RAY_KHR == 4445, "(uint)shady::Opcode.TRACE_RAY_KHR");
	test::@check((uint)shady::Opcode.TYPE_ACCELERATION_STRUCTURE_KHR == 5341, "(uint)shady::Opcode.TYPE_ACCELERATION_STRUCTURE_KHR");
	test::@check((uint)shady::Opcode.RAY_QUERY_PROCEED_KHR == 4477, "(uint)shady::Opcode.RAY_QUERY_PROCEED_KHR");
	test::@check((uint)shady::Opcode.RAY_QUERY_GET_INTERSECTION_WORLD_TO_OBJECT_KHR == 6032, "(uint)shady::Opcode.RAY_QUERY_GET_INTERSECTION_WORLD_TO_OBJECT_KHR");
	test::@check((uint)shady::ExecutionModel.RAY_GENERATION == 5313, "(uint)shady::ExecutionModel.RAY_GENERATION");
	test::@check((uint)shady::ExecutionModel.CALLABLE == 5318, "(uint)shady::ExecutionModel.CALLABLE");
	test::@check((uint)shady::StorageClass.INCOMING_RAY_PAYLOAD == 5342, "(uint)shady::StorageClass.INCOMING_RAY_PAYLOAD");
	test::@check((uint)shady::Builtin.RAY_GEOMETRY_INDEX == 5352, "(uint)shady::Builtin.RAY_GEOMETRY_INDEX");
	test::@check((uint)shady::Capability.RAY_TRACING_KHR == 4479, "(uint)shady::Capability.RAY_TRACING_KHR");
	test::@check((uint)shady::RayFlags.SKIP_AABBS == 0x200, "(uint)shady::RayFlags.SKIP_AABBS");
	test::@check(shady::VERSION_1_4 == 0x00010400, "shady::VERSION_1_4");
}

<*
 The storage-image vocabulary, spot-checked against the SPIR-V grammar: one
 value from each numbering space, and both ends of the format table.
*>
fn void the_storage_image_numbers_match_the_grammar() @test
{
	test::@check((uint)shady::Opcode.IMAGE_READ == 98, "(uint)shady::Opcode.IMAGE_READ");
	test::@check((uint)shady::Opcode.IMAGE_WRITE == 99, "(uint)shady::Opcode.IMAGE_WRITE");
	test::@check((uint)shady::Opcode.IMAGE_QUERY_SIZE == 104, "(uint)shady::Opcode.IMAGE_QUERY_SIZE");
	test::@check((uint)shady::Opcode.IMAGE_TEXEL_POINTER == 60, "(uint)shady::Opcode.IMAGE_TEXEL_POINTER");
	test::@check((uint)shady::Capability.IMAGE_1D == 44, "(uint)shady::Capability.IMAGE_1D");
	test::@check((uint)shady::Capability.IMAGE_CUBE_ARRAY == 34, "(uint)shady::Capability.IMAGE_CUBE_ARRAY");
	test::@check((uint)shady::Capability.STORAGE_IMAGE_EXTENDED_FORMATS == 49, "(uint)shady::Capability.STORAGE_IMAGE_EXTENDED_FORMATS");
	test::@check((uint)shady::Capability.STORAGE_IMAGE_READ_WITHOUT_FORMAT == 55, "(uint)shady::Capability.STORAGE_IMAGE_READ_WITHOUT_FORMAT");
	test::@check((uint)shady::Capability.STORAGE_IMAGE_WRITE_WITHOUT_FORMAT == 56, "(uint)shady::Capability.STORAGE_IMAGE_WRITE_WITHOUT_FORMAT");
	test::@check((uint)shady::Capability.STORAGE_IMAGE_ARRAY_NON_UNIFORM_INDEXING == 5309, "(uint)shady::Capability.STORAGE_IMAGE_ARRAY_NON_UNIFORM_INDEXING");
	test::@check((uint)shady::StorageClass.IMAGE == 11, "(uint)shady::StorageClass.IMAGE");
	test::@check((uint)shady::Decoration.NON_WRITABLE == 24, "(uint)shady::Decoration.NON_WRITABLE");
	test::@check((uint)shady::Decoration.NON_READABLE == 25, "(uint)shady::Decoration.NON_READABLE");
	test::@check((uint)shady::MemorySemantics.IMAGE_MEMORY == 0x800, "(uint)shady::MemorySemantics.IMAGE_MEMORY");
	test::@check((uint)shady::ImageFormat.RGBA32F == 1, "(uint)shady::ImageFormat.RGBA32F");
	test::@check((uint)shady::ImageFormat.R11F_G11F_B10F == 8, "(uint)shady::ImageFormat.R11F_G11F_B10F");
	test::@check((uint)shady::ImageFormat.R32UI == 33, "(uint)shady::ImageFormat.R32UI");
	test::@check((uint)shady::ImageFormat.R8UI == 39, "(uint)shady::ImageFormat.R8UI");
}
