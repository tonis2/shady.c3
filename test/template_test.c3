<*
 Templates: a module with holes in it, and the text a host splices in to fill
 them.

 `@required` is a hole the text must fill; `@fallback` is one with a default
 answer the text may replace. The tests that matter most are the ones about
 *where* a mistake is reported - a template is read by the host and a body by
 its author, so a refusal has to land in the author's own `#line` region.

 Which body ran is told apart by laziness: a function is emitted only when
 something calls it, so a replaced fallback that calls a function nobody
 defines is never emitted and compiles, while the same fallback left in place
 is refused.
*>
module template_test;

import std::io;
import shady;
import shady_support;

const String TEMPLATE = `
#line 1 "template"
struct FragmentIn
{
	float4 position @position;
	float4 color;
}

fn float4 shade(FragmentIn input) @fallback
{
	return missing(input.color);
}

fn float4 frag(FragmentIn input) @fragment
{
	return shade(input);
}
`;

fn String with_body(String body) => string::tformat("%s\n#line 1 \"body\"\n%s", TEMPLATE, body);

fn void a_fallback_nothing_replaces_is_the_body_that_runs() @test
{
	String error = shady_support::compile_error(TEMPLATE);
	test::@check(error.contains("missing"), "the fallback should be emitted, and its unknown call refused; got `%s`", error);
}

fn void a_definition_after_the_fallback_replaces_it() @test
{
	String error = shady_support::compile_error(with_body("fn float4 shade(FragmentIn input) { return input.color; }"));
	test::@check(error == "", "the body should replace the fallback, which is then never emitted; got `%s`", error);
}

fn void a_definition_before_the_fallback_replaces_it() @test
{
	String source = string::tformat("#line 1 \"body\"\nfn float4 shade(FragmentIn input) { return input.color; }\n%s", TEMPLATE);
	String error = shady_support::compile_error(source);
	test::@check(error == "", "order should not decide which body wins; got `%s`", error);
}

fn void a_hole_has_one_fallback() @test
{
	String error = shady_support::compile_error(with_body("fn float4 shade(FragmentIn input) @fallback { return input.color; }"));
	test::@check(error.starts_with("body:1:") && error.contains("already has a @fallback") && error.contains("template:7"),
		"a second fallback should be refused at its line, naming the first; got `%s`", error);
}

fn void a_fallback_cannot_fill_a_required_hole() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
fn float4 shade(FragmentIn input) @required;
fn float4 shade(FragmentIn input) @fallback { return input.color; }
fn float4 frag(FragmentIn input) @fragment { return shade(input); }
`));
	test::@check(error.contains("@required") && error.contains("drop @required"),
		"a fallback filling a required hole should be refused; got `%s`", error);
}

fn void a_fallback_needs_a_body_and_is_not_an_entry_point() @test
{
	String bodyless = shady_support::compile_error(shady_support::fragment(`
fn float4 shade(FragmentIn input) @fallback;
fn float4 frag(FragmentIn input) @fragment { return input.color; }
`));
	test::@check(bodyless.contains("needs a body"), "a bodyless fallback should be refused; got `%s`", bodyless);

	String entry = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment @fallback { return input.color; }
`));
	test::@check(entry.contains("entry point"), "a fallback entry point should be refused; got `%s`", entry);

	String both = shady_support::compile_error(shady_support::fragment(`
fn float4 shade(FragmentIn input) @required @fallback;
fn float4 frag(FragmentIn input) @fragment { return input.color; }
`));
	test::@check(both.contains("both @required and @fallback"), "a hole cannot be both; got `%s`", both);
}

fn void a_second_definition_is_refused_in_the_authors_region() @test
{
	String error = shady_support::compile_error(with_body(`
fn float4 helper(float4 c) { return c; }

fn float4 helper(float4 c) { return c * 2.0; }
fn float4 shade(FragmentIn input) { return helper(input.color); }
`));
	test::@check(error.starts_with("body:4:1:") && error.contains("already defined with this signature at body:2"),
		"the duplicate should be reported at body:4, naming body:2; got `%s`", error);
}

fn void a_mistyped_hole_is_refused_at_the_definition() @test
{
	// Without the rule this is an overload: it compiles, and the fallback runs.
	String error = shady_support::compile_error(with_body(`
fn float3 shade(FragmentIn input) { return input.color.rgb; }
`));
	test::@check(error.starts_with("body:2:1:")
		&& error.contains("fn float4 shade(FragmentIn input)")
		&& error.contains("template:7"),
		"a definition with the wrong signature should be refused where it is, quoting the hole; got `%s`", error);
}

