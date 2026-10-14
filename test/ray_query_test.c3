<*
 Inline ray queries and the acceleration structures they trace against: what
 each method lowers to, the capability and version a ray makes a module need,
 the interfaces a SPIR-V 1.4 module's entry points list, and the refusals that
 keep a query and a descriptor out of memory.

 `test/conformance/ray_query.shady` hands a whole module to `spirv-val`; these
 pin the instructions and the refusals, which the validator never sees.
*>
module ray_query_test;

import std::core::test;
import shady;
import shady_support;

const String SCENE = `
accel scene @set(0) @binding(0);
struct FragmentIn { float4 position @position; float3 world; }
`;

<*
 A fragment shader with a query `q` aimed at the scene, then `body`, before
 `return result;`.
*>
fn String query(String body)
{
	return string::tformat(`%s
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    q.init(scene, RAY_FLAG_NONE, 0xFF, input.world, 0.001, float3(0.0, 1.0, 0.0), 100.0);
    float4 result = float4(0.0);
%s
    return result;
}
`, SCENE, body);
}

// --- The acceleration structure ---------------------------------------------

fn void an_accel_binds_like_a_texture() @test
{
	char[] spirv = shady_support::build(string::tformat(`%s
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`, SCENE));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.TYPE_ACCELERATION_STRUCTURE_KHR),
		"an accel is an OpTypeAccelerationStructureKHR");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.DESCRIPTOR_SET, 0)
		&& shady_support::has_decoration_value(spirv, shady::Decoration.BINDING, 0),
		"and a descriptor with a set and a binding");
	// Declared but traced against by nothing: still a type that needs one of
	// the two ray capabilities, and so still a 1.4 module.
	test::@check(shady_support::has_capability(spirv, shady::Capability.RAY_QUERY_KHR),
		"an accel nothing traces still declares RayQueryKHR");
	test::@check(shady_support::version(spirv) == shady::VERSION_1_4, "and is a SPIR-V 1.4 module");
}

fn void the_hlsl_name_is_the_same_type() @test
{
	String error = shady_support::compile_error(`
RaytracingAccelerationStructure scene;
struct FragmentIn { float4 position @position; }
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    q.init(scene, 0u, 0xFF, float3(0.0), 0.0, float3(1.0), 1.0);
    return float4(1.0);
}
`);
	test::@check(error == "", "HLSL's name for an accel traces like `accel`; got '%s'", error);
}

<*
 A table of scenes indexed non-uniformly: the index and the slot carry
 NonUniform, the array is a runtime descriptor array - and the sampled-image
 capability stays out, since there is no image in sight.
*>
fn void an_accel_array_is_indexed_like_a_texture_table() @test
{
	char[] spirv = shady_support::build(`
accel scenes[];
struct Push @pushconstant { uint which; }
Push push;
struct FragmentIn { float4 position @position; }
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    q.init(scenes[NonUniformResourceIndex(push.which)], 0u, 0xFF, float3(0.0), 0.0, float3(1.0), 1.0);
    return float4(1.0);
}
`);
	defer free(spirv);

	test::@check(shady_support::has_capability(spirv, shady::Capability.RUNTIME_DESCRIPTOR_ARRAY), "a runtime descriptor array");
	test::@check(shady_support::decoration_count(spirv, shady::Decoration.NON_UNIFORM) >= 3,
		"the index, the slot and the loaded accel are NonUniform");
	test::@check(!shady_support::has_capability(spirv, shady::Capability.SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING),
		"no image capability for a table of scenes");
}

// --- What a query lowers to ---------------------------------------------------

