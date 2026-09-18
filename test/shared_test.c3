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

<*
 Cooperative matrices: `coopmat<T, M, N, scope, use>` is a type family, and
 the use is part of the identity - A, B and the accumulator are laid out
 differently, so two shapes that differ only in use are two types.
*>
fn void a_coopmat_type_declares_its_shape() @test
{
	String error = rejection(`
shared float tile[256];
`, `
fn void store(uint i)
{
    coopmat<float, 16, 16, workgroup, a>   a_mat;
    coopmat<float, 16, 16, workgroup, b>   b_mat;
    coopmat<float, 16, 16, workgroup, accumulator> acc_mat;

    coop_load(a_mat, &tile[0], 16u);
    coop_load(b_mat, &tile[0], 16u);
    coop_load(acc_mat, &tile[0], 16u);
    coop_muladd(a_mat, b_mat, acc_mat, acc_mat);
}
`);

	test::@check(error == "", "a coopmat should compile; got '%s'", error);
}

fn void a_coopmat_refuses_a_bad_use() @test
{
	String error = rejection(`
shared float tile[256];
`, `
fn void store(uint i)
{
    coopmat<float, 16, 16, workgroup, wrong> mat;
    coop_load(mat, &tile[0], 16u);
}
`);

	test::@check(error.contains("not a coopmat use"), "the refusal should name the use; got '%s'", error);
}

fn void a_coopmat_refuses_a_shape_that_does_not_multiply() @test
{
	String error = rejection(`
shared float tile[256];
`, `
fn void store(uint i)
{
    coopmat<float, 16, 8, workgroup, a>   a_mat;
    coopmat<float, 16, 16, workgroup, b>  b_mat;
    coopmat<float, 16, 16, workgroup, accumulator> acc_mat;

    coop_load(a_mat, &tile[0], 16u);
    coop_load(b_mat, &tile[0], 16u);
    coop_load(acc_mat, &tile[0], 16u);
    coop_muladd(a_mat, b_mat, acc_mat, acc_mat);
}
`);

	test::@check(error.contains("cannot multiply"), "a shape mismatch should be refused; got '%s'", error);
}

<*
 A byte tile has to be reachable: `uint8(x)` is the narrowing, and the element
 type says what the array's elements are.
*>
fn void a_byte_tile_compiles() @test
{
	String error = rejection(`
shared uint8 tile[64];
`, `
fn void store(uint i)
{
    uint word = 0x1234u;
    tile[i] = uint8(word >> 8u);
    tile[i] = uint8(0u);
}
`);

	test::@check(error == "", "a byte tile should compile; got '%s'", error);
}

<*
 An assignment is not a conversion. A 32-bit value landing in a byte slot by
 way of `=` is refused, and the refusal names the conversion that was meant.
*>
fn void a_byte_cannot_be_assigned_from_a_wider_integer() @test
{
	String error = rejection(`
shared uint8 tile[64];
`, `
fn void store(uint i)
{
    uint word = 0x1234u;
    tile[i] = word;
}
`);

	test::@check(error.contains("write `uint8(x)` to narrow it"),
		"the refusal should name the conversion; got '%s'", error);
}

<*
 The same rule where the value is an `int` rather than a `uint`: the bitcast
 that carries `uint i = 0;` is only the identity when both sides are 32 bits.
*>
fn void a_byte_cannot_be_assigned_from_a_wider_int() @test
{
	String error = rejection(`
shared uint8 tile[64];
`, `
fn void store(uint i)
{
    int value = -3;
    tile[i] = value;
}
`);

	test::@check(error.contains("write `uint8(x)` to narrow it"),
		"the refusal should name the conversion; got '%s'", error);
}

<*
 A coopmat of bytes is a shape the hardware has, and it is spelled with the
 byte element rather than a float one.
*>
fn void a_coopmat_holds_byte_tiles() @test
{
	String error = rejection(`
shared uint8 tile[256];
`, `
fn void store(uint i)
{
    coopmat<uint8, 16, 16, subgroup, a>   a_mat;
    coopmat<uint8, 16, 16, subgroup, b>   b_mat;
    coopmat<uint, 16, 16, subgroup, accumulator> acc;

    coop_load(a_mat, &tile[0], 16u);
    coop_load(b_mat, &tile[0], 16u);
    coop_load(acc, &tile[0], 16u);
    coop_muladd(a_mat, b_mat, acc, acc);
}
`);

	test::@check(error == "", "a byte coopmat should compile; got '%s'", error);
}


<*
 A byte array as a storage block: the shape a quantised weight tensor has,
 and the thing every `uint8` in this language is ultimately for.
*>
fn void a_byte_storage_block_compiles() @test
{
	String error = rejection(`
uint8 weights[];
`, `
fn void store(uint i)
{
    uint word = uint(weights[i]);
    weights[i] = uint8(word);
}
`);

	test::@check(error == "", "a byte storage block should compile; got '%s'", error);
}
