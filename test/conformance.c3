<*
 Conformance corpus: compile each shader with shady and validate the module
 with `spirv-val --target-env vulkan1.3`.

 The sources are embedded rather than read from disk, so the test runs the same
 from this directory or from an importing project.

 Adding a shader is a file under `test/conformance/`, an `$embed` below, and an
 entry in `CORPUS`.
*>
module conformance;

import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::os::process;
import shady;

const String OUT_DIR = "build/shady/conformance";
const uint SPIRV_MAGIC = 0x07230203;

const char[*] EMBED_TRIANGLE     = $embed("conformance/triangle.shady");
const char[*] EMBED_PUSHCONSTANT = $embed("conformance/pushconstant.shady");
const char[*] EMBED_BDA          = $embed("conformance/bda.shady");
const char[*] EMBED_MULTI_ENTRY  = $embed("conformance/multi_entry.shady");
const char[*] EMBED_COMPUTE      = $embed("conformance/compute.shady");
const char[*] EMBED_FUNCTIONS    = $embed("conformance/functions.shady");
const char[*] EMBED_OPERATORS    = $embed("conformance/operators.shady");
const char[*] EMBED_ARRAYS       = $embed("conformance/arrays.shady");
const char[*] EMBED_BUILTINS     = $embed("conformance/builtins.shady");
const char[*] EMBED_SCALAR       = $embed("conformance/scalar_layout.shady");
const char[*] EMBED_POINTERS     = $embed("conformance/pointers.shady");
const char[*] EMBED_BINDLESS     = $embed("conformance/bindless.shady");
const char[*] EMBED_SPEC         = $embed("conformance/spec.shady");
const char[*] EMBED_INT_BUILTINS = $embed("conformance/integer_builtins.shady");

struct Case
{
	String name;
	String source;
	// Compiled with C3's packing rather than std140/std430.
	bool   scalar;
}

const Case[*] CORPUS = {
	{ "triangle",     (String)EMBED_TRIANGLE[..],     false },
	{ "pushconstant", (String)EMBED_PUSHCONSTANT[..], false },
	{ "bda",          (String)EMBED_BDA[..],          false },
	{ "multi_entry",  (String)EMBED_MULTI_ENTRY[..],  false },
	{ "compute",      (String)EMBED_COMPUTE[..],      false },
	{ "functions",    (String)EMBED_FUNCTIONS[..],    false },
	{ "operators",    (String)EMBED_OPERATORS[..],    false },
	{ "arrays",       (String)EMBED_ARRAYS[..],       false },
	{ "builtins",     (String)EMBED_BUILTINS[..],     false },
	{ "scalar",       (String)EMBED_SCALAR[..],       true  },
	{ "pointers",     (String)EMBED_POINTERS[..],     true  },
	{ "bindless",     (String)EMBED_BINDLESS[..],     false },
	{ "spec",         (String)EMBED_SPEC[..],         false },
	{ "int_builtins", (String)EMBED_INT_BUILTINS[..], false },
};

fn void the_conformance_corpus_compiles_and_validates() @test
{
	path::mkdir(OUT_DIR, recursive: true)!!;

	uint failures = 0;
	foreach (entry : CORPUS)
	{
		if (!conforms(entry)) failures++;
	}

	test::@check(failures == 0, "%d of %d corpus shaders failed; see the output above",
		failures, CORPUS.len);
}

<*
 Compiles one corpus entry, writes its SPIR-V and validates it.

 A false return is a failure already printed; the caller only counts.
*>
fn bool conforms(Case entry) @private
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(entry.source, &diagnostic, scalar_layout: entry.scalar);
	if (catch spirv)
	{
		io::printfn("FAIL %s: %s", entry.name, diagnostic.to_string(tmem));
		diagnostic.free();
		return false;
	}
	diagnostic.free();
	defer free(spirv);

	if (spirv.len < 4 || ((uint*)spirv.ptr)[0] != SPIRV_MAGIC)
	{
		io::printfn("FAIL %s: the compiler did not return SPIR-V", entry.name);
		return false;
	}

	String out_path = string::tformat("%s/%s.spv", OUT_DIR, entry.name);
	file::save(out_path, spirv)!!;

	if (!spirv_val(out_path, entry.scalar)) return false;

	io::printfn("ok   %s (%d bytes)", entry.name, spirv.len);
	return true;
}

<*
 Runs `spirv-val` over one module.

 A scalar-layout module needs `--scalar-block-layout` for the same reason the
 engine needs `VK_EXT_scalar_block_layout`: a `float4` at offset 108 is legal
 only under that feature, and the validator enforces it.

 A missing spirv-val skips rather than fails: the toolchain is a developer
 dependency, and a harness that cannot run should say so once instead of
 leaving the corpus unverified and calling it red.
*>
fn bool spirv_val(String path, bool scalar) @private
{
	String[] command = scalar
		? (String[]) { "spirv-val", "--target-env", "vulkan1.3", "--scalar-block-layout", path }
		: (String[]) { "spirv-val", "--target-env", "vulkan1.3", path };
	process::Process? spawned = process::spawn(command);
	if (catch spawned)
	{
		io::printn("conformance: spirv-val is not on PATH; validation skipped");
		return true;
	}

	process::Process child = spawned;
	defer (void)child.destroy();

	int status = child.join()!!;
	if (status == 0) return true;

	char[4096] note;
	sz got = child.read_stderr(&note[0], note.len)!!;
	if (got > 0) io::printn((String)note[:got]);
	io::printfn("conformance: spirv-val exited %d for %s", status, path);
	return false;
}
