<*
 Arrays: locals, struct members, initialiser lists, dynamic indexing, and
 arrays reached through a device address.
*>
module array_test;

import std::core::test;
import shady;
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

<*
 A module-level table is one OpConstantComposite. A literal index extracts
 from it. A runtime index reads it through a local copy, because SPIR-V indexes
 a composite by a runtime value only through a pointer.
*>
fn void a_module_constant_table_indexes_both_ways() @test
{
	char[] spirv = shady_support::build(shady_support::fragment(`
const float  ROUGH[4] = { 0.2, 0.4, 0.6, 1 };
const float2 TAPS[2]  = { float2(-1.0, 0.5), float2(1.0) };

fn float4 frag(FragmentIn input) @fragment
{
    int i = int(input.color.x * 3.0);
    return float4(ROUGH[i], ROUGH[3], TAPS[i & 1]);
}
`));
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.CONSTANT_COMPOSITE), "the table is a constant composite");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.COMPOSITE_EXTRACT), "ROUGH[3] is an extract");
	test::@check(shady_support::has_opcode(spirv, shady::Opcode.ACCESS_CHAIN), "ROUGH[i] goes through a local");
}

fn void a_constant_table_cannot_be_assigned() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
const float ROUGH[2] = { 0.2, 0.4 };

fn float4 frag(FragmentIn input) @fragment
{
    ROUGH[1] = input.color.x;
    return float4(ROUGH[1]);
}
`));

	test::@check(error.contains("cannot assign"), "an element of a constant is a copy; got '%s'", error);
}

fn void a_literal_index_past_a_constant_table_is_refused() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
const float ROUGH[2] = { 0.2, 0.4 };

fn float4 frag(FragmentIn input) @fragment { return float4(ROUGH[2]); }
`));

	test::@check(error.contains("past the end"), "ROUGH[2] reaches past a float[2]; got '%s'", error);
}

fn void a_constant_table_is_its_length_of_literals() @test
{
	String brief = shady_support::compile_error(shady_support::fragment(`
const float ROUGH[3] = { 0.2, 0.4 };
fn float4 frag(FragmentIn input) @fragment { return float4(ROUGH[0]); }
`));
	test::@check(brief.contains("needs 3 elements"), "a short table is refused; got '%s'", brief);

	String folded = shady_support::compile_error(shady_support::fragment(`
const float ROUGH[2] = { 0.2, 0.2 * 2.0 };
fn float4 frag(FragmentIn input) @fragment { return float4(ROUGH[0]); }
`));
	test::@check(folded.contains("needs a number"), "an element is a literal; got '%s'", folded);

	String spec = shady_support::compile_error(shady_support::fragment(`
const float ROUGH[2] @spec(0) = { 0.2, 0.4 };
fn float4 frag(FragmentIn input) @fragment { return float4(ROUGH[0]); }
`));
	test::@check(spec.contains("only a scalar"), "a table is not a spec constant; got '%s'", spec);
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

<*
 An array member of a struct is an argument like any other element.

 The shape is the cut-out shadow module's: a struct with a table of transforms,
 one row picked by a runtime index, handed to a helper.
*>
fn void an_array_member_can_be_an_argument() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Table
{
	float4 rows[2];
}

fn float2 pick(float2 uv, float4 row) { return uv + row.xy; }

fn float4 frag(FragmentIn input) @fragment
{
	Table table;
	table.rows[0] = float4(0.1, 0.2, 0.0, 0.0);
	table.rows[1] = float4(0.3, 0.4, 0.0, 0.0);
	uint which = (uint)(input.color.x * 2.0);
	return float4(pick(input.color.xy, table.rows[which]), 0.0, 1.0);
}
`));

	test::@check(error == "", "an array member is an argument; got '%s'", error);
}

fn void a_forward_reference_between_helpers() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float2 pick(float2 uv, float4 row) { return helper(uv, row); }
fn float2 helper(float2 uv, float4 row) { return uv + row.xy; }

fn float4 frag(FragmentIn input) @fragment
{
	return float4(pick(input.color.xy, input.color), 0.0, 1.0);
}
`));

	test::@check(error == "", "a helper may call one declared later; got '%s'", error);
}

fn void an_array_member_reached_through_a_pointer() @test
{
	char[] spirv = shady_support::build(string::tformat("%s\n%s", `
struct Rec @address
{
	float4 rows[8];
	uint count;
}
struct Push @pushconstant { Rec* rec; }
Push push;

struct Out { float4 position @position; }

fn float2 pick(float2 uv, float4 row) { return uv + row.xy; }

fn float4 frag(FragmentIn input) @fragment
{
	Rec r = push.rec[0];
	uint which = 1;
	float2 uv = input.color.xy;
	uv = pick(uv, r.rows[which]);
	return float4(uv, 0.0, 1.0);
}

fn Out vert() @vertex { Out o; o.position = float4(0.0, 0.0, 0.0, 1.0); return o; }
`, shady_support::FRAGMENT_IO));
	defer free(spirv);
	test::@check(spirv.len > 0, "the module compiled");
}

<*
 A second array dimension is refused, whichever way it is written. A TypeRef
 holds one length, and `float[4] taps[3]` used to keep the second and drop the
 first without a word - an array of three where the author wrote twelve.
*>
fn void a_second_dimension_is_refused() @test
{
	String[] sources = {
		"fn float4 frag(FragmentIn input) @fragment { float[4] taps[3]; return input.color; }",
		"fn float4 frag(FragmentIn input) @fragment { float taps[3][4]; return input.color; }",
		"struct Grid { float[3][4] cells; }\nfn float4 frag(FragmentIn input) @fragment { return input.color; }",
		"struct Grid { float cells[3][4]; }\nfn float4 frag(FragmentIn input) @fragment { return input.color; }",
	};

	foreach (source : sources)
	{
		String error = shady_support::compile_error(shady_support::fragment(source));
		test::@check(error.contains("multidimensional"),
			"a second dimension should be refused; for '%s' got '%s'", source, error);
	}
}
