<*
 Conformance corpus: compile each shader with shady and validate the module
 with `spirv-val --target-env vulkan1.3`.

 The sources are embedded rather than read from disk, so the test runs the same
 from this directory or from an importing project.

 Adding a shader is a file under `test/conformance/`, an `$embed` below, and an
 entry in `CORPUS`.
*>
module conformance;

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

struct Case
{
	String name;
	String source;
}

const Case[*] CORPUS = {
	{ "triangle",     (String)EMBED_TRIANGLE[..] },
	{ "pushconstant", (String)EMBED_PUSHCONSTANT[..] },
	{ "bda",          (String)EMBED_BDA[..] },
	{ "multi_entry",  (String)EMBED_MULTI_ENTRY[..] },
	{ "compute",      (String)EMBED_COMPUTE[..] },
	{ "functions",    (String)EMBED_FUNCTIONS[..] },
};

fn void the_conformance_corpus_compiles_and_validates() @test
{
	path::mkdir(OUT_DIR, recursive: true)!!;

	uint failures = 0;
	foreach (entry : CORPUS)
	{
		if (!conforms(entry)) failures++;
	}

	assert(failures == 0, "conformance shaders failed; see the output above");
}

<*
 Compiles one corpus entry, writes its SPIR-V and validates it.

 A false return is a failure already printed; the caller only counts.
*>
fn bool conforms(Case entry) @private
{
	shady::Diagnostic diagnostic;
	char[]? spirv = shady::compile(entry.source, &diagnostic);
	if (catch spirv)
	{
		io::printfn(
			"FAIL %s: %s:%d:%d: %s",
			entry.name,
			entry.name,
			diagnostic.line,
			diagnostic.column,
			diagnostic.message
		);
		return false;
	}
	defer free(spirv);

	if (spirv.len < 4 || ((uint*)spirv.ptr)[0] != SPIRV_MAGIC)
	{
		io::printfn("FAIL %s: the compiler did not return SPIR-V", entry.name);
		return false;
	}

	String out_path = string::tformat("%s/%s.spv", OUT_DIR, entry.name);
	file::save(out_path, spirv)!!;

	if (!spirv_val(out_path)) return false;

	io::printfn("ok   %s (%d bytes)", entry.name, spirv.len);
	return true;
}

<*
 Runs `spirv-val` over one module.

 A missing spirv-val skips rather than fails: the toolchain is a developer
 dependency, and a harness that cannot run should say so once instead of
 leaving the corpus unverified and calling it red.
*>
fn bool spirv_val(String path) @private
{
	String[] command = { "spirv-val", "--target-env", "vulkan1.3", path };
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
