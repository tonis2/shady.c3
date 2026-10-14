<*
 Operators and control flow: ternary, ++/--, compound bitwise assignment,
 C-style casts, break/continue, and out/inout parameters.
*>
module operator_test;

import std::core::test;
import shady;
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
    float scalar = (float)bits.x + (float)(uint)small[0].x;
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

<*
 A single component of a vector is writable, and a multi-component swizzle is
 not.

 SPIR-V has no store into a composite, so `uv.x = a` is `uv = insert(uv, a, 0)`
 - the inverse of the extract the read path uses. `uv.xy = a` would need a
 masked store, which SPIR-V does not have in any form, so it stays refused
 where it is written rather than doing half of it.
*>
fn void a_vector_component_is_an_lvalue() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	float2 uv = input.color.xy;
	uv.x = input.color.z;
	uv.y += 2.0;
	return float4(uv, 0.0, 1.0);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.COMPOSITE_INSERT),
		"the component write is a composite insert");
}

fn void a_multi_component_swizzle_is_not_assignable() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	float2 uv = input.color.xy;
	uv.xy = input.color.zw;
	return float4(uv, 0.0, 1.0);
}
`));

	test::@check(error.contains("cannot assign"),
		"a masked write is refused rather than half done; got `%s`", error);
}

<*
 A `uint` and a `float` are not mixed implicitly: only literals adapt, so the
 two sides of an operation have to agree on their kind, or one of them is
 converted where the port writes it.
*>
fn void a_float_and_a_uint_are_not_mixed() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	uint count = 3u;
	float half = 0.5;
	return float4(half / count);
}
`));

	test::@check(error.contains("convert one side explicitly"),
		"mixing a float with a uint is refused; got `%s`", error);
}

<*
 `uint` arithmetic is unsigned: SPIR-V picks the opcode by signedness, and a
 division or comparison compiled as signed is wrong above half the range.
*>
fn void uint_arithmetic_is_unsigned() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	uint a = uint(input.color.x * 8.0);
	uint b = a / 2u;
	uint c = a % 3u;
	bool  d = a < c;
	return float4(float(b + c), 0.0, 0.0, d ? 1.0 : 0.0);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.U_DIV), "a uint divide is OpUDiv");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.U_MOD), "a uint remainder is OpUMod");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.U_LESS_THAN), "a uint compare is OpULessThan");
}

<*
 An integer vector times a scalar is an integer multiply of a splat.

 `OpVectorTimesScalar` is for floats only. `int2 * 4` emitted with it is
 invalid SPIR-V, and RADV ran it as a zero: every `corner = id.xy * 4` in a
 kernel landed on texel (0, 0).
*>
fn void an_integer_vector_times_a_scalar_is_an_integer_multiply() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	int2 cell = int2(int(input.color.x), int(input.color.y)) * 4;
	uint2 step = uint2(uint(input.color.z), 3u) * 2u;
	return float4(float2(cell), float2(step));
}
`));
	defer free(spirv);

	test::@check(!shady_support::has_opcode(spirv, shady::Opcode.VECTOR_TIMES_SCALAR),
		"an int2 or uint2 times a scalar is not OpVectorTimesScalar");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.I_MUL), "it is OpIMul of a splat");
}

<*
 A float vector times a float is still the one instruction, and a float vector
 times a `uint` is refused like any other mix of kinds - it used to reach the
 same float-only shortcut and come out as invalid SPIR-V instead.
*>
fn void a_float_vector_times_a_scalar_is_one_instruction() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.xy * 2.0, 0.0, 1.0);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.VECTOR_TIMES_SCALAR),
		"a float2 times a float is OpVectorTimesScalar");
}

<*
 A scalar of another kind beside a vector is refused on either side, and for
 any operator. The broadcast used to come first and made the scalar look like
 the vector, so a `uint` was splatted into a `float2` the module then refused.
*>
fn void a_float_vector_times_a_uint_is_refused() @test
{
	String right = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	uint count = 3u;
	return float4(input.color.xy * count, 0.0, 1.0);
}
`));
	test::@check(right.contains("convert one side explicitly"),
		"a float2 times a uint is refused; got `%s`", right);

	String left = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	uint count = 3u;
	return float4(count + input.color.xy, 0.0, 1.0);
}
`));
	test::@check(left.contains("convert one side explicitly"),
		"a uint plus a float2 is refused; got `%s`", left);
}

<*
 `%` is C3's remainder: the result takes the sign of the left side, so
 `-7 % 3` is -1. That is OpSRem and OpFRem; OpSMod and OpFMod are GLSL's
 floored `mod()`, which takes the sign of the right side instead.
*>
fn void a_signed_remainder_truncates() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	int   i = int(input.color.x * 8.0) - 4;
	int   r = i % 3;
	float f = input.color.y % 2.0;
	return float4(float(r), f, 0.0, 1.0);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.S_REM), "an int remainder is OpSRem");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.F_REM), "a float remainder is OpFRem");
	test::@check(!shady_support::has_opcode(spirv, shady::Opcode.S_MOD), "`%%` is not the floored OpSMod");
	test::@check(!shady_support::has_opcode(spirv, shady::Opcode.F_MOD), "`%%` is not the floored OpFMod");
}

fn void a_matrix_divides_and_negates_by_columns() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	float2x2 m = float2x2(input.color.xy, input.color.zw);
	float2x2 halved  = m / 2.0;
	float2x2 flipped = -m;
	float2x2 shifted = 1.0 - m;
	float2x2 summed  = halved + flipped + shifted;
	summed /= 4.0;
	return float4(summed[0], summed[1]);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.F_DIV), "a matrix divides a column at a time");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.F_NEGATE), "a matrix negates a column at a time");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.COMPOSITE_EXTRACT), "a matrix is taken apart by column");
}

fn void a_matrix_cannot_be_compared() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
	float2x2 m = float2x2(input.color.xy, input.color.zw);
	if (m == m) return float4(1.0);
	return float4(0.0);
}
`));

	test::@check(error.contains("a matrix takes"), "a matrix comparison should be refused; got '%s'", error);
}
