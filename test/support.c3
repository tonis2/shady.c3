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
fn bool has_opcode(char[] spirv, shady::Opcode opcode)
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

<*
 Whether any `OpExtInst` asks the GLSL std450 library for this instruction.
*>
fn bool has_ext_inst(char[] spirv, shady::GlslOp instruction)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.EXT_INST && words[i + 4] == (uint)instruction) return true;
		i += len;
	}
	return false;
}

fn bool has_capability(char[] spirv, shady::Capability capability)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.CAPABILITY && words[i + 1] == (uint)capability) return true;
		i += len;
	}
	return false;
}

<*
 Whether any `OpDecorate` carries this decoration and this first operand.
*>
fn bool has_decoration_value(char[] spirv, shady::Decoration decoration, uint value)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.DECORATE && words[i + 2] == (uint)decoration && words[i + 3] == value) return true;
		i += len;
	}
	return false;
}

<*
 Whether any `OpDecorate` carries this decoration, whatever its operand.
*>
fn bool has_decoration(char[] spirv, shady::Decoration decoration)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.DECORATE && words[i + 2] == (uint)decoration) return true;
		i += len;
	}
	return false;
}

<*
 How many `OpDecorate` instructions carry this decoration - for a decoration
 that has to land on several ids, such as NonUniform on every step from a
 descriptor array to the image instruction.
*>
fn uint decoration_count(char[] spirv, shady::Decoration decoration)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	uint  found = 0;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.DECORATE && words[i + 2] == (uint)decoration) found++;
		i += len;
	}
	return found;
}

<*
 The SPIR-V version in the module header.
*>
fn uint version(char[] spirv) => ((uint*)spirv.ptr)[1];

<*
 Whether an `OpExtension` names this extension.
*>
fn bool has_extension(char[] spirv, String name)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)shady::Opcode.EXTENSION) continue;
		if (((usz)(words[i] >> 16) - 1) * 4 < name.len + 1) continue;
		String text = (String)((char*)&words[i + 1])[:name.len + 1];
		if (text[:name.len] == name && text[name.len] == 0) return true;
	}
	return false;
}

<*
 Whether some `OpEntryPoint` is of this execution model.
*>
fn bool has_execution_model(char[] spirv, shady::ExecutionModel model)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) == (uint)shady::Opcode.ENTRY_POINT && words[i + 1] == (uint)model) return true;
	}
	return false;
}

<*
 How many of the variables in the interface of the entry point published as
 `entry` are in `storage`. A missing entry point counts as none.
*>
fn uint interface_count(char[] spirv, String entry, shady::StorageClass storage)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint  found = 0;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)shady::Opcode.ENTRY_POINT) continue;
		usz   length = (usz)(words[i] >> 16);
		char* name   = (char*)&words[i + 3];
		// The name is a NUL-terminated string padded to whole words; the
		// interface starts at the word after its terminator.
		usz chars = 0;
		while (name[chars] != 0) chars++;
		if (name[:chars] != entry) continue;

		for (usz at = 3 + chars / 4 + 1; at < length; at++)
		{
			if (variable_storage(spirv, words[i + at]) == (uint)storage) found++;
		}
	}
	return found;
}

<*
 The storage class of the `OpVariable` defining `id`, or 0xffffffff.
*>
fn uint variable_storage(char[] spirv, uint id)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) == (uint)shady::Opcode.VARIABLE && words[i + 2] == id) return words[i + 3];
	}
	return 0xffff_ffff;
}

<*
 How many variables the interface of `entry` lists, whatever their storage.
*>
fn uint interface_size(char[] spirv, String entry)
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	for (usz i = 5; i < count; i += (usz)(words[i] >> 16))
	{
		if ((words[i] & 0xffff) != (uint)shady::Opcode.ENTRY_POINT) continue;
		usz   length = (usz)(words[i] >> 16);
		char* name   = (char*)&words[i + 3];
		usz chars = 0;
		while (name[chars] != 0) chars++;
		if (name[:chars] != entry) continue;
		return (uint)(length - (3 + chars / 4 + 1));
	}
	return 0;
}
