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
		// an array - the bindless texture table is `Sampler2D three_textures[]`,
		// and a bare `float data[]` is a storage buffer written the short way.
		// The two are told apart by what the array holds: an opaque element is
		// a runtime-sized *descriptor* array, anything else a storage buffer.
		Type* type = self.resolve_type(decl.resource.type, decl.line, decl.column)!;
		resource.type  = type;
		resource.block = type.kind == STRUCT ? type.block : BlockKind.NONE;
		if (type.kind == ARRAY && type.runtime && !type.element.is_opaque()) resource.block = STORAGE;
		if (resource.block == STORAGE && type.kind == ARRAY && type.element.contains_bool())
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s[]` holds a bool, which has no layout in a storage buffer - store a `uint` and compare it with 0u",
				type.element.name));
			return CODEGEN_ERROR~;
		}

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
				// A runtime-sized array is the tail of the block it lives in, so
				// it is legal in exactly one place: the last member of a
				// @storage struct, which is what a storage buffer is. Anywhere
				// else there is nothing to stop the array, and the block that
				// contains it has no size.
				if (type.block != STORAGE)
				{
					self.fail(source.line, source.column, string::format(self.allocator,
						"`%s[]` is a runtime-sized array, which is only a member of an @storage block",
						member_type.element.name));
					return CODEGEN_ERROR~;
				}
				if (i + 1 < decl.struct_decl.members.len)
				{
					self.fail(source.line, source.column,
						"a runtime-sized array has no size, so nothing may follow it in the block");
					return CODEGEN_ERROR~;
				}
				if (!member_type.element.may_back_a_runtime_array())
				{
					self.fail(source.line, source.column, string::format(self.allocator,
						"`%s[]` cannot back a runtime-sized array - it is not a scalar, vector, matrix or struct",
						member_type.element.name));
					return CODEGEN_ERROR~;
				}
			}
			if (member_type.holds_handle())
			{
				self.fail(source.line, source.column, string::format(self.allocator,
					"`%s.%s` cannot be %s - a handle is not data, and a struct is data",
					decl.name, source.name, (member_type.kind == ARRAY ? member_type.element : member_type).a_name(self.allocator)));
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

	// A block is memory the host writes, and Vulkan gives a bool no layout in
	// it. A nested plain struct is reached here too: it is the block's memory
	// all the same, even though the struct alone is a legal local.
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.STRUCT) continue;
		Type* type = self.types.find(decl.name);
		if (type.block == NONE) continue;
		foreach (i, &m : type.members)
		{
			if (!m.type.contains_bool()) continue;
			self.fail(decl.struct_decl.members[i].line, decl.struct_decl.members[i].column, string::format(self.allocator,
				"`%s.%s` holds a bool, which has no layout in a %s block - store a `uint` and compare it with 0u",
				type.name, m.name, type.block.attribute()));
			return CODEGEN_ERROR~;
		}
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
			case STORAGE:
				Layout layout = self.block_layout(resource.block);
				storage = resource.block == BlockKind.UNIFORM
					? StorageClass.UNIFORM
					: resource.block == BlockKind.STORAGE
						? StorageClass.STORAGE_BUFFER
						: StorageClass.PUSH_CONSTANT;

				// A bare runtime-sized array - `float data[];` - is a storage
				// buffer written the short way: SPIR-V has no runtime array at
				// the top level of a descriptor, so the declaration becomes the
				// block it describes. A `@storage` struct is already one, and a
				// runtime-sized descriptor array is a binding of its own.
				//
				// The wrapper is kept as the variable's type rather than only
				// as the descriptor's, so that the variable's pointer and its
				// pointee are the same type - and `index_expression` steps
				// through the block again when the shader indexes the name.
				if (type.kind == ARRAY && type.runtime)
				{
					type = self.types.wrap_runtime_array(type);
					resource.type = type;
				}

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
				if (resource.block == BlockKind.STORAGE)
				{
					// SPIR-V 1.3 folded the storage buffer storage class in; a
					// 1.0 module declares the extension that added it. Emitted
					// here rather than at the header because whether the module
					// has one is only known once the resources are walked.
					self.mod.extension("SPV_KHR_storage_buffer_storage_class");

					// Bytes in a buffer are the one place the language reaches
					// 8-bit memory, and the capability is what says the host
					// enabled the device feature for it. Without this the
					// module is one a driver may refuse - or worse, accept and
					// misread.
					if (type.contains_byte_integer()) self.mod.capability(Capability.STORAGE_BUFFER_8BIT_ACCESS);
					if (type.contains_16bit())
					{
						self.mod.extension("SPV_KHR_16bit_storage");
						self.mod.capability(Capability.STORAGE_BUFFER_16BIT_ACCESS);
					}
				}
				else
				{
					if (type.contains_byte_integer()) self.mod.capability(Capability.UNIFORM_AND_STORAGE_BUFFER_8BIT_ACCESS);
					if (type.contains_16bit())
					{
						self.mod.extension("SPV_KHR_16bit_storage");
						self.mod.capability(Capability.UNIFORM_AND_STORAGE_BUFFER_16BIT_ACCESS);
					}
				}
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
					String message;
					switch (element.kind)
					{
						case STRUCT:
							message = string::format(self.allocator,
								"`%s` is a plain struct - mark it @uniform, @storage or @pushconstant to bind it", element.name);
						case RAY_QUERY:
							message = "a RayQuery is a function's own traversal - declare it as a local";
						default:
							message = string::format(self.allocator, "`%s` cannot be a module-level variable", type.name);
					}
					self.fail(decl.line, decl.column, message);
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
		default:
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
fn void? Codegen.stage_variables(&self, Type* type, StorageClass storage, StageVarList* out, Stage stage, uint* next_location, uint line, uint column)
{
	foreach (i, &member : type.members)
	{
		if (member.is_position && storage == StorageClass.INPUT && stage != Stage.FRAGMENT)
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
			self.check_builtin(member, storage, stage)!;
			self.mod.decorate(id, Decoration.BUILTIN, (Id)(uint)member.builtin);
		}
		else
		{
			uint location = *next_location;
			if (Attribute* explicit_location = member.attributes.find("location"))
			{
				location = (uint)explicit_location.args[0].number;
			}
			self.mod.decorate(id, Decoration.LOCATION, location);
			*next_location = location + 1;
		}

		// An integer cannot be interpolated, so a varying that carries one is Flat
		// on both sides of the stage boundary. Asked of the type rather than left to
		// `@flat`, because there is no other legal spelling for it: a vertex output
		// or fragment input of integer type without this decoration is a module the
		// validator refuses, and the author has nothing to decide. `@flat` still
		// parses, so a file that says it says nothing wrong.
		//
		// Only those two are varyings. Interpolation happens between the stages,
		// so Vulkan forbids Flat on a vertex input and a fragment output
		// (VUID-StandaloneSpirv-Flat-06201/06202) - an integer render target is
		// an ordinary output - and `@flat` on a struct shared with either side is
		// left off there rather than refused.
		bool varying = (storage == StorageClass.OUTPUT && stage == Stage.VERTEX)
			|| (storage == StorageClass.INPUT && stage == Stage.FRAGMENT);
		TypeKind scalar = member.type.scalar().kind;
		bool integer = !member.is_position && !member.is_builtin
			&& (scalar == INT || scalar == UINT || scalar == BOOL);
		if (varying && (member.attributes.find("flat") || integer)) self.mod.decorate(id, Decoration.FLAT);

		out.push({ .id = id, .type = member.type, .member_index = (usz)i, .is_position = member.is_position });
		self.interface_ids.push(id);
	}
}

<*
 What an entry point's parameter is to its stage.
*>
enum ParamRole : char
{
	STAGE_INPUT,    // varyings and built-ins, copied into a local
	PAYLOAD,        // `inout P p` in a closest-hit, any-hit or miss shader
	CALLABLE_DATA,  // `inout D d` in a callable shader
	HIT_ATTRIBUTES, // a plain struct in a closest-hit or any-hit shader
}

<*
 Classify a parameter by its shape, the way HLSL does: a ray-tracing stage takes
 its payload `inout`, its built-ins in a struct of `@builtin` members, and its
 hit attributes as a plain struct. `earlier` are the roles of the parameters
 before this one, since each of the ray roles is one parameter at most.
*>
fn ParamRole? Codegen.param_role(&self, Decl* decl, Param* param, Stage stage, ParamRole[] earlier)
{
	Type* type = self.types.find(param.type.name);
	if (!type || type.kind != STRUCT || param.type.is_array || param.type.is_pointer)
	{
		self.fail(param.line, param.column, "an entry point parameter must be a struct");
		return CODEGEN_ERROR~;
	}

	if (!stage.is_ray_tracing())
	{
		if (param.by_ref)
		{
			self.fail(param.line, param.column, string::format(self.allocator,
				"`%s` is %s shader's input, which it cannot write back - drop `%s`",
				param.name, stage_list(stage.bit(), self.allocator), param.is_inout ? "inout" : "out"));
			return CODEGEN_ERROR~;
		}
		return ParamRole.STAGE_INPUT;
	}

	ParamRole role;
	if (param.by_ref)
	{
		if (!param.is_inout)
		{
			self.fail(param.line, param.column, string::format(self.allocator,
				"write `inout %s %s` - the payload arrives holding what its caller traced it with", type.name, param.name));
			return CODEGEN_ERROR~;
		}
		switch (stage)
		{
			case Stage.CLOSEST_HIT:
			case Stage.ANY_HIT:
			case Stage.MISS:
				role = ParamRole.PAYLOAD;
			case Stage.CALLABLE:
				role = ParamRole.CALLABLE_DATA;
			case Stage.RAYGEN:
				self.fail(param.line, param.column,
					"a ray-generation shader starts rays rather than receiving one - declare the payload as a local and pass it to `trace_ray`");
				return CODEGEN_ERROR~;
			default:
				self.fail(param.line, param.column,
					"an intersection shader has no payload - it reports what it finds with `report_intersection`");
				return CODEGEN_ERROR~;
		}
	}
	else
	{
		usz builtins = 0;
		foreach (&member : type.members) if (member.is_builtin) builtins++;
		if (builtins == type.members.len) return ParamRole.STAGE_INPUT;
		if (builtins)
		{
			foreach (&member : type.members)
			{
				if (member.is_builtin) continue;
				self.fail(param.line, param.column, string::format(self.allocator,
					"a ray-tracing shader has no varyings, so `%s.%s` needs a @builtin - or move it to a struct of its own if it is the hit attributes",
					type.name, member.name));
				return CODEGEN_ERROR~;
			}
		}
		if (stage != Stage.CLOSEST_HIT && stage != Stage.ANY_HIT)
		{
			self.fail(param.line, param.column, string::format(self.allocator,
				"`%s` has no @builtin members, so it would be hit attributes - which only a closest-hit or any-hit shader has",
				param.name));
			return CODEGEN_ERROR~;
		}
		role = ParamRole.HIT_ATTRIBUTES;
		if (type.size(Layout.SCALAR) > 32)
		{
			self.warn(param.line, param.column, string::format(self.allocator,
				"`%s` is %d bytes of hit attributes - Vulkan only guarantees 32 (maxRayHitAttributeSize)",
				type.name, type.size(Layout.SCALAR)));
		}
	}

	if (type.block != NONE)
	{
		self.fail(param.line, param.column, string::format(self.allocator,
			"`%s` is %s, so it is memory the host lays out - a payload or hit attributes are a plain struct",
			type.name, type.block.attribute()));
		return CODEGEN_ERROR~;
	}
	foreach (other : earlier)
	{
		if (other != role) continue;
		self.fail(param.line, param.column, string::format(self.allocator,
			"`%s` already takes its %s - an entry point has one", decl.name,
			role == ParamRole.HIT_ATTRIBUTES ? "hit attributes" : role == ParamRole.PAYLOAD ? "payload" : "callable data"));
		return CODEGEN_ERROR~;
	}
	return role;
}

<*
 A `@builtin` member is something this stage is handed, of the type Vulkan
 hands it as. Checked here rather than where the struct is declared, because
 one struct may be the input of several stages.
*>
fn void? Codegen.check_builtin(&self, StructMember* member, StorageClass storage, Stage stage)
{
	Attribute*  attribute = member.attributes.find("builtin");
	BuiltinInfo info;
	builtin_info(attribute.args[0].name, &info);

	if (storage == StorageClass.OUTPUT)
	{
		self.fail(attribute.line, attribute.column, string::format(self.allocator,
			"`@builtin(%s)` is an input, so it is a parameter's member, not a returned one", info.name));
		return CODEGEN_ERROR~;
	}
	if (!(info.stages & stage.bit()))
	{
		self.fail(attribute.line, attribute.column, string::format(self.allocator,
			"`@builtin(%s)` is only in %s shader, and this is %s shader",
			info.name, stage_list(info.stages, self.allocator), stage_list(stage.bit(), self.allocator)));
		return CODEGEN_ERROR~;
	}
	Type* expected = self.types.find(info.type_name);
	if (!member.type.matches_builtin(expected))
	{
		self.fail(attribute.line, attribute.column, string::format(self.allocator,
			"`@builtin(%s)` is a %s, so `%s` cannot be a %s", info.name, expected.name, member.name, member.type.name));
		return CODEGEN_ERROR~;
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
fn void? Codegen.emit_entry_point(&self, Decl* decl, Stage stage, String entry_name)
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
	self.stage = stage;
	self.reach = self.new_reach(true);
	ExecutionModel execution_model = stage.execution_model();

	Type* void_t  = self.types.find("void");
	Id    fn_void = self.mod.type_function(self.type_id(void_t));

	if (stage.is_ray_tracing()) self.ray_tracing_capability();

	// A workgroup's shape is a compute shader's alone; on any other stage the
	// attribute would be read by nothing.
	foreach (name : (String[]) { "threads", "subgroup_size" })
	{
		Attribute* attribute = decl.attributes.find(name);
		if (!attribute || stage == Stage.COMPUTE) continue;
		self.fail(attribute.line, attribute.column, string::format(self.allocator,
			"@%s is the shape of a compute workgroup, and `%s` is %s shader",
			name, decl.name, stage_list(stage.bit(), self.allocator)));
		return CODEGEN_ERROR~;
	}

	// What each parameter is: stage input, or - in a ray-tracing stage - the
	// payload, the callable data or the hit attributes.
	ParamRole[] roles = alloc::alloc_array(self.allocator, ParamRole, decl.function.params.len);
	foreach (p, param : decl.function.params)
	{
		roles[p] = self.param_role(decl, &decl.function.params[p], stage, roles[:p])!;
	}

	// Inputs, one struct per parameter. A second parameter is how a stage takes
	// a builtin beside its varying struct: a fragment's `front_facing` has no
	// place in the struct the vertex stage writes, and Vulkan refuses a vertex
	// output decorated with it.
	uint next_input_location = 0;
	foreach (p, param : decl.function.params)
	{
		if (roles[p] != ParamRole.STAGE_INPUT) continue;
		Type* input_type = self.types.find(param.type.name);
		sz first = (sz)self.inputs.len();
		self.stage_variables(input_type, StorageClass.INPUT, &self.inputs, stage, &next_input_location, decl.line, decl.column)!;
		for (sz i = first; i < (sz)self.inputs.len(); i++) self.inputs[i].parameter = (uint)p;
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
		uint next_output_location = 0;
		self.stage_variables(return_type, StorageClass.OUTPUT, &self.outputs, stage, &next_output_location, decl.line, decl.column)!;
	}
	else if (return_type.kind != VOID)
	{
		// A bare value is the stage's single output at location 0.
		Id id = self.mod.global_var(self.pointer_to(StorageClass.OUTPUT, return_type), StorageClass.OUTPUT);
		self.mod.decorate(id, Decoration.LOCATION, 0);
		self.outputs.push({ .id = id, .type = return_type, .member_index = 0 });
		self.interface_ids.push(id);
	}

	if (stage.is_ray_tracing() && return_type.kind != VOID)
	{
		self.fail(decl.line, decl.column, string::format(self.allocator,
			"`%s` is %s shader, which returns void - what it finds goes back through the payload",
			decl.name, stage_list(stage.bit(), self.allocator)));
		return CODEGEN_ERROR~;
	}

	if (stage == Stage.VERTEX)
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

	// Rebuild each parameter struct as a local, member by member.
	foreach (p, param : decl.function.params)
	{
		Type* input_type = self.types.find(param.type.name);
		switch (roles[p])
		{
			case PAYLOAD:
			case CALLABLE_DATA:
				// The caller's payload is reached in place: whatever this
				// shader writes to it is what the caller reads back.
				StorageClass storage = roles[p] == ParamRole.PAYLOAD
					? StorageClass.INCOMING_RAY_PAYLOAD
					: StorageClass.INCOMING_CALLABLE_DATA;
				self.bind_local(param.name, input_type, self.ray_global(storage, input_type), storage);
				continue;
			case HIT_ATTRIBUTES:
				// Read-only in a hit shader (VUID-StandaloneSpirv-HitAttributeKHR-04703),
				// so the shader gets a copy it may write like any parameter.
				Id attributes = self.ray_global(StorageClass.HIT_ATTRIBUTE, input_type);
				Id copy = function.local(self.pointer_to(StorageClass.FUNCTION, input_type));
				self.mod.name(copy, param.name);
				function.store(copy, function.load(self.type_id(input_type), attributes));
				self.bind_local(param.name, input_type, copy);
				continue;
			default:
		}
		Id pointer = function.local(self.pointer_to(StorageClass.FUNCTION, input_type));
		self.mod.name(pointer, param.name);

		foreach (&input : self.inputs)
		{
			if (input.parameter != (uint)p) continue;
			Id value  = function.load(self.type_id(input.type), input.id);
			Id member = function.access_chain(
				self.pointer_to(StorageClass.FUNCTION, input.type),
				pointer,
				(Id[]) { self.const_int((int)input.member_index) });
			function.store(member, value);
		}

		self.bind_local(param.name, input_type, pointer);
	}

	self.statement(decl.function.body)!;
	if (!self.terminated) function.ret();

	function.end();
	self.func = null;

	// OpName keeps the function's own name so a disassembly maps back to the
	// source; the entry point publishes whatever the stage attribute asked for.
	// Its OpEntryPoint waits for the end of the build (see reach.c3): from
	// SPIR-V 1.4 its interface lists the globals it reaches, and only then is
	// the module's version known.
	self.mod.name(function.id, decl.name);
	Id[] io = alloc::alloc_array(self.allocator, Id, self.interface_ids.len());
	foreach (i, id : self.interface_ids) io[i] = id;
	self.entries.push({
		.stage    = stage,
		.function = function.id,
		.name     = entry_name,
		.fn_name  = decl.name,
		.io       = io,
		.reach    = self.reach,
	});
	self.reach = null;

	if (stage == Stage.FRAGMENT)
	{
		self.mod.execution_mode(function.id, ExecutionMode.ORIGIN_UPPER_LEFT);
	}
	else if (stage == Stage.COMPUTE)
	{
		Attribute* threads = decl.attributes.find( "threads");
		if (!threads || threads.args.len != 3)
		{
			self.fail(decl.line, decl.column, "a @compute entry point needs @threads(x, y, z)");
			return CODEGEN_ERROR~;
		}
		self.mod.execution_mode(function.id, ExecutionMode.LOCAL_SIZE,
			(uint)threads.args[0].number, (uint)threads.args[1].number, (uint)threads.args[2].number);

		// A kernel whose tiles are laid out for so many lanes a subgroup says so;
		// the host asks the pipeline for it (LANGUAGE.md 6.2).
		Attribute* lanes = decl.attributes.find("subgroup_size");
		if (lanes)
		{
			uint n = lanes.args.len == 1 ? (uint)lanes.args[0].number : 0;
			if (n < 4 || n > 128 || (n & (n - 1)) != 0)
			{
				self.fail(decl.line, decl.column, "@subgroup_size takes one power of two from 4 to 128");
				return CODEGEN_ERROR~;
			}
			self.mod.module_processed(string::tformat("shady.subgroup_size %d", n));
		}
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
	codegen.map       = &map;
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
	codegen.entries.init(&arena, 4);
	codegen.ray_globals.init(&arena, 4);

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
	self.check_holes()!;
	self.check_modules()!;
	self.check_required()!;
	self.assign_bindings(self.ast)!;
	self.emit_resources(self.ast)!;
	self.declare_shared(self.ast)!;

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
		Attribute* stage = stage_attribute(decl.attributes, &kind);
		if (!stage)
		{
			// An ordinary function: declared by declare_functions and emitted
			// on first call. Not an entry point, so nothing to do here.
			continue;
		}

		String entry_name = self.entry_name(decl, stage)!;
		foreach (taken : entry_names)
		{
			if (taken != entry_name) continue;
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"there is already an entry point called `%s` - the host tells them apart by name", entry_name));
			return CODEGEN_ERROR~;
		}
		entry_names.push(entry_name);

		self.emit_entry_point(decl, kind, entry_name)!;
	}

	if (!entry_names.len())
	{
		self.fail(0, 0, "the shader has no entry points");
		return CODEGEN_ERROR~;
	}

	// The whole shader has been walked: what a helper asks of its stages can be
	// asked of every entry point reaching it, the header can be finished, and
	// with the version final the entry points can say what they reach.
	self.check_entry_stages()!;
	self.finish_module();
	self.publish_entry_points();

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
