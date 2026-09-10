<*
 The public entry point: shady source in, SPIR-V out.

 Everything happens in memory and in one process. A bad shader is a fault with
 a line, a column and a message - never an exit, and never a temporary file.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

<*
 Where a compile failed. Empty `message` means it succeeded.
*>
struct Diagnostic
{
	String message;
	uint   line;
	uint   column;
}

fn String Diagnostic.to_string(&self, Allocator allocator)
{
	if (!self.message.len) return "";
	return string::format(allocator, "%d:%d: %s", self.line, self.column, self.message);
}

const uint UNASSIGNED_BINDING = 0xffffffff;

// --- Resource binding --------------------------------------------------------

<*
 Assign descriptor set and binding numbers.

 Explicit `@set`/`@binding` win; everything else is numbered in declaration
 order, skipping anything an explicit attribute already claimed. A collision is
 an error rather than a silent overwrite (LANGUAGE.md 3.2).
*>
fn void? Codegen.assign_bindings(&self, Ast* ast)
{
	bool has_push_constant = false;

	// First pass: honour explicit attributes.
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.RESOURCE) continue;

		// uint.max marks 'not yet assigned', so an explicit binding of 0 still counts.
		Resource resource = { .name = decl.name, .binding = UNASSIGNED_BINDING };

		if (Attribute* set = find_attribute(decl.attributes, "set"))
		{
			if (set.args.len != 1)
			{
				self.fail(set.line, set.column, "@set takes one number");
				return CODEGEN_ERROR~;
			}
			resource.set = (uint)set.args[0].number;
		}
		if (Attribute* binding = find_attribute(decl.attributes, "binding"))
		{
			if (binding.args.len != 1)
			{
				self.fail(binding.line, binding.column, "@binding takes one number");
				return CODEGEN_ERROR~;
			}
			resource.binding = (uint)binding.args[0].number;
		}

		// The type is already resolved: declare_structs ran first.
		Type* type = self.types.find(decl.resource.type.name);
		if (!type)
		{
			self.fail(decl.line, decl.column,
				string::format(self.allocator, "unknown type `%s`", decl.resource.type.name));
			return CODEGEN_ERROR~;
		}
		resource.type  = type;
		resource.block = type.kind == STRUCT ? type.block : BlockKind.NONE;

		if (resource.block == PUSH_CONSTANT)
		{
			// A push constant block is not a descriptor. Vulkan allows exactly
			// one per pipeline, so a second is an error rather than a binding
			// clash nobody would recognise.
			if (has_push_constant)
			{
				self.fail(decl.line, decl.column, "a shader may have only one push_constant block");
				return CODEGEN_ERROR~;
			}
			has_push_constant = true;
			if (find_attribute(decl.attributes, "set") || find_attribute(decl.attributes, "binding"))
			{
				self.fail(decl.line, decl.column, "a push_constant block has no set or binding");
				return CODEGEN_ERROR~;
			}
		}

		self.resources.push(resource);
	}

	// Second pass: fill in the gaps, per set.
	usz at = 0;
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.RESOURCE) continue;
		Resource* resource = &self.resources[(sz)at++];
		if (resource.block == PUSH_CONSTANT || resource.binding != UNASSIGNED_BINDING) continue;

		uint candidate = 0;
		while (self.binding_taken(resource.set, candidate)) candidate++;
		resource.binding = candidate;
	}

	// Third pass: reject duplicates, which explicit attributes can still create.
	foreach (i, &a : self.resources)
	{
		if (a.block == PUSH_CONSTANT) continue;
		foreach (j, &b : self.resources)
		{
			if (j <= i || b.block == PUSH_CONSTANT) continue;
			if (a.set == b.set && a.binding == b.binding)
			{
				self.fail(0, 0, string::format(self.allocator,
					"`%s` and `%s` both want set %d binding %d", a.name, b.name, a.set, a.binding));
				return CODEGEN_ERROR~;
			}
		}
	}
}

fn bool Codegen.binding_taken(&self, uint set, uint binding)
{
	foreach (&resource : self.resources)
	{
		if (resource.block == PUSH_CONSTANT) continue;
		if (resource.set == set && resource.binding == binding) return true;
	}
	return false;
}

// --- Declarations ------------------------------------------------------------

<*
 Read a struct's `@uniform`, `@pushconstant` or `@address` attribute.

 At most one: they choose the layout and the storage class, and a struct
 cannot be two kinds of block at once.
