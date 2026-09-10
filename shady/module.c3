<*
 SPIR-V module builder.

 A module is assembled as a set of word lists, one per section of the SPIR-V
 logical layout, then concatenated behind a five-word header. Callers never
 touch words directly; they ask for ids and emit instructions.

 Deliberately does no optimisation and no validation - it emits what it is
 told. Structural correctness that the emitter *can* guarantee cheaply (type
 uniqueness, section ordering, the id bound) it does guarantee.
*>
module shady;

import std::collections::list;
import std::core::mem;
import std::core::mem::alloc;

alias Id = uint;
const Id NO_ID = 0;

alias WordList = List{uint};
alias IdList = List{Id};

<*
 A previously emitted type or constant, so an identical one is not declared
 twice. SPIR-V requires non-aggregate types to be unique - two OpTypeFloat 32
 in one module is invalid - and a linear scan is plenty: shaders have tens of
 types, not thousands, and it avoids inventing a hash over operand words.
*>
struct CachedDecl @local
{
	uint  opcode;
	Id[]  operands;
	Id    result;
}

struct Module
{
	Allocator allocator;
	uint      version;
	Id        next_id;

	// Sections, in the order the SPIR-V logical layout requires them.
	WordList capabilities;
	WordList extensions;
	WordList ext_imports;
	WordList memory_model;
	WordList entry_points;
	WordList execution_modes;
	WordList debug_names;
	WordList annotations;
	WordList declarations; // types, constants, and non-function variables
	WordList functions;

	List{CachedDecl} cache;
}

fn Module* Module.init(&self, Allocator allocator = mem, uint version = VERSION_1_0)
{
	*self = { .allocator = allocator, .version = version, .next_id = 1 };

	self.capabilities.init(allocator);
	self.extensions.init(allocator);
	self.ext_imports.init(allocator);
	self.memory_model.init(allocator);
	self.entry_points.init(allocator);
	self.execution_modes.init(allocator);
	self.debug_names.init(allocator);
	self.annotations.init(allocator);
	self.declarations.init(allocator);
	self.functions.init(allocator);
	self.cache.init(allocator);

	return self;
}

fn void Module.free(&self)
{
	// Cached operands came from the module's own allocator, which is not
	// necessarily the heap - freeing them with mem::free corrupts an arena.
	foreach (entry : self.cache) if (entry.operands.ptr) alloc::free(self.allocator, entry.operands.ptr);
	self.capabilities.free();
	self.extensions.free();
	self.ext_imports.free();
	self.memory_model.free();
	self.entry_points.free();
	self.execution_modes.free();
	self.debug_names.free();
	self.annotations.free();
	self.declarations.free();
	self.functions.free();
	self.cache.free();
	*self = {};
}

<*
 Reserve the next unused result id. Ids are dense from 1; the header's bound is
 simply the next unreserved one.
*>
fn Id Module.id(&self) => self.next_id++;

// --- Raw emission ------------------------------------------------------------

<*
 Append one instruction. The word count in the high half of the first word
 covers the opcode word itself, hence the +1.
*>
fn void emit(WordList* section, uint opcode, Id... operands)
{
	section.push(((uint)(1 + operands.len) << 16) | opcode);
	foreach (word : operands) section.push(word);
}

<*
 Same, but for instructions whose operand count is not known at the call site.
*>
fn void emit_slice(WordList* section, uint opcode, Id[] operands)
{
	section.push(((uint)(1 + operands.len) << 16) | opcode);
	foreach (word : operands) section.push(word);
}

<*
 A SPIR-V literal string: NUL-terminated UTF-8 packed little-endian into whole
 words, zero padded. Returns how many words were appended.
*>
fn uint push_string(WordList* words, String text)
{
	uint word  = 0;
	uint count = 0;
	usz  i     = 0;

	for (; i < text.len; i++)
	{
		word |= (uint)text[i] << (uint)((i % 4) * 8);
		if (i % 4 == 3)
		{
			words.push(word);
			count++;
			word = 0;
		}
	}

	// Always emits a final word, which carries the NUL terminator and padding.
	words.push(word);
	return count + 1;
}

fn Id[] string_words(String text, Allocator allocator) @local
{
	WordList words;
	words.init(allocator, 8);
	push_string(&words, text);
	return words.array_view();
}

