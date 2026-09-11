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

	mod.capability(shady::CAPABILITY_SHADER);
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
	mod.decorate(ubo_struct, shady::DECORATION_BLOCK);
	mod.member_decorate(ubo_struct, 0, shady::DECORATION_OFFSET, 0);
	mod.member_decorate(ubo_struct, 0, shady::DECORATION_COL_MAJOR);
	mod.member_decorate(ubo_struct, 0, shady::DECORATION_MATRIX_STRIDE, 16);
	mod.member_decorate(ubo_struct, 1, shady::DECORATION_OFFSET, 64);
	mod.member_decorate(ubo_struct, 1, shady::DECORATION_COL_MAJOR);
	mod.member_decorate(ubo_struct, 1, shady::DECORATION_MATRIX_STRIDE, 16);
	mod.name(ubo_struct, "Uniforms");
	mod.member_name(ubo_struct, 0, "projection");
	mod.member_name(ubo_struct, 1, "view");

	shady::Id ubo_ptr = mod.type_pointer(shady::STORAGE_CLASS_UNIFORM, ubo_struct);
	shady::Id ubo     = mod.global_var(ubo_ptr, shady::STORAGE_CLASS_UNIFORM);
	mod.decorate(ubo, shady::DECORATION_DESCRIPTOR_SET, 0);
	mod.decorate(ubo, shady::DECORATION_BINDING, 0);
	mod.name(ubo, "uniforms");

	shady::Id mat4_uniform_ptr = mod.type_pointer(shady::STORAGE_CLASS_UNIFORM, mat4);

	// --- texture + sampler at bindings 1 and 2 ---
	shady::Id image_t   = mod.type_image(float_t);
	shady::Id sampler_t = mod.type_sampler();
	shady::Id sampled_t = mod.type_sampled_image(image_t);

	shady::Id image_ptr   = mod.type_pointer(shady::STORAGE_CLASS_UNIFORM_CONSTANT, image_t);
	shady::Id sampler_ptr = mod.type_pointer(shady::STORAGE_CLASS_UNIFORM_CONSTANT, sampler_t);

	shady::Id tex = mod.global_var(image_ptr, shady::STORAGE_CLASS_UNIFORM_CONSTANT);
	mod.decorate(tex, shady::DECORATION_DESCRIPTOR_SET, 0);
	mod.decorate(tex, shady::DECORATION_BINDING, 1);
	mod.name(tex, "tex");

	shady::Id samp = mod.global_var(sampler_ptr, shady::STORAGE_CLASS_UNIFORM_CONSTANT);
	mod.decorate(samp, shady::DECORATION_DESCRIPTOR_SET, 0);
	mod.decorate(samp, shady::DECORATION_BINDING, 2);
	mod.name(samp, "tex_sampler");

	// --- vertex stage interface ---
	shady::Id in_vec3_ptr  = mod.type_pointer(shady::STORAGE_CLASS_INPUT, vec3);
	shady::Id in_vec4_ptr  = mod.type_pointer(shady::STORAGE_CLASS_INPUT, vec4);
	shady::Id in_vec2_ptr  = mod.type_pointer(shady::STORAGE_CLASS_INPUT, vec2);
	shady::Id out_vec4_ptr = mod.type_pointer(shady::STORAGE_CLASS_OUTPUT, vec4);
	shady::Id out_vec2_ptr = mod.type_pointer(shady::STORAGE_CLASS_OUTPUT, vec2);

	shady::Id in_position = mod.global_var(in_vec3_ptr, shady::STORAGE_CLASS_INPUT);
	mod.decorate(in_position, shady::DECORATION_LOCATION, 0);
	shady::Id in_color = mod.global_var(in_vec4_ptr, shady::STORAGE_CLASS_INPUT);
	mod.decorate(in_color, shady::DECORATION_LOCATION, 1);
	shady::Id in_uv = mod.global_var(in_vec2_ptr, shady::STORAGE_CLASS_INPUT);
	mod.decorate(in_uv, shady::DECORATION_LOCATION, 2);

	// A bare variable decorated BuiltIn Position, rather than a gl_PerVertex
	// block. Both are valid; this one is less machinery.
	shady::Id gl_position = mod.global_var(out_vec4_ptr, shady::STORAGE_CLASS_OUTPUT);
	mod.decorate(gl_position, shady::DECORATION_BUILTIN, shady::BUILTIN_POSITION);

	shady::Id out_color = mod.global_var(out_vec4_ptr, shady::STORAGE_CLASS_OUTPUT);
	mod.decorate(out_color, shady::DECORATION_LOCATION, 0);
	shady::Id out_uv = mod.global_var(out_vec2_ptr, shady::STORAGE_CLASS_OUTPUT);
	mod.decorate(out_uv, shady::DECORATION_LOCATION, 1);

	// --- fragment stage interface ---
	shady::Id frag_color = mod.global_var(in_vec4_ptr, shady::STORAGE_CLASS_INPUT);
	mod.decorate(frag_color, shady::DECORATION_LOCATION, 0);
	shady::Id frag_uv = mod.global_var(in_vec2_ptr, shady::STORAGE_CLASS_INPUT);
	mod.decorate(frag_uv, shady::DECORATION_LOCATION, 1);
	shady::Id frag_out = mod.global_var(out_vec4_ptr, shady::STORAGE_CLASS_OUTPUT);
	mod.decorate(frag_out, shady::DECORATION_LOCATION, 0);

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

		shady::Id view_projection = vs.binop(shady::OP_MATRIX_TIMES_MATRIX, mat4, projection, view);
		shady::Id clip            = vs.binop(shady::OP_MATRIX_TIMES_VECTOR, vec4, view_projection, local);

		vs.store(gl_position, clip);
		vs.store(out_color, vs.load(vec4, in_color));
		vs.store(out_uv, vs.load(vec2, in_uv));
		vs.ret();
	}
	vs.end();
	mod.name(vs.id, "vert");
	mod.entry_point(shady::EXECUTION_MODEL_VERTEX, vs.id, "vert",
		{ in_position, in_color, in_uv, gl_position, out_color, out_uv });

	// --- fragment shader ---
	shady::Function fs = mod.begin_function(void_t, fn_void);
	{
		shady::Id image   = fs.load(image_t, tex);
		shady::Id sampler = fs.load(sampler_t, samp);
		shady::Id texel   = fs.image_sample(vec4, fs.sampled_image(sampled_t, image, sampler), fs.load(vec2, frag_uv));
		shady::Id tinted  = fs.binop(shady::OP_F_MUL, vec4, texel, fs.load(vec4, frag_color));
		fs.store(frag_out, tinted);
		fs.ret();
	}
	fs.end();
	mod.name(fs.id, "frag");
	mod.entry_point(shady::EXECUTION_MODEL_FRAGMENT, fs.id, "frag", { frag_color, frag_uv, frag_out });
	mod.execution_mode(fs.id, shady::EXECUTION_MODE_ORIGIN_UPPER_LEFT);

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
