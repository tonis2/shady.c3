<*
 Operators and control flow: ternary, ++/--, compound bitwise assignment,
 C-style casts, break/continue, and out/inout parameters.
*>
module operator_test;

import std::core::test;
import shady_support;

fn void a_ternary_branches() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    return input.color.x > 0.5 ? input.color : float4(0.0, 0.0, 0.0, 1.0);
}
`));

	test::@check(error == "", "a ternary should lower to a branch; got '%s'", error);
}

fn void prefix_and_postfix_differ() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    int i = 0;
    int old = i++;
    int now = ++i;
    float3 v = input.color.xyz;
    v--;
    --v;
    return float4(v, float(old + now));
}
`));

	test::@check(error == "", "++ and -- should work before and after a value; got '%s'", error);
}

fn void compound_bitwise_assignment() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    uint bits = 1u;
    bits |= 2u;
    bits ^= 4u;
    bits <<= 2;
    bits >>= 1;
    bits &= 31u;
    return float4(float(bits));
}
`));

	test::@check(error == "", "|= ^= &= <<= >>= should all fold into an assignment; got '%s'", error);
}

fn void casts_narrow_and_convert() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float4x4 m = float4x4(input.color, input.color, input.color, input.color);
    float3x3 small = (float3x3)m;
    uint3 bits = (uint3)int3(1, 2, 3);
    float scalar = (float)bits.x + (uint)small[0].x;
    return float4(small[0], scalar);
}
`));

	test::@check(error == "", "a cast should narrow a matrix and convert vector components; got '%s'", error);
}

fn void break_and_continue_in_a_loop() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float total = 0.0;
    for (int k = 0; k < 16; k++)
    {
        if (k == 2) continue;
        if (k == 9) break;
        total += float(k);
    }
    return float4(total);
}
`));

	test::@check(error == "",
		"break and continue should branch to the loop's merge and continue blocks; got '%s'", error);
}

fn void break_outside_a_loop_is_an_error() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { break; return input.color; }
`));

	test::@check(error.len > 0, "break outside a loop should be refused; got '%s'", error);
}

fn void out_and_inout_write_back() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn void split(float3 v, out float3 a, inout float3 b)
{
    a = v;
    b = b + v;
}

fn float4 frag(FragmentIn input) @fragment
{
    float3 a;
    float3 b = input.color.xyz;
    split(input.color.xyz, a, b);
    return float4(a + b, 1.0);
}
`));

	test::@check(error == "", "out and inout should pass the argument by pointer; got '%s'", error);
}

fn void an_out_argument_must_be_a_variable() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn void twice(out float v) { v = v * 2.0; }
fn float4 frag(FragmentIn input) @fragment { twice(1.0); return input.color; }
`));

	test::@check(error.contains("must be a variable"),
		"a literal cannot be an out argument; got '%s'", error);
}

fn void a_parenthesised_variable_is_not_a_cast() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float x = 1.0;
    float y = input.color.x;
    return float4((x) - y);
}
`));

	test::@check(error == "", "`(x) - y` must stay a subtraction, not become a cast; got '%s'", error);
}
