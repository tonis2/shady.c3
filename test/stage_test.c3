<*
 The stage vocabulary: one table, spelled the same by the parser and by anything
 generating source for it.
*>
module stage_test;

import std::core::test;
import shady;
import shady_support;

fn void a_stage_has_one_spelling() @test
{
	assert(Stage.VERTEX.attribute() == "vertex");
	assert(Stage.FRAGMENT.attribute() == "fragment");
	assert(Stage.COMPUTE.attribute() == "compute");
}

fn void an_attribute_name_maps_back_to_its_stage() @test
{
	Stage out;
	assert(shady::stage_from_attribute(Stage.VERTEX.attribute(), &out));
	assert(out == Stage.VERTEX);
	assert(shady::stage_from_attribute(Stage.FRAGMENT.attribute(), &out));
	assert(out == Stage.FRAGMENT);
	assert(shady::stage_from_attribute(Stage.COMPUTE.attribute(), &out));
	assert(out == Stage.COMPUTE);
}

fn void every_other_attribute_is_not_a_stage() @test
{
	Stage out;
	assert(!shady::stage_from_attribute("position", &out));
	assert(!shady::stage_from_attribute("spec", &out));
	assert(!shady::stage_from_attribute("set", &out));
	assert(!shady::stage_from_attribute("", &out));
}

fn void each_stage_is_a_distinct_execution_model() @test
{
	assert(Stage.VERTEX.execution_model() != Stage.FRAGMENT.execution_model());
	assert(Stage.FRAGMENT.execution_model() != Stage.COMPUTE.execution_model());
	assert(Stage.VERTEX.execution_model() != Stage.COMPUTE.execution_model());
}

// The spelling a generator would write, compiled: this is the direction that
// used to be untested on the language's side.
fn void the_spelling_compiles_to_the_same_stage() @test
{
	String source = `struct VertexIn
{
	uint vid @builtin(vertex_index);
}

struct VertexOut
{
	float4 position @position;
}

fn VertexOut vertexMain(VertexIn input) @vertex
{
	VertexOut output;
	output.position = float4((float)input.vid, 0.0, 0.0, 1.0);
	return output;
}
`;
	assert(shady_support::compile_error(source).len == 0);
}

<*
 An integer varying is Flat on both sides, without the author saying so.

 `@flat` is still accepted, but there is nothing to decide: a fragment shader
 input of integer type must be decorated Flat, and a variable that carries one
 between stages has no other legal spelling.
*>
fn void an_integer_varying_is_flat() @test
{
	char[] spirv = shady_support::build(`
struct VOut
{
	float4 position @position;
	uint variant;
}

struct FIn
{
	float4 position @position;
	uint variant;
}

fn VOut vert() @vertex
{
	VOut o;
	o.position = float4(0.0, 0.0, 0.0, 1.0);
	o.variant = 3u;
	return o;
}

fn float4 frag(FIn input) @fragment
{
	return float4(float(input.variant));
}
`);
	defer free(spirv);

	test::@check(shady_support::has_decoration(spirv, shady::Decoration.FLAT),
		"an integer varying is decorated Flat without being asked");
}

<*
 Flat belongs to the two ends of a varying - a vertex output and a fragment
 input - and Vulkan refuses it anywhere else (VUID-StandaloneSpirv-Flat-06201
 and 06202). An integer render target is an ordinary fragment output, and an
 integer vertex attribute an ordinary vertex input, so neither carries it, even
 when the struct says `@flat`.
*>
fn void an_integer_fragment_output_is_not_flat() @test
{
	char[] spirv = shady_support::build(`
struct VIn
{
	float3 position;
	uint id @flat;
}

struct VOut
{
	float4 position @position;
	float4 color;
}

struct Targets
{
	float4 color;
	uint id;
}

fn VOut vert(VIn input) @vertex
{
	VOut o;
	o.position = float4(input.position, float(input.id));
	o.color = float4(1.0);
	return o;
}

fn Targets frag(VOut input) @fragment
{
	Targets t;
	t.color = input.color;
	t.id = 7u;
	return t;
}
`);
	defer free(spirv);

	test::@check(!shady_support::has_decoration(spirv, shady::Decoration.FLAT),
		"neither a vertex input nor a fragment output may be Flat");
}

fn void an_integer_vector_varying_is_flat() @test
{
	char[] spirv = shady_support::build(`
struct VOut
{
	float4 position @position;
	uint2 tile;
}

fn VOut vert() @vertex
{
	VOut o;
	o.position = float4(0.0, 0.0, 0.0, 1.0);
	o.tile = uint2(1u, 2u);
	return o;
}

fn float4 frag(VOut input) @fragment
{
	return float4(float(input.tile.x));
}
`);
	defer free(spirv);

	test::@check(shady_support::has_decoration(spirv, shady::Decoration.FLAT),
		"a uint2 varying is an integer varying, and Flat like a uint");
}

<*
 Every stage there is, through each of its spellings: the attribute names it,
 the name maps back to it, and it has an execution model of its own.
