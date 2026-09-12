<*
 Specialization constants: a `const` with `@spec(id)` becomes an `OpSpecConstant`
 with a `SpecId` decoration, so one module serves several variants.
*>
module spec_test;

import std::core::test;
import shady;
import shady_support;

const String SPECS = `
const bool  SHADOWS @spec(0) = true;
const uint  TAPS    @spec(1) = 4u;
const float SCALE   @spec(2) = 1.5;

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn float4 frag(FragmentIn input) @fragment
{
    float total = SCALE;
    if (SHADOWS)
    {
        total += float(TAPS);
    }
    return input.color * total;
}
`;

fn void spec_constants_are_emitted_with_their_ids() @test
{
	char[] spirv = shady_support::build(SPECS);
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.SPEC_CONSTANT_TRUE),
		"a bool spec constant should be OpSpecConstantTrue");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.SPEC_CONSTANT),
		"a uint or float spec constant should be OpSpecConstant");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.SPEC_ID, 0),
		"spec id 0 should be decorated");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.SPEC_ID, 1),
		"spec id 1 should be decorated");
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.SPEC_ID, 2),
		"spec id 2 should be decorated");
}

<*
 The boolean that turns a whole pass on and off. The branch is still in the
 module - the driver folds it when the pipeline is specialized - so what the
 test can pin without a device is that the constant and its spec id are there.
*>
fn void a_bool_spec_constant_gates_a_branch() @test
{
	String error = shady_support::compile_error(SPECS);
	test::@check(error == "", "a bool spec constant should gate a branch; got '%s'", error);
}

fn void a_plain_constant_is_just_a_constant() @test
{
	char[] spirv = shady_support::build(`
const float PI = 3.14159;

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn float4 frag(FragmentIn input) @fragment
{
    return input.color * PI;
}
`);
	defer free(spirv);

	test::@check(!shady_support::has_decoration(spirv, shady::Decoration.SPEC_ID),
		"a const without @spec should not be decorated");
}

fn void rejects_a_non_scalar_constant() @test
{
	String error = shady_support::compile_error(`
const float2 PAIR @spec(0) = float2(1.0);

struct FragmentIn { float4 position @position; float4 color; }
fn float4 frag(FragmentIn input) @fragment { return input.color; }
`);

	test::@check(error.contains("only bool, int, uint and float"),
		"a spec constant has to be a scalar to be replaceable; got '%s'", error);
}

fn void rejects_a_non_literal_initialiser() @test
{
	String error = shady_support::compile_error(`
const float BAKE @spec(0) = 1.0 + 2.0;

struct FragmentIn { float4 position @position; float4 color; }
fn float4 frag(FragmentIn input) @fragment { return input.color * BAKE; }
`);

	test::@check(error.contains("needs a number"),
		"a spec constant's default has to be a literal; got '%s'", error);
}

fn void rejects_a_duplicate_spec_id() @test
{
	String error = shady_support::compile_error(`
const float A @spec(0) = 1.0;
const float B @spec(0) = 2.0;

struct FragmentIn { float4 position @position; float4 color; }
fn float4 frag(FragmentIn input) @fragment { return input.color * (A + B); }
`);

	test::@check(error.contains("already used"),
		"two constants may not share a spec id; got '%s'", error);
}