// --- Deduplicated declarations -----------------------------------------------

<*
 Emit into the declarations section.

 Two instruction shapes live here and they are NOT interchangeable:
   OpTypeFloat etc.  ->  <result> = Op <operands>
   OpConstant, OpVariable -> <result type> <result> <operands>
 Passing NO_ID as `result_type` selects the first shape.

 `dedupe` must be false for aggregates. Two structs with the same members are
 legitimately different types in SPIR-V, and sharing them would share their
 Offset/Block decorations too.
*>
fn Id Module.decl(&self, uint opcode, Id result_type, Id[] operands, bool dedupe)
{
	bool typed = result_type != NO_ID;

	if (dedupe)
	{
		foreach (entry : self.cache)
		{
			if (entry.opcode != opcode) continue;
			if (entry.operands.len != operands.len + (typed ? 1 : 0)) continue;

			bool same = true;
			usz  at   = 0;
			if (typed)
			{
				if (entry.operands[0] != result_type) continue;
				at = 1;
			}
			foreach (i, word : operands)
			{
				if (entry.operands[at + (usz)i] != word) { same = false; break; }
			}
			if (same) return entry.result;
		}
	}

	Id result = self.id();

	if (dedupe)
	{
		// `operands` is a temporary slice; the cache outlives it.
		Id[] kept = alloc::alloc_array(self.allocator, Id, operands.len + (typed ? 1 : 0));
		if (typed) kept[0] = result_type;
		if (operands.len) kept[(typed ? 1 : 0)..] = operands[..];
		self.cache.push({ .opcode = opcode, .operands = kept, .result = result });
	}

	self.declarations.push(((uint)((typed ? 3 : 2) + operands.len) << 16) | opcode);
	if (typed) self.declarations.push(result_type);
	self.declarations.push(result);
	foreach (word : operands) self.declarations.push(word);

	return result;
}

<*
 Record `result` as the answer the dedup cache should give for this
 instruction, without emitting anything.

 Only forward-declared pointers need this: their id exists before their
 definition does, and a later `unique` for the same operands must find it
 rather than minting a second pointer type.
*>
fn void Module.cache_result(&self, uint opcode, Id result, Id... operands)
{
	Id[] kept = alloc::alloc_array(self.allocator, Id, operands.len);
	if (operands.len) kept[..] = operands[..];
	self.cache.push({ .opcode = opcode, .operands = kept, .result = result });
}

<*
 A shared declaration with no result type, i.e. a type: `%r = OpTypeX ...`.
*>
fn Id Module.unique(&self, uint opcode, Id... operands) => self.decl(opcode, NO_ID, operands, true);

<*
 As `unique`, for operand lists built at runtime.
*>
fn Id Module.unique_slice(&self, uint opcode, Id[] operands) => self.decl(opcode, NO_ID, operands, true);

<*
 A shared declaration that carries a result type, i.e. a constant.
*>
fn Id Module.unique_typed(&self, uint opcode, Id result_type, Id... operands)
{
	return self.decl(opcode, result_type, operands, true);
}

fn Id Module.unique_typed_slice(&self, uint opcode, Id result_type, Id[] operands)
{
	return self.decl(opcode, result_type, operands, true);
}

<*
 An unshared declaration with no result type - structs and arrays.
*>
fn Id Module.declare(&self, uint opcode, Id... operands) => self.decl(opcode, NO_ID, operands, false);

fn Id Module.declare_slice(&self, uint opcode, Id[] operands) => self.decl(opcode, NO_ID, operands, false);

<*
 An unshared declaration carrying a result type - global variables, which must
 each be their own object even when two have the same pointer type.
*>
fn Id Module.declare_typed(&self, uint opcode, Id result_type, Id... operands)
{
	return self.decl(opcode, result_type, operands, false);
}

// --- Module-level directives -------------------------------------------------

fn void Module.capability(&self, uint capability)
{
	emit(&self.capabilities, OP_CAPABILITY, capability);
}

fn void Module.extension(&self, String name)
{
	@pool() {
		emit_slice(&self.extensions, OP_EXTENSION, string_words(name, tmem));
	};
}

