<*
 The public entry point: shady source in, SPIR-V out.

 Everything happens in memory and in one process. A bad shader is a fault with
 a line, a column and a message - never an exit, and never a temporary file.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

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

		if (Attribute* set = decl.attributes.find("set"))
		{
			if (set.args.len != 1)
			{
				self.fail(set.line, set.column, "@set takes one number");
				return CODEGEN_ERROR~;
			}
			resource.set = (uint)set.args[0].number;
		}
		if (Attribute* binding = decl.attributes.find("binding"))
		{
			if (binding.args.len != 1)
			{
				self.fail(binding.line, binding.column, "@binding takes one number");
				return CODEGEN_ERROR~;
			}
			resource.binding = (uint)binding.args[0].number;
		}

		// The type is resolved the way a local's is, because a resource may be
		// an array - the bindless texture table is `Sampler2D three_textures[]`.
		Type* type = self.resolve_type(decl.resource.type, decl.line, decl.column)!;
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
			if (decl.attributes.find( "set") || decl.attributes.find( "binding"))
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
		type.pointer_id = self.mod.type_forward_pointer(StorageClass.PHYSICAL_STORAGE_BUFFER);
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
			Type* member_type = self.resolve_type(source.type, source.line, source.column)!;
			if (member_type.kind == ARRAY && member_type.runtime)
			{
				self.fail(source.line, source.column, "a runtime-sized array cannot be a struct member");
				return CODEGEN_ERROR~;
			}
			members[i] = {
				.name        = source.name,
				.type        = member_type,
				.attributes  = source.attributes,
				.is_position = source.attributes.find("position") != null,
			};
			if (Attribute* builtin = source.attributes.find("builtin"))
			{
				Builtin which;
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
	// out for the device-address layout, decorate it Block, and close the
	// forward pointer.
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

		Layout layout = self.block_layout(ADDRESS);
		uint?  size   = type.assign_offsets(layout);
		if (catch size)
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` nests a struct another block lays out differently - give each block its own struct",
				type.name));
			return CODEGEN_ERROR~;
		}
		Id type_id = self.type_id(type);
		self.mod.decorate(type_id, Decoration.BLOCK);
		self.decorate_block_members(type_id, type, layout);

		self.mod.define_forward_pointer(type.pointer_id, StorageClass.PHYSICAL_STORAGE_BUFFER, type_id);
		self.mod.decorate(type.pointer_id, Decoration.ARRAY_STRIDE, size);
	}
}

<*
 Emit the module-level `const`s and register them by name.

 With `@spec(id)` a constant is a *specialization* constant: the value written
 here is a default the host may replace when it creates the pipeline, which is
 how one module serves several variants without recompiling. Without `@spec` it
 is an ordinary constant.

 Only scalars, and only literal initialisers: a spec constant has to be a single
 SPIR-V literal to be replaceable, and anything else would need constant folding
 first.
*>
fn void? Codegen.declare_constants(&self, Ast* ast)
{
	// A spec id is the host's handle on a value, so two constants sharing one is
	// a mistake worth naming rather than letting the last one win.
	UintList spec_ids;
	spec_ids.init(self.allocator, 8);

	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.CONSTANT) continue;

		Type* type = self.types.find(decl.constant.type.name);
		if (!type)
		{
			self.fail(decl.line, decl.column,
				string::format(self.allocator, "unknown type `%s`", decl.constant.type.name));
			return CODEGEN_ERROR~;
		}
		if (!type.is_scalar())
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` cannot be a constant; only bool, int, uint and float can", type.name));
			return CODEGEN_ERROR~;
		}

		bool is_spec = false;
		uint spec_id = 0;
		if (Attribute* spec = decl.attributes.find("spec"))
		{
			if (spec.args.len != 1 || spec.args[0].is_name)
			{
				self.fail(spec.line, spec.column, "@spec takes one number");
				return CODEGEN_ERROR~;
			}
			is_spec = true;
			spec_id = (uint)spec.args[0].number;
			foreach (existing : spec_ids)
			{
				if (existing == spec_id)
				{
					self.fail(spec.line, spec.column,
						string::format(self.allocator, "spec id %d is already used", spec_id));
					return CODEGEN_ERROR~;
				}
			}
			spec_ids.push(spec_id);
		}

		Expr* value = decl.constant.value;
		Id    id;

		switch (type.kind)
		{
			case BOOL:
				if (value.kind != ExprKind.BOOL_LITERAL)
				{
					self.fail(decl.line, decl.column, "a bool constant needs `true` or `false`");
					return CODEGEN_ERROR~;
				}
				id = is_spec
					? self.mod.spec_constant_bool(self.type_id(type), value.boolean.value, spec_id)
					: (value.boolean.value
						? self.mod.const_true(self.type_id(type))
						: self.mod.const_false(self.type_id(type)));

			case INT:
				if (value.kind != ExprKind.INT_LITERAL)
				{
					self.fail(decl.line, decl.column, "an int constant needs an integer literal");
					return CODEGEN_ERROR~;
				}
				id = is_spec
					? self.mod.spec_constant_i32(self.type_id(type), (int)value.literal.value, spec_id)
					: self.mod.const_i32(self.type_id(type), (int)value.literal.value);

			case UINT:
				if (value.kind != ExprKind.INT_LITERAL)
				{
					self.fail(decl.line, decl.column, "a uint constant needs an integer literal");
					return CODEGEN_ERROR~;
				}
				id = is_spec
					? self.mod.spec_constant_u32(self.type_id(type), (uint)value.literal.value, spec_id)
					: self.mod.const_u32(self.type_id(type), (uint)value.literal.value);

			case FLOAT:
				if (value.kind != ExprKind.FLOAT_LITERAL && value.kind != ExprKind.INT_LITERAL)
				{
					self.fail(decl.line, decl.column, "a float constant needs a number");
					return CODEGEN_ERROR~;
				}
				float number = value.kind == ExprKind.FLOAT_LITERAL
					? (float)value.literal.value
					: (float)((int)value.literal.value);
				id = is_spec
					? self.mod.spec_constant_f32(self.type_id(type), number, spec_id)
					: self.mod.const_f32(self.type_id(type), number);

			default:
				self.fail(decl.line, decl.column, "only scalars can be constants");
				return CODEGEN_ERROR~;
		}

		self.mod.name(id, decl.name);
		self.constants.push({
			.name    = decl.name,
			.type    = type,
			.id      = id,
			.is_spec = is_spec,
			.line    = decl.line,
			.column  = decl.column,
		});
	}
}