*>
fn BlockKind? Codegen.block_kind(&self, Decl* decl)
{
	BlockKind found = NONE;
	foreach (&attribute : decl.attributes)
	{
		BlockKind kind;
		if (!block_kind_from_name(attribute.name, &kind)) continue;
		if (found != NONE)
		{
			self.fail(attribute.line, attribute.column, string::format(self.allocator,
				"`%s` is already %s, it cannot also be %s", decl.name, found.attribute(), kind.attribute()));
			return CODEGEN_ERROR~;
		}
		found = kind;
	}
	return found;
}

<*
 Turn the AST's structs into types, so functions can refer to them regardless
 of declaration order.
*>
fn void? Codegen.declare_structs(&self, Ast* ast)
{
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.STRUCT) continue;
		if (self.types.find(decl.name))
		{
			self.fail(decl.line, decl.column,
				string::format(self.allocator, "`%s` is already a type", decl.name));
			return CODEGEN_ERROR~;
		}
		Type* type  = self.types.add(STRUCT, decl.name);
		type.block  = self.block_kind(decl)!;
		if (type.block == ADDRESS) self.uses_device_addresses = true;
	}

	// Every @address struct's pointer type is declared - not defined - before
	// any struct body is emitted. That is what lets one hold a pointer to
	// itself, or to a struct declared further down.
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.STRUCT) continue;
		if (self.types.find(decl.name).block != ADDRESS) continue;
		Type* type = self.types.find(decl.name);
		type.pointer_id = self.mod.type_forward_pointer(STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER);
		self.types.pointer_to(type);
	}

	// Members in a second pass, so structs may refer to each other.
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.STRUCT) continue;
		Type* type = self.types.find(decl.name);

		StructMember[] members = alloc::alloc_array(self.allocator, StructMember, decl.struct_decl.members.len);
		foreach (i, &source : decl.struct_decl.members)
		{
			Type* member_type = self.types.find(source.type.name);
			if (!member_type)
			{
				self.fail(source.line, source.column,
					string::format(self.allocator, "unknown type `%s`", source.type.name));
				return CODEGEN_ERROR~;
			}
			if (source.type.is_pointer)
			{
				if (member_type.block != ADDRESS)
				{
					self.fail(source.line, source.column, string::format(self.allocator,
						"`%s*` is not a device address - mark `%s` with @address to give it one",
						member_type.name, member_type.name));
					return CODEGEN_ERROR~;
				}
				member_type = self.types.pointer_to(member_type);
			}
			members[i] = {
				.name        = source.name,
				.type        = member_type,
				.attributes  = source.attributes,
				.is_position = find_attribute(source.attributes, "position") != null,
			};
			if (Attribute* builtin = find_attribute(source.attributes, "builtin"))
			{
				uint which;
				if (builtin.args.len != 1 || !builtin.args[0].is_name || !builtin_from_name(builtin.args[0].name, &which))
				{
					self.fail(builtin.line, builtin.column, "@builtin needs a known builtin name");
					return CODEGEN_ERROR~;
				}
				members[i].is_builtin = true;
				members[i].builtin    = which;
			}
		}
		type.members = members;
	}

	// Now that every @address struct's members are known, emit its type, lay it
	// out std430, decorate it Block, and close the forward pointer.
	//
	// ArrayStride records the element size on the pointer type. Indexing does
	// not depend on it - Codegen.offset_address computes the stride itself, and
	// says why - but it is accurate, it is what tools read the pointer's shape
	// from, and it costs four words.
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.STRUCT) continue;
		Type* type = self.types.find(decl.name);
		if (type.block != ADDRESS) continue;

		uint size    = type.assign_offsets(STD430);
		Id   type_id = self.type_id(type);
		self.mod.decorate(type_id, DECORATION_BLOCK);
		self.decorate_block_members(type_id, type, STD430);

		self.mod.define_forward_pointer(type.pointer_id, STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER, type_id);
		self.mod.decorate(type.pointer_id, DECORATION_ARRAY_STRIDE, size);
	}
}

<*
 Offset, and for matrices ColMajor and MatrixStride, on every member of a
 block. The offsets must already have been assigned.
