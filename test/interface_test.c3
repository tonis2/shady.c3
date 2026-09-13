<*
 `interface` and `provides`: a named set of declarations, and a module's claim
 that it defines every one of them (LANGUAGE.md section 3.5).

 An interface is static - there is no `any`, no vtable, no run-time dispatch.
 It is `@required` generalised from one declaration to a named set, so the
 check is the same shape: asked of the module, once, at compile time.
*>
module interface_test;

import std::core::test;
import shady_support;

<*
 The whole point: the interface declares, the module defines, a call resolves
 through the declaration.
*>
fn void an_interface_the_module_defines_compiles() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Surface { float3 albedo; }

interface Shading
{
	fn float3 diffuse(Surface s);
	fn float3 ambient(Surface s);
}

fn float3 diffuse(Surface s) { return s.albedo; }
fn float3 ambient(Surface s) { return s.albedo * 0.1; }

provides Shading;

fn float4 shade(FragmentIn input)
{
	Surface s;
	s.albedo = input.color.rgb;
	return float4(diffuse(s) + ambient(s), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
	return shade(input);
}
`));

	test::@check(error == "", "an interface the module defines should compile; got `%s`", error);
}

<*
 A missing member is refused once, at the interface, even though nothing calls
 it - the difference between an interface and a plain declaration.
*>
fn void a_missing_member_names_the_interface_and_the_member() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
struct Surface { float3 albedo; }

interface Shading
{
	fn float3 diffuse(Surface s);
	fn float3 ambient(Surface s);
}

fn float3 diffuse(Surface s) { return s.albedo; }

provides Shading;

fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.rgb, 1.0);
}
`));

	test::@check(error.contains("Shading") && error.contains("ambient"),
		"the refusal should name the interface and the member; got `%s`", error);
}

<*
 A definition of the same name with another signature is an overload, not the
 member. Name-only matching would call this satisfied.
*>
fn void a_same_named_overload_does_not_satisfy_a_member() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
interface Shading
{
	fn float3 tint(float3 color);
}

fn float3 tint(float4 color) { return color.rgb; }

provides Shading;

fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.rgb, 1.0);
}
`));

	test::@check(error.contains("Shading") && error.contains("tint"),
		"the missing member should be named even when an overload of it exists; got `%s`", error);
}

<*
 Declaring an interface is not claiming it: no `provides`, no obligation. A
 plain declaration keeps the same rule.
*>
fn void an_interface_nobody_provides_is_not_an_error() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
interface Optional
{
	fn float3 helper();
}

fn float4 frag(FragmentIn input) @fragment
{
	return input.color;
}
`));

	test::@check(error == "", "an unclaimed interface alone is not an error; got `%s`", error);
}

fn void providing_an_interface_that_does_not_exist_is_refused() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
provides Nonesuch;

fn float4 frag(FragmentIn input) @fragment
{
	return input.color;
}
`));

	test::@check(error.contains("Nonesuch"), "the refusal should name the unknown interface; got `%s`", error);
}

<*
 Two interfaces may name the same signature - one obligation, one declaration,
 so the shared definition satisfies either claim.
*>
fn void two_interfaces_may_share_a_member() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
interface Luminous
{
	fn float3 glow();
}

interface Bright
{
	fn float3 glow();
}

fn float3 glow() { return float3(1.0); }

provides Luminous;
provides Bright;

fn float4 frag(FragmentIn input) @fragment
{
	return float4(glow(), 1.0);
}
`));

	test::@check(error == "", "one definition should satisfy both interfaces; got `%s`", error);
}

<*
 A member is the declaration the provider fills, so it cannot also be a
 definition - two places to say the same thing.
*>
fn void an_interface_member_cannot_have_a_body() @test
{
	String error = shady_support::compile_error(`
interface Shading
{
	fn float3 tint(float3 color) { return color; }
}
`);

	test::@check(error.contains("interface member"),
		"a member with a body should be refused where it is written; got `%s`", error);
}
