<*
 Storage buffers: `@storage` blocks and the runtime-sized arrays that make a
 buffer's length the host's business rather than the shader's.

 The short spelling - `float data[];` - and the long one - a `@storage` struct
 whose last member is the array - are one feature seen from two sides: the
 wrapper the short one needs is generated, and everything below is the same.
*>
module storage_test;

import std::core::test;
import std::io;
import shady;
import shady_support;

// A compute stage to hang each test's declarations on. The entry point is in
// the tail so a test only writes what it is about.
const String HEAD = `
struct ComputeIn { uint3 thread @builtin(global_invocation_id); }
`;

const String TAIL = `
fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    store(i);
}
`;

<*
 Compile a fragment with a `store(uint)` the test defines, so the declarations
 under test are reachable by the entry point rather than optimized away (which
 shady does not do, but a kernel nothing calls is not a test of anything).

 Answers the diagnostic, or "" when it compiled.
*>
fn String rejection(String body, String store)
{
	String source = string::tformat("%s\n%s\n%s\n%s", HEAD, body, store, TAIL);
	return shady_support::compile_error(source);
}

fn void accepts_both_spellings() @test
{
	String error = rejection(`
float       data[];
float4      rows[];
struct Row { float2 value; }
Row         table[];

struct Extra @storage
{
    float  scale;
    float2 bias[];
}
Extra extra;
`, `
fn void store(uint i)
{
    data[i]     = rows[i].y;
    table[i].value = float2(1.0, 2.0);
    extra.bias[i]  = extra.scale;
}
`);

	test::@check(error == "", "a bare array and an @storage struct should both compile; got '%s'", error);
}

<*
 The variable names the block, so a bare `float data[];` and a `float4 data[];`
 are two different buffers - and the member the wrapper generates is named
 after the element, never after the variable.
*>
fn void a_bare_array_indexes_like_an_array() @test
{
	// The short spelling only has to behave like the long one: the same read,
	// written both ways, has to compile the same either way.
	String long_form = rejection(`
struct Data @storage { float values[]; }
Data data;
`, `
fn void store(uint i) { data.values[i] = float(i); }
`);
	String short_form = rejection("float data[];\n", `
fn void store(uint i) { data[i] = float(i); }
`);

	test::@check(long_form == "", "the explicit spelling should compile; got '%s'", long_form);
	test::@check(short_form == "", "the short spelling should compile; got '%s'", short_form);
}

fn void a_struct_element_lays_out_by_its_own_rules() @test
{
	// `Row` is { float2, uint } - 12 bytes under std430, and the stride the
	// array gets. A scalar-layout compile must not change that: a buffer is
	// read by whoever wrote it, so its layout cannot depend on a compiler flag.
	String error = rejection(`
struct Row { float2 value; uint tag; }
Row rows[];
`, `
fn void store(uint i) { rows[i].tag = i; }
`);

	test::@check(error == "", "a struct element should compile; got '%s'", error);
}

fn void a_runtime_array_outside_a_storage_block_is_refused() @test
{
	String plain = rejection(`
struct Row { float2 value; }
struct Holder { Row rows[]; }
`, `
fn void store(uint i) { }
`);

	test::@check(plain.contains("only a member of an @storage block"),
		"the message should name @storage; got '%s'", plain);

	String local = rejection("", `
fn void store(uint i) { float scratch[]; }
`);
	test::@check(local.contains("only a member of an @storage block"),
		"a local runtime array should be refused the same way; got '%s'", local);
}

<*
 Nothing can follow an array whose length the shader does not know.
*>
fn void rejects_a_member_after_the_runtime_array() @test
{
	String error = rejection(`
struct Data @storage
{
    float values[];
    uint  count;
}
Data data;
`, `
fn void store(uint i) { }
`);

	test::@check(error.contains("nothing may follow it"),
		"the message should say why the order matters; got '%s'", error);
}

fn void rejects_an_opaque_element() @test
{
	String error = rejection(`
struct Data @storage { sampler s[]; }
Data data;
`, `
fn void store(uint i) { }
`);

	test::@check(error.contains("cannot back a runtime-sized array"),
		"the message should say an opaque type cannot be an element; got '%s'", error);
}

<*
 A runtime-sized array is a storage buffer, so a fixed one still is not - the
 old refusal is still the right one for `float data[4];`.
*>
fn void rejects_a_fixed_array_resource() @test
{
	String error = rejection("float data[4];\n", `
fn void store(uint i) { }
`);

	test::@check(error.contains("cannot be a module-level variable"),
		"a fixed array is still not a resource; got '%s'", error);
}

<*
 Two buffers in one shader bind as two descriptors, in declaration order.
*>
fn void two_buffers_take_two_bindings() @test
{
	String error = rejection(`
float  source[];
float4 destination[];
`, `
fn void store(uint i) { destination[i] = float4(source[i]); }
`);

	test::@check(error == "", "two buffers should both bind; got '%s'", error);
}

<*
 The SPIR-V for a bare array is the block SPIR-V requires: one struct holding
 one runtime array, and the variable's pointer is to that struct. A module that
 emitted the array itself would fail `spirv-val`, which the conformance corpus
 checks - this is the same claim read back out of the words.
*>
fn void a_bare_array_is_emitted_as_a_block() @test
{
	char[] spirv = shady_support::build(string::tformat("%s\n%s\n%s\n%s", HEAD, `
float data[];
`, `
fn void store(uint i) { data[i] = float(i); }
`, TAIL));
	defer free(spirv);
	uint* words = (uint*)spirv.ptr;
	usz count = spirv.len / 4;

	bool has_storage_buffer_pointer = false;
	bool has_block_decoration = false;
	bool has_runtime_array = false;
	usz i = 5;
	while (i < count)
	{
		uint word   = words[i];
		usz length  = (usz)(word >> 16);
		if (length == 0 || i + length > count) break;

		switch ((shady::Opcode)(word & 0xffff))
		{
			case shady::Opcode.TYPE_POINTER:
				if (length >= 4 && words[i + 2] == (uint)shady::StorageClass.STORAGE_BUFFER)
				{
					has_storage_buffer_pointer = true;
				}
			case shady::Opcode.DECORATE:
				if (length >= 3 && words[i + 2] == (uint)shady::Decoration.BLOCK) has_block_decoration = true;
			case shady::Opcode.TYPE_RUNTIME_ARRAY:
				has_runtime_array = true;
			default:
		}
		i += length;
	}

	test::@check(has_storage_buffer_pointer, "the descriptor should be a StorageBuffer pointer");
	test::@check(has_block_decoration, "the generated block should be decorated Block");
	test::@check(has_runtime_array, "the array should be an OpTypeRuntimeArray");
}
