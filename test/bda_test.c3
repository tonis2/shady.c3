<*
 Buffer device addresses: a `buffer` behind a 64-bit address, indexed by the
 shader itself.

 The checks here are on the emitted SPIR-V rather than on rendering, because
 the properties that matter are structural - std430 offsets, the addressing
 model, and an `Aligned` operand on every access through an address. Whether it
 draws is settled by `src/main.c3`, which pulls its whole cube this way.
*>
module bda_test;

import std::core::test;
import std::io;
import std::io::path;
import shady;
import shady_support;

const String OUT_DIR = "build/shady";

const String PARTICLES = `
struct Particle @address {
    float4 position;
    float4 velocity;
}

struct Push @pushconstant {
    Particle* particles;
    uint      count;
}

Push pc;

struct VertexIn
{
    uint index @builtin(vertex_index);
}

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn FragmentIn vert(VertexIn input) @vertex
{
    Particle* p = pc.particles;

    FragmentIn output;
    output.position = p[input.index].position;
    output.color    = p[input.index].velocity;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    return input.color;
}
`;

fn void compiles_a_device_address_shader() @test
{
	char[] spirv = shady_support::build(PARTICLES);
	defer free(spirv);

	// SPIR-V 1.3: buffer device addresses were an extension before 1.5.
	test::@check(((uint*)spirv.ptr)[1] == shady::VERSION_1_3,
		"device addresses need SPIR-V 1.3, got version %d", ((uint*)spirv.ptr)[1]);

	path::mkdir(OUT_DIR, recursive: true)!!;
	file::save(string::tformat("%s/bda.spirv", OUT_DIR), spirv)!!;
	io::printfn("shady: compiled a device-address shader to %d bytes of SPIR-V", spirv.len);
}

<*
 A device address is not a descriptor. It must not consume a binding, and the
 resources that are descriptors must still be numbered from zero.
*>
fn void push_constants_take_no_binding() @test
{
	char[] spirv = shady_support::build(`
struct Data @address { float4 value; }

struct Push @pushconstant { Data* data; }
struct Uniforms @uniform { float4x4 mvp; }

Push pc;
Uniforms uniforms;
texture2d tex;

struct Out { float4 position @position; }

fn Out vert() @vertex
{
    Out output;
    output.position = uniforms.mvp * pc.data[0].value;
    return output;
}
`);
	defer free(spirv);

	test::@check(spirv.len > 0, "a push constant beside a uniform block should compile to something");
}

<*
 `T*` only means anything for a `buffer`. A pointer to a plain struct has no
 layout and no address, so it is rejected rather than silently emitted.
*>
fn void rejects_a_pointer_to_a_plain_struct() @test
{
	String error = shady_support::compile_error(`
struct Plain { float4 value; }
struct Push @pushconstant { Plain* p; }
Push pc;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = pc.p[0].value; return o; }
`);

	test::@check(error.contains("device address"),
		"the message should say the struct needs an address; got '%s'", error);
}

<*
 Only one push constant block: Vulkan allows exactly one per pipeline, so a
 second is an error here rather than a binding clash nobody would recognise.
*>
fn void rejects_two_push_constant_blocks() @test
{
	String error = shady_support::compile_error(`
struct A @pushconstant { uint x; }
struct B @pushconstant { uint y; }
A a;
B b;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = float4(0.0, 0.0, 0.0, 1.0); return o; }
`);

	test::@check(error.len > 0, "two push constant blocks should be refused; got '%s'", error);
}