fn Id Module.ext_inst_import(&self, String name)
{
	Id result = self.id();
	@pool() {
		Id[] text = string_words(name, tmem);
		self.ext_imports.push(((uint)(2 + text.len) << 16) | OP_EXT_INST_IMPORT);
		self.ext_imports.push(result);
		foreach (word : text) self.ext_imports.push(word);
	};
	return result;
}

fn void Module.set_memory_model(&self, uint addressing_model = ADDRESSING_MODEL_LOGICAL, uint memory_model = MEMORY_MODEL_GLSL450)
{
	self.memory_model.clear();
	emit(&self.memory_model, OP_MEMORY_MODEL, addressing_model, memory_model);
}

<*
 Declare an entry point.

 `interface` must list every Input and Output variable the entry point can
 reach, statically. Getting this wrong is the most common way to produce a
 module that validates but misbehaves, so it is explicit rather than inferred.
*>
fn void Module.entry_point(&self, uint execution_model, Id function, String name, Id[] interface_ids = {})
{
	@pool() {
		Id[] text = string_words(name, tmem);
		self.entry_points.push(((uint)(3 + text.len + interface_ids.len) << 16) | OP_ENTRY_POINT);
		self.entry_points.push(execution_model);
		self.entry_points.push(function);
		foreach (word : text) self.entry_points.push(word);
		foreach (id : interface_ids) self.entry_points.push(id);
	};
}

fn void Module.execution_mode(&self, Id function, uint mode, Id... operands)
{
	self.execution_modes.push(((uint)(3 + operands.len) << 16) | OP_EXECUTION_MODE);
	self.execution_modes.push(function);
	self.execution_modes.push(mode);
	foreach (word : operands) self.execution_modes.push(word);
}

// --- Debug names -------------------------------------------------------------

fn void Module.name(&self, Id target, String text)
{
	@pool() {
		Id[] words = string_words(text, tmem);
		self.debug_names.push(((uint)(2 + words.len) << 16) | OP_NAME);
		self.debug_names.push(target);
		foreach (word : words) self.debug_names.push(word);
	};
}

fn void Module.member_name(&self, Id target, uint member, String text)
{
	@pool() {
		Id[] words = string_words(text, tmem);
		self.debug_names.push(((uint)(3 + words.len) << 16) | OP_MEMBER_NAME);
		self.debug_names.push(target);
		self.debug_names.push(member);
		foreach (word : words) self.debug_names.push(word);
	};
}

// --- Decorations -------------------------------------------------------------

fn void Module.decorate(&self, Id target, uint decoration, Id... operands)
{
	self.annotations.push(((uint)(3 + operands.len) << 16) | OP_DECORATE);
	self.annotations.push(target);
	self.annotations.push(decoration);
	foreach (word : operands) self.annotations.push(word);
}

fn void Module.member_decorate(&self, Id target, uint member, uint decoration, Id... operands)
{
	self.annotations.push(((uint)(4 + operands.len) << 16) | OP_MEMBER_DECORATE);
	self.annotations.push(target);
	self.annotations.push(member);
	self.annotations.push(decoration);
	foreach (word : operands) self.annotations.push(word);
}

// --- Assembly ----------------------------------------------------------------

<*
 Concatenate the sections into a finished module.

 The result is owned by `allocator`. Word order here IS the SPIR-V logical
 layout - reordering these lines produces a module that fails validation.
*>
fn char[] Module.build(&self, Allocator allocator = mem)
{
	WordList out;
	out.init(allocator, 1024);

	out.push(MAGIC);
	out.push(self.version);
	out.push(GENERATOR);
	out.push(self.next_id); // bound: ids are 1 ..< next_id
	out.push(0);            // reserved: instruction schema

	out.push_all(self.capabilities.array_view());
	out.push_all(self.extensions.array_view());
	out.push_all(self.ext_imports.array_view());
	out.push_all(self.memory_model.array_view());
	out.push_all(self.entry_points.array_view());
	out.push_all(self.execution_modes.array_view());
	out.push_all(self.debug_names.array_view());
	out.push_all(self.annotations.array_view());
	out.push_all(self.declarations.array_view());
	out.push_all(self.functions.array_view());

	uint[] words = out.array_view();
	// SPIR-V words are 32-bit by definition.
	return ((char*)words.ptr)[:words.len * 4];
}
