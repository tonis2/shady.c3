<*
 Plain functions, overloading, and method calls.

 A method is an ordinary function whose first parameter is the receiver, so
 `image.Sample(uv)` is `Sample(image, uv)` - one mechanism, not two.
*>
module function_test;

import std::io;
import shady;

const String VERTEX_IO = `
struct FragmentIn
{
    float4 position @position;
    float4 color;
}
`;

fn String shader(String body)
{
	return string::tformat("%s\n%s", VERTEX_IO, body);
}

fn bool compiles(String source)
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(source, &diagnostic);
	if (catch spirv)
	{
		io::printfn("shady: %d:%d: %s", diagnostic.line, diagnostic.column, diagnostic.message);
		return false;
	}
	free(spirv);
	return true;
}

fn String failure(String source)
{
	shady::Diagnostic diagnostic;
	if (catch shady::compile(source, &diagnostic)) return diagnostic.message;
	unreachable("the shader should have failed");
}

fn void calls_a_function_declared_later() @test
{
	assert(compiles(shader(`
fn float4 frag(FragmentIn input) @fragment
{
    return shade(input.color);
}

fn float4 shade(float4 color)
{
    return color;
}
`)), "a call to a function declared below should resolve");
}

fn void overloads_by_argument_count() @test
{
	assert(compiles(shader(`
fn float4 frag(FragmentIn input) @fragment
{
    return pick(input.color);
}

fn float4 pick(float4 color) { return color; }
fn float4 pick(float4 color, float amount) { return color * amount; }
`)), "the one-argument overload should be chosen");
}

fn void overloads_by_argument_type() @test
{
	assert(compiles(shader(`
fn float4 frag(FragmentIn input) @fragment
{
    return pick(input.color) + pick(input.color.xy);
}

fn float4 pick(float4 color) { return color; }
fn float4 pick(float2 uv) { return float4(uv, 0.0, 1.0); }
`)), "the overload matching the argument type should be chosen");
}

fn void a_self_method_takes_the_receiver_by_reference() @test
{
	assert(compiles(shader(`
struct Map
{
    int at;
}

fn Map map_at(int at) { Map m; m.at = at; return m; }

fn float4 Map.Sample(&self, float2 uv)
{
    return float4(uv, float(self.at), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
    return map_at(3).Sample(input.color.xy);
}
`)), "a &self method should take the receiver as a pointer");
}

fn void writes_through_self_reach_the_caller() @test
{
	assert(compiles(shader(`
struct Counter
{
    float value;
}

fn void Counter.bump(&self)
{
    self.value = self.value + 1.0;
}

fn float4 frag(FragmentIn input) @fragment
{
    Counter counter;
    counter.value = 0.0;
    counter.bump();
    return float4(counter.value);
}
`)), "a write through &self should reach the caller's storage");
}

fn void an_explicit_receiver_is_a_method_too() @test
{
	assert(compiles(shader(`
struct Map
{
    int at;
}

fn float4 Map.Sample(Map image, float2 uv)
{
    return float4(uv, float(image.at), 1.0);
}

fn float4 frag(FragmentIn input) @fragment
{
    Map m;
    m.at = 2;
    return m.Sample(input.color.xy);
}
`)), "the receiver of a qualified method may be written out");
}

fn void a_method_resolves_by_receiver_type() @test
{
	assert(compiles(shader(`
struct A { float x; }
struct B { float y; }

fn float A.value(A a) { return a.x; }
fn float B.value(B b) { return b.y; }

fn float4 frag(FragmentIn input) @fragment
{
    A a;
    a.x = 1.0;
    B b;
    b.y = 2.0;
    return float4(a.value() + b.value());
}
`)), "two types may each have a method of the same name");
}

fn void a_self_method_needs_a_receiver_type() @test
{
	String message = failure(shader(`
fn float4 Sample(&self, float2 uv) { return float4(uv, self.at, 1.0); }
fn float4 frag(FragmentIn input) @fragment { return Sample(input.color.xy); }
`));
	io::printfn("shady: %s", message);
	assert(message.len > 0, "`self` without a qualified name should be refused");
}

fn void rejects_recursion() @test
{
	String message = failure(shader(`
fn float4 frag(FragmentIn input) @fragment { return f(input.color); }
fn float4 f(float4 color) { return f(color); }
`));
	io::printfn("shady: %s", message);
	assert(message.len > 0, "recursion should be refused");
}

fn void rejects_an_ambiguous_call() @test
{
	String message = failure(shader(`
fn float4 frag(FragmentIn input) @fragment { return pick(input.color); }
fn float4 pick(float4 color) { return color; }
fn float4 pick(float4 color) { return color * 2.0; }
`));
	io::printfn("shady: %s", message);
	assert(message.len > 0, "an ambiguous overload should be refused");
}

fn void rejects_a_missing_return() @test
{
	String message = failure(shader(`
fn float4 frag(FragmentIn input) @fragment { return f(input.color); }
fn float4 f(float4 color) { if (color.x > 0.0) { return color; } }
`));
	io::printfn("shady: %s", message);
	assert(message.len > 0, "a path with no return should be refused");
}
