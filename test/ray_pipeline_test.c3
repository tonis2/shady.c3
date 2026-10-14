<*
 The ray-tracing pipeline stages: how an entry point's parameters become its
 payload, its hit attributes and its built-ins, what `trace_ray` and the other
 calls lower to, and the refusals that keep each call in the stages that have
 it.

 `test/conformance/ray_pipeline.shady` hands every stage to `spirv-val`; these
 pin what the validator cannot see - the copies, the interfaces, and the
 shaders it never receives because they were refused.
*>
module ray_pipeline_test;

import std::core::test;
import shady;
import shady_support;

const String COMMON = `
accel scene;
float4 pixels[];
struct Payload { float3 color; }
struct Bary { float2 uv; }
struct LaunchIn { uint3 id @builtin(launch_id); uint3 size @builtin(launch_size); }
struct HitIn { uint kind @builtin(hit_kind); float t @builtin(ray_tmax); }
`;

fn String shader(String body) => string::tformat("%s\n%s", COMMON, body);
fn String refused(String body) => shady_support::compile_error(shader(body));

const String RAYGEN = `
fn void gen(LaunchIn at) @raygen
{
    Payload p;
    p.color = float3(0.0);
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, float3(0.0), 0.001, float3(0.0, 0.0, 1.0), 100.0, p);
    pixels[at.id.x] = float4(p.color, 1.0);
}
`;

fn void every_stage_is_its_execution_model() @test
{
	char[] spirv = shady_support::build(shader(string::tformat(`%s
fn void sky(inout Payload p) @miss { p.color = float3(1.0); }
fn void hit(inout Payload p, Bary b, HitIn h) @closest_hit { p.color = float3(b.uv, h.t); }
fn void alpha(inout Payload p, Bary b) @any_hit { if (b.uv.x > 0.5) ignore_intersection(); }
struct Sphere { float3 normal; }
fn void ball(LaunchIn at) @intersection { Sphere s; s.normal = float3(1.0); report_intersection(1.0, 0u, s); }
struct Material { float3 albedo; }
fn void shade(inout Material m) @callable { m.albedo = float3(0.5); }
`, RAYGEN)));
	defer free(spirv);

	shady::ExecutionModel[*] models = {
		shady::ExecutionModel.RAY_GENERATION, shady::ExecutionModel.MISS, shady::ExecutionModel.CLOSEST_HIT,
		shady::ExecutionModel.ANY_HIT, shady::ExecutionModel.INTERSECTION, shady::ExecutionModel.CALLABLE,
	};
	foreach (model : models)
	{
		test::@check(shady_support::has_execution_model(spirv, model), "execution model %d is missing", (uint)model);
	}
	test::@check(shady_support::has_capability(spirv, shady::Capability.RAY_TRACING_KHR), "RayTracingKHR");
	test::@check(shady_support::has_extension(spirv, "SPV_KHR_ray_tracing"), "SPV_KHR_ray_tracing");
	test::@check(shady_support::version(spirv) == shady::VERSION_1_4, "a 1.4 module");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.TRACE_RAY_KHR), "OpTraceRayKHR");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.REPORT_INTERSECTION_KHR), "OpReportIntersectionKHR");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.IGNORE_INTERSECTION_KHR), "OpIgnoreIntersectionKHR");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.BUILTIN, (uint)shady::Builtin.LAUNCH_ID), "LaunchId");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.BUILTIN, (uint)shady::Builtin.HIT_KIND), "HitKind");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.BUILTIN, (uint)shady::Builtin.RAY_TMAX), "RayTmax");
}

<*
 The payload a hit or miss shader is handed is its caller's, reached in place:
 the shader's writes are access chains into the IncomingRayPayload variable,
 with no copy - and each entry point lists exactly one, its own.
*>
fn void an_incoming_payload_is_reached_in_place() @test
{
	char[] spirv = shady_support::build(shader(`
struct Shadow { bool lit; }
fn void sky(inout Payload p) @miss { p.color = float3(1.0); }
fn void shadow(inout Shadow s) @miss { s.lit = true; }
`));
	defer free(spirv);

	test::@check(shady_support::interface_count(spirv, "sky", shady::StorageClass.INCOMING_RAY_PAYLOAD) == 1, "sky has its payload");
	test::@check(shady_support::interface_count(spirv, "shadow", shady::StorageClass.INCOMING_RAY_PAYLOAD) == 1,
		"and the shadow miss its own - not both");
	test::@check(shady_support::interface_size(spirv, "shadow") == 1, "and nothing else");
}

