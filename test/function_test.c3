<*
 Plain functions, overloading, and method calls.

 A method is an ordinary function whose first parameter is the receiver, so
 `image.Sample(uv)` is `Sample(image, uv)` - one mechanism, not two.
*>
module function_test;

import std::core::test;
import shady_support;

fn void calls_a_function_declared_later() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    return shade(input.color);
}

fn float4 shade(float4 color)
{
    return color;
}
`));

	test::@check(error == "", "a call to a function declared below should resolve; got '%s'", error);
}

fn void overloads_by_argument_count() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    return pick(input.color);
}

fn float4 pick(float4 color) { return color; }
fn float4 pick(float4 color, float amount) { return color * amount; }
`));

	test::@check(error == "", "the one-argument overload should be chosen; got '%s'", error);
}

fn void overloads_by_argument_type() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    return pick(input.color) + pick(input.color.xy);
}

fn float4 pick(float4 color) { return color; }
fn float4 pick(float2 uv) { return float4(uv, 0.0, 1.0); }
`));

	test::@check(error == "", "the overload matching the argument type should be chosen; got '%s'", error);
}

fn void a_self_method_takes_the_receiver_by_reference() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Map
{
    int at;
}

fn Map map_at(int at) { Map m; m.at = at; return m; }

fn float4 Map.Sample(&self, float2 uv)
{
    return float4(uv, float(self.at), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
    return map_at(3).Sample(input.color.xy);
}
`));

	test::@check(error == "", "a &self method should take the receiver as a pointer; got '%s'", error);
}

fn void writes_through_self_reach_the_caller() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Counter
{
    float value;
}

fn void Counter.bump(&self)
{
    self.value = self.value + 1.0;
}

fn float4 frag(FragmentIn input) @fragment
{
    Counter counter;
    counter.value = 0.0;
    counter.bump();
    return float4(counter.value);
}
`));

	test::@check(error == "", "a write through &self should reach the caller's storage; got '%s'", error);
}

fn void an_explicit_receiver_is_a_method_too() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Map
{
    int at;
}

fn float4 Map.Sample(Map image, float2 uv)
{
    return float4(uv, float(image.at), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
    Map m;
    m.at = 2;
    return m.Sample(input.color.xy);
}
`));

	test::@check(error == "", "the receiver of a qualified method may be written out; got '%s'", error);
}

fn void a_method_resolves_by_receiver_type() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct A { float x; }
struct B { float y; }

fn float A.value(A a) { return a.x; }
fn float B.value(B b) { return b.y; }

fn float4 frag(FragmentIn input) @fragment
{
    A a;
    a.x = 1.0;
    B b;
    b.y = 2.0;
    return float4(a.value() + b.value());
}
`));

	test::@check(error == "", "two types may each have a method of the same name; got '%s'", error);
}

fn void a_self_method_needs_a_receiver_type() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 Sample(&self, float2 uv) { return float4(uv, self.at, 1.0); }
fn float4 frag(FragmentIn input) @fragment { return Sample(input.color.xy); }
`));

	test::@check(error.len > 0, "`self` without a qualified name should be refused; got '%s'", error);
}

fn void rejects_recursion() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { return f(input.color); }
fn float4 f(float4 color) { return f(color); }
`));

	test::@check(error.contains("recursion"),
		"a function that calls itself should be refused as recursion; got '%s'", error);
}

fn void rejects_an_ambiguous_call() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { return pick(input.color); }
fn float4 pick(float4 color) { return color; }
fn float4 pick(float4 color) { return color * 2.0; }
`));

	test::@check(error.contains("overload"),
		"an ambiguous overload should be named as one; got '%s'", error);
}

fn void rejects_a_missing_return() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { return f(input.color); }
fn float4 f(float4 color) { if (color.x > 0.0) { return color; } }
`));

	test::@check(error.len > 0, "a path with no return should be refused; got '%s'", error);
}

<*
 A member of an `out` parameter is an expression like any other.

 The shape is `mesh.shady`'s vertex body: it writes into an `out` struct and
 passes one of that struct's members to a helper. Failing to resolve the member's
 type there is what "no `variant_uv` takes these arguments" means - the
 overload set is empty because the argument's type could not be worked out.
*>
fn void a_member_of_an_out_parameter_is_an_argument() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Output
{
	float2 uv;
	float3 color;
}

fn float2 move_uv(float2 uv, float4 row) { return uv + row.xy; }

fn void build(out Output output)
{
	output.uv = float2(0.25, 0.5);
	output.uv = move_uv(output.uv, float4(0.1, 0.2, 0.0, 0.0));
}

fn float4 frag(FragmentIn input) @fragment
{
	Output output;
	build(output);
	return float4(output.uv, 0.0, 1.0);
}
`));

	test::@check(error == "", "a member of an out parameter can be an argument; got `%s`", error);
}

<*
 Both arguments at once: a member of an `out` parameter, and an array element of
 a wire struct copied out of a push block.

 Each of those alone resolves; together they did not, which is the shape
 `mesh.shady` writes for its per-copy uv and the reason this test exists.
*>
fn void both_argument_shapes_at_once() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Row @address
{
	float4 rows[4];
	uint  count;
}

struct Push @pushconstant { Row* row; }
Push push;

struct Output
{
	float2 uv;
}

fn float2 move_uv(float2 uv, float4 row) { return uv + row.xy; }

fn void build(out Output output)
{
	Row row = push.row[0];
	output.uv = float2(0.25, 0.5);
	if (row.count != 0)
	{
		uint which = min(row.count, 3);
		output.uv = move_uv(output.uv, row.rows[which]);
	}
}

fn float4 frag(FragmentIn input) @fragment
{
	Output output;
	build(output);
	return float4(output.uv, 0.0, 1.0);
}
`));

	test::@check(error == "", "both argument shapes resolve together; got `%s`", error);
}

<*
 A helper whose parameter is a vector it swizzles and assigns into.
*>
fn void a_helper_called_with_two_vector_literals() @test
{
	String error = shady_support::compile_error(`
struct VertexIn { uint vid @builtin(vertex_index); }
struct VertexOutput { float2 uv; float4 sv_position @position; }

fn float2 variant_uv(float2 uv, float4 row)
{
	uint turns = ((uint)row.z) & 3;
	if (turns == 1) uv = float2(uv.y, 1.0 - uv.x);
	else if (turns == 2) uv = float2(1.0 - uv.x, 1.0 - uv.y);
	else if (turns == 3) uv = float2(1.0 - uv.y, uv.x);

	uint flip = (uint)row.w;
	if ((flip & 1) != 0) uv.x = 1.0 - uv.x;
	if ((flip & 2) != 0) uv.y = 1.0 - uv.y;

	return uv + row.xy;
}

fn void build(VertexIn input, out VertexOutput output)
{
	output.uv = variant_uv(float2(0.0, 0.0), float4(0.0, 0.0, 0.0, 0.0));
}

fn VertexOutput vertexMain(VertexIn input) @vertex
{
	VertexOutput output;
	build(input, output);
	output.sv_position = float4(0.0, 0.0, 0.0, 1.0);
	return output;
}
`);
	test::@check(error == "", "a helper with two vector arguments resolves; got `%s`", error);
}
