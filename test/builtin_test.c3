<*
 Builtins a ported body expects and the compiler did not have: `mul`, `lerp`,
 `rsqrt`, `asuint`, `all`/`any`, `select`, and `[unroll]`.
*>
module builtin_test;

import std::core::test;
import shady_support;

fn void mul_spells_the_matrix_product() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float4x4 m = float4x4(input.color, input.color, input.color, input.color);
    float4 v = mul(m, input.color);
    float4x4 n = mul(m, m);
    return v + n[0];
}
`));

	test::@check(error == "", "mul should be a matrix product with the same rules as `*`; got '%s'", error);
}

fn void any_and_all_reduce_a_bool_vector() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    bool2 low  = input.color.xy <= float2(0.0);
    bool2 high = input.color.xy >= float2(1.0);
    if (any(low) || all(high)) return float4(1.0);
    return float4(0.0);
}
`));

	test::@check(error == "", "any and all should reduce a bool vector to a bool; got '%s'", error);
}

fn void asuint_reinterprets_the_bits() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    uint bits = asuint(input.color.x);
    uint3 packed = asuint(input.color.xyz);
    return float4(float(bits & 255u) + float(packed.z));
}
`));

	test::@check(error == "", "asuint should bitcast a float or vector to its uint shape; got '%s'", error);
}

fn void lerp_and_rsqrt_are_aliases() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float3 low = float3(0.0);
    float3 high = input.color.xyz;
    float3 blended = lerp(low, high, 0.25);
    float scaled = rsqrt(dot(high, high) + 1.0);
    return float4(blended * scaled, 1.0);
}
`));

	test::@check(error == "", "lerp and rsqrt should be the mix and inversesqrt spellings; got '%s'", error);
}

fn void select_picks_by_condition() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float4 no = float4(0.0);
    bool2 bits = input.color.xy > 0.5;
    return select(no, input.color, bits.x && bits.y);
}
`));

	test::@check(error == "", "select(when_false, when_true, condition) should lower to OpSelect; got '%s'", error);
}

fn void unroll_is_accepted_and_ignored() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float total = 0.0;
    [unroll] for (int k = 0; k < 4; k++)
    {
        total += float(k);
    }
    return float4(total);
}
`));

	test::@check(error == "", "[unroll] should not be an error; got '%s'", error);
}