fn void a_mistyped_required_hole_is_refused_at_the_definition() @test
{
	String error = shady_support::compile_error(`
#line 1 "template"
struct FragmentIn
{
	float4 position @position;
	float4 color;
}
fn float4 shade(FragmentIn input) @required;
fn float4 frag(FragmentIn input) @fragment { return shade(input); }
#line 1 "body"
fn float4 shade(FragmentIn input, float k) { return input.color * k; }
`);
	test::@check(error.starts_with("body:1:1:") && error.contains("template:6"),
		"a required hole defined with the wrong signature should be named at the definition; got `%s`", error);
}

fn void an_unknown_attribute_is_refused_where_it_is_written() @test
{
	String function = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @framgent { return input.color; }
`));
	test::@check(function.contains("unknown attribute `@framgent`") && function.contains("@fragment"),
		"a misspelt stage should be refused, listing what a function takes; got `%s`", function);

	String member = shady_support::compile_error(`
struct FragmentIn
{
	float4 position @postion;
}
fn float4 frag(FragmentIn input) @fragment { return input.position; }
`);
	test::@check(member.starts_with("4:18:") && member.contains("unknown attribute `@postion`"),
		"a member's attribute should be refused at its own column; got `%s`", member);

	String wrong_kind = shady_support::compile_error(shady_support::fragment(`
fn float4 frag(FragmentIn input) @fragment @binding(0) { return input.color; }
`));
	test::@check(wrong_kind.contains("`@binding` does not apply to a function"),
		"a known attribute on the wrong declaration says so; got `%s`", wrong_kind);

	String parameter = shady_support::compile_error(shady_support::fragment(`
fn float4 tint(float4 c @builtin(position)) { return c; }
fn float4 frag(FragmentIn input) @fragment { return tint(input.color); }
`));
	test::@check(parameter.contains("does not apply to a parameter"),
		"a parameter takes no attribute; got `%s`", parameter);
}

fn void the_holes_of_a_template_are_listed() @test
{
	@pool()
	{
		String source = `
#line 1 "material"
struct Vertex { float3 local; }
struct Surface { float4 albedo; }
fn float3 shade(Surface s) @fallback { return s.albedo.rgb; }
fn void displace(inout Vertex v) @required;
fn float3 helper(Surface s) { return s.albedo.rgb; }
`;
		shady::Hole[]? found = shady::holes(source, tmem);
		if (catch found)
		{
			test::@check(false, "a template should parse");
			return;
		}
		test::@check(found.len == 2, "two holes, the helper is not one; got %d", found.len);
		test::@check(found[0].name == "shade" && found[0].fallback, "shade is a fallback");
		test::@check(found[0].signature == "fn float3 shade(Surface s)", "got `%s`", found[0].signature);
		test::@check(found[0].region == "material" && found[0].line == 3, "got %s:%d", found[0].region, found[0].line);
		test::@check(found[1].name == "displace" && !found[1].fallback, "displace is required");
		test::@check(found[1].signature == "fn void displace(inout Vertex v)", "inout is kept; got `%s`", found[1].signature);
	};
}

fn void the_two_spellings_of_a_body_are_told_apart() @test
{
	test::@check(shady::defines_functions("fn float3 shade(Surface s) { return s.albedo; }")!!, "a function");
	test::@check(!shady::defines_functions("return s.albedo; // fn in a comment")!!, "a bare body, fn only in a comment");
	test::@check(!shady::defines_functions("float3 fnord = s.albedo;\nreturn fnord;")!!, "fnord is an identifier");
}

fn void keywords_and_top_level_names() @test
{
	test::@check(shady::is_keyword("for") && shady::is_keyword("out") && shady::is_keyword("default"), "keywords");
	test::@check(!shady::is_keyword("normal") && !shady::is_keyword("inout") && !shady::is_keyword("float"), "not keywords");

	@pool()
	{
		String[]? names = shady::top_level_names(`
struct Post { float3 color; }
const float PI = 3.14;
fn float3 post(Post p) @required;
fn float3 post(Post p, float k) { return p.color * k; }
`, tmem);
		if (catch names)
		{
			test::@check(false, "the text should parse");
			return;
		}
		test::@check(names.len == 3 && names[0] == "Post" && names[1] == "PI" && names[2] == "post",
			"each name once, in order; got %d", names.len);
	};
}
