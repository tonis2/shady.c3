<*
 `interface`: a named set of function declarations, and the module rule that
 checks its members (LANGUAGE.md section 3.5).

 The interface is static - there is no `any`, no vtable, no run-time dispatch.
 Its members are declarations of the module, so each one is satisfied by a
 definition in that module or refused at the declaration; no `implements`
 statement exists.
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
module shading;

struct Surface { float3 albedo; }

interface Shading
{
	fn float3 diffuse(Surface s);
	fn float3 ambient(Surface s);
}

fn float3 diffuse(Surface s) { return s.albedo; }
fn float3 ambient(Surface s) { return s.albedo * 0.1; }

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
 A missing member is refused at the declaration, naming the module and the
 member - no call site needed.
*>
fn void a_missing_member_names_the_module_and_the_member() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
module shading;

struct Surface { float3 albedo; }

interface Shading
{
	fn float3 diffuse(Surface s);
	fn float3 ambient(Surface s);
}

fn float3 diffuse(Surface s) { return s.albedo; }

fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.rgb, 1.0);
}
`));

	test::@check(error.contains("shading") && error.contains("ambient"),
		"the refusal should name the module and the member; got `%s`", error);
}

<*
 A definition of the same name with another signature is an overload, not the
 member. Name-only matching would call this satisfied.
*>
fn void a_same_named_overload_does_not_satisfy_a_member() @test
{
	String error = shady_support::compile_error(shady_support::fragment(`
module shading;

interface Shading
{
	fn float3 tint(float3 color);
}

fn float3 tint(float4 color) { return color.rgb; }

fn float4 frag(FragmentIn input) @fragment
{
	return float4(input.color.rgb, 1.0);
}
`));

	test::@check(error.contains("shading") && error.contains("tint"),
		"the missing member should be named even when an overload of it exists; got `%s`", error);
}

<*
 Declaring an interface with no module is not the module's claim: its members
 keep the older rule, refused only where they are called.
*>
fn void an_interface_without_a_module_is_not_an_error() @test
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

	test::@check(error == "", "a module-less interface alone is not an error; got `%s`", error);
}

<*
 Two interfaces may name the same signature - one declaration, so one
 definition fills both.
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

fn float4 frag(FragmentIn input) @fragment
{
	return float4(glow(), 1.0);
}
`));

	test::@check(error == "", "one definition should satisfy both interfaces; got `%s`", error);
}

<*
 A member is a declaration, so it cannot also be a definition - two places to
 say the same thing.
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
