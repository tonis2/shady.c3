<*
 What each function reaches, and what that asks of the entry points that call
 it.

 A helper is emitted once - inside the first entry point that calls it - and
 runs in every entry point that reaches it. So two questions cannot be answered
 while its body is being written, only once every entry point is known:

  - **Which globals does an entry point use?** From SPIR-V 1.4 on, `OpEntryPoint`
    lists every global variable its call tree touches, not just its inputs and
    outputs, and a helper's globals belong to every entry point that calls it.
    A ray-tracing module is a 1.4 module, so this is where its interfaces come
    from.
  - **Which stages may run it?** `sample()` with an implicit level needs a
    fragment shader and `trace_ray` one of three ray-tracing stages. Inside an
    entry point's own body that is asked on the spot; inside a helper it is
    written down, and asked of each entry point that reaches the helper.

 Each function body records both in a `Reach` while it is emitted: the globals
 it names, the helpers it calls, and the stage requirements of what it does. The
 entry points are published at the end of `build`, once the module's version is
 final, with the closure of their reach.
*>
module shady;

import std::collections::list;

<*
 A stage restriction found inside a helper, kept with the message the entry
 point's own body would have given, and where the offending code is.
*>
struct StageRequirement
{
	uint   mask;
	uint   line;
	uint   column;
	String message;
}

alias StageRequirementList = List{StageRequirement};
alias FunctionSigPtrList   = List{FunctionSig*};

struct Reach
{
	bool                 is_entry;
	IdListC              globals;
	FunctionSigPtrList   callees;
	StageRequirementList requirements;

	// The hit-attribute type this function reports, and where: an entry point
	// may have one, so two reaching the same entry point is refused at the
	// second report.
	Type* hit_attribute;
	uint  hit_line;
	uint  hit_column;
}

<*
 An entry point, emitted and waiting for its `OpEntryPoint`: that instruction
 is written last, because its interface depends on the module's final version.
*>
struct EntryRecord
{
	Stage  stage;
	Id     function;
	String name;      // the published name
	String fn_name;   // the function's own, for messages
	Id[]   io;        // the stage's Input and Output variables
	Reach* reach;
}

alias EntryRecordList = List{EntryRecord};

<*
 A new, empty reach on the compile's arena.
*>
fn Reach* Codegen.new_reach(&self, bool is_entry)
{
	Reach* reach = alloc::new(self.allocator, Reach);
	*reach = { .is_entry = is_entry };
	reach.globals.init(self.allocator, 4);
	reach.callees.init(self.allocator, 4);
	reach.requirements.init(self.allocator, 2);
	return reach;
}

<*
 The function being emitted uses a global variable.
*>
fn void Codegen.use_global(&self, Id id)
{
	if (!self.reach) return;
	foreach (existing : self.reach.globals) if (existing == id) return;
	self.reach.globals.push(id);
}

<*
 The function being emitted calls `sig`. Recorded on every call, including one
 to a helper an earlier entry point already emitted: that helper's globals are
 this caller's too.
*>
fn void Codegen.note_callee(&self, FunctionSig* sig)
{
	if (!self.reach) return;
	foreach (existing : self.reach.callees) if (existing == sig) return;
	self.reach.callees.push(sig);
}

<*
 What the code at `line:column` does only runs in the stages of `mask`.

 In an entry point's own body that is a question with an answer, asked now. In
 a helper it is recorded, and `check_entry_stages` asks it of every entry point
 the helper is reached from - with `message`, which says what the code needs,
 and the entry point that broke it.
*>
fn void? Codegen.require_stages(&self, uint mask, uint line, uint column, String message)
{
	if (!self.reach || self.reach.is_entry)
	{
		if (mask & self.stage.bit()) return;
		self.fail(line, column, message);
		return CODEGEN_ERROR~;
	}
	foreach (&requirement : self.reach.requirements) if (requirement.mask == mask) return;
	self.reach.requirements.push({ .mask = mask, .line = line, .column = column, .message = message });
}

<*
 Every function an entry point reaches, itself excluded, each once.
*>
fn void collect_callees(Reach* reach, FunctionSigPtrList* out) @private
{
	foreach (callee : reach.callees)
	{
		bool seen = false;
		foreach (existing : *out) if (existing == callee) seen = true;
		if (seen || !callee.reach) continue;
		out.push(callee);
		collect_callees(callee.reach, out);
	}
}

<*
 Ask each entry point the stage requirements of everything it reaches.
