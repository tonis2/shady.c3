<*
 `import`: the module's text is its import closure, each file under its own
 `#line` region (LANGUAGE.md section 3.6).

 Resolution is a step of its own - `resolve_imports` - because the compiler's
 input is one string. The fixtures here stand in for a file supply, the way
 three.c3's `load_source` does through the `ShaderFile` enum.
*>
module import_test;

import std::core::test;
import shady;
import shady_support;

faultdef NO_SUCH_IMPORT;

const String LIB = `
fn float3 tint(float3 color)
{
	return color * 0.5;
}
`;

// The same function, defined twice with the same signature by two files.
const String LIB_TWO = `
fn float3 tint(float3 color)
{
	return color + color;
}
`;

const String DIAMOND = `
import "lib.shady";

fn float3 bright(float3 color)
{
	return tint(color) + tint(color);
}
`;

const String BROKEN = `
fn float3 broken()
{
	return nonesuch;
}
`;

const String CYCLE_A = `import "cycle_b.shady";
fn float3 a() { return float3(1.0); }
`;

const String CYCLE_B = `import "cycle_a.shady";
fn float3 b() { return float3(2.0); }
`;

// An interface in one file, its definition and its claim in another: the check
// is the module's, not a file's.
const String CONTRACT = `
struct Surface { float3 albedo; }

interface Shading
{
	fn float3 shade(Surface s);
}

fn float3 lit(Surface s)
{
	return shade(s);
}
`;

fn String? fixture_import(String name, Allocator allocator)
{
	switch (name)
	{
		case "lib.shady":     return LIB.copy(allocator);
		case "lib_two.shady": return LIB_TWO.copy(allocator);
		case "diamond.shady": return DIAMOND.copy(allocator);
		case "broken.shady":  return BROKEN.copy(allocator);
		case "cycle_a.shady": return CYCLE_A.copy(allocator);
		case "cycle_b.shady": return CYCLE_B.copy(allocator);
		case "contract.shady": return CONTRACT.copy(allocator);
		default:              return NO_SUCH_IMPORT~;
	}
}

<*
 Resolve under the fixture and compile. "(the fixture import did not resolve)"
 when resolution itself failed - the tests that expect a resolution refusal call
 `resolve_imports` themselves, for the diagnostic.
*>
fn String compile_imports(String source)
{
	String? resolved = shady::resolve_imports(source, "root.shady", &fixture_import);
	if (catch resolved)
	{
		return "(the fixture import did not resolve)";
	}
	String closure = resolved;
	defer free(closure);
	return shady_support::compile_error(closure);
}

fn String resolve_error(String source) @private
{
	shady::Diagnostic diagnostic;
	String? resolved = shady::resolve_imports(source, "root.shady", &fixture_import, &diagnostic);
	String message = "";
	if (catch resolved)
	{
		message = diagnostic.to_string(tmem);
	}
	diagnostic.free();
	return message;
}

fn uint count_of(String text, String needle) @private
{
	uint count = 0;
	usz  at    = 0;
	while (at < text.len)
	{
		sz? found = text[at..].index_of(needle);
		if (catch found) break;
		count++;
		at += (usz)found + needle.len;
	}
	return count;
}

fn void an_import_makes_a_definition_visible() @test
{
	String error = compile_imports(shady_support::fragment(`
import "lib.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return float4(tint(input.color.rgb), 1.0);
}
`));

	test::@check(error == "", "a function defined in an imported file should resolve; got `%s`", error);
}

<*
 The point of the `#line` regions: a fault in the imported file names that file
 and its own line, not a line in the spliced module.
*>
fn void a_diagnostic_in_an_imported_file_names_that_file() @test
{
	String error = compile_imports(shady_support::fragment(`
import "broken.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.rgb + broken(), 1.0);
}
`));

	test::@check(error.contains("broken.shady:4:") && error.contains("nonesuch"),
		"the fault should name the imported file and its line; got `%s`", error);
}

fn void a_cycle_is_refused() @test
{
	String error = resolve_error(`import "cycle_a.shady";
`);

	test::@check(error.contains("import cycle") && error.contains("cycle_a.shady") && error.contains("cycle_b.shady"),
		"a circular import should be refused and name the chain; got `%s`", error);
}

fn void a_file_imported_twice_is_included_once() @test
{
	String error = compile_imports(shady_support::fragment(`
import "lib.shady";
import "lib.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return float4(tint(input.color.rgb), 1.0);
}
`));

	test::@check(error == "", "one file imported twice should compile as one copy; got `%s`", error);
}

fn void two_definitions_of_one_function_are_refused() @test
{
	String error = compile_imports(shady_support::fragment(`
import "lib.shady";
import "lib_two.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return float4(tint(input.color.rgb), 1.0);
}
`));

	test::@check(error.contains("matches more than one"),
		"two definitions of one function should be refused; got `%s`", error);
}

fn void an_unknown_import_is_refused() @test
{
	String error = resolve_error(`import "ghost.shady";
`);

	test::@check(error.contains("ghost.shady") && error.contains("not found"),
		"an import the file supply does not have should be refused by name; got `%s`", error);
}

<*
 Resolution writes the closure, not a refusal, so the include-once property is
 visible directly: `tint` stands once though every file imports it.
*>
fn void the_closure_holds_an_imported_file_once() @test
{
	String? resolved = shady::resolve_imports(shady_support::fragment(`
import "lib.shady";
import "lib.shady";
import "diamond.shady";

fn float4 frag(FragmentIn input) @fragment
{
	return float4(bright(input.color.rgb), 1.0);
}
`), "root.shady", &fixture_import);
	if (catch resolved)
	{
		test::@check(false, "resolution should succeed");
		return;
	}
	String closure = resolved;
	defer free(closure);

	test::@check(count_of(closure, "fn float3 tint(float3 color)") == 1,
		"one file imported three ways should stand once; found it %d times",
		count_of(closure, "fn float3 tint(float3 color)"));
	test::@check(closure.contains("#line 1 \"lib.shady\""),
		"the imported file should keep a `#line` region of its own");

	String error = shady_support::compile_error(closure);
	test::@check(error == "", "the closure should compile; got `%s`", error);
}

<*
 An interface declared in an imported file and provided by the root: the check
 runs on the module, so the two halves meet.
*>
fn void an_interface_in_an_imported_file_is_checked_on_the_module() @test
{
	String error = compile_imports(shady_support::fragment(`
import "contract.shady";

provides Shading;

fn float3 shade(Surface s)
{
	return s.albedo;
}

fn float4 shaded(FragmentIn input)
{
	Surface s;
	s.albedo = input.color.rgb;
	return float4(lit(s), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
	return shaded(input);
}
`));

	test::@check(error == "", "an imported interface should be satisfied across files; got `%s`", error);
}

fn void an_import_must_stand_alone_on_its_line() @test
{
	String error = resolve_error(`import "lib.shady" fn float3 f() { return float3(1.0); }
`);

	test::@check(error.contains("alone"),
		"an import with something beside it should be refused; got `%s`", error);
}