*>
fn void every_stage_round_trips() @test
{
	foreach (stage : Stage::values)
	{
		Stage out;
		test::@check(shady::stage_from_attribute(stage.attribute(), &out) && out == stage,
			"@%s should name its own stage", stage.attribute());
		foreach (other : Stage::values)
		{
			if (other == stage) continue;
			test::@check(stage.execution_model() != other.execution_model(),
				"@%s and @%s are different execution models", stage.attribute(), other.attribute());
		}
	}
}

fn void a_function_is_one_stage() @test
{
	String error = shady_support::compile_error(`
struct FragmentIn { float4 position @position; }
fn float4 frag(FragmentIn input) @fragment @compute
{
	return float4(1.0);
}
`);
	test::@check(error.contains("already a @fragment entry point"), "two stages on one function; got '%s'", error);
}

fn void a_void_entry_point_returns_nothing() @test
{
	String error = shady_support::compile_error(`
float data[];
struct ComputeIn { uint3 id @builtin(global_invocation_id); }
fn void main(ComputeIn at) @compute @threads(1, 1, 1)
{
	return data[0];
}
`);
	test::@check(error.contains("returns void"), "a value return in a void entry point; got '%s'", error);
}

<*
 `discard` ends a fragment, so it is refused in any other stage - in the entry
 point's own body, and in a helper only a vertex shader calls.
*>
fn void discard_is_fragment_only() @test
{
	String error = shady_support::compile_error(`
struct VertexOut { float4 position @position; }
fn VertexOut vert() @vertex
{
	VertexOut o;
	o.position = float4(1.0);
	if (o.position.x > 2.0) discard;
	return o;
}
`);
	test::@check(error.contains("`discard`") && error.contains("fragment"), "discard in a vertex shader; got '%s'", error);

	error = shady_support::compile_error(`
struct VertexOut { float4 position @position; }
fn void cull(float x)
{
	if (x > 2.0) discard;
}
fn VertexOut vert() @vertex
{
	VertexOut o;
	o.position = float4(1.0);
	cull(o.position.x);
	return o;
}
`);
	test::@check(error.starts_with("5:") && error.contains("`cull` is reached from `vert`, a vertex shader"),
		"discard in a helper a vertex shader calls; got '%s'", error);
}

<*
 A module that uses nothing past SPIR-V 1.0 stays there, and its entry points
 list only their inputs and outputs: listing a uniform block is a 1.4 rule, and
 a 1.0 validator refuses it.
*>
fn void a_plain_interface_is_inputs_and_outputs() @test
{
	char[] spirv = shady_support::build(`
struct Uniforms @uniform { float4 tint; }
Uniforms uniforms;
struct FragmentIn { float4 position @position; float4 color; }
fn float4 frag(FragmentIn input) @fragment
{
	return input.color * uniforms.tint;
}
`);
	defer free(spirv);

	test::@check(shady_support::version(spirv) == shady::VERSION_1_0, "the module stays at 1.0");
	test::@check(shady_support::interface_size(spirv, "frag") == 3, "position, color and the output");
	test::@check(shady_support::interface_count(spirv, "frag", shady::StorageClass.UNIFORM) == 0,
		"a 1.0 interface lists no uniform block");
}

<*
 A built-in is something a stage is handed: refused in a stage that does not
 have it, as a type Vulkan does not give it, and in a returned struct. Each of
 these used to be a module only the validator refused.
*>
fn void a_builtin_belongs_to_its_stage() @test
{
	String error = shady_support::compile_error(`
struct FragmentIn { float4 position @position; uint id @builtin(vertex_index); }
fn float4 frag(FragmentIn input) @fragment
{
	return float4(float(input.id));
}
`);
	test::@check(error.starts_with("2:") && error.contains("only in a vertex shader, and this is a fragment shader"),
		"vertex_index in a fragment shader; got '%s'", error);

	error = shady_support::compile_error(`
struct FragmentIn { float4 position @position; float facing @builtin(front_facing); }
fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.facing);
}
`);
	test::@check(error.contains("is a bool, so `facing` cannot be a float"), "a float front_facing; got '%s'", error);

	error = shady_support::compile_error(`
struct ComputeIn { uint3 id @builtin(global_invocation_id); }
struct Out { float4 position @position; uint3 id @builtin(global_invocation_id); }
fn Out vert() @vertex
{
	Out o;
	o.position = float4(1.0);
	return o;
}
`);
	test::@check(error.contains("is an input"), "a built-in in a returned struct; got '%s'", error);
}

fn void an_integer_builtin_takes_either_signedness() @test
{
	String error = shady_support::compile_error(`
struct VertexIn { int vid @builtin(vertex_index); int3 unused; }
struct VertexOut { float4 position @position; }
fn VertexOut vert(VertexIn input) @vertex
{
	VertexOut o;
	o.position = float4(float(input.vid));
	return o;
}
`);
	test::@check(error == "", "an int vertex_index is as good as a uint; got '%s'", error);
}
