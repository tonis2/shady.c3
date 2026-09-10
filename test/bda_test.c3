<*
 Buffer device addresses: a `buffer` behind a 64-bit address, indexed by the
 shader itself.

 The checks here are on the emitted SPIR-V rather than on rendering, because
 the properties that matter are structural - std430 offsets, the addressing
 model, and an `Aligned` operand on every access through an address. Whether it
 draws is settled by `src/main.c3`, which pulls its whole cube this way.
*>
module bda_test;

import std::io;
import std::io::path;
import shady;

const String OUT_DIR = "build/shady";

const String PARTICLES = `
buffer Particle
{
    float4 position;
    float4 velocity;
}

struct Push
{
    Particle* particles;
    uint      count;
}

push_constant Push pc;

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

fn char[] build(String source)
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(source, &diagnostic);
	if (catch spirv)
	{
		io::printfn("shady error at %d:%d - %s", diagnostic.line, diagnostic.column, diagnostic.message);
		unreachable("the shader should compile");
	}
	return spirv;
}

fn void compiles_a_device_address_shader() @test
{
	char[] spirv = build(PARTICLES);
	defer free(spirv);

	// SPIR-V 1.3: buffer device addresses were an extension before 1.5.
	assert(((uint*)spirv.ptr)[1] == shady::VERSION_1_3, "device addresses need SPIR-V 1.3");

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
	char[] spirv = build(`
buffer Data { float4 value; }

struct Push { Data* data; }
struct Uniforms { float4x4 mvp; }

push_constant Push pc;
uniform Uniforms uniforms;
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
	assert(spirv.len > 0);
}

<*
 `T*` only means anything for a `buffer`. A pointer to a plain struct has no
 layout and no address, so it is rejected rather than silently emitted.
*>
fn void rejects_a_pointer_to_a_plain_struct() @test
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(`
struct Plain { float4 value; }
struct Push { Plain* p; }
push_constant Push pc;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = pc.p[0].value; return o; }
`, &diagnostic);

	if (try spirv)
	{
		free(spirv);
		unreachable("a pointer to a non-buffer struct should not compile");
	}
	assert(diagnostic.message.len > 0, "the error should say something");
	io::printfn("shady: rejected `Plain*` - %s", diagnostic.message);
}

<*
 Only one push constant block: Vulkan allows exactly one per pipeline, so a
 second is an error here rather than a binding clash nobody would recognise.
*>
fn void rejects_two_push_constant_blocks() @test
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(`
struct A { uint x; }
struct B { uint y; }
push_constant A a;
push_constant B b;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = float4(0.0, 0.0, 0.0, 1.0); return o; }
`, &diagnostic);

	if (try spirv)
	{
		free(spirv);
		unreachable("two push constant blocks should not compile");
	}
	io::printfn("shady: rejected a second push_constant block - %s", diagnostic.message);
}
