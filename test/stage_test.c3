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
