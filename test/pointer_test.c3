<*
 Buffer device addresses beyond structs: flat scalar/vector/matrix streams,
 pointer parameters, pointer locals, writes through an address, and the one
 atomic the cluster pass uses.
*>
module pointer_test;

import std::core::test;
import shady;
import shady_support;

<*
 Whether the module contains an instruction with this opcode, which is how a
 structural claim such as "this lowered to an atomic" is checked here.
*>
fn bool has_opcode(char[] spirv, shady::Opcode opcode) @private
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5; // the five-word header
	while (i < count)
	{
		uint word = words[i];
		if ((word & 0xffff) == (uint)opcode) return true;
		i += (usz)(word >> 16);
	}
	return false;
}

fn void pointers_to_scalars_vectors_and_matrices() @test
{
	String error = shady_support::compile_error(`
struct Push @pushconstant
{
    float3*   positions;
    float4*   colors;
    uint*     counts;
    uint4*    joints;
    float4x4* palette;
    float*    weights;
    uint      count;
}
Push push;

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn float4 frag(FragmentIn input) @fragment
{
    uint i = uint(input.color.x);
    float3 p = push.positions[i];
    float4 c = push.colors[i];
    uint   n = push.counts[i];
    uint4  j = push.joints[i];
    float4x4 m = push.palette[i];
    float  w = push.weights[i];
    return c + float4(p, float(n) + float(j.x) + w) + m[0];
}
`);

	test::@check(error == "", "a device address may point at a scalar, vector or matrix; got '%s'", error);
}

fn void a_pointer_parameter_passes_the_address() @test
{
	String error = shady_support::compile_error(`
struct Push @pushconstant
{
    float3* positions;
}
Push push;

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn float3 read(float3* data, uint i)
{
    return data[i];
}

fn float4 frag(FragmentIn input) @fragment
{
    return float4(read(push.positions, uint(input.color.x)), 1.0);
}
`);

	test::@check(error == "", "a pointer may be a parameter and an argument; got '%s'", error);
}

fn void a_pointer_local_is_reassigned_and_chosen() @test
{
	String error = shady_support::compile_error(`
struct Push @pushconstant
{
    float3* first;
    float3* second;
}
Push push;

struct FragmentIn
{
    float4 position @position;
    float4 color;
}

fn float4 frag(FragmentIn input) @fragment
{
    float3* p = push.first;
    if (input.color.x > 0.5) p = push.second;

    uint i = uint(input.color.y);
    float3* chosen = input.color.z > 0.5 ? push.first : push.second;
    return float4(p[i] + chosen[i], 1.0);
}
`);

	test::@check(error == "", "a pointer local may be reassigned and chosen by a branch; got '%s'", error);
}

<*
 The write side: a struct built in a register and stored through a device
 address. This is what the skin pass does, and what no test covered before.
*>
fn void writes_through_a_device_address() @test
{
	String error = shady_support::compile_error(`
struct Vertex @address
{
    float3 position;
    float3 normal;
}

struct Push @pushconstant
{
    float3* positions;
    Vertex* output;
    uint    count;
}
Push push;

struct ComputeIn
{
    uint3 id @builtin(global_invocation_id);
}

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint index = input.id.x;
    if (index >= push.count) return;

    Vertex vertex;
    vertex.position = push.positions[index];
    vertex.normal = float3(0.0, 1.0, 0.0);
    push.output[index] = vertex;
}
`);

	test::@check(error == "", "a struct should be writable through a device address; got '%s'", error);
}

<*
 The cluster pass's overflow counter, checked at the instruction level: a
 relaxed load-and-add would compile and be wrong, so the emitted opcode is what
 the test pins.
*>
fn void interlocked_add_lowers_to_an_atomic() @test
{
	char[] spirv = shady_support::build(`
struct Push @pushconstant
{
    uint* overflow;
}
Push push;

struct ComputeIn
{
    uint3 id @builtin(global_invocation_id);
}

fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    if (input.id.x >= 4u) return;
    InterlockedAdd(push.overflow[0], 1u);
}
`, scalar_layout: true);
	defer free(spirv);

	test::@check(has_opcode(spirv, shady::Opcode.ATOMIC_I_ADD),
		"InterlockedAdd should lower to OpAtomicIAdd");
}

fn void rejects_a_pointer_to_a_plain_struct() @test
{
	String error = shady_support::compile_error(`
struct Plain { float4 value; }
struct Push @pushconstant { Plain* p; }
Push push;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = push.p[0].value; return o; }
`);

	test::@check(error.len > 0, "a pointer to a non-@address struct should still be refused; got '%s'", error);
}

fn void rejects_an_interlocked_add_that_is_not_a_variable() @test
{
	String error = shady_support::compile_error(`
struct Out { float4 position @position; }
fn Out vert() @vertex
{
    Out o;
    o.position = float4(float(InterlockedAdd(1u, 2u)));
    return o;
}
`);

	test::@check(error.contains("InterlockedAdd"),
		"the error should name the call; got '%s'", error);
}