<*
 Offset, and for matrices ColMajor and MatrixStride, on every member of a
 block. The offsets must already have been assigned by `assign_offsets`.

 A struct nested inside the block gets the same treatment - its members carry
 `Offset` too, and the enclosing block's layout is what decides them - and so
 do arrays, whose stride is likewise the block's. The recursive call is guarded
 because one struct may be nested twice inside a block, and its type id is
 decorated once.
*>
fn void Codegen.decorate_block_members(&self, Id type_id, Type* type, Layout layout)
{
	if (type.members_decorated) return;
	type.members_decorated = true;

	foreach (i, &m : type.members)
	{
		uint member = (uint)i;
		self.mod.member_decorate(type_id, member, Decoration.OFFSET, m.offset);

		if (m.type.kind == MATRIX)
		{
			self.mod.member_decorate(type_id, member, Decoration.COL_MAJOR);
			self.mod.member_decorate(type_id, member, Decoration.MATRIX_STRIDE, m.type.matrix_stride(layout));
		}

		// Every array layer in the member's type, then the struct inside it.
		Type* element = m.type;
		while (element.kind == ARRAY)
		{
			self.mod.decorate(self.type_id(element), Decoration.ARRAY_STRIDE, array_stride(element.element, layout));
			element = element.element;
		}
		if (element.kind == STRUCT)
		{
			self.decorate_block_members(self.type_id(element), element, layout);
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

		StorageClass storage;
		switch (resource.block)
		{
			case UNIFORM:
			case PUSH_CONSTANT:
				Layout layout = self.block_layout(resource.block);
				storage = resource.block == BlockKind.UNIFORM
					? StorageClass.UNIFORM
					: StorageClass.PUSH_CONSTANT;

				// Block layout has to be decided before the type id is emitted,
				// because the decorations hang off that id.
				uint? size = type.assign_offsets(layout);
				if (catch size)
				{
					self.fail(decl.line, decl.column, string::format(self.allocator,
						"`%s` nests a struct another block lays out differently - give each block its own struct",
						type.name));
					return CODEGEN_ERROR~;
				}
				resource.size = size;
				Id type_id    = self.type_id(type);
				self.mod.decorate(type_id, Decoration.BLOCK);
				self.decorate_block_members(type_id, type, layout);

			case ADDRESS:
				self.fail(decl.line, decl.column, string::format(self.allocator,
					"`%s` is @address, so it is reached through a `%s*`, not bound as a variable",
					type.name, type.name));
				return CODEGEN_ERROR~;

			case NONE:
			{
				// An image, a sampler or a combined `Sampler2D` - or an array
				// of one, which is the bindless texture table.
				Type* element = type.kind == ARRAY ? type.element : type;
				if (!element.is_opaque())
				{
					self.fail(decl.line, decl.column, element.kind == STRUCT
						? string::format(self.allocator,
							"`%s` is a plain struct - mark it @uniform or @pushconstant to bind it", element.name)
						: string::format(self.allocator,
							"`%s` cannot be a module-level variable", type.name));
					return CODEGEN_ERROR~;
				}

				// A runtime-sized descriptor array needs the extension; a fixed
				// one does not.
				if (type.kind == ARRAY && type.runtime)
				{
					self.mod.capability(Capability.RUNTIME_DESCRIPTOR_ARRAY);
					self.mod.extension("SPV_EXT_descriptor_indexing");
				}
				storage = StorageClass.UNIFORM_CONSTANT;
				break;
			}
		}

		resource.storage = storage;
		resource.id      = self.mod.global_var(self.pointer_to(storage, type), storage);
		self.mod.name(resource.id, decl.name);

		// A push constant block has no descriptor to bind, so it gets neither
		// a set nor a binding - and it never consumed one, see assign_bindings.
		if (storage != StorageClass.PUSH_CONSTANT)
		{
			self.mod.decorate(resource.id, Decoration.DESCRIPTOR_SET, resource.set);
			self.mod.decorate(resource.id, Decoration.BINDING, resource.binding);
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
fn void? Codegen.stage_variables(&self, Type* type, StorageClass storage, StageVarList* out, ExecutionModel execution_model, uint line, uint column)
{
	uint next_location = 0;

	foreach (i, &member : type.members)
	{
		if (member.is_position && storage == StorageClass.INPUT && execution_model != ExecutionModel.FRAGMENT)
		{
			self.fail(line, column, "@position is only meaningful on a vertex output or a fragment input");
			return CODEGEN_ERROR~;
		}

		Id pointer_type = self.pointer_to(storage, member.type);
		Id id           = self.mod.global_var(pointer_type, storage);
		self.mod.name(id, member.name);

		if (member.is_position)
		{
			bool is_fragment_input = storage == StorageClass.INPUT;
			self.mod.decorate(id, Decoration.BUILTIN, (Id)(is_fragment_input ? Builtin.FRAG_COORD : Builtin.POSITION));
		}
		else if (member.is_builtin)
		{
			self.mod.decorate(id, Decoration.BUILTIN, (Id)(uint)member.builtin);
		}
		else
		{
			uint location = next_location;
			if (Attribute* explicit_location = member.attributes.find("location"))
			{
				location = (uint)explicit_location.args[0].number;
			}
			self.mod.decorate(id, Decoration.LOCATION, location);
			next_location = location + 1;
		}

		if (member.attributes.find("flat")) self.mod.decorate(id, Decoration.FLAT);

		out.push({ .id = id, .type = member.type, .member_index = (usz)i, .is_position = member.is_position });
		self.interface_ids.push(id);
	}
}

<*
 The name an entry point is published under.

 The function's own name by default, or the stage attribute's argument when it
 has one: `fn float4 shade(...) @fragment(main)` compiles to an entry point
 called `main`. That matters when the host hardcodes a name, and it lets two
 variants keep readable function names while presenting the names a pipeline
 expects.
*>
fn String? Codegen.entry_name(&self, Decl* decl, Attribute* stage)
{
	if (!stage.args.len) return decl.name;

	if (stage.args.len != 1 || !stage.args[0].is_name)
	{
		self.fail(stage.line, stage.column, string::format(self.allocator,
			"@%s takes one name, or nothing at all", stage.name));
		return CODEGEN_ERROR~;
	}
	return stage.args[0].name;
}

<*
 Emit one entry point.

 The parameter struct is rebuilt as a function local so the body can read it
 with ordinary member access, and the return value is scattered back out to the
 stage's output variables (see emit_return).
*>
fn void? Codegen.emit_entry_point(&self, Decl* decl, ExecutionModel execution_model, String entry_name)
{
	if (!decl.function.body)
	{
		self.fail(decl.line, decl.column, string::format(self.allocator,
			"`%s` is an entry point, so it is the definition: it cannot be declared without a body",
			decl.name));
		return CODEGEN_ERROR~;
	}

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
		self.stage_variables(input_type, StorageClass.INPUT, &self.inputs, execution_model, decl.line, decl.column)!;
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
		self.stage_variables(return_type, StorageClass.OUTPUT, &self.outputs, execution_model, decl.line, decl.column)!;
	}
	else if (return_type.kind != VOID)
	{
		// A bare value is the stage's single output at location 0.
		Id id = self.mod.global_var(self.pointer_to(StorageClass.OUTPUT, return_type), StorageClass.OUTPUT);
		self.mod.decorate(id, Decoration.LOCATION, 0);
		self.outputs.push({ .id = id, .type = return_type, .member_index = 0 });
		self.interface_ids.push(id);
	}

	if (execution_model == ExecutionModel.VERTEX)
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
		Id pointer = function.local(self.pointer_to(StorageClass.FUNCTION, input_type));
		self.mod.name(pointer, decl.function.params[0].name);

		foreach (&input : self.inputs)
		{
			Id value  = function.load(self.type_id(input.type), input.id);
			Id member = function.access_chain(
				self.pointer_to(StorageClass.FUNCTION, input.type),
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

	// OpName keeps the function's own name so a disassembly maps back to the
	// source; the entry point publishes whatever the stage attribute asked for.
	self.mod.name(function.id, decl.name);
	self.mod.entry_point(execution_model, function.id, entry_name, self.interface_ids.array_view());

	if (execution_model == ExecutionModel.FRAGMENT)
	{
		self.mod.execution_mode(function.id, ExecutionMode.ORIGIN_UPPER_LEFT);
	}
	else if (execution_model == ExecutionModel.GL_COMPUTE)
	{
		Attribute* threads = decl.attributes.find( "threads");
		if (!threads || threads.args.len != 3)
		{
			self.fail(decl.line, decl.column, "a @compute entry point needs @threads(x, y, z)");
			return CODEGEN_ERROR~;
		}
		self.mod.execution_mode(function.id, ExecutionMode.LOCAL_SIZE,
			(uint)threads.args[0].number, (uint)threads.args[1].number, (uint)threads.args[2].number);
	}
}

// --- Entry point -------------------------------------------------------------

<*
 Compile shady source to a single SPIR-V module holding every entry point.

 The result is owned by `allocator`. On failure the fault is accompanied by
 `diagnostic`, if one was passed in - every string in it is a copy on
 `allocator` and is the caller's to free.

 Warnings travel beside the fault rather than in it: pass a `warnings` list and
 every non-fatal finding is appended to it, whether the compile succeeded or
 not. The list must already be initialized, and its entries are the caller's to
 free, like the diagnostic.

 @param scalar_layout : `Pack every block with C3's own rules - 4-byte scalars,
 no rounding to 16 - rather than std140/std430. This is the mode that lines
 generated structs up with three.c3's wire layout, and it is off by default.`
 @param warnings : `Where non-fatal findings go. Nothing is appended when this is null.`
*>
fn char[]? compile(
	String source,
	Diagnostic* diagnostic = null,
	Allocator allocator = mem,
	bool scalar_layout = false,
	DiagnosticList* warnings = null)
{
	Diagnostic local_diagnostic;
	if (!diagnostic) diagnostic = &local_diagnostic;
	*diagnostic = {};

	// The `#line` regions and the findings the passes collect are the compile's
	// own working state, so they live in its arena and die with it.
	DynamicArenaAllocator arena;
	arena.init(mem, 64 * 1024);
	defer arena.free();

	LineMap map;
	map.init(&arena);

	DiagnosticList findings;
	findings.init(&arena, 4);

	Parser parser;
	Ast? parsed = parse(source, &parser, &map);
	if (catch parsed)
	{
		*diagnostic = diagnostic_at(allocator, source, &map, DiagnosticKind.ERROR,
			parser.error_line, parser.error_column, parser.error_length, parser.error);
		if (parser.error.len) free(parser.error);
		copy_warnings(warnings, allocator, source, &map, &findings);
		return PARSE_ERROR~;
	}
	// `catch` above narrows `parsed` to a plain Ast from here on.
	Ast ast = parsed;
	defer ast.free();

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
	codegen.scalar_layout = scalar_layout;
	codegen.warnings  = &findings;
	codegen.resources.init(&arena, 8);
	codegen.constants.init(&arena, 8);
	codegen.locals.init(&arena, 16);
	codegen.functions.init(&arena, 8);
	codegen.loops.init(&arena, 4);
	codegen.inputs.init(&arena, 8);
	codegen.outputs.init(&arena, 8);
	codegen.interface_ids.init(&arena, 16);

	mod.capability(Capability.SHADER);
	codegen.glsl = mod.ext_inst_import("GLSL.std.450");
	mod.set_memory_model();

	if (catch codegen.build())
	{
		*diagnostic = diagnostic_at(allocator, source, &map, DiagnosticKind.ERROR,
			codegen.error_line, codegen.error_column, codegen.error_length, codegen.error);
		copy_warnings(warnings, allocator, source, &map, &findings);
		return CODEGEN_ERROR~;
	}

	copy_warnings(warnings, allocator, source, &map, &findings);

	// Buffer device addresses change the module header, not just its body: the
	// addressing model stops being Logical, so it can only be written once the
	// shader has been walked. set_memory_model rewrites its section rather than
	// appending, which is what makes that safe.
	if (codegen.uses_device_addresses)
	{
		mod.version = VERSION_1_3;
		mod.capability(Capability.PHYSICAL_STORAGE_BUFFER_ADDRESSES);
		// Addresses are computed as 64-bit integers, which is a capability of
		// its own even though PhysicalStorageBufferAddresses implies the type.
		mod.capability(Capability.INT64);
		mod.extension(EXTENSION_PHYSICAL_STORAGE_BUFFER);
		mod.set_memory_model(AddressingModel.PHYSICAL_STORAGE_BUFFER64);
	}

	return mod.build(allocator);
}

<*
 Move the findings the passes collected to the caller's list.

 The positions are physical and the map is physical, so this is also where a
 warning learns the region and line number its writer used. Nothing happens
 when the caller did not ask for warnings.
*>
fn void copy_warnings(
	DiagnosticList* out,
	Allocator allocator,
	String source,
	LineMap* map,
	DiagnosticList* findings)
{
	if (!out) return;
	foreach (&finding : findings)
	{
		out.push(diagnostic_at(allocator, source, map, finding.kind,
			finding.line, finding.column, finding.length, finding.message));
	}
}

fn void? Codegen.build(&self)
{
	self.declare_structs(self.ast)!;
	self.declare_constants(self.ast)!;
	self.declare_functions(self.ast)!;
	self.check_required()!;
	self.assign_bindings(self.ast)!;
	self.emit_resources(self.ast)!;

	// One module can hold as many entry points as it likes, of any stage. The
	// host picks between them by name, through `pName` in
	// VkPipelineShaderStageCreateInfo, so the names have to be distinct.
	StringList entry_names;
	entry_names.init(self.allocator, 4);

	foreach (decl : self.ast.decls)
	{
		if (decl.kind != DeclKind.FUNCTION) continue;

		// Whichever of the stage attributes this function carries. Asked of
		// `Stage` rather than compared here, because the same list is what a
		// generator writing a module has to spell.
		Stage      kind;
		Attribute* stage = null;
		foreach (&attribute : decl.attributes)
		{
			if (stage_from_attribute(attribute.name, &kind))
			{
				stage = attribute;
				break;
			}
		}
		if (!stage)
		{
			// An ordinary function: declared by declare_functions and emitted
			// on first call. Not an entry point, so nothing to do here.
			continue;
		}
		ExecutionModel execution_model = kind.execution_model();

		String entry_name = self.entry_name(decl, stage)!;
		foreach (taken : entry_names)
		{
			if (taken != entry_name) continue;
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"there is already an entry point called `%s` - the host tells them apart by name", entry_name));
			return CODEGEN_ERROR~;
		}
		entry_names.push(entry_name);

		self.emit_entry_point(decl, execution_model, entry_name)!;
	}

	if (!entry_names.len())
	{
		self.fail(0, 0, "the shader has no entry points");
		return CODEGEN_ERROR~;
	}

	// A spec constant is the host's handle on a value, so one no code reads is
	// a knob wired to nothing - and the host setting it would never find out.
	// Everything that reads a constant resolves it by name, so by here the
	// answer is known.
	foreach (&constant : self.constants)
	{
		if (!constant.is_spec || constant.used) continue;
		self.warn(constant.line, constant.column, string::format(self.allocator,
			"the specialization constant `%s` is never read - setting it changes nothing",
			constant.name), (uint)constant.name.len);
	}
}