*>
fn void Codegen.decorate_block_members(&self, Id type_id, Type* type, Layout layout)
{
	foreach (i, &m : type.members)
	{
		self.mod.member_decorate(type_id, (uint)i, DECORATION_OFFSET, m.offset);
		if (m.type.kind == MATRIX)
		{
			self.mod.member_decorate(type_id, (uint)i, DECORATION_COL_MAJOR);
			self.mod.member_decorate(type_id, (uint)i, DECORATION_MATRIX_STRIDE, m.type.matrix_stride(layout));
		}
	}
}

<*
 Emit the module-level resource variables and their decorations.
*>
fn void? Codegen.emit_resources(&self, Ast* ast)
{
	usz at = 0;
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.RESOURCE) continue;
		Resource* resource = &self.resources[(sz)at++];

		// assign_bindings resolved the type and its block kind already.
		Type* type = resource.type;

		uint storage;
		switch (resource.block)
		{
			case UNIFORM:
			case PUSH_CONSTANT:
				Layout layout = resource.block.layout();
				storage = resource.block == BlockKind.UNIFORM
					? STORAGE_CLASS_UNIFORM
					: STORAGE_CLASS_PUSH_CONSTANT;

				// Block layout has to be decided before the type id is emitted,
				// because the decorations hang off that id.
				resource.size = type.assign_offsets(layout);
				Id type_id    = self.type_id(type);
				self.mod.decorate(type_id, DECORATION_BLOCK);
				self.decorate_block_members(type_id, type, layout);

			case ADDRESS:
				self.fail(decl.line, decl.column, string::format(self.allocator,
					"`%s` is @address, so it is reached through a `%s*`, not bound as a variable",
					type.name, type.name));
				return CODEGEN_ERROR~;

			case NONE:
				if (type.kind != TEXTURE && type.kind != SAMPLER)
				{
					self.fail(decl.line, decl.column, type.kind == STRUCT
						? string::format(self.allocator,
							"`%s` is a plain struct - mark it @uniform or @pushconstant to bind it", type.name)
						: string::format(self.allocator,
							"`%s` cannot be a module-level variable", type.name));
					return CODEGEN_ERROR~;
				}
				storage = STORAGE_CLASS_UNIFORM_CONSTANT;
		}

		resource.storage = storage;
		resource.id      = self.mod.global_var(self.pointer_to(storage, type), storage);
		self.mod.name(resource.id, decl.name);

		// A push constant block has no descriptor to bind, so it gets neither
		// a set nor a binding - and it never consumed one, see assign_bindings.
		if (storage != STORAGE_CLASS_PUSH_CONSTANT)
		{
			self.mod.decorate(resource.id, DECORATION_DESCRIPTOR_SET, resource.set);
			self.mod.decorate(resource.id, DECORATION_BINDING, resource.binding);
		}
	}
}

// --- Stage lowering ----------------------------------------------------------

<*
 Create the Input or Output variables mirroring a stage I/O struct.

 Locations are assigned in declaration order, skipping builtins, and honouring
 an explicit @location.

 `@position` means different things on the two sides, the way SV_Position does
 in HLSL: as a vertex output it is BuiltIn Position, the clip-space position;
 as a fragment input it is BuiltIn FragCoord, the window-space fragment
 coordinate. Vulkan rejects BuiltIn Position in a fragment shader outright
 (VUID-Position-Position-04318), so this is a translation, not a convenience.
*>
fn void? Codegen.stage_variables(&self, Type* type, uint storage, StageVarList* out, uint execution_model, uint line, uint column)
{
	uint next_location = 0;

	foreach (i, &member : type.members)
	{
		if (member.is_position && storage == STORAGE_CLASS_INPUT && execution_model != EXECUTION_MODEL_FRAGMENT)
		{
			self.fail(line, column, "@position is only meaningful on a vertex output or a fragment input");
			return CODEGEN_ERROR~;
		}

		Id pointer_type = self.pointer_to(storage, member.type);
		Id id           = self.mod.global_var(pointer_type, storage);
		self.mod.name(id, member.name);

		if (member.is_position)
		{
			bool is_fragment_input = storage == STORAGE_CLASS_INPUT;
			self.mod.decorate(id, DECORATION_BUILTIN, is_fragment_input ? BUILTIN_FRAG_COORD : BUILTIN_POSITION);
		}
		else if (member.is_builtin)
		{
			self.mod.decorate(id, DECORATION_BUILTIN, member.builtin);
		}
		else
		{
			uint location = next_location;
			if (Attribute* explicit_location = find_attribute(member.attributes, "location"))
			{
				location = (uint)explicit_location.args[0].number;
			}
			self.mod.decorate(id, DECORATION_LOCATION, location);
			next_location = location + 1;
		}

		if (find_attribute(member.attributes, "flat")) self.mod.decorate(id, DECORATION_FLAT);

		out.push({ .id = id, .type = member.type, .member_index = (usz)i, .is_position = member.is_position });
		self.interface_ids.push(id);
	}
}

