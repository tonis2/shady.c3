<*
 Arrays: locals, struct members, initialiser lists, dynamic indexing, and
 arrays reached through a device address.
*>
module array_test;

import std::core::test;
import shady_support;

fn void a_local_array_indexes_dynamically() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float2 taps[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0)
    };
    int i = int(input.color.x * 3.0);
    return float4(taps[i], 0.0, 1.0);
}
`));

	test::@check(error == "", "a local array should be indexable by a runtime value; got '%s'", error);
}

fn void a_const_local_array_is_initialised() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    const float2 taps[2] = { float2(0.0, 0.0), float2(1.0, 1.0) };
    return float4(taps[0], taps[1]);
}
`));

	test::@check(error == "", "a `const` array should be declarable inside a function; got '%s'", error);
}

fn void a_struct_member_array_is_addressable() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Grid
{
    float4 rows[4];
}

fn float4 frag(FragmentIn input) @fragment
{
    Grid grid;
    grid.rows[0] = input.color;
    grid.rows[1] = float4(1.0);
    int i = int(input.color.y * 1.0);
    return grid.rows[i];
}
`));

	test::@check(error == "", "a struct member array should be assignable and indexable; got '%s'", error);
}

fn void an_array_reached_through_an_address_indexes() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Row @address
{
    float4 values[4];
}

struct Push @pushconstant
{
    Row* rows;
}

Push push;

fn float4 frag(FragmentIn input) @fragment
{
    return push.rows[1].values[2];
}
`));

	test::@check(error == "",
		"a member array of an @address struct should index through the address; got '%s'", error);
}

fn void a_short_initialiser_is_an_error() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float2 taps[2] = { float2(0.0, 0.0) };
    return float4(taps[0], 0.0, 1.0);
}
`));

	test::@check(error.contains("initialiser"),
		"an initialiser with too few elements should be refused; got '%s'", error);
}

fn void an_array_is_not_a_function_parameter() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 first(float4 values[4]) { return values[0]; }
fn float4 frag(FragmentIn input) @fragment { return input.color; }
`));

	test::@check(error.contains("array parameter"),
		"an array parameter should be refused with a pointer suggestion; got '%s'", error);
}
