<*
 `module`: a file's identity, and the rule that a bodyless declaration in a
 module is defined by a file of that module (LANGUAGE.md sections 3 and 3.5).

 The fixtures here stand in for a file supply, the way three.c3's `load_source`
 does through the `ShaderFile` enum.
*>
module module_test;

import std::core::test;
import shady;
import shady_support;

faultdef NO_SUCH_IMPORT;

// The shared half: declarations, an interface naming two of them, and the walk
// that calls through all three.
const String SHARED = `
module lighting;

struct Surface
{
	float3 albedo;
}

interface AreaAlgorithm
{
	fn float3 diffuse(Surface s);
	fn float3 ambient(Surface s);
}

fn float3 rim(Surface s);

fn float3 intensity(Surface s)
{
	return diffuse(s) + ambient(s) + rim(s);
}
`;

// The tail: definitions in the same module - the lighting shape in miniature.
const String TAIL = `
module lighting;

import "shared.shady";

fn float3 diffuse(Surface s) { return s.albedo; }
fn float3 ambient(Surface s) { return s.albedo * 0.1; }
fn float3 rim(Surface s)      { return s.albedo * 0.2; }
`;

// A tail in another module: its definitions do not fill the declarations.
const String OTHER_TAIL = `
module other;

import "shared.shady";

fn float3 diffuse(Surface s) { return s.albedo; }
fn float3 ambient(Surface s) { return s.albedo; }
fn float3 rim(Surface s)      { return s.albedo; }
`;

fn String? fixture_import(String name, Allocator allocator)
{
	switch (name)
	{
		case "shared.shady": return SHARED.copy(allocator);
		case "tail.shady":   return TAIL.copy(allocator);
		case "other.shady":  return OTHER_TAIL.copy(allocator);
		default:             return NO_SUCH_IMPORT~;
	}
}

fn String compile_imports(String source)
{
	String? resolved = shady::resolve_imports(source, "root.shady", &fixture_import);
	if (catch resolved) return "(the fixture import did not resolve)";
	String closure = resolved;
	defer free(closure);
	return shady_support::compile_error(closure);
}

fn void a_module_statement_is_accepted() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
module lighting;

fn float3 lit() { return float3(1.0); }

fn float4 frag(FragmentIn input) @fragment
{
	return float4(lit(), 1.0);
}
`));

	test::@check(error == "", "a module statement should be accepted; got `%s`", error);
}

fn void a_dotted_module_statement_is_one_name() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
module three.render.lighting;

fn float3 lit() { return float3(1.0); }

fn float4 frag(FragmentIn input) @fragment
{
	return float4(lit(), 1.0);
}
`));

	test::@check(error == "", "a dotted module name should be accepted; got `%s`", error);
}

<*
 Two files carrying the same module name are one module: the shared half
 declares, the tail defines, and nothing writes `implements`.
*>
fn void two_files_with_the_same_module_compose() @test
{
	String error = compile_imports(shady_support::fragment(`
import "tail.shady";

fn float4 frag(FragmentIn input) @fragment
{
	Surface s;
	s.albedo = input.color.rgb;
	return float4(intensity(s), 1.0);
}
`));

	test::@check(error == "", "a definition in another file of the module should fill the declaration; got `%s`", error);
}

<*
 The other side: a definition in a different module is not the module's
 definition, and the declaration is refused where it stands.
*>
fn void a_definition_in_another_module_does_not_fill_the_declaration() @test
{
	String error = compile_imports(shady_support::fragment(`
import "other.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return input.color;
}
`));

	test::@check(error.contains("lighting") && error.contains("diffuse"),
		"the refusal should name the module and the declaration; got `%s`", error);
	test::@check(!error.contains("no `diffuse` takes these arguments"),
		"the declaration should be refused before any call; got `%s`", error);
}

<*
 A declaration nothing defines at all - and nothing calls - is still an error
 in a module, raised at the declaration rather than left until a call.
*>
fn void an_undefined_declaration_in_a_module_is_refused_at_the_declaration() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
module lighting;

fn float3 diffuse(float3 albedo);

fn float4 frag(FragmentIn input) @fragment
{
	return input.color;
}
`));

	test::@check(error.contains("lighting") && error.contains("diffuse"),
		"the refusal should name the module and the declaration; got `%s`", error);
	test::@check(error.contains("no file of"),
		"the refusal should be the declaration-site one; got `%s`", error);
}
