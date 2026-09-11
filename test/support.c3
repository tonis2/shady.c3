<*
 Shared helpers for the suite: compile a shader once, with the compiler's own
 memory checked, and hand back either the SPIR-V or the diagnostic.

 `compile_error` runs the compile under `mem::@assert_leak`, so a compiler that
 keeps something is a hard failure at the test that compiled it, not a slow
 drift the runner reports at the end of the file. Everything it compiles is
 released inside that scope; the only thing that crosses back out is the
 message, copied to the temp allocator.

 Under `--safe=no` the leak assertion is inert (see `std::core::mem`), so the
 suite still runs where the tracker is unavailable.
*>
module shady_support;

import std::io;
import shady;

const String FRAGMENT_IO = `
struct FragmentIn
{
    float4 position @position;
    float4 color;
}
`;

<*
 A fragment stage with the shared interface, so a test writes only the body.
*>
fn String fragment(String body)
{
	return string::tformat("%s\n%s", FRAGMENT_IO, body);
}

<*
 "" when the shader compiled, otherwise "line:column: message".

 Every shader in this suite goes through here, so the leak check sees every
 compile. An empty return means success; a test that expected a refusal checks
 that the string is not empty, and can quote it when it is.
*>
fn String compile_error(String source, bool scalar_layout = false)
{
	shady::Diagnostic diagnostic;
	String error = "";

	mem::@assert_leak()
	{
		char[]? maybe = shady::compile(source, &diagnostic, scalar_layout: scalar_layout);
		if (catch maybe)
		{
			error = diagnostic.to_string(tmem);
		}
		else
		{
			free(maybe);
		}
		diagnostic.free();
	};

	return error;
}

<*
 The SPIR-V for a shader that must compile. Owned by the caller.

 Use this only when the test needs the words themselves - the entry-point
 names, the header version, a capability, a file to hand to `spirv-val`. When
 the test only cares whether the shader compiled, use `compile_error`, which
 frees it here and so can check the compiler for leaks.
*>
fn char[] build(String source, bool scalar_layout = false)
{
	shady::Diagnostic diagnostic;
	char[]? maybe = shady::compile(source, &diagnostic, scalar_layout: scalar_layout);
	if (catch maybe)
	{
		io::printfn("shady: %s", diagnostic.to_string(tmem));
		diagnostic.free();
		unreachable("the shader should compile");
	}
	return maybe;
}

// --- Reading the module ------------------------------------------------------

<*
 Whether the module contains an instruction with this opcode. That is how a
 structural claim - "this lowered to an atomic", "this is a spec constant" - is
 checked without a disassembler.
*>
fn bool has_opcode(char[] spirv, uint opcode)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5; // the five-word header
	while (i < count)
	{
		uint word = words[i];
		if ((word & 0xffff) == opcode) return true;
		i += (usz)(word >> 16);
	}
	return false;
}

fn bool has_capability(char[] spirv, uint capability)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		uint opcode = word & 0xffff;
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::OP_CAPABILITY && words[i + 1] == capability) return true;
		i += len;
	}
	return false;
}

<*
 Whether any `OpDecorate` carries this decoration and this first operand.
*>
fn bool has_decoration_value(char[] spirv, uint decoration, uint value)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		uint opcode = word & 0xffff;
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::OP_DECORATE && words[i + 2] == decoration && words[i + 3] == value) return true;
		i += len;
	}
	return false;
}

<*
 Whether any `OpDecorate` carries this decoration, whatever its operand.
*>
fn bool has_decoration(char[] spirv, uint decoration)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		uint opcode = word & 0xffff;
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::OP_DECORATE && words[i + 2] == decoration) return true;
		i += len;
	}
	return false;
}
