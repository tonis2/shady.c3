<*
 What a failed compile tells the writer: the region, the line, the source line
 and a caret - and what a successful one may still have to say.

 The acceptance case for the whole source-map path is here: a body spliced
 behind `#line 1 "material"` is reported as `material:3:12`, not as some line
 in the generated module nobody wrote.
*>
module diagnostic_test;

import std::core::test;
import std::io;
import shady;

<*
 A fragment stage whose body is behind a `#line` directive.

 The unknown name is on body line 3, column 12, and is twelve bytes long, so
 every field of the diagnostic has a number that could only come from the
 body's own text.
*>
const String MAPPED = `
struct FragmentIn
{
    float4 position @position;
    float4 color;
}

#line 1 "material"
fn float4 frag(FragmentIn input) @fragment
{
    return notAFunction;
}
`;

const String UNREAD_SPEC = `
const bool SHADOWS @spec(0) = true;

struct FragmentIn
{
    float4 position @position;
}

fn float4 frag(FragmentIn input) @fragment
{
    return float4(1.0);
}
`;

<*
 Compile in a scope with the compiler's memory checked.

 Returns true when the shader compiled, and leaves the diagnostic and the
 warnings for the caller - which is what the tests want: the things under test
 are their fields.

 Everything is allocated on the temp allocator, so the diagnostic outlives the
 assertion's scope without a free the assertion would read as a leak, and the
 caller must not free it. A compile is small and a test is shorter.
*>
fn bool compiles(String source, shady::Diagnostic* diagnostic, shady::DiagnosticList* warnings = null)
{
	bool ok = false;
	mem::@assert_leak()
	{
		shady::Diagnostic local;
		if (!diagnostic) diagnostic = &local;

		char[]? spirv = shady::compile(source, diagnostic, tmem, warnings: warnings);
		if (catch spirv)
		{
			ok = false;
		}
		else
		{
			ok = true;
		}
	};
	return ok;
}

fn void a_body_is_reported_by_its_own_line_and_name() @test
{
	shady::Diagnostic diagnostic;
	test::@check(!compiles(MAPPED, &diagnostic), "the shader is supposed to fail");

	test::@check(diagnostic.kind == shady::DiagnosticKind.ERROR, "it is an error");
	test::@check(diagnostic.name == "material",
		"the region is the one the directive named; got '%s'", diagnostic.name);
	test::@check(diagnostic.line == 3, "on line 3 of the body; got %d", diagnostic.line);
	test::@check(diagnostic.column == 12, "at column 12: got %d", diagnostic.column);
	test::@check(diagnostic.length == 12, "underlining 12 bytes; got %d", diagnostic.length);
	test::@check(diagnostic.line_text == "    return notAFunction;",
		"and the echoed line is the body's, not the module's; got '%s'", diagnostic.line_text);

	test::@check(diagnostic.to_string(tmem).contains("material:3:12"),
		"the heading names the body's coordinates; got '%s'", diagnostic.to_string(tmem));
}

fn void the_rendered_diagnostic_shows_the_line_and_the_caret() @test
{
	shady::Diagnostic diagnostic;
	test::@check(!compiles(MAPPED, &diagnostic), "the shader is supposed to fail");

	String rendered = diagnostic.render(tmem);

	// The caret line is the printed gutter, then the reported column: 5 + 11
	// spaces, so the carets sit under `notAFunction`.
	String expected = string::tformat("%s\n%s\n%s",
		"material:3:12: unknown name `notAFunction`",
		" 3 |     return notAFunction;",
		"                ^^^^^^^^^^^^");
	test::@check(rendered == expected,
		"the heading, the body's line and the caret under the name; got:\n%s", rendered);
}

fn void a_later_directive_renumbers_what_follows_it() @test
{
	// The shape generated source has: a body region, then a restore directive
	// that takes the numbering back to the module. The error is after the
	// restore, so it must be reported in the module's numbering, not the
	// body's.
	String source = `
struct FragmentIn
{
    float4 position @position;
}

#line 1 "vertex"
#line 40 "three.material"
fn float4 frag(FragmentIn input) @fragment
{
    return notAFunction;
}
`;

	shady::Diagnostic diagnostic;
	test::@check(!compiles(source, &diagnostic), "the shader is supposed to fail");

	test::@check(diagnostic.name == "three.material",
		"the last directive before the error names the region; got '%s'", diagnostic.name);
	test::@check(diagnostic.line == 42,
		"and numbers its line from 40; got %d", diagnostic.line);
}