*>
fn void? Codegen.check_entry_stages(&self)
{
	foreach (&entry : self.entries)
	{
		FunctionSigPtrList reached;
		reached.init(self.allocator, 4);
		collect_callees(entry.reach, &reached);

		foreach (sig : reached)
		{
			foreach (&requirement : sig.reach.requirements)
			{
				if (requirement.mask & entry.stage.bit()) continue;
				self.fail(requirement.line, requirement.column, string::format(self.allocator,
					"%s; `%s` is reached from `%s`, %s shader",
					requirement.message, sig.decl.name, entry.fn_name,
					stage_list(entry.stage.bit(), self.allocator)));
				return CODEGEN_ERROR~;
			}
		}

		// An entry point has one hit-attribute variable
		// (VUID-StandaloneSpirv-HitAttributeKHR-04702), so everything it
		// reaches reports one type.
		Reach* first = entry.reach.hit_attribute ? entry.reach : null;
		foreach (sig : reached)
		{
			Reach* reach = sig.reach;
			if (!reach.hit_attribute) continue;
			if (!first)
			{
				first = reach;
				continue;
			}
			if (reach.hit_attribute == first.hit_attribute) continue;
			self.fail(reach.hit_line, reach.hit_column, string::format(self.allocator,
				"this reports `%s` as the hit attributes, and %s reports `%s` - `%s` is one intersection shader, with one hit-attribute type",
				reach.hit_attribute.name, self.where(first.hit_line), first.hit_attribute.name, entry.fn_name));
			return CODEGEN_ERROR~;
		}
	}
}

<*
 Write each entry point's `OpEntryPoint`. Its interface is the stage's inputs
 and outputs - and, in a module of SPIR-V 1.4 or later, every global variable
 its call tree uses, each once.
*>
fn void Codegen.publish_entry_points(&self)
{
	bool full = self.mod.version >= VERSION_1_4;
	foreach (&entry : self.entries)
	{
		IdListC interface_ids;
		interface_ids.init(self.allocator, entry.io.len + 8);
		foreach (id : entry.io) interface_ids.push(id);

		if (full)
		{
			FunctionSigPtrList reached;
			reached.init(self.allocator, 4);
			collect_callees(entry.reach, &reached);

			add_globals(&interface_ids, entry.reach);
			foreach (sig : reached) add_globals(&interface_ids, sig.reach);
		}

		self.mod.entry_point(entry.stage.execution_model(), entry.function, entry.name, interface_ids.array_view());
	}
}

fn void add_globals(IdListC* interface_ids, Reach* reach) @private
{
	foreach (id : reach.globals)
	{
		bool listed = false;
		foreach (existing : *interface_ids) if (existing == id) listed = true;
		if (!listed) interface_ids.push(id);
	}
}

<*
 What the module header needs once the whole shader has been walked: the
 features found anywhere in it decide the version, the capabilities and the
 addressing model, and none of them can be written before the walk is done.
*>
fn void Codegen.finish_module(&self)
{
	// Buffer device addresses change the module header, not just its body: the
	// addressing model stops being Logical, so it can only be written once the
	// shader has been walked. The memory model is kept: a cooperative matrix
	// may already have made it Vulkan's.
	if (self.uses_device_addresses)
	{
		self.mod.require_version(VERSION_1_3);
		self.mod.capability(Capability.PHYSICAL_STORAGE_BUFFER_ADDRESSES);
		// Addresses are computed as 64-bit integers, which is a capability of
		// its own even though PhysicalStorageBufferAddresses implies the type.
		self.mod.capability(Capability.INT64);
		self.mod.extension(EXTENSION_PHYSICAL_STORAGE_BUFFER);
		self.mod.set_addressing_model(AddressingModel.PHYSICAL_STORAGE_BUFFER64);
	}

	// An acceleration structure is only a legal type next to one of the two
	// ray capabilities. One nothing traces against gets the query capability:
	// it is what a raster or compute module would use it for.
	if (self.uses_accel
		&& !self.mod.has_capability(Capability.RAY_QUERY_KHR)
		&& !self.mod.has_capability(Capability.RAY_TRACING_KHR))
	{
		self.ray_query_capability();
	}

	// Skipping triangles or AABBs outright is a traversal feature of its own,
	// which the host enables as `rayTraversalPrimitiveCulling`. Named only
	// where a ray is traced: a flag held in a uint and never traced with
	// asks nothing of the device.
	if (self.uses_primitive_culling
		&& (self.mod.has_capability(Capability.RAY_QUERY_KHR) || self.mod.has_capability(Capability.RAY_TRACING_KHR)))
	{
		self.mod.capability(Capability.RAY_TRAVERSAL_PRIMITIVE_CULLING_KHR);
	}
}
