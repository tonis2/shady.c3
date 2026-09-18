<*
Shared memory, the barrier that makes it usable, and the two guarantees the
language makes about them: the length is the module's to state, and an unwritten
slot reads as zero.

 The execution half lives where it can run: a kernel through three.compute that
 reduces through a shared array is the only way to know a barrier synchronises
 something, and that test is in three's suite.
*>
module shared_test;

import std::core::test;
import std::io;
import std::io::file;
import shady;
import shady_support;

const String COMPUTE_HEAD = `
struct ComputeIn { uint3 thread @builtin(global_invocation_id); }
`;

const String COMPUTE_TAIL = `
fn void main(ComputeIn input) @compute @threads(64, 1, 1)
{
    uint i = input.thread.x;
    store(i);
}
`;

<*
 Compile a body plus the entry point that touches it, so nothing the test
 declared is unreachable. Answers the diagnostic, or "" when it compiled.
*>
fn String rejection(String body, String store)
{
	String source = string::tformat("%s\n%s\n%s\n%s", COMPUTE_HEAD, body, store, COMPUTE_TAIL);
	return shady_support::compile_error(source);
}

fn void a_shared_array_compiles_and_is_workgroup_storage() @test
{
	String source = string::tformat(`%s
shared float tile[64];

%s

%s`, COMPUTE_HEAD, `
fn void store(uint i)
{
    tile[i] = float(i);
    tile[i] = tile[63u - i];
}
`, COMPUTE_TAIL);

	String error = shady_support::compile_error(source);
	test::@check(error == "", "a shared array should compile; got '%s'", error);

	char[] spirv = shady_support::build(source);
	defer free(spirv);

	test::@check(has_workgroup_variable(spirv), "the shared array should be a Workgroup OpVariable");

	// No initialiser: SPIR-V gives a Workgroup variable no place to put one, so
	// the zeroing is the shader's if it needs it. The language says so in the
	// doc comment rather than pretending otherwise.
	test::@check(!has_initialised_workgroup_variable(spirv),
		"a Workgroup variable should not carry an initialiser");
}

// Whether any Workgroup variable carries an initialiser, which SPIR-V does
// not allow and a driver is free to misread.
fn bool has_initialised_workgroup_variable(char[] spirv)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word = words[i];
		uint len  = word >> 16;
		if ((word & 0xffff) == (uint)shady::Opcode.VARIABLE && i + 3 < count
			&& (words[i + 3] & 0xffff) == 4 && len > 4)
		{
			return true;
		}
		if (len == 0) break;
		i += len;
	}
	return false;
}

// The storage class operand of OpVariable is its third word, so the test reads
// it rather than trusting a whole-module "was there a 4 anywhere".
fn bool has_workgroup_variable(char[] spirv)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word = words[i];
		if ((word & 0xffff) == (uint)shady::Opcode.VARIABLE)
		{
			if (i + 3 < count && (words[i + 3] & 0xffff) == 4) return true;
		}
		usz len = (usz)(word >> 16);
		if (len == 0) break;
		i += len;
	}
	return false;
}

fn void a_shared_array_needs_a_length() @test
{
	String error = rejection(`
shared float tile[];
`, `
fn void store(uint i)
{
    tile[i] = 1.0;
}
`);

	test::@check(error != "", "a runtime-sized shared array should be refused");
	test::@check(error.contains("length"), "the refusal should say what is missing, got '%s'", error);
}

fn void barrier_takes_no_arguments() @test
{
	String error = rejection(`
shared uint counter;
`, `
fn void store(uint i)
{
    counter = 1u;
    barrier(2u);
}
`);

	test::@check(error.contains("no arguments"), "`barrier(2)` should be refused; got '%s'", error);
}

fn void a_shared_scalar_compiles() @test
{
	String error = rejection(`
shared uint counter;
`, `
fn void store(uint i)
{
    counter = counter + 1u;
    barrier;
    barrier;
}
`);
	test::@check(error == "", "a shared scalar and a barrier should compile; got '%s'", error);
}