<*
 Emit one entry point.

 The parameter struct is rebuilt as a function local so the body can read it
 with ordinary member access, and the return value is scattered back out to the
 stage's output variables (see emit_return).
*>
fn void? Codegen.emit_entry_point(&self, Decl* decl, uint execution_model)
{
	self.inputs.clear();
	self.outputs.clear();
	self.interface_ids.clear();
	self.locals.clear();

	Type* void_t  = self.types.find("void");
	Id    fn_void = self.mod.type_function(self.type_id(void_t));

	// Inputs, from the single parameter's struct type.
	Type* input_type = null;
	if (decl.function.params.len > 1)
	{
		self.fail(decl.line, decl.column, "an entry point takes at most one parameter");
		return CODEGEN_ERROR~;
	}
	if (decl.function.params.len == 1)
	{
		input_type = self.types.find(decl.function.params[0].type.name);
		if (!input_type || input_type.kind != STRUCT)
		{
			self.fail(decl.line, decl.column, "an entry point parameter must be a struct");
			return CODEGEN_ERROR~;
		}
		self.stage_variables(input_type, STORAGE_CLASS_INPUT, &self.inputs, execution_model, decl.line, decl.column)!;
	}

	// Outputs, from the return type.
	Type* return_type = self.types.find(decl.function.return_type.name);
	if (!return_type)
	{
		self.fail(decl.line, decl.column,
			string::format(self.allocator, "unknown type `%s`", decl.function.return_type.name));
		return CODEGEN_ERROR~;
	}

	if (return_type.kind == STRUCT)
	{
		self.stage_variables(return_type, STORAGE_CLASS_OUTPUT, &self.outputs, execution_model, decl.line, decl.column)!;
	}
	else if (return_type.kind != VOID)
	{
		// A bare value is the stage's single output at location 0.
		Id id = self.mod.global_var(self.pointer_to(STORAGE_CLASS_OUTPUT, return_type), STORAGE_CLASS_OUTPUT);
		self.mod.decorate(id, DECORATION_LOCATION, 0);
		self.outputs.push({ .id = id, .type = return_type, .member_index = 0 });
		self.interface_ids.push(id);
	}

	if (execution_model == EXECUTION_MODEL_VERTEX)
	{
		bool has_position = false;
		foreach (&output : self.outputs) if (output.is_position) has_position = true;
		if (!has_position)
		{
			self.fail(decl.line, decl.column,
				"a vertex entry point must return a struct with one member marked @position");
			return CODEGEN_ERROR~;
		}
	}

	Function function = self.mod.begin_function(self.type_id(void_t), fn_void);
	self.func       = &function;
	self.fn_return  = return_type;
	self.terminated = false;

	// Rebuild the parameter struct as a local, member by member.
	if (input_type)
	{
		Id pointer = function.local(self.pointer_to(STORAGE_CLASS_FUNCTION, input_type));
		self.mod.name(pointer, decl.function.params[0].name);

		foreach (&input : self.inputs)
		{
			Id value  = function.load(self.type_id(input.type), input.id);
			Id member = function.access_chain(
				self.pointer_to(STORAGE_CLASS_FUNCTION, input.type),
				pointer,
				(Id[]) { self.const_int((int)input.member_index) });
			function.store(member, value);
		}

		self.locals.push({ .name = decl.function.params[0].name, .type = input_type, .pointer = pointer });
	}

	self.statement(decl.function.body)!;
	if (!self.terminated) function.ret();

	function.end();
	self.func = null;

	self.mod.name(function.id, decl.name);
	self.mod.entry_point(execution_model, function.id, decl.name, self.interface_ids.array_view());

	if (execution_model == EXECUTION_MODEL_FRAGMENT)
	{
		self.mod.execution_mode(function.id, EXECUTION_MODE_ORIGIN_UPPER_LEFT);
	}
	else if (execution_model == EXECUTION_MODEL_GLCOMPUTE)
	{
		Attribute* threads = find_attribute(decl.attributes, "threads");
		if (!threads || threads.args.len != 3)
		{
			self.fail(decl.line, decl.column, "a @compute entry point needs @threads(x, y, z)");
			return CODEGEN_ERROR~;
		}
		self.mod.execution_mode(function.id, EXECUTION_MODE_LOCAL_SIZE,
			(uint)threads.args[0].number, (uint)threads.args[1].number, (uint)threads.args[2].number);
	}
}