<*
 A payload handed to a helper by reference, or used as a `&self` receiver,
 travels through a Function copy - and comes back: the call's writes land in
 the caller's payload, not in the copy.
*>
fn void a_payload_keeps_what_a_helper_writes() @test
{
	char[] spirv = shady_support::build(shader(`
fn void darken(inout Payload p) { p.color = p.color * 0.5; }
fn void Payload.brighten(&self) { self.color = self.color * 2.0; }
fn void sky(inout Payload p) @miss
{
    darken(p);
    p.brighten();
}
`));
	defer free(spirv);

	// The miss shader writes nothing itself, so every store into the incoming
	// payload is a write-back: one for the helper, one for the method.
	uint* words   = (uint*)spirv.ptr;
	usz   count   = spirv.len / 4;
	uint  payload = 0;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) == (uint)shady::Opcode.VARIABLE
			&& words[i + 3] == (uint)shady::StorageClass.INCOMING_RAY_PAYLOAD) payload = words[i + 2];
	}
	uint writebacks = 0;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) == (uint)shady::Opcode.STORE && words[i + 1] == payload) writebacks++;
	}
	test::@check(payload != 0, "the miss shader has an incoming payload");
	test::@check(writebacks == 2, "each call writes the payload back; got %d", writebacks);
}

fn void a_hit_shader_reads_its_attributes() @test
{
	char[] spirv = shady_support::build(shader(`
fn void hit(inout Payload p, Bary b) @closest_hit
{
    b.uv = b.uv * 2.0;
    p.color = float3(b.uv, 0.0);
}
`));
	defer free(spirv);

	test::@check(shady_support::interface_count(spirv, "hit", shady::StorageClass.HIT_ATTRIBUTE) == 1,
		"the hit attributes are in the interface");
}

fn void a_terminator_works_from_a_helper() @test
{
	String error = refused(`
fn void drop(Bary b) { if (b.uv.x > 0.5) ignore_intersection(); }
fn void stop() { terminate_ray(); }
fn void alpha(inout Payload p, Bary b) @any_hit
{
    drop(b);
    if (b.uv.y > 0.5) stop();
}
`);
	test::@check(error == "", "an any-hit shader may decide in a helper; got '%s'", error);
}

