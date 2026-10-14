<*
 Builtins a ported body expects and the compiler did not have: `mul`, `lerp`,
 `rsqrt`, `asuint`, `all`/`any`, `select`, and `[unroll]`.
*>
module builtin_test;

import std::core::test;
import shady;
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

fn void ashalf_reads_the_low_16_bits() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    uint bits = asuint(input.color.x);
    half h = ashalf(bits & 65535u);
    half one = ashalf(0x3C00);
    return float4(float(h * one));
}
`));

	test::@check(error == "", "ashalf should make a half of a word's low 16 bits; got '%s'", error);
}

fn void ashalf_refuses_a_float() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    half h = ashalf(input.color.x);
    return float4(float(h));
}
`));

	test::@check(error.contains("ashalf"), "ashalf of a float should be refused; got '%s'", error);
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

<*
 The one builtin here that is two-argument without being a mix of a
 one-argument form: the quadrant the vector points into is the whole of what
 makes it different from `atan(y / x)`.
*>
fn void atan2_lowers_to_the_quadrant_aware_atangent() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    return float4(atan2(input.color.y, input.color.x));
}
`));
	defer free(spirv);

	test::@check(shady_support::has_ext_inst(spirv, shady::GlslOp.ATAN2),
		"atan2 should be GLSL.std.450's Atan2, not an atan or a division");
}

<*
 GLSL.std.450 has no unsigned `abs` or `sign`, and the signed-or-float choice
 used to fall through to `FAbs` on a uint - invalid SPIR-V. A uint is its own
 absolute value, and its sign is `min(x, 1)`.
*>
fn void abs_and_sign_on_a_uint() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    uint a = uint(input.color.x * 8.0);
    uint2 v = uint2(a, 3u);
    return float4(float(abs(a) + sign(a)), float2(sign(v)), 1.0);
}
`));
	defer free(spirv);

	test::@check(!shady_support::has_ext_inst(spirv, shady::GlslOp.FABS), "abs on a uint should not be FAbs");
	test::@check(!shady_support::has_ext_inst(spirv, shady::GlslOp.FSIGN), "sign on a uint should not be FSign");
	test::@check(shady_support::has_ext_inst(spirv, shady::GlslOp.UMIN), "sign on a uint should be UMin(x, 1)");
}

fn void dot_on_int_vectors_sums_products() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    int2 a = int2(int(input.color.x), 2);
    return float4(float(dot(a, int2(1, 3))));
}
`));
	defer free(spirv);

	test::@check(!shady_support::has_opcode(spirv, shady::Opcode.DOT), "OpDot takes floats only");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.I_MUL), "an integer dot should multiply");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.I_ADD), "an integer dot should sum");
}

fn void dot_refuses_mismatched_vectors() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { return float4(dot(input.color.xyz, input.color.xy)); }
`));

	test::@check(error.contains("`dot` takes two"), "a dot of two shapes should be refused; got '%s'", error);
}

fn void mod_floors_and_fmod_truncates() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float2 wrapped = mod(input.color.xy, 2.0);
    float  cut     = fmod(input.color.z, 2.0);
    int    i       = mod(int(input.color.w), 3);
    return float4(wrapped, cut, float(i));
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.F_MOD), "mod on floats should be FMod");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.F_REM), "fmod should be FRem");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.S_MOD), "mod on ints should be SMod");
}

fn void fwidth_is_the_core_opcode() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment { return float4(fwidth(input.color.xy), 0.0, 1.0); }
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.FWIDTH), "fwidth should be OpFwidth");
}

fn void faceforward_inverse_and_determinant() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float3 n = faceforward(input.color.xyz, input.color.zyx, input.color.xyz);
    float3x3 m = float3x3(n, n.yzx, n.zxy);
    float3x3 inv = inverse(m);
    return float4(inv[0], determinant(m));
}
`));
	defer free(spirv);

	test::@check(shady_support::has_ext_inst(spirv, shady::GlslOp.FACE_FORWARD), "faceforward should be FaceForward");
	test::@check(shady_support::has_ext_inst(spirv, shady::GlslOp.MATRIX_INVERSE), "inverse should be MatrixInverse");
	test::@check(shady_support::has_ext_inst(spirv, shady::GlslOp.DETERMINANT), "determinant should be Determinant");
}

fn void determinant_refuses_a_non_square_matrix() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment
{
    float2x3 m = float2x3(input.color.xyz, input.color.yzx);
    return float4(determinant(m));
}
`));

	test::@check(error.contains("square matrix"), "a non-square determinant should be refused; got '%s'", error);
}