// --- Entry point -------------------------------------------------------------

<*
 Compile shady source to a single SPIR-V module holding every entry point.

 The result is owned by `allocator`. On failure the fault is accompanied by
 `diagnostic`, if one was passed in.
*>
fn char[]? compile(String source, Diagnostic* diagnostic = null, Allocator allocator = mem)
{
	Diagnostic local_diagnostic;
	if (!diagnostic) diagnostic = &local_diagnostic;
	*diagnostic = {};

	Parser parser;
	Ast? parsed = parse(source, &parser);
	if (catch parsed)
	{
		*diagnostic = { .message = parser.error, .line = parser.error_line, .column = parser.error_column };
		return PARSE_ERROR~;
	}
	// `catch` above narrows `parsed` to a plain Ast from here on.
	Ast ast = parsed;
	defer ast.free();

	DynamicArenaAllocator arena;
	arena.init(mem, 64 * 1024);
	defer arena.free();

	TypeTable types;
	types.init(&arena);

	// Everything the module allocates comes from the arena, so releasing the
	// arena releases the module too.
	Module mod;
	mod.init(&arena);

	Codegen codegen;
	codegen.allocator = &arena;
	codegen.mod       = &mod;
	codegen.types     = &types;
	codegen.ast       = &ast;
	codegen.resources.init(&arena, 8);
	codegen.locals.init(&arena, 16);
	codegen.inputs.init(&arena, 8);
	codegen.outputs.init(&arena, 8);
	codegen.interface_ids.init(&arena, 16);

	mod.capability(CAPABILITY_SHADER);
	codegen.glsl = mod.ext_inst_import("GLSL.std.450");
	mod.set_memory_model();

	if (catch codegen.build())
	{
		*diagnostic = { .message = codegen.error, .line = codegen.error_line, .column = codegen.error_column };
		return CODEGEN_ERROR~;
	}

	// Buffer device addresses change the module header, not just its body: the
	// addressing model stops being Logical, so it can only be written once the
	// shader has been walked. set_memory_model rewrites its section rather than
	// appending, which is what makes that safe.
	if (codegen.uses_device_addresses)
	{
		mod.version = VERSION_1_3;
		mod.capability(CAPABILITY_PHYSICAL_STORAGE_BUFFER_ADDRESSES);
		// Addresses are computed as 64-bit integers, which is a capability of
		// its own even though PhysicalStorageBufferAddresses implies the type.
		mod.capability(CAPABILITY_INT64);
		mod.extension(EXTENSION_PHYSICAL_STORAGE_BUFFER);
		mod.set_memory_model(ADDRESSING_MODEL_PHYSICAL_STORAGE_BUFFER64);
	}

	return mod.build(allocator);
}

fn void? Codegen.build(&self)
{
	self.declare_structs(self.ast)!;
	self.assign_bindings(self.ast)!;
	self.emit_resources(self.ast)!;

	bool has_entry_point = false;
	foreach (decl : self.ast.decls)
	{
		if (decl.kind != DeclKind.FUNCTION) continue;

		uint execution_model;
		if (find_attribute(decl.attributes, "vertex"))        { execution_model = EXECUTION_MODEL_VERTEX; }
		else if (find_attribute(decl.attributes, "fragment")) { execution_model = EXECUTION_MODEL_FRAGMENT; }
		else if (find_attribute(decl.attributes, "compute"))  { execution_model = EXECUTION_MODEL_GLCOMPUTE; }
		else
		{
			self.fail(decl.line, decl.column,
				"plain functions are not implemented yet - mark this @vertex, @fragment or @compute");
			return CODEGEN_ERROR~;
		}

		self.emit_entry_point(decl, execution_model)!;
		has_entry_point = true;
	}

	if (!has_entry_point)
	{
		self.fail(0, 0, "the shader has no entry points");
		return CODEGEN_ERROR~;
	}
}