fn void a_callable_gets_its_data_back() @test
{
	char[] spirv = shady_support::build(shader(`
struct Material { float3 albedo; }
fn void gen(LaunchIn at) @raygen
{
    Material m;
    m.albedo = float3(1.0);
    execute_callable(0u, m);
    pixels[at.id.x] = float4(m.albedo, 1.0);
}
fn void shade(inout Material m) @callable { m.albedo = float3(0.5); }
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.EXECUTE_CALLABLE_KHR), "OpExecuteCallableKHR");
	test::@check(shady_support::interface_count(spirv, "gen", shady::StorageClass.CALLABLE_DATA) == 1, "the caller's data");
	test::@check(shady_support::interface_count(spirv, "shade", shady::StorageClass.INCOMING_CALLABLE_DATA) == 1, "the callee's");
}

// --- Refusals -----------------------------------------------------------------

fn void a_builtin_is_in_the_stages_that_have_it() @test
{
	String error = refused(`
fn void sky(inout Payload p, HitIn h) @miss { p.color = float3(h.t); }
`);
	test::@check(error.contains("`@builtin(hit_kind)` is only in an any-hit or closest-hit shader, and this is a miss shader"),
		"hit_kind in a miss shader; got '%s'", error);

	error = refused(`
struct BadLaunch { float3 id @builtin(launch_id); }
fn void gen(BadLaunch at) @raygen { }
`);
	test::@check(error.contains("is a uint3"), "a float3 launch id; got '%s'", error);
}

fn void a_ray_tracing_shader_has_no_varyings() @test
{
	String error = refused(`
struct Mixed { uint3 id @builtin(launch_id); float2 uv; }
fn void gen(Mixed at) @raygen { }
`);
	test::@check(error.contains("has no varyings"), "a varying in a raygen input; got '%s'", error);

	error = refused(`
fn void sky(inout Payload p, Bary b) @miss { }
`);
	test::@check(error.contains("only a closest-hit or any-hit shader has"), "hit attributes in a miss shader; got '%s'", error);

	error = refused(`
fn float4 gen(LaunchIn at) @raygen { return float4(1.0); }
`);
	test::@check(error.contains("returns void"), "a ray-generation shader returning a value; got '%s'", error);

	error = refused(`
fn void gen(LaunchIn at) @raygen @threads(8, 8, 1) { }
`);
	test::@check(error.contains("compute workgroup"), "@threads on a ray-generation shader; got '%s'", error);
}

fn void each_ray_role_is_one_parameter() @test
{
	String error = refused(`
fn void gen(inout Payload p) @raygen { }
`);
	test::@check(error.contains("starts rays rather than receiving one"), "a payload in a raygen shader; got '%s'", error);

	error = refused(`
fn void sky(inout Payload p, inout Payload q) @miss { }
`);
	test::@check(error.contains("already takes its payload"), "two payloads; got '%s'", error);

	error = refused(`
fn void sky(out Payload p) @miss { }
`);
	test::@check(error.contains("write `inout Payload p`"), "an out payload; got '%s'", error);

	error = refused(`
struct FragmentIn { float4 position @position; }
fn float4 frag(inout FragmentIn input) @fragment { return float4(1.0); }
`);
	test::@check(error.contains("cannot write back"), "inout on a fragment input; got '%s'", error);
}

fn void each_call_runs_in_the_stages_that_have_it() @test
{
	String error = refused(`
fn void alpha(inout Payload p, Bary b) @any_hit
{
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, float3(0.0), 0.0, float3(1.0), 1.0, p);
}
`);
	test::@check(error.contains("`trace_ray` starts a ray"), "trace_ray in any-hit; got '%s'", error);

	error = refused(`
fn void hit(inout Payload p) @closest_hit { ignore_intersection(); }
`);
	test::@check(error.contains("only an any-hit shader"), "ignore in closest-hit; got '%s'", error);

	error = refused(`
fn void drop() { ignore_intersection(); }
fn void hit(inout Payload p) @closest_hit { drop(); }
`);
	test::@check(error.starts_with("10:") && error.contains("`drop` is reached from `hit`, a closest-hit shader"),
		"ignore in a helper a closest-hit shader calls; got '%s'", error);

	error = refused(`
struct Sphere { float3 normal; }
fn void hit(inout Payload p) @closest_hit { Sphere s; report_intersection(1.0, 0u, s); }
`);
	test::@check(error.contains("only an intersection shader"), "report outside intersection; got '%s'", error);

	error = refused(`
fn void alpha(inout Payload p) @any_hit { bool b = ignore_intersection(); }
`);
	test::@check(error.contains("a statement of its own"), "a terminator as an expression; got '%s'", error);

	error = refused(`
fn void alpha(inout Payload p) @any_hit { discard; }
`);
	test::@check(error.contains("ignore_intersection()"), "discard in any-hit points at ignore_intersection; got '%s'", error);
}

fn void an_intersection_shader_reports_one_attribute_type() @test
{
	String error = refused(`
struct Sphere { float3 normal; }
struct Box { float3 corner; }
fn void ball(LaunchIn at) @intersection
{
    Sphere s; Box b;
    report_intersection(1.0, 0u, s);
    report_intersection(2.0, 0u, b);
}
`);
	test::@check(error.contains("one hit-attribute type"), "two attribute types in one entry; got '%s'", error);

	error = refused(`
struct Sphere { float3 normal; }
struct Box { float3 corner; }
fn void sphere_hit() { Sphere s; report_intersection(1.0, 0u, s); }
fn void box_hit() { Box b; report_intersection(2.0, 0u, b); }
fn void both(LaunchIn at) @intersection
{
    sphere_hit();
    box_hit();
}
`);
	test::@check(error.contains("one hit-attribute type") && error.contains("`both`"),
		"two attribute types through helpers; got '%s'", error);
}

fn void a_payload_is_a_variable() @test
{
	String error = refused(`
fn Payload make() { Payload p; p.color = float3(0.0); return p; }
fn void gen(LaunchIn at) @raygen
{
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, float3(0.0), 0.0, float3(1.0), 1.0, make());
}
`);
	test::@check(error.contains("must be a variable"), "a temporary payload; got '%s'", error);

	error = refused(`
fn void gen(LaunchIn at) @raygen
{
    float3 c;
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0, float3(0.0), 0.0, float3(1.0), 1.0, c);
}
`);
	test::@check(error.contains("as a plain struct"), "a vector payload; got '%s'", error);
}