fn void a_query_traces_in_any_stage() @test
{
	char[] spirv = shady_support::build(query(`
    while (q.proceed())
    {
        if (q.candidate_type() == CANDIDATE_NON_OPAQUE_TRIANGLE) q.confirm();
        if (q.candidate_type() == CANDIDATE_PROCEDURAL_PRIMITIVE && q.candidate_aabb_opaque()) q.generate(0.5);
    }
    if (q.committed_type() != COMMITTED_NOTHING) result.x = q.committed_t();
    q.terminate();
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.TYPE_RAY_QUERY_KHR), "the query's type");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_INITIALIZE_KHR), "init");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_PROCEED_KHR), "proceed");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_CONFIRM_INTERSECTION_KHR), "confirm");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_GENERATE_INTERSECTION_KHR), "generate");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_TERMINATE_KHR), "terminate");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_GET_INTERSECTION_TYPE_KHR), "the intersection type");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.RAY_QUERY_GET_INTERSECTION_CANDIDATE_AABB_OPAQUE_KHR), "aabb opacity");
	test::@check(shady_support::has_capability(spirv, shady::Capability.RAY_QUERY_KHR), "RayQueryKHR");
	test::@check(shady_support::has_extension(spirv, "SPV_KHR_ray_query"), "SPV_KHR_ray_query");
	test::@check(shady_support::version(spirv) == shady::VERSION_1_4, "a 1.4 module");
}

fn void every_getter_has_its_instruction() @test
{
	char[] spirv = shady_support::build(query(`
    q.proceed();
    uint  a = q.committed_instance_custom_index() + q.committed_instance_id() + q.committed_sbt_offset()
            + q.committed_geometry_index() + q.committed_primitive_index() + q.ray_flags();
    float b = q.committed_t() + q.ray_tmin();
    float2 bary = q.committed_barycentrics();
    float3 c = q.committed_object_ray_origin() + q.committed_object_ray_direction()
             + q.world_ray_origin() + q.world_ray_direction();
    float4x3 m = q.committed_object_to_world();
    float4x3 n = q.candidate_world_to_object();
    if (q.committed_front_face()) result = float4(c, float(a) + b + bary.x + m[0].x + n[1].y);
`));
	defer free(spirv);

	shady::Opcode[*] getters = {
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_CUSTOM_INDEX_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_ID_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_SBT_RECORD_OFFSET_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_GEOMETRY_INDEX_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_PRIMITIVE_INDEX_KHR,
		shady::Opcode.RAY_QUERY_GET_RAY_FLAGS_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_T_KHR,
		shady::Opcode.RAY_QUERY_GET_RAY_T_MIN_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_BARYCENTRICS_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_RAY_ORIGIN_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_RAY_DIRECTION_KHR,
		shady::Opcode.RAY_QUERY_GET_WORLD_RAY_ORIGIN_KHR,
		shady::Opcode.RAY_QUERY_GET_WORLD_RAY_DIRECTION_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_TO_WORLD_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_WORLD_TO_OBJECT_KHR,
		shady::Opcode.RAY_QUERY_GET_INTERSECTION_FRONT_FACE_KHR,
	};
	foreach (opcode : getters)
	{
		test::@check(shady_support::has_opcode(spirv, opcode), "getter opcode %d is missing", (uint)opcode);
	}
}

<*
 The integer getters answer in uint, like the constants they are compared
 with, so `q.committed_type() == COMMITTED_NOTHING` needs no cast.
*>
fn void the_integer_getters_are_uint() @test
{
	String error = shady_support::compile_error(query(`
    uint kind = q.committed_type();
    uint prim = q.candidate_primitive_index();
    result.x = float(kind + prim);
`));
	test::@check(error == "", "got '%s'", error);
}

// --- Interfaces ---------------------------------------------------------------

<*
 A ray-tracing module is SPIR-V 1.4, where an entry point lists every global its
 call tree uses - and only those. The vertex shader lists its uniform block and
 not the scene; the fragment shader lists the scene and not the uniforms, even
 though the scene is reached through a helper.
*>
fn void each_entry_point_lists_what_it_reaches() @test
{
	char[] spirv = shady_support::build(`
struct Uniforms @uniform { float4x4 mvp; }
Uniforms uniforms;
accel scene;
struct VertexIn { float3 position; }
struct FragmentIn { float4 position @position; float3 world; }

fn bool hits(inout RayQuery q, float3 p)
{
    q.init(scene, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xFF, p, 0.001, float3(0.0, 1.0, 0.0), 100.0);
    while (q.proceed()) {}
    return q.committed_type() != COMMITTED_NOTHING;
}

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn o;
    o.position = uniforms.mvp * float4(input.position, 1.0);
    o.world = input.position;
    return o;
}

fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    return hits(q, input.world) ? float4(0.0) : float4(1.0);
}

struct ComputeIn { uint3 id @builtin(global_invocation_id); }
fn void main(ComputeIn at) @compute @threads(1, 1, 1)
{
    RayQuery q;
    hits(q, float3(at.id));
}
`);
	defer free(spirv);

	test::@check(shady_support::interface_count(spirv, "vert", shady::StorageClass.UNIFORM) == 1, "the vertex shader lists its uniforms");
	test::@check(shady_support::interface_count(spirv, "vert", shady::StorageClass.UNIFORM_CONSTANT) == 0, "and not the scene");
	test::@check(shady_support::interface_count(spirv, "frag", shady::StorageClass.UNIFORM_CONSTANT) == 1,
		"the fragment shader lists the scene its helper traces");
	test::@check(shady_support::interface_count(spirv, "frag", shady::StorageClass.UNIFORM) == 0, "and not the uniforms");
	test::@check(shady_support::interface_count(spirv, "main", shady::StorageClass.UNIFORM_CONSTANT) == 1,
		"a second caller of the helper lists the scene too");
}

<*
 Device addresses want 1.3 and are written once the shader has been walked -
 after the query asked for 1.4, which they must not undo.
*>
fn void device_addresses_keep_the_module_at_1_4() @test
{
	char[] spirv = shady_support::build(string::tformat(`%s
struct Vertex @address { float3 position; }
struct Ptrs @uniform { Vertex* verts; }
Ptrs ptrs;
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    q.init(scene, 0u, 0xFF, ptrs.verts[0].position, 0.0, float3(1.0), 1.0);
    return float4(1.0);
}
`, SCENE));
	defer free(spirv);

	test::@check(shady_support::version(spirv) == shady::VERSION_1_4, "still 1.4");
	test::@check(shady_support::has_capability(spirv, shady::Capability.PHYSICAL_STORAGE_BUFFER_ADDRESSES), "with addresses");
}

fn void skipping_geometry_is_a_capability_of_its_own() @test
{
	char[] plain = shady_support::build(query("    q.proceed();"));
	defer free(plain);
	test::@check(!shady_support::has_capability(plain, shady::Capability.RAY_TRAVERSAL_PRIMITIVE_CULLING_KHR),
		"no culling capability without a SKIP flag");

	char[] culling = shady_support::build(string::tformat(`%s
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery q;
    q.init(scene, RAY_FLAG_SKIP_TRIANGLES, 0xFF, input.world, 0.0, float3(1.0), 1.0);
    return float4(1.0);
}
`, SCENE));
	defer free(culling);
	test::@check(shady_support::has_capability(culling, shady::Capability.RAY_TRAVERSAL_PRIMITIVE_CULLING_KHR),
		"RAY_FLAG_SKIP_TRIANGLES asks for primitive culling");
}

fn void a_shader_constant_shadows_a_ray_constant() @test
{
	String error = shady_support::compile_error(string::tformat(`%s