fn void a_source_without_directives_keeps_its_physical_numbering() @test
{
	// No directive, so the fourth line of the source is line 4 of the source:
	// no region name, and nothing renumbered.
	String source = `
struct FragmentIn
{
    float4 position @position;
}

fn float4 frag(FragmentIn input) @fragment
{
    return notAFunction;
}
`;

	shady::Diagnostic diagnostic;
	test::@check(!compiles(source, &diagnostic), "the shader is supposed to fail");

	test::@check(diagnostic.name.len == 0, "there is no region to name; got '%s'", diagnostic.name);
	test::@check(diagnostic.line == 9, "and the line is the physical one; got %d", diagnostic.line);
	test::@check(diagnostic.to_string(tmem) == "9:12: unknown name `notAFunction`",
		"the heading is bare when there is no region; got '%s'", diagnostic.to_string(tmem));
}

fn void a_lexer_error_reports_where_it_happened() @test
{
	// The lexer runs before there is an AST, so its fault used to reach the
	// caller as an empty message. It now carries the position it stopped at.
	shady::Diagnostic diagnostic;
	test::@check(!compiles("fn $ x", &diagnostic), "the shader is supposed to fail");

	test::@check(diagnostic.message.contains("unexpected character"),
		"the message says what was unexpected; got '%s'", diagnostic.message);
	test::@check(diagnostic.line == 1 && diagnostic.column == 4,
		"and where: got %d:%d", diagnostic.line, diagnostic.column);
	test::@check(diagnostic.line_text == "fn $ x",
		"with the line it was on; got '%s'", diagnostic.line_text);
}

fn void a_malformed_directive_says_which_directive() @test
{
	shady::Diagnostic diagnostic;
	test::@check(!compiles("#line nope\nfn float4 f() @fragment { return float4(1.0); }", &diagnostic),
		"the shader is supposed to fail");
	test::@check(diagnostic.message.contains("`#line`"),
		"the message names the directive; got '%s'", diagnostic.message);

	test::@check(!compiles("#define X 1\nfn float4 f() @fragment { return float4(1.0); }", &diagnostic),
		"the shader is supposed to fail");
	test::@check(diagnostic.message.contains("no preprocessor"),
		"and says there is no preprocessor; got '%s'", diagnostic.message);
}

fn void an_unread_spec_constant_warns_but_compiles() @test
{
	shady::DiagnosticList warnings;
	warnings.init(tmem, 4);

	shady::Diagnostic diagnostic;
	test::@check(compiles(UNREAD_SPEC, &diagnostic, &warnings), "a warning is not a failure");

	test::@check(warnings.len() == 1, "one warning; got %d", warnings.len());
	shady::Diagnostic* warning = &warnings[0];
	test::@check(warning.kind == shady::DiagnosticKind.WARNING, "it is a warning");
	test::@check(warning.message.contains("SHADOWS"),
		"naming the constant the host would set in vain; got '%s'", warning.message);
	test::@check(warning.line == 2, "on the line it was declared; got %d", warning.line);
	test::@check(warning.to_string(tmem).starts_with("warning: "),
		"and a warning says so; got '%s'", warning.to_string(tmem));
}

fn void a_read_spec_constant_warns_about_nothing() @test
{
	String source = `
const bool SHADOWS @spec(0) = true;

struct FragmentIn
{
    float4 position @position;
}

fn float4 frag(FragmentIn input) @fragment
{
    if (SHADOWS)
    {
        return float4(0.5);
    }
    return float4(1.0);
}
`;

	shady::DiagnosticList warnings;
	warnings.init(tmem, 4);

	shady::Diagnostic diagnostic;
	test::@check(compiles(source, &diagnostic, &warnings), "the shader compiles");
	test::@check(warnings.len() == 0,
		"a constant something reads is not a warning; got %d", warnings.len());
}