const float RAY_FLAG_NONE = 2.5;
fn float4 frag(FragmentIn input) @fragment
{
    return float4(RAY_FLAG_NONE);
}
`, SCENE));
	test::@check(error == "", "the shader's own name wins; got '%s'", error);
}

// --- Refusals -----------------------------------------------------------------

fn String refused(String source) => shady_support::compile_error(string::tformat("%s\n%s", SCENE, source));

fn void a_query_is_a_local_or_a_reference() @test
{
	String error = refused(`
fn bool f(RayQuery q) { return true; }
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("inout RayQuery q"), "a by-value query parameter; got '%s'", error);

	error = refused(`
fn RayQuery f();
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("cannot return a RayQuery"), "a returned query; got '%s'", error);

	error = refused(`
struct Holder { RayQuery q; }
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("`Holder.q` cannot be a RayQuery"), "a query member; got '%s'", error);

	error = refused(`
RayQuery global_query;
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("declare it as a local"), "a module-level query; got '%s'", error);

	error = refused(`
shared RayQuery queries[4];
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("cannot be shared"), "a shared query; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment { RayQuery qs[2]; return float4(1.0); }
`);
	test::@check(error.contains("array of RayQuery"), "an array of queries; got '%s'", error);
}

fn void a_query_is_not_a_value() @test
{
	String error = refused(`
fn float4 frag(FragmentIn input) @fragment { RayQuery a; RayQuery b = a; return float4(1.0); }
`);
	test::@check(error.contains("starts empty"), "an initialised query; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment { RayQuery a; RayQuery b; b = a; return float4(1.0); }
`);
	test::@check(error.contains("cannot be assigned"), "an assigned query; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment
{
    RayQuery a; RayQuery b;
    RayQuery c;
    bool pick = input.world.x > 0.0;
    (pick ? a : b).proceed();
    return float4(1.0);
}
`);
	test::@check(error.contains("`?:` cannot choose a RayQuery"), "a chosen query; got '%s'", error);

	error = refused(`
fn bool step(inout RayQuery q) { return q.proceed(); }
fn float4 frag(FragmentIn input) @fragment { RayQuery a; step(&a); return float4(1.0); }
`);
	test::@check(error.contains("a RayQuery has no operators"), "the address of a query; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment { RayQuery a; a.trace(); return float4(1.0); }
`);
	test::@check(error.contains("a RayQuery has no method `trace`"), "an unknown method; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment { RayQuery a; a.init(scene, 0u, 0xFF, float3(0.0), 0.0, float3(1.0)); return float4(1.0); }
`);
	test::@check(error.contains("`init` takes 7 arguments"), "a short init; got '%s'", error);

	error = refused(`
Sampler2D tex;
fn float4 frag(FragmentIn input) @fragment { RayQuery a; a.init(tex, 0u, 0xFF, float3(0.0), 0.0, float3(1.0), 1.0); return float4(1.0); }
`);
	test::@check(error.contains("traces against an `accel`"), "init against a texture; got '%s'", error);
}

<*
 A descriptor is bound by the host, so it is a module-level variable and
 nothing else: these were all modules Vulkan refuses, because an image, a
 sampler or a scene cannot be stored into a Function variable.
*>
fn void a_descriptor_lives_at_module_level() @test
{
	String error = refused(`
Sampler2D tex;
fn float4 frag(FragmentIn input) @fragment { Sampler2D copy = tex; return float4(1.0); }
`);
	test::@check(error.contains("cannot be a local"), "a texture local; got '%s'", error);

	error = refused(`
Sampler2D tex;
fn float4 shade(Sampler2D t, float2 uv) { return t.sample_lod(uv, 0.0); }
fn float4 frag(FragmentIn input) @fragment { return shade(tex, float2(0.5)); }
`);
	test::@check(error.contains("cannot be a parameter"), "a texture parameter; got '%s'", error);

	error = refused(`
fn float4 frag(FragmentIn input) @fragment { accel other; return float4(1.0); }
`);
	test::@check(error.contains("cannot be a local"), "an accel local; got '%s'", error);

	error = refused(`
struct Bundle @uniform { accel inner; }
fn float4 frag(FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("`Bundle.inner` cannot be an accel"),
		"an accel member; got '%s'", error);

	error = refused(`
accel second;
fn float4 frag(FragmentIn input) @fragment { second = scene; return float4(1.0); }
`);
	test::@check(error.contains("cannot be assigned"), "an assigned accel; got '%s'", error);
}
