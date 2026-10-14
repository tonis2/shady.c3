<*
 AST to SPIR-V, in one pass.

 Resolution and emission happen together: there is no separate typed IR, so an
 expression's type is worked out at the moment its instructions are emitted.
 That is the whole reason this compiler is a fraction of Kongruent's size - no
 bytecode, no transform passes, no disassembler.

 Anything unsupported raises a fault with a position rather than emitting
 something plausible-looking, because a shader that miscompiles silently is far
 worse than one that refuses to build.
*>
module shady;

import std::collections::list;

faultdef CODEGEN_ERROR;

<*
 An expression's result. `pointer` is non-zero when the value is addressable,
 which is what makes it assignable.

 `storage` is the storage class `pointer` lives in. It has to be carried rather
 than looked up, because an access chain's result is a fresh id that belongs to
 no variable, and because reaching a device address changes the storage class
 mid-expression.
*>
struct Value
{
	Type* type;
	Id    id;      // the loaded value; 0 when only a pointer is held
	Id    pointer; // 0 when the value is not addressable
	StorageClass storage; // storage class of `pointer`

	// The value came from `NonUniformResourceIndex`, or is a descriptor
	// reached through one. Carried so every instruction on the way to the
	// image operation can be decorated, which is where drivers look.
	bool  non_uniform;
}

struct Local
{
	String name;
	Type*  type;
	Id     pointer;
	// Almost always Function. A ray-tracing stage's incoming payload is named
	// like a parameter but lives in its own storage class, and is reached in
	// place rather than copied.
	StorageClass storage;
}

struct Resource
{
	String    name;
	Type*     type;
	Id        id;
	StorageClass storage;
	BlockKind block;   // NONE for an opaque type, else the struct's block kind
	uint      set;
	uint      binding;
	uint      size;    // block size in bytes, for uniform and push constant blocks
}

<*
 A stage input or output variable, plus the struct member it mirrors.
*>
struct StageVar
{
	Id    id;
	Type* type;
	usz   member_index;
	// Which of the entry point's parameter structs this variable came from.
	// Zero for every stage whose interface is one struct, which is all of the
	// corpus but a fragment taking a builtin beside its varyings.
	uint  parameter;
	bool  is_position;
}

<*
 A non-entry function, with its signature resolved up front so a call to one
 declared further down the file still has something to resolve against.
*>
struct FunctionSig
{
	Decl*   decl;
	Type*   return_type;
	// Effective parameters: the receiver first for a method, then what was
	// written after it, so a call's operands line up with this list.
	Type*[] params;
	String[] names;
	bool[]  refs;   // by-reference parameters (out / inout); the receiver is separate
	bool[]  outs;   // the subset that need not be initialised
	bool    has_receiver;
	bool    receiver_ref;   // `&self` - the receiver arrives as a pointer
	String  receiver_name;  // what the receiver is called in the body
	Id      func_id;
	bool    emitted;
	bool    emitting; // set while the body is being emitted, to catch recursion

	// What the body uses and asks of its callers' stages, recorded while it
	// is emitted. Null until then.
	Reach*  reach;

	// `@required`: this module needs a definition it does not contain, and the
	// text that provides one is spliced in from elsewhere. Carried on the
	// signature rather than read off the declaration, because the declaration is
	// what the definition replaces.
	bool    required;

	// `@fallback`: a definition another one of the same signature replaces.
	bool    fallback;

	// The name is a template's hole - `@required` or `@fallback` - so every
	// definition of it must have the hole's signature rather than overload it.
	// Survives the definition that fills or replaces the hole.
	bool    hole;
	// The template's own declaration of that hole, kept when a definition takes
	// the signature's place, so a message can quote the hole rather than the
	// text that filled it.
	Decl*   hole_decl;
}

alias FunctionSigList = List{FunctionSig};
alias ValueList       = List{Value};

alias LocalList    = List{Local};
alias ResourceList = List{Resource};
alias StageVarList = List{StageVar};
alias IdListC      = List{Id};
alias UintList     = List{uint};
alias StringList   = List{String};

<*
 A module-level `const`, with the `SpecId` it was given or no spec id when it was
 not. Its id resolves wherever its name is written.

 `used` is what the warning about a spec constant nothing reads asks: a value
 the host may set that no code observes is a knob wired to nothing.
*>
struct Constant
{
	String name;
	Type*  type;
	Id     id;
	bool   is_spec;
	bool   used;
	uint   line;
	uint   column;
}
alias ConstantList = List{Constant};

struct Codegen
{
	Module*    mod;
	TypeTable* types;
	Ast*       ast;
	Allocator  allocator;
	// The `#line` regions, so a message about one declaration can name where
	// another one is - "already defined at material:3". Null when a caller
	// compiles without one; positions are then plain line numbers.
	LineMap*   map;

	ResourceList resources;
	ConstantList constants;
	LocalList    locals;
	FunctionSigList functions;
	LoopList     loops;

	Function*    func;
	Type*        fn_return;
	StageVarList inputs;
	StageVarList outputs;
	IdListC      interface_ids;
	bool         terminated; // current block already has a terminator

	// The stage of the entry point being emitted. A helper is emitted once,
	// inside the first entry point that calls it, and runs in every stage that
	// reaches it - so code inside a helper must not branch on this. A check
	// that depends on the stage goes through `require_stages`, which records it
	// on the helper and asks every entry point that reaches it.
	Stage stage;

	// The reach of the function being emitted, and the entry points waiting
	// for their `OpEntryPoint` (see reach.c3).
	Reach*          reach;
	EntryRecordList entries;

	// The payload, callable-data and hit-attribute variables the pipeline's
	// calls pass through (see ray.c3).
	RayGlobalList   ray_globals;

	Id glsl; // the GLSL.std.450 import

	<*
	 Set when the shader declares a `buffer`. The addressing model, the
	 capability and the SPIR-V version all change when it is, so it has to be
	 known before the header is written - see `compile`.
	*>
	bool uses_device_addresses;

	// An acceleration structure was declared, so the module needs one of the
	// ray capabilities even if nothing traces against it.
	bool uses_accel;

	// A ray flag that skips triangles or AABBs was named, which is a
	// capability of its own.
	bool uses_primitive_culling;

	<*
	 Lay every block out with C3's packing instead of std140/std430. Off by
	 default, so the std140/std430 rules stay the documented behavior unless a
	 compile asks for scalar.
	*>
	bool scalar_layout;

	String error;
	uint   error_line;
	uint   error_column;
	uint   error_length;

	// Non-fatal findings, appended as they are found. Null is legal: a compile
	// that was not asked for warnings finds none.
	DiagnosticList* warnings;
}

<*
 Which layout a block gets: the kind's own unless this compile asked for
 scalar, which overrides every kind the same way `-force-glsl-scalar-layout`
 does.

 Storage buffers are the exception, and the reason is the host side of the
 seam: a general-purpose compute buffer is written and read by whatever
 uploaded it, so its layout has to be the one everyone can agree on. Scalar
 packing would repack `float3` to 12 bytes and a struct of {float, float3} to
 16, which is not the layout any other tool lays data out in.
*>
fn Layout Codegen.block_layout(&self, BlockKind kind)
{
	if (kind == STORAGE) return STD430;
	return self.scalar_layout ? SCALAR : kind.layout();
}

fn void Codegen.fail(&self, uint line, uint column, String message, uint length = 0)
{
	if (self.error.len) return;
	self.error        = message;
	self.error_line   = line;
	self.error_column = column;
	self.error_length = length;
}

<*
 Where a physical line is, as a reader would name it: `material:3` inside a
 `#line` region, `line 40` outside one. For a message about one declaration
 that has to point at another.
*>
fn String Codegen.where(&self, uint physical)
{
	if (self.map)
	{
		if (LineDirective* directive = self.map.find(physical))
		{
			return string::format(self.allocator, "%s:%d", directive.name, (int)physical + directive.offset);
		}
	}
	return string::format(self.allocator, "line %d", physical);
}

<*
 A finding that is worth saying and not worth stopping for.

 The position is physical, like every other one the pass records; `compile`
 owns the map that renumbers it.
*>
fn void Codegen.warn(&self, uint line, uint column, String message, uint length = 0)
{
	if (!self.warnings) return;
	self.warnings.push({
		.kind    = WARNING,
		.message = message.copy(self.allocator),
		.line    = line,
		.column  = column,
		.length  = length,
	});
}

// --- Scope -------------------------------------------------------------------

<*
 Bring a name into scope. Every local goes through here: StorageClass's zero
 value is UniformConstant, so a local pushed without one would be reached
 through access chains of the wrong storage class.
*>
fn void Codegen.bind_local(&self, String name, Type* type, Id pointer, StorageClass storage = StorageClass.FUNCTION)
{
	self.locals.push({ .name = name, .type = type, .pointer = pointer, .storage = storage });
}

fn Local* Codegen.find_local(&self, String name)
{
	// Backwards, so an inner scope shadows an outer one.
	for (sz i = self.locals.len() - 1; i >= 0; i--)
	{
		Local* local = &self.locals[i];
		if (local.name == name) return local;
	}
	return null;
}

fn Resource* Codegen.find_resource(&self, String name)
{
	foreach (&resource : self.resources)
	{
		if (resource.name == name) return resource;
	}
	return null;
}

fn Constant* Codegen.find_constant(&self, String name)
{
	foreach (&constant : self.constants)
	{
		if (constant.name == name)
		{
			// Resolution is the only way a constant is reached, so this is
			// where "something reads it" is recorded.
			constant.used = true;
			return constant;
		}
	}
	return null;
}

// --- SPIR-V types ------------------------------------------------------------

<*
 The SPIR-V id for a shady type, emitted on first use and cached on the Type.
*>
fn Id Codegen.type_id(&self, Type* type)
{
	if (type.id != NO_ID) return type.id;

	switch (type.kind)
	{
		case VOID:    type.id = self.mod.type_void();
		case BOOL:    type.id = self.mod.type_bool();
		case INT:
		{
			type.id = self.mod.type_int(type.width(), true);
			if (type.width() == 8) self.mod.capability(Capability.INT8);
		}
		case UINT:
		{
			type.id = self.mod.type_int(type.width(), false);
			if (type.width() == 8) self.mod.capability(Capability.INT8);
		}
		case FLOAT:
		{
			type.id = self.mod.type_float(type.width());
			if (type.width() == 16) self.mod.capability(Capability.FLOAT16);
		}
		case VECTOR:  type.id = self.mod.type_vector(self.type_id(type.element), type.count);
		case MATRIX:  type.id = self.mod.type_matrix(self.type_id(type.element), type.count);
		case ARRAY:
		{
			if (type.runtime)
			{
				type.id = self.mod.type_runtime_array(self.type_id(type.element));
			}
			else
			{
				Id length = self.mod.const_u32(self.type_id(self.types.find("uint")), type.count);
				type.id = self.mod.type_array(self.type_id(type.element), length);
			}
			// The ArrayStride is a property of the block the array sits in, so
			// it is decorated by decorate_block_members, not here.
			self.mod.name(type.id, type.name);
		}
		case COOPMAT:
		{
			// The KHR shape of the type: component type, scope, rows,
			// columns. The Vulkan binding for this hardware is built from the
			// same four numbers, which is why the shape is in the name.
			Id scope_id = self.scope_constant(type.scope);
			type.id = self.mod.declare(Opcode.TYPE_COOPERATIVE_MATRIX_KHR,
				self.type_id(type.element), scope_id,
				self.mod.const_u32(self.type_id(self.types.find("uint")), type.rows),
				self.mod.const_u32(self.type_id(self.types.find("uint")), type.count),
				self.mod.const_u32(self.type_id(self.types.find("uint")), type.use));
			self.coopmat_capability();
		}
		case SAMPLER: type.id = self.mod.type_sampler();
		case SAMPLED_IMAGE: type.id = self.mod.type_sampled_image(self.image_type_id(type));
		case POINTER:
			// A buffer struct pre-declares its pointer type with
			// OpTypeForwardPointer, so it exists before this is reached. A
			// pointer to a scalar, vector or matrix is created here instead,
			// striding by the pointee's size for the same reason a buffer's is.
			if (type.element.pointer_id != NO_ID)
			{
				type.id = type.element.pointer_id;
			}
			else
			{
				type.id = self.mod.type_pointer(StorageClass.PHYSICAL_STORAGE_BUFFER, self.type_id(type.element));
				self.mod.decorate(type.id, Decoration.ARRAY_STRIDE,
					array_stride(type.element, self.block_layout(ADDRESS)));
			}
		case TEXTURE: type.id = self.image_type_id(type);
		case ACCEL:
			// No capability here: a declared resource is emitted whether or not
			// anything reads it, and which of the two ray capabilities it needs
			// depends on what does. `finish_module` covers one nothing reads.
			type.id = self.mod.unique(Opcode.TYPE_ACCELERATION_STRUCTURE_KHR);
			self.uses_accel = true;
		case RAY_QUERY:
			type.id = self.mod.unique(Opcode.TYPE_RAY_QUERY_KHR);
			self.ray_query_capability();
		case STRUCT:
			@pool() {
				Id[] members = alloc::alloc_array(tmem, Id, type.members.len);
				foreach (i, &m : type.members) members[i] = self.type_id(m.type);
				type.id = self.mod.type_struct(members);
			};
			self.mod.name(type.id, type.name);
			foreach (i, &m : type.members) self.mod.member_name(type.id, (uint)i, m.name);
	}

	return type.id;
}

<*
 The OpTypeImage behind a texture or a combined sampler, declaring the
 capability its shape needs. Neither of these is implied by Shader: a 1D image
 needs Sampled1D, which the validator checks, and a cube array needs
 SampledCubeArray, which it does not - a driver handed one without it may
 refuse the module, and the host has to enable `imageCubeArray` either way.
*>
fn Id Codegen.image_type_id(&self, Type* type)
{
	if (type.dim == Dim.D1) self.mod.capability(Capability.SAMPLED_1D);
	if (type.dim == Dim.CUBE && type.arrayed) self.mod.capability(Capability.SAMPLED_CUBE_ARRAY);
	return self.mod.type_image(self.type_id(type.element.element), type.dim, type.depth, type.arrayed);
}

<*
 Load a descriptor - a texture, a sampler, a combined sampler - from its
 variable or its slot in a descriptor array, carrying a non-uniform index's
 decoration onto the loaded value.
*>
fn Id Codegen.load_descriptor(&self, Value descriptor)
{
	Id id = self.func.load(self.type_id(descriptor.type), descriptor.pointer);
	if (descriptor.non_uniform) self.mod.decorate(id, Decoration.NON_UNIFORM);
	return id;
}

fn Id Codegen.pointer_to(&self, StorageClass storage_class, Type* type)
{
	return self.mod.type_pointer(storage_class, self.type_id(type));
}

<*
 A written type, resolved: an array wraps its element, and `T*` wraps an
 `@address` struct or a scalar, vector or matrix. An array's stride is not
 decided here - the block that contains it lays it out later.
*>
fn Type*? Codegen.resolve_type(&self, TypeRef ref, uint line, uint column)
{
	if (ref.is_coopmat) return self.resolve_coopmat(ref, line, column);

	Type* type = self.types.find(ref.name);
	if (!type)
	{
		self.fail(line, column, string::format(self.allocator, "unknown type `%s`", ref.name));
		return CODEGEN_ERROR~;
	}

	if (ref.is_array)
	{
		if (ref.is_pointer)
		{
			self.fail(line, column, "an array of device-address pointers is not supported");
			return CODEGEN_ERROR~;
		}
		Type* array = self.types.array_of(type, ref.array_size);
		// A length of zero is `T[]`: a runtime-sized array, which is only legal
		// as a module-level resource or a member of an @storage block.
		array.runtime = ref.array_size == 0;
		return array;
	}

	if (ref.is_pointer)
	{
		// A device address may point at an @address struct, or at a plain
		// scalar, vector or matrix: a mesh's streams are flat arrays of float3,
		// uint4 and float4x4, not arrays of structs.
		bool addressable = type.kind == VECTOR || type.kind == MATRIX || type.is_scalar()
			|| (type.kind == STRUCT && type.block == ADDRESS);
		if (type.contains_bool() && type.kind != STRUCT)
		{
			self.fail(line, column, string::format(self.allocator,
				"`%s*` cannot be a device address - a bool has no layout in memory; point at a `uint`", type.name));
			return CODEGEN_ERROR~;
		}
		if (!addressable)
		{
			if (type.kind == STRUCT)
			{
				self.fail(line, column, string::format(self.allocator,
					"`%s*` is not a device address - mark `%s` with @address to give it one",
					type.name, type.name));
			}
			else
			{
				self.fail(line, column, string::format(self.allocator,
					"`%s*` cannot be a device address", type.name));
			}
			return CODEGEN_ERROR~;
		}
		return self.types.pointer_to(type);
	}

	return type;
}

// --- Constants ---------------------------------------------------------------

<*
 An untyped integer literal takes the kind of the other side: `u & 1` is a uint
 operation, `v * 2` multiplies floats, and `bits <<= 2` shifts by a uint. That
 is the one implicit conversion the language has (LANGUAGE.md 5.3) - everything
 else has to say what it means with a cast.
*>
fn Value Codegen.adapt_literal(&self, Value value, Expr* side, Type* other)
{
	if (side.kind != INT_LITERAL || value.type.kind != INT && value.type.kind != UINT) return value;

	switch (other.scalar().kind)
	{
		case UINT:
		{
			Type* uint_t = self.types.find("uint");
			return (Value) { .type = uint_t, .id = self.mod.const_u32(self.type_id(uint_t), (uint)side.literal.value) };
		}
		case FLOAT:
			return (Value) { .type = self.types.find("float"), .id = self.const_float(side.literal.value) };
		default:
			return value;
	}
}

<*
 Which instruction a builtin that has one per number family uses.

 `GLSL.std.450` spells `min` three times - `FMin`, `UMin` and `SMin` - and each
 one takes only its own operands, so an integer `min` compiled as `FMin` is
 invalid SPIR-V rather than a slow path. A uint has no `abs` or `sign` in
 GLSL.std.450 at all, so `builtin_call` answers those two itself before it gets
 here; the unsigned choice of either is never taken.
*>
fn GlslOp Codegen.by_sign(&self, GlslOp floats, GlslOp unsigned, GlslOp signed, Type* result)
{
	switch (result.scalar().kind)
	{
		case UINT: return unsigned;
		case INT:  return signed;
		default:   return floats;
	}
}

fn Id Codegen.const_float(&self, double value)
{
	return self.mod.const_f32(self.type_id(self.types.find("float")), (float)value);
}

fn Id Codegen.const_int(&self, int value)
{
	return self.mod.const_i32(self.type_id(self.types.find("int")), value);
}

// --- Expressions -------------------------------------------------------------

<*
 Materialise a value: loads through the pointer when only an address is held.
*>
fn Id Codegen.rvalue(&self, Value value)
{
	if (value.id != NO_ID) return value.id;

	// A matrix behind a device address is read a column at a time. SPIR-V gives
	// a matrix its layout with `ColMajor` and `MatrixStride`, and both are
	// *member* decorations - a bare pointer has no member to carry them, so a
	// matrix load through one leaves the stride unspecified and the hardware
	// reads every column from the first one's address. Four loads at the
	// column stride and a construct say the same thing without a decoration to
	// hang it on. A matrix in a struct is the ordinary case and stays a load:
	// its member decorations are what describe it.
	if (value.type.kind == MATRIX && value.storage == StorageClass.PHYSICAL_STORAGE_BUFFER)
	{
		Type* column = value.type.element;
		uint  stride = value.type.matrix_stride(self.block_layout(ADDRESS));

		Id[] columns = alloc::alloc_array(tmem, Id, value.type.count);
		for (uint i = 0; i < value.type.count; i++)
		{
			Id pointer = self.offset_pointer(value.pointer, column, i * stride);
			columns[i] = self.func.load(self.type_id(column), pointer, self.access_alignment(value));
		}
		return self.func.composite_construct(self.type_id(value.type), columns);
	}

	return self.func.load(self.type_id(value.type), value.pointer, self.access_alignment(value));
}

<*
 Write `value` through `target`'s pointer.

 A matrix behind a device address is written a column at a time, for the reason
 `rvalue` reads one that way.
*>
fn void Codegen.store(&self, Value target, Id value)
{
	if (target.type.kind != MATRIX || target.storage != StorageClass.PHYSICAL_STORAGE_BUFFER)
	{
		self.func.store(target.pointer, value, self.access_alignment(target));
		return;
	}

	Type* column = target.type.element;
	uint  stride = target.type.matrix_stride(self.block_layout(ADDRESS));

	for (uint i = 0; i < target.type.count; i++)
	{
		Id pointer = self.offset_pointer(target.pointer, column, i * stride);
		Id part    = self.func.composite_extract(self.type_id(column), value, i);
		self.func.store(pointer, part, self.access_alignment(target));
	}
}

<*
 The address `base_pointer + offset` bytes along, as a pointer to `type`.

 A device address is arithmetic the shader does itself: nothing describes the
 layout to the hardware, so even a constant offset is an instruction.
*>
fn Id Codegen.offset_pointer(&self, Id base_pointer, Type* type, uint offset)
{
	Id ulong_t = self.mod.type_int(64, false);
	Id address = self.func.unop(Opcode.CONVERT_PTR_TO_U, ulong_t, base_pointer);
	if (offset)
	{
		address = self.func.binop(Opcode.I_ADD, ulong_t, address, self.mod.const_u64(ulong_t, offset));
	}
	Id pointer_type = self.mod.type_pointer(StorageClass.PHYSICAL_STORAGE_BUFFER, self.type_id(type));
	return self.func.unop(Opcode.CONVERT_U_TO_PTR, pointer_type, address);
}

<*
 The `Aligned` operand a load or store through this value's pointer needs.

 Zero means no memory operand at all, which is right for every storage class
 the driver knows the layout of. A device address is the exception: nothing
 describes it to the hardware, so the shader states the alignment itself. The
 type's own std430 alignment is the answer, and it holds as long as the host
 aligns the buffer to the pointee's alignment - see LANGUAGE.md section 10.
*>
fn uint Codegen.access_alignment(&self, Value value)
{
	if (value.storage != StorageClass.PHYSICAL_STORAGE_BUFFER) return 0;
	return value.type.align(self.block_layout(ADDRESS));
}

<*
 `p[i]` on a device address, lowered to 64-bit address arithmetic:
 `(T*)((ulong)p + i * stride)`.

 OpPtrAccessChain expresses this in one instruction and validates, but drivers
 do not reliably honour the pointer's ArrayStride: RADV silently strides by
 zero, so every index reads element 0. glslang never emits it for buffer
 references either - it emits exactly the arithmetic below - which makes this
 the path drivers are actually tested against.
*>
fn Value? Codegen.offset_address(&self, Value base, Value index, Expr* expr)
{
	Type* element = base.type.element;
	Id    ulong_t = self.mod.type_int(64, false);

	// The index is a 32-bit int or uint; widen it to the address width.
	if (!index.type.is_numeric() || index.type.kind == FLOAT)
	{
		self.fail(expr.line, expr.column, "a device address must be indexed by an integer");
		return CODEGEN_ERROR~;
	}
	Id wide;
	if (index.type.kind == INT)
	{
		// Sign-extend, then reinterpret: the arithmetic below is unsigned.
		Id long_t = self.mod.type_int(64, true);
		wide = self.func.unop(Opcode.BITCAST, ulong_t, self.func.unop(Opcode.S_CONVERT, long_t, self.rvalue(index)));
	}
	else
	{
		wide = self.func.unop(Opcode.U_CONVERT, ulong_t, self.rvalue(index));
	}

	// The element's strided size, not its bare size: under std430 a float3
	// occupies 12 bytes but the next element starts at 16.
	Id stride  = self.mod.const_u64(ulong_t, array_stride(element, self.block_layout(ADDRESS)));
	Id address = self.func.unop(Opcode.CONVERT_PTR_TO_U, ulong_t, self.rvalue(base));
	Id offset  = self.func.binop(Opcode.I_MUL, ulong_t, wide, stride);
	Id target  = self.func.binop(Opcode.I_ADD, ulong_t, address, offset);

	Id pointer_type = self.mod.type_pointer(StorageClass.PHYSICAL_STORAGE_BUFFER, self.type_id(element));
	Id pointer      = self.func.unop(Opcode.CONVERT_U_TO_PTR, pointer_type, target);

	return (Value) { .type = element, .pointer = pointer, .storage = StorageClass.PHYSICAL_STORAGE_BUFFER };
}

<*
 Reach through a device address: the pointer *value* becomes the base pointer
 for the access that follows, and the storage class changes with it.

 Returns false when `value` is not a pointer, so callers can fall through to
 ordinary composite access.
*>
fn bool Codegen.deref(&self, Value value, Value* out)
{
	if (value.type.kind != POINTER) return false;
	*out = {
		.type    = value.type.element,
		.pointer = self.rvalue(value),
		.storage = StorageClass.PHYSICAL_STORAGE_BUFFER,
	};
	return true;
}

fn Value? Codegen.expression(&self, Expr* expr)
{
	switch (expr.kind)
	{
		case INT_LITERAL:
			Type* type = self.types.find(expr.literal.is_unsigned ? "uint" : "int");
			return (Value) { .type = type, .id = self.mod.const_u32(self.type_id(type), (uint)expr.literal.value) };

		case FLOAT_LITERAL:
			Type* type = self.types.find("float");
			return (Value) { .type = type, .id = self.const_float(expr.literal.value) };

		case BOOL_LITERAL:
			Type* type = self.types.find("bool");
			Id    id   = expr.boolean.value ? self.mod.const_true(self.type_id(type)) : self.mod.const_false(self.type_id(type));
			return (Value) { .type = type, .id = id };

		case IDENT:
			if (Local* local = self.find_local(expr.ident.name))
			{
				return (Value) { .type = local.type, .pointer = local.pointer, .storage = local.storage };
			}
			if (Constant* constant = self.find_constant(expr.ident.name))
			{
				return (Value) { .type = constant.type, .id = constant.id };
			}
			if (Resource* resource = self.find_resource(expr.ident.name))
			{
				self.use_global(resource.id);
				// Textures and samplers stay as pointers; they are only ever
				// loaded at the point of sampling.
				return (Value) { .type = resource.type, .pointer = resource.id, .storage = resource.storage };
			}
			uint ray_value;
			bool culls;
			if (ray_constant(expr.ident.name, &ray_value, &culls))
			{
				if (culls) self.uses_primitive_culling = true;
				Type* uint_t = self.types.find("uint");
				return (Value) { .type = uint_t, .id = self.mod.const_u32(self.type_id(uint_t), ray_value) };
			}
			self.fail(expr.line, expr.column,
				string::format(self.allocator, "unknown name `%s`", expr.ident.name),
				(uint)expr.ident.name.len);
			return CODEGEN_ERROR~;

		case MEMBER:
			return self.member_expression(expr);

		case INDEX:
			return self.index_expression(expr);

		case CONDITIONAL:
			return self.conditional_expression(expr);

		case CAST:
			return self.cast_expression(expr);

		case UPDATE:
			return self.update_expression(expr);

		case INITIALIZER:
			self.fail(expr.line, expr.column, "an initialiser is only valid in a declaration");
			return CODEGEN_ERROR~;

		case CALL:
			return self.call_expression(expr);

		case UNARY:
		case REFERENCE:
			return self.unary_expression(expr);

		case BINARY:
			return self.binary_expression(expr);

		case ASSIGN:
			return self.assign_expression(expr);
	}
}

fn Value? Codegen.member_expression(&self, Expr* expr)
{
	Value base = self.expression(expr.member.value)!;

	// `p.member` on a device address reads through it, the way `->` would.
	Value through;
	if (self.deref(base, &through)) base = through;

	// A swizzle on a vector.
	if (base.type.kind == VECTOR)
	{
		uint[4] indices;
		uint    count;
		if (!swizzle_indices(expr.member.name, &indices, &count))
		{
			self.fail(expr.line, expr.column,
				string::format(self.allocator, "`%s` is not a valid swizzle (do not mix xyzw with rgba)", expr.member.name));
			return CODEGEN_ERROR~;
		}
		for (uint i = 0; i < count; i++)
		{
			if (indices[i] >= base.type.count)
			{
				self.fail(expr.line, expr.column,
					string::format(self.allocator, "swizzle `%s` reaches past a %s", expr.member.name, base.type.name));
				return CODEGEN_ERROR~;
			}
		}

		Id source = self.rvalue(base);

		if (count == 1)
		{
			Type* scalar = base.type.element;
			return (Value) { .type = scalar, .id = self.func.composite_extract(self.type_id(scalar), source, indices[0]) };
		}

		Type* result = self.vector_of(base.type.element, count);
		return (Value) { .type = result, .id = self.shuffle(result, source, &indices, count) };
	}

	if (base.type.kind != STRUCT)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "`%s` has no members", base.type.name));
		return CODEGEN_ERROR~;
	}

	usz index = base.type.member_index(expr.member.name);
	if (index == (usz)-1)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "`%s` has no member `%s`", base.type.name, expr.member.name));
		return CODEGEN_ERROR~;
	}

	return self.member_value(base, (uint)index);
}

<*
 One member of a struct value, by index.

 The walk `member_expression` does once the member is resolved, so a caller
 that already knows which one it wants - the implicit array of a bare storage
 buffer - does not spell the access chain a second way.
*>
fn Value Codegen.member_value(&self, Value base, uint index)
{
	Type* member_type = base.type.members[index].type;

	if (base.pointer != NO_ID)
	{
		Id ptr = self.func.access_chain(self.mod.type_pointer(base.storage, self.type_id(member_type)),
			base.pointer, (Id[]) { self.const_int((int)index) });
		return (Value) { .type = member_type, .pointer = ptr, .storage = base.storage };
	}

	return (Value) { .type = member_type, .id = self.func.composite_extract(self.type_id(member_type), base.id, index) };
}

<*
 Emit a shuffle picking exactly `count` components.
*>
fn Id Codegen.shuffle(&self, Type* result, Id source, uint[4]* indices, uint count)
{
	Id type = self.type_id(result);
	switch (count)
	{
		case 2: return self.func.vector_shuffle(type, source, source, (*indices)[0], (*indices)[1]);
		case 3: return self.func.vector_shuffle(type, source, source, (*indices)[0], (*indices)[1], (*indices)[2]);
		default: return self.func.vector_shuffle(type, source, source, (*indices)[0], (*indices)[1], (*indices)[2], (*indices)[3]);
	}
}

<*
 The vector type with `count` components of `element`, e.g. float3.
*>
fn Type* Codegen.vector_of(&self, Type* element, uint count)
{
	if (count == 1) return element;
	String prefix;
	switch (element.kind)
	{
		case FLOAT: prefix = "float";
		case INT:   prefix = "int";
		case UINT:  prefix = "uint";
		default:    prefix = "bool";
	}
	return self.types.find(string::format(self.allocator, "%s%d", prefix, count));
}

<*
 `shared float tile[64];`: one workgroup's scratch space.

 SPIR-V wants the variable at module scope with the Workgroup storage class,
 and wants the array's length known - a workgroup has no unbounded memory to
 put a runtime-sized array in, so the length is checked here rather than
 discovered by a driver. Nothing else is needed: reads and writes go through
 the ordinary pointer paths, and every access from an invocation that is not
 the declaring one is the author's to serialise with `barrier`.

 The variable is a `Resource` like any other module-level name, so identifiers
 resolve through the one lookup the language already has.
*>
fn void? Codegen.declare_shared(&self, Ast* ast)
{
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.SHARED) continue;

		Type* type = self.resolve_type(decl.resource.type, decl.line, decl.column)!;
		if (type.kind == ARRAY && type.runtime)
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` needs a length - a workgroup's memory is as big as the module says it is", decl.name));
			return CODEGEN_ERROR~;
		}
		if (type.holds_handle())
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` cannot be shared - %s is a handle, not memory a workgroup can hold", decl.name,
				(type.kind == ARRAY ? type.element : type).a_name(self.allocator)));
			return CODEGEN_ERROR~;
		}

		Id pointer_type = self.mod.type_pointer(StorageClass.WORKGROUP, self.type_id(type));

		// No `ArrayStride` on the array: standalone SPIR-V validation refuses
		// an explicit layout on a Workgroup type at all, and the element type
		// already says how big the elements are.

		// No initialiser, because SPIR-V puts none on a Workgroup variable: the
		// specification gives OpVariable in Workgroup storage no initialiser
		// operand, and a driver handed one may read the variable as zeroes or
		// as anything else. Everything a shared slot holds is written by an
		// invocation that reached it, and the shader's own zeroing is the only
		// one that is guaranteed.
		Id id = self.mod.global_var(pointer_type, StorageClass.WORKGROUP);

		self.resources.push({ .name = decl.name, .type = type, .id = id, .storage = StorageClass.WORKGROUP });
	}
	return;
}

<*
 The shape of a `coopmat<T, M, N, scope>`.

 What a tile may hold is small on purpose: the byte integers the hardware's
 integer matmul takes, and the float the graphics hardware takes. A cooperative
 matrix is a promise about what the hardware can do, not a general type, and a
 shader that names a shape no driver implements is refused here with a sentence
 about the shape rather than three frames later.

 Which of those shapes a driver actually has is the host's question, answered
 through `VK_KHR_cooperative_matrix` before a pipeline is built.
*>
fn Type*? Codegen.resolve_coopmat(&self, TypeRef ref, uint line, uint column)
{
	Type* element = self.types.find(ref.coopmat_element);
	if (!element)
	{
		self.fail(line, column, string::format(self.allocator, "unknown coopmat element type `%s`", ref.coopmat_element));
		return CODEGEN_ERROR~;
	}
	// What the tile may hold: the byte integers and the 32-bit accumulator
	// they multiply into are the hardware's integer matmul, and half and float
	// are the other family. Nothing else is a shape a driver implements, so nothing
	// else is spellable.
	bool numeric = element.kind == FLOAT || element.kind == INT || element.kind == UINT;
	if (!numeric || element.count != 0 || ref.coopmat_rows == 0 || ref.coopmat_columns == 0)
	{
		self.fail(line, column, "a coopmat holds a scalar - `uint8`, `int8`, `half` or `float`");
		return CODEGEN_ERROR~;
	}

	uint scope;
	if (ref.coopmat_scope == "workgroup")
	{
		scope = 2;
	}
	else if (ref.coopmat_scope == "subgroup")
	{
		scope = 3;
	}
	else
	{
		self.fail(line, column, string::format(self.allocator,
			"`%s` is not a coopmat scope - write `workgroup` or `subgroup`", ref.coopmat_scope));
		return CODEGEN_ERROR~;
	}

	// Which side of the product the tile is: A, B, or the accumulator. It is
	// part of the tile's identity rather than a property of the call, because
	// the hardware lays the three out differently.
	uint use;
	if (ref.coopmat_use == "a")
	{
		use = 0;
	}
	else if (ref.coopmat_use == "b")
	{
		use = 1;
	}
	else if (ref.coopmat_use == "accumulator")
	{
		use = 2;
	}
	else
	{
		self.fail(line, column, string::format(self.allocator,
			"`%s` is not a coopmat use - write `a`, `b` or `accumulator`", ref.coopmat_use));
		return CODEGEN_ERROR~;
	}

	return self.types.coopmat_of(element, ref.coopmat_rows, ref.coopmat_columns, scope, use,
		ref.coopmat_scope, ref.coopmat_use);
}

<*
 The storage class a pointer id was declared with. Tracked by asking the
 resources and locals, since SPIR-V ids carry no type information here.
*>
fn Value? Codegen.index_expression(&self, Expr* expr)
{
	Value base  = self.expression(expr.index.value)!;
	Value index = self.expression(expr.index.index)!;

	// A device address indexes as an array of its pointee.
	if (base.type.kind == POINTER)
	{
		return self.offset_address(base, index, expr);
	}

	// A bare runtime-sized array is bound as the block it describes, so the
	// array is one member in - `data[i]` is the block's array indexed. The
	// wrapper is the compiler's, not the shader's, so the step is taken here
	// rather than asked of whoever wrote the declaration.
	if (base.type.kind == STRUCT && base.type.runtime_array_block)
	{
		base = self.member_value(base, 0);
	}

	if (base.type.kind != VECTOR && base.type.kind != MATRIX && base.type.kind != ARRAY)
	{
		self.fail(expr.line, expr.column, "only vectors, matrices, arrays and device addresses can be indexed");
		return CODEGEN_ERROR~;
	}

	Type* element = base.type.element;

	if (base.pointer != NO_ID)
	{
		Id ptr = self.func.access_chain(self.mod.type_pointer(base.storage, self.type_id(element)),
			base.pointer, (Id[]) { self.rvalue(index) });

		// A descriptor picked by a non-uniform index is itself non-uniform,
		// and so is everything made from it on the way to the image
		// operation - the load, the sampled image. The decoration on the
		// index alone is not what the driver reads.
		if (index.non_uniform && element.is_opaque())
		{
			// The capability is the images' alone: an acceleration structure
			// array indexed non-uniformly needs only ShaderNonUniform, which
			// NonUniformResourceIndex already declared.
			self.mod.decorate(ptr, Decoration.NON_UNIFORM);
			if (element.is_image_like()) self.mod.capability(Capability.SAMPLED_IMAGE_ARRAY_NON_UNIFORM_INDEXING);
			return (Value) { .type = element, .pointer = ptr, .storage = base.storage, .non_uniform = true };
		}
		return (Value) { .type = element, .pointer = ptr, .storage = base.storage };
	}

	self.fail(expr.line, expr.column, "indexing a temporary is not supported yet");
	return CODEGEN_ERROR~;
}

fn Value? Codegen.unary_expression(&self, Expr* expr)
{
	Value operand = self.expression(expr.unary.operand)!;
	if (operand.type.is_handle())
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"%s has no operators - it is a handle, not a value", operand.type.a_name(self.allocator)));
		return CODEGEN_ERROR~;
	}
	Id    id      = self.rvalue(operand);
	Id    type    = self.type_id(operand.type);

	switch (expr.unary.op)
	{
		case MINUS:
			bool is_float = operand.type.scalar().kind == FLOAT;
			if (operand.type.kind == MATRIX)
			{
				// OpFNegate takes scalars and vectors, so a matrix negates a
				// column at a time, like its other arithmetic.
				return (Value) { .type = operand.type, .id = self.matrix_columns(Opcode.F_NEGATE, operand.type, id, operand.type, NO_ID, null) };
			}
			return (Value) { .type = operand.type, .id = self.func.unop(is_float ? Opcode.F_NEGATE : Opcode.S_NEGATE, type, id) };
		case BANG:
			return (Value) { .type = operand.type, .id = self.func.unop(Opcode.LOGICAL_NOT, type, id) };
		case AMP:
		{
			// `&x` is an address, and an address in this language is a
			// Function-storage pointer to the value. An lvalue already has
			// one; a temporary gets a local to live in, so the address is
			// still of something that exists.
			if (operand.pointer != NO_ID)
			{
				return (Value) { .type = operand.type, .pointer = operand.pointer, .storage = operand.storage };
			}
			Id local = self.func.local(self.pointer_to(StorageClass.FUNCTION, operand.type));
			self.func.store(local, id);
			return (Value) { .type = operand.type, .pointer = local, .storage = StorageClass.FUNCTION };
		}
		default:
			self.fail(expr.line, expr.column, "unsupported unary operator");
			return CODEGEN_ERROR~;
	}
}

fn Value? Codegen.assign_expression(&self, Expr* expr)
{
	// `v.x = a` and `v.x += a`, before the general path: a vector component is
	// an lvalue in the language, and SPIR-V has no store into a composite, so
	// the write is the whole vector with that component replaced. A
	// multi-component swizzle is *not* assignable - `v.xy = a` would need a
	// masked store - and falls through to the refusal below.
	if (expr.assign.target.kind == MEMBER)
	{
		Expr* member = expr.assign.target;
		Value base   = self.expression(member.member.value)!;
		uint[4] indices;
		uint    count;
		if (base.type.kind == VECTOR && base.pointer != NO_ID
			&& swizzle_indices(member.member.name, &indices, &count) && count == 1)
		{
			return self.assign_component(expr, member, base, indices[0]);
		}
	}

	Value target = self.expression(expr.assign.target)!;
	if (target.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "cannot assign to this expression");
		return CODEGEN_ERROR~;
	}
	if (target.type.is_handle())
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"%s cannot be assigned - it is a handle, not a value", target.type.a_name(self.allocator)));
		return CODEGEN_ERROR~;
	}

	Value value = self.expression(expr.assign.value)!;
	Id    id;

	if (expr.assign.op == EQ)
	{
		id = self.coerce(value, target.type, expr)!;
	}
	else
	{
		// `a += b` is `a = a + b`, with the same operator selection.
		TokenKind op = compound_op(expr.assign.op);
		Value current = { .type = target.type, .id = self.rvalue(target) };
		value = self.adapt_literal(value, expr.assign.value, target.type);
		id = self.arithmetic(op, current, value, expr)!;
	}

	self.store(target, id);
	return (Value) { .type = target.type, .id = id };
}

<*
 `v[i] = a`: read the component, work out its new value, write the vector back.

 `member` is the swizzle expression, kept for its position in a diagnostic.
*>
fn Value? Codegen.assign_component(&self, Expr* expr, Expr* member, Value base, uint index)
{
	Type* scalar = base.type.element;
	if (index >= base.type.count)
	{
		self.fail(member.line, member.column,
			string::format(self.allocator, "swizzle `%s` reaches past a %s", member.member.name, base.type.name));
		return CODEGEN_ERROR~;
	}

	Id   current = self.rvalue(base);
	Id   part    = self.func.composite_extract(self.type_id(scalar), current, index);
	Id[] operands = alloc::alloc_array(tmem, Id, 2);
	Value value = self.expression(expr.assign.value)!;

	Id id;
	if (expr.assign.op == EQ)
	{
		id = self.coerce(value, scalar, expr)!;
	}
	else
	{
		Value now = { .type = scalar, .id = part };
		value = self.adapt_literal(value, expr.assign.value, scalar);
		id = self.arithmetic(compound_op(expr.assign.op), now, value, expr)!;
	}

	Id updated = self.func.composite_insert(self.type_id(base.type), current, id, index);
	self.func.store(base.pointer, updated, self.access_alignment(base));
	return (Value) { .type = scalar, .id = id };
}

<*
 The binary operator an assignment operator stands for, so `v.x += a` and
 `v += a` pick the same instruction.
*>
fn TokenKind compound_op(TokenKind assign_op) @private
{
	switch (assign_op)
	{
		case PLUS_EQ:  return PLUS;
		case MINUS_EQ: return MINUS;
		case STAR_EQ:  return STAR;
		case SLASH_EQ: return SLASH;
		case AMP_EQ:   return AMP;
		case PIPE_EQ:  return PIPE;
		case CARET_EQ: return CARET;
		case SHL_EQ:   return SHL;
		case SHR_EQ:   return SHR;
		default:       return PERCENT;
	}
}

<*
 `condition ? then : else`, lowered to a real branch so only the taken arm runs.

 The result is written to a local in each arm and read back at the merge, which
 is also why a ternary is addressable.
*>
fn Value? Codegen.conditional_expression(&self, Expr* expr)
{
	Value condition = self.expression(expr.conditional.condition)!;
	// Materialise the test before the merge: SPIR-V requires the merge to be
	// immediately followed by the branch, and loading a bool local is an
	// instruction like any other.
	Id    test = self.condition(condition, expr.conditional.condition);

	Id then_label  = self.func.new_label();
	Id else_label  = self.func.new_label();
	Id merge_label = self.func.new_label();

	Id    pointer = NO_ID;
	Type* result  = null;

	self.func.selection_merge(merge_label);
	self.func.branch_conditional(test, then_label, else_label);

	self.func.label(then_label);
	self.terminated = false;
	Value then_value = self.expression(expr.conditional.then_value)!;
	result  = then_value.type;
	if (result.is_handle())
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`?:` cannot choose %s - it is a handle, not a value; branch with `if` instead", result.a_name(self.allocator)));
		return CODEGEN_ERROR~;
	}
	pointer = self.func.local(self.pointer_to(StorageClass.FUNCTION, result));
	self.func.store(pointer, self.coerce(then_value, result, expr.conditional.then_value)!);
	if (!self.terminated) self.func.branch(merge_label);

	self.func.label(else_label);
	self.terminated = false;
	Value else_value = self.expression(expr.conditional.else_value)!;
	self.func.store(pointer, self.coerce(else_value, result, expr.conditional.else_value)!);
	if (!self.terminated) self.func.branch(merge_label);

	// Unlike an if, both arms always reach the merge: an expression cannot
	// return or break, so the merge is never the unreachable kind.
	self.func.label(merge_label);
	self.terminated = false;
	return (Value) { .type = result, .pointer = pointer, .storage = StorageClass.FUNCTION };
}

<*
 A C-style cast. Unlike a constructor, a cast may narrow: `(float3x3)mat4`
 drops the fourth column and the fourth row.
*>
fn Value? Codegen.cast_expression(&self, Expr* expr)
{
	Type* target = self.types.find(expr.cast_expr.type.name);
	if (!target)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "unknown type `%s`", expr.cast_expr.type.name));
		return CODEGEN_ERROR~;
	}
	Value value = self.expression(expr.cast_expr.value)!;
	return self.cast_value(value, target, expr);
}

fn Value? Codegen.cast_value(&self, Value value, Type* target, Expr* expr)
{
	Type* from = value.type;
	if (from == target) return value;
	Id id = self.rvalue(value);

	if (from.is_scalar() && target.is_scalar())
	{
		return (Value) { .type = target, .id = self.convert_scalar(id, from, target) };
	}

	if (target.kind == VECTOR && from.is_scalar())
	{
		Id component = self.convert_scalar(id, from, target.element);
		return (Value) { .type = target, .id = self.splat(target, component) };
	}

	if (target.is_scalar() && from.kind == VECTOR)
	{
		Id first = self.func.composite_extract(self.type_id(from.element), id, 0);
		return (Value) { .type = target, .id = self.convert_scalar(first, from.element, target) };
	}

	if (target.kind == VECTOR && from.kind == VECTOR)
	{
		uint count = target.count < from.count ? target.count : from.count;
		Id[] components = self.new_ids(count);
		for (uint i = 0; i < count; i++)
		{
			Id component = self.func.composite_extract(self.type_id(from.element), id, i);
			components[i] = self.convert_scalar(component, from.element, target.element);
		}
		return (Value) { .type = target, .id = self.func.composite_construct(self.type_id(target), components) };
	}

	if (target.kind == MATRIX && from.kind == MATRIX)
	{
		uint columns = target.count < from.count ? target.count : from.count;
		Id[] result = self.new_ids(columns);
		for (uint i = 0; i < columns; i++)
		{
			Id column = self.func.composite_extract(self.type_id(from.element), id, i);
			result[i] = self.cast_column(column, from.element, target.element);
		}
		return (Value) { .type = target, .id = self.func.composite_construct(self.type_id(target), result) };
	}

	self.fail(expr.line, expr.column,
		string::format(self.allocator, "cannot cast a %s to a %s", from.name, target.name));
	return CODEGEN_ERROR~;
}

<*
 One column of a matrix cast: convert components, keep or drop the tail.
*>
fn Id Codegen.cast_column(&self, Id column, Type* from, Type* to)
{
	if (from == to) return column;

	uint count = to.count < from.count ? to.count : from.count;
	Id[] components = self.new_ids(count);
	for (uint i = 0; i < count; i++)
	{
		Id component = self.func.composite_extract(self.type_id(from.element), column, i);
		components[i] = self.convert_scalar(component, from.element, to.element);
	}
	return self.func.composite_construct(self.type_id(to), components);
}

<*
 `++x` / `x++` / `--x` / `x--`. The target is updated in place; `prefix`
 decides whether the expression's value is the new one or the old one.
*>
fn Value? Codegen.update_expression(&self, Expr* expr)
{
	Value target = self.expression(expr.update.target)!;
	if (target.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "cannot update this expression");
		return CODEGEN_ERROR~;
	}

	Id    old = self.rvalue(target);
	Value one = { .type = target.type, .id = self.one_like(target.type) };
	Value now = { .type = target.type, .id = old };

	TokenKind op = expr.update.op == PLUS_PLUS ? PLUS : MINUS;
	Id updated = self.arithmetic(op, now, one, expr)!;
	self.func.store(target.pointer, updated, self.access_alignment(target));

	return (Value) { .type = target.type, .id = expr.update.prefix ? updated : old };
}

fn Id Codegen.one_like(&self, Type* type)
{
	Type* scalar = type.scalar();
	Id one;
	if (scalar.kind == FLOAT)
	{
		one = self.const_float(1.0);
	}
	else if (scalar.kind == UINT)
	{
		one = self.mod.const_u32(self.type_id(scalar), 1);
	}
	else
	{
		one = self.const_int(1);
	}

	if (type.kind == VECTOR) return self.splat(type, one);
	return one;
}

fn Value? Codegen.binary_expression(&self, Expr* expr)
{
	Value left  = self.expression(expr.binary.left)!;
	Value right = self.expression(expr.binary.right)!;
	left  = self.adapt_literal(left, expr.binary.left, right.type);
	right = self.adapt_literal(right, expr.binary.right, left.type);
	Id    id    = self.arithmetic(expr.binary.op, left, right, expr)!;

	Type* result = self.result_type(expr.binary.op, left.type, right.type);
	return (Value) { .type = result, .id = id };
}

<*
 Apply a component-wise operator to a matrix, a column at a time.

 SPIR-V's `OpFAdd`, `OpFSub`, `OpFDiv` and `OpFNegate` take scalars and vectors
 only, so a matrices' worth of any of them is a miscompile the validator
 catches - as it caught `matrix + matrix` once. `OpCompositeExtract`/`Construct`
 is how the columns come apart and go back together.

 Either side may be a matrix of the result's type or a float, which is splatted
 to a column; `m / 2.0` and `1.0 - m` are both GLSL's component-wise forms. A
 null `right_type` makes the operator unary, which is how `-m` is spelled.
*>
fn Id Codegen.matrix_columns(&self, Opcode op, Type* matrix, Id left, Type* left_type, Id right, Type* right_type)
{
	Id column_type = self.type_id(matrix.element);
	Id left_splat  = left_type.kind == MATRIX ? NO_ID : self.splat(matrix.element, left);
	Id right_splat = !right_type || right_type.kind == MATRIX ? NO_ID : self.splat(matrix.element, right);
	@pool() {
		Id[] columns = alloc::alloc_array(tmem, Id, (sz)matrix.count);
		for (uint i = 0; i < matrix.count; i++)
		{
			Id a = left_splat != NO_ID ? left_splat : self.func.composite_extract(column_type, left, i);
			if (!right_type)
			{
				columns[i] = self.func.unop(op, column_type, a);
				continue;
			}
			Id b = right_splat != NO_ID ? right_splat : self.func.composite_extract(column_type, right, i);
			columns[i] = self.func.binop(op, column_type, a, b);
		}
		return self.func.composite_construct(self.type_id(matrix), columns);
	};
}

<*
 The type an operator produces. Comparisons yield bool; matrix products follow
 the column-vector convention.
*>
fn Type* Codegen.result_type(&self, TokenKind op, Type* left, Type* right)
{
	switch (op)
	{
		case EQ_EQ:
		case BANG_EQ:
		case LT:
		case LT_EQ:
		case GT:
		case GT_EQ:
		case AMP_AMP:
		case PIPE_PIPE:
			// A comparison of vectors yields a bool vector of the same shape;
			// SPIR-V requires the result and operands to match.
			return left.kind == VECTOR
				? self.vector_of(self.types.find("bool"), left.count)
				: self.types.find("bool");
		default:
			break;
	}

	if (left.kind == MATRIX && right.kind == VECTOR) return right;  // OpMatrixTimesVector
	if (left.kind == MATRIX && right.kind == MATRIX) return left;
	if (left.kind == MATRIX && right.is_scalar())    return left;
	if (left.is_scalar() && right.kind == MATRIX)    return right;  // OpMatrixTimesScalar
	if (left.is_scalar() && right.kind == VECTOR)    return right;
	return left;
}

<*
 Emit an arithmetic or comparison instruction, choosing the opcode from the
 operand types. This is where float and int operations diverge, and where the
 matrix products get picked up.
*>
fn Id? Codegen.arithmetic(&self, TokenKind op, Value left, Value right, Expr* expr)
{
	Id left_id  = self.rvalue(left);
	Id right_id = self.rvalue(right);

	Type* lt = left.type;
	Type* rt = right.type;

	// Matrix products first: they are the one case where the operand types
	// pick a completely different opcode rather than a signed/unsigned variant.
	if (op == STAR)
	{
		if (lt.kind == MATRIX && rt.kind == VECTOR)
		{
			return self.func.binop(Opcode.MATRIX_TIMES_VECTOR, self.type_id(rt), left_id, right_id);
		}
		if (lt.kind == MATRIX && rt.kind == MATRIX)
		{
			return self.func.binop(Opcode.MATRIX_TIMES_MATRIX, self.type_id(lt), left_id, right_id);
		}
		if (lt.kind == VECTOR && rt.kind == MATRIX)
		{
			return self.func.binop(Opcode.VECTOR_TIMES_MATRIX, self.type_id(lt), left_id, right_id);
		}
		if (lt.kind == MATRIX && rt.is_scalar())
		{
			return self.func.binop(Opcode.MATRIX_TIMES_SCALAR, self.type_id(lt), left_id, right_id);
		}
		if (lt.is_scalar() && rt.kind == MATRIX)
		{
			// `OpMatrixTimesScalar` takes the matrix first, whichever side the
			// scalar was written on.
			return self.func.binop(Opcode.MATRIX_TIMES_SCALAR, self.type_id(rt), right_id, left_id);
		}
		if (lt.kind == VECTOR && rt.is_scalar())
		{
			return self.func.binop(Opcode.VECTOR_TIMES_SCALAR, self.type_id(lt), left_id, right_id);
		}
	}

	// The products are done; what is left of a matrix's arithmetic is
	// component-wise, and SPIR-V has none of it for matrices, so it goes a
	// column at a time. The other side is the same matrix type or a float.
	// Anything else - a comparison, `%`, a bitwise operator - has no meaning
	// on a matrix and is refused rather than emitted for the validator.
	if (lt.kind == MATRIX || rt.kind == MATRIX)
	{
		Type* matrix = lt.kind == MATRIX ? lt : rt;
		Type* other  = lt.kind == MATRIX ? rt : lt;
		bool  fits   = other == matrix || (other.is_scalar() && other.kind == FLOAT && other.width() == 32);
		Opcode column_op;
		switch (op)
		{
			case PLUS:  column_op = Opcode.F_ADD;
			case MINUS: column_op = Opcode.F_SUB;
			case SLASH: column_op = Opcode.F_DIV;
			default:    fits = false;
		}
		if (!fits)
		{
			self.fail(expr.line, expr.column, string::format(self.allocator,
				"a %s cannot be used with a %s here - a matrix takes + - and / with a matrix of its type or a float, and * as a product",
				lt.name, rt.name));
			return CODEGEN_ERROR~;
		}
		return self.matrix_columns(column_op, matrix, left_id, lt, right_id, rt);
	}

	// Broadcast a scalar against a vector for the component-wise operators.
	if (lt.kind == VECTOR && rt.is_scalar())
	{
		right_id = self.splat(lt, right_id);
		rt       = lt;
	}
	else if (rt.kind == VECTOR && lt.is_scalar())
	{
		left_id = self.splat(rt, left_id);
		lt      = rt;
	}

	// The two sides have to agree: only literals are converted implicitly
	// (LANGUAGE.md 5.3), so a `uint` next to a `float` is refused here rather
	// than carried into an instruction whose operands do not match its type.
	// That mismatch is invalid SPIR-V, and a driver that is handed one may do
	// anything - RADV crashes rather than reporting it. The width is part of
	// the type: a half next to a float, or a byte next to a uint, is the same
	// mismatch as a uint next to a float.
	if (lt.scalar().kind != rt.scalar().kind || lt.scalar().width() != rt.scalar().width())
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"cannot use a %s and a %s in one operation - convert one side explicitly",
			lt.name, rt.name));
		return CODEGEN_ERROR~;
	}

	bool is_float  = lt.scalar().kind == FLOAT;
	bool is_signed = lt.scalar().kind == INT;
	bool is_uint   = lt.scalar().kind == UINT;
	Id   type      = self.type_id(lt);
	Id   bool_type = self.type_id(self.result_type(op, lt, rt));

	switch (op)
	{
		case PLUS:    return self.func.binop(is_float ? Opcode.F_ADD : Opcode.I_ADD, type, left_id, right_id);
		case MINUS:   return self.func.binop(is_float ? Opcode.F_SUB : Opcode.I_SUB, type, left_id, right_id);
		case STAR:    return self.func.binop(is_float ? Opcode.F_MUL : Opcode.I_MUL, type, left_id, right_id);
		case SLASH:   return self.func.binop(is_float ? Opcode.F_DIV : (is_uint ? Opcode.U_DIV : Opcode.S_DIV), type, left_id, right_id);
		// `%` is C3's remainder: it takes the sign of the left side, so
		// `-7 % 3` is -1. GLSL's floored modulo is `mod()`.
		case PERCENT: return self.func.binop(is_float ? Opcode.F_REM : (is_uint ? Opcode.U_MOD : Opcode.S_REM), type, left_id, right_id);
		case AMP:     return self.func.binop(Opcode.BITWISE_AND, type, left_id, right_id);
		case PIPE:    return self.func.binop(Opcode.BITWISE_OR, type, left_id, right_id);
		case CARET:   return self.func.binop(Opcode.BITWISE_XOR, type, left_id, right_id);
		case SHL:     return self.func.binop(Opcode.SHIFT_LEFT_LOGICAL, type, left_id, right_id);
		case SHR:     return self.func.binop(is_signed ? Opcode.SHIFT_RIGHT_ARITHMETIC : Opcode.SHIFT_RIGHT_LOGICAL, type, left_id, right_id);
		case EQ_EQ:   return self.func.binop(is_float ? Opcode.F_ORD_EQUAL : Opcode.I_EQUAL, bool_type, left_id, right_id);
		case BANG_EQ: return self.func.binop(is_float ? Opcode.F_ORD_NOT_EQUAL : Opcode.I_NOT_EQUAL, bool_type, left_id, right_id);
		case LT:      return self.func.binop(is_float ? Opcode.F_ORD_LESS_THAN : (is_uint ? Opcode.U_LESS_THAN : Opcode.S_LESS_THAN), bool_type, left_id, right_id);
		case LT_EQ:   return self.func.binop(is_float ? Opcode.F_ORD_LESS_THAN_EQUAL : (is_uint ? Opcode.U_LESS_THAN_EQUAL : Opcode.S_LESS_THAN_EQUAL), bool_type, left_id, right_id);
		case GT:      return self.func.binop(is_float ? Opcode.F_ORD_GREATER_THAN : (is_uint ? Opcode.U_GREATER_THAN : Opcode.S_GREATER_THAN), bool_type, left_id, right_id);
		case GT_EQ:   return self.func.binop(is_float ? Opcode.F_ORD_GREATER_THAN_EQUAL : (is_uint ? Opcode.U_GREATER_THAN_EQUAL : Opcode.S_GREATER_THAN_EQUAL), bool_type, left_id, right_id);
		case AMP_AMP: return self.func.binop(Opcode.LOGICAL_AND, bool_type, left_id, right_id);
		case PIPE_PIPE: return self.func.binop(Opcode.LOGICAL_OR, bool_type, left_id, right_id);
		default:
			self.fail(expr.line, expr.column, "unsupported operator");
			return CODEGEN_ERROR~;
	}
}

<*
 Replicate a scalar across a vector, so `v * 2.0` and `v + 1.0` work.
*>
fn Id Codegen.splat(&self, Type* vector, Id scalar)
{
	@pool() {
		Id[] components = alloc::alloc_array(tmem, Id, vector.count);
		for (uint i = 0; i < vector.count; i++) components[i] = scalar;
		return self.func.composite_construct(self.type_id(vector), components);
	};
}

<*
 Adapt a value to an expected type. Only literal-width adjustments happen
 implicitly; anything else is the caller's job to write out (LANGUAGE.md 5.3).
*>
fn Id? Codegen.coerce(&self, Value value, Type* expected, Expr* expr)
{
	if (value.type == expected) return self.rvalue(value);

	// An integer literal in a float slot becomes a float.
	if (expected.kind == FLOAT && value.type.kind == INT)
	{
		return self.func.unop(Opcode.CONVERT_S_TO_F, self.type_id(expected), self.rvalue(value));
	}
	// int and uint are both 32 bits, so moving between them is a reinterpretation
	// and not a conversion - which is why `uint i = 0;` is allowed, as in C.
	//
	// The widths must match for that to be true. Assigning a 32-bit value to an
	// 8-bit slot is a *narrowing*, and one spelled by an assignment rather than
	// a conversion is one nobody asked for; `uint8(x)` is how a shader says it
	// means it.
	if ((expected.kind == UINT && value.type.kind == INT)
		|| (expected.kind == INT && value.type.kind == UINT))
	{
		if (expected.width() != value.type.width())
		{
			self.fail(expr.line, expr.column, string::format(self.allocator,
				"cannot use a %s where a %s is expected - write `%s(x)` to narrow it",
				value.type.name, expected.name, expected.name));
			return CODEGEN_ERROR~;
		}
		return self.func.unop(Opcode.BITCAST, self.type_id(expected), self.rvalue(value));
	}
	if (expected.kind == VECTOR && value.type.is_scalar())
	{
		return self.splat(expected, self.rvalue(value));
	}

	// A narrower integer slot is the one of these a shader hits by writing an
	// assignment it meant as a conversion, so the refusal says which
	// conversion.
	if (expected.is_numeric() && value.type.is_numeric() && expected.width() < value.type.width())
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"cannot use a %s where a %s is expected - write `%s(x)` to narrow it",
			value.type.name, expected.name, expected.name));
		return CODEGEN_ERROR~;
	}

	self.fail(expr.line, expr.column,
		string::format(self.allocator, "cannot use a %s where a %s is expected", value.type.name, expected.name));
	return CODEGEN_ERROR~;
}

// --- User functions ----------------------------------------------------------

fn Id[] Codegen.new_ids(&self, usz len)
{
	if (len == 0) return {};
	return alloc::alloc_array(self.allocator, Id, (sz)len);
}

fn Type*[] Codegen.new_types(&self, usz len)
{
	if (len == 0) return {};
	return alloc::alloc_array(self.allocator, Type*, (sz)len);
}

fn String[] Codegen.new_names(&self, usz len)
{
	if (len == 0) return {};
	return alloc::alloc_array(self.allocator, String, (sz)len);
}

fn bool[] Codegen.new_bools(&self, usz len)
{
	if (len == 0) return {};
	return alloc::alloc_array(self.allocator, bool, (sz)len);
}

<*
 Resolve every non-entry function's signature before any body is emitted.

 A body may call a function declared after it, so the whole list is built first;
 this is the function-level analogue of `declare_structs`.
*>
fn void? Codegen.declare_functions(&self, Ast* ast)
{
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.FUNCTION) continue;
		Stage stage;
		if (stage_attribute(decl.attributes, &stage)) continue;

		Type* return_type = self.types.find(decl.function.return_type.name);
		if (!return_type)
		{
			self.fail(decl.line, decl.column,
				string::format(self.allocator, "unknown type `%s`", decl.function.return_type.name));
			return CODEGEN_ERROR~;
		}
		if (decl.function.return_type.is_array || decl.function.return_type.is_pointer)
		{
			self.fail(decl.line, decl.column, "a function cannot return an array or a pointer");
			return CODEGEN_ERROR~;
		}
		if (return_type.is_handle())
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"a function cannot return %s - it is a handle, not a value", return_type.a_name(self.allocator)));
			return CODEGEN_ERROR~;
		}

		Param[] written = decl.function.params;

		Type*  receiver      = null;
		bool   receiver_ref  = false;
		String receiver_name = "";
		usz    first         = 0; // where the ordinary parameters begin

		if (decl.function.receiver.len)
		{
			receiver = self.types.find(decl.function.receiver);
			if (!receiver || receiver.kind != STRUCT)
			{
				self.fail(decl.line, decl.column, string::format(self.allocator,
					"`%s` is not a struct, so it cannot be a method receiver", decl.function.receiver));
				return CODEGEN_ERROR~;
			}
			if (written.len == 0)
			{
				self.fail(decl.line, decl.column, string::format(self.allocator,
					"`%s.%s` needs a receiver parameter", receiver.name, decl.name));
				return CODEGEN_ERROR~;
			}

			if (written[0].is_self)
			{
				receiver_ref  = written[0].by_ref;
				receiver_name = written[0].name;
				first         = 1;
			}
			else
			{
				if (written[0].type.is_pointer || written[0].type.is_array)
				{
					self.fail(written[0].line, written[0].column,
						"a method receiver is a value, or `&self` for a reference");
					return CODEGEN_ERROR~;
				}
				Type* declared = self.types.find(written[0].type.name);
				if (!declared || declared != receiver)
				{
					self.fail(written[0].line, written[0].column, string::format(self.allocator,
						"the first parameter of `%s.%s` must be a %s", receiver.name, decl.name, receiver.name));
					return CODEGEN_ERROR~;
				}
				receiver_name = written[0].name;
				first         = 1;
			}
		}
		else if (written.len && written[0].is_self)
		{
			self.fail(written[0].line, written[0].column,
				"`self` needs a receiver type: write `fn R Type.name(&self, ...)`");
			return CODEGEN_ERROR~;
		}

		foreach (i, &param : written)
		{
			if ((usz)i < first || !param.is_self) continue;
			self.fail(param.line, param.column, "`self` must be the first parameter");
			return CODEGEN_ERROR~;
		}

		usz rest  = written.len - first;
		usz total = rest + (receiver ? (usz)1 : (usz)0);

		Type*[]  params = self.new_types(total);
		String[] names  = self.new_names(total);
		bool[]   refs   = self.new_bools(total);
		bool[]   outs   = self.new_bools(total);
		usz at = 0;
		if (receiver)
		{
			params[0] = receiver;
			names[0]  = receiver_name;
			at        = 1;
		}

		for (usz i = first; i < written.len; i++)
		{
			if (written[i].by_ref && written[i].type.is_pointer)
			{
				self.fail(written[i].line, written[i].column,
					"a parameter is either `out`/`inout` or a device-address pointer, not both");
				return CODEGEN_ERROR~;
			}

			if (written[i].type.is_array)
			{
				self.fail(written[i].line, written[i].column,
					"an array parameter is not supported - pass a device-address pointer");
				return CODEGEN_ERROR~;
			}
			Type* type = self.resolve_type(written[i].type, written[i].line, written[i].column)!;
			if (type.is_opaque())
			{
				self.fail(written[i].line, written[i].column, string::format(self.allocator,
					"%s cannot be a parameter - it is a descriptor, so the function names the module-level variable itself",
					type.a_name(self.allocator)));
				return CODEGEN_ERROR~;
			}
			if (type.kind == RAY_QUERY && !written[i].by_ref)
			{
				self.fail(written[i].line, written[i].column, string::format(self.allocator,
					"a RayQuery is traversal state, not a value - pass it as `inout RayQuery %s`", written[i].name));
				return CODEGEN_ERROR~;
			}
			params[at] = type;
			names[at]  = written[i].name;
			refs[at]   = written[i].by_ref;
			outs[at]   = written[i].is_out;
			at++;
		}

		// The shape of `@required` and `@fallback` - body or none, never an entry
		// point, never both - was checked when the tree was parsed.
		bool has_body = decl.function.body != null;
		bool required = decl.attributes.find("required") != null;
		bool fallback = decl.attributes.find("fallback") != null;

		FunctionSig sig = {
			.decl          = decl,
			.required      = required,
			.fallback      = fallback,
			.hole          = required || fallback,
			.hole_decl     = required || fallback ? decl : null,
			.return_type   = return_type,
			.params        = params,
			.names         = names,
			.refs          = refs,
			.outs          = outs,
			.has_receiver  = receiver != null,
			.receiver_ref  = receiver_ref,
			.receiver_name = receiver_name,
		};

		// Two bodies of one signature. Calls resolve across the whole program, not
		// per module, so this is asked of every definition rather than of the
		// module's own: a second body is refused where it is written - which is the
		// author's line when the second one is a spliced body - instead of as an
		// ambiguous call somewhere neither definition is. The one exception is a
		// `@fallback`, which exists to be replaced.
		if (has_body)
		{
			FunctionSig* twin = null;
			foreach (&existing : self.functions)
			{
				if (existing.decl.name != decl.name) continue;
				if (!existing.decl.function.body) continue;
				if (!signatures_agree(existing, &sig)) continue;
				twin = existing;
				break;
			}

			if (twin)
			{
				if (twin.fallback && fallback)
				{
					self.fail(decl.line, decl.column, string::format(self.allocator,
						"`%s` already has a @fallback with this signature at %s - a hole has one fallback",
						decl.name, self.where(twin.decl.line)));
					return CODEGEN_ERROR~;
				}
				if (!twin.fallback && !fallback)
				{
					self.fail(decl.line, decl.column, string::format(self.allocator,
						"`%s` is already defined with this signature at %s",
						decl.name, self.where(twin.decl.line)));
					return CODEGEN_ERROR~;
				}
				// One of the two is the fallback, and the other one wins whichever
				// came first - in the fallback's place, so the hole keeps its
				// position in the module.
				if (twin.fallback)
				{
					sig.hole      = true;
					sig.hole_decl = twin.hole_decl;
					sig.required  = twin.required;
					*twin = sig;
				}
				else
				{
					twin.hole      = true;
					twin.hole_decl = decl;
				}
				continue;
			}
		}

		// One function, declared and then defined - or one of the two, when the
		// text that defines it is spliced in from elsewhere. The two spellings
		// have to agree, so the definition cannot quietly become a second
		// function with the same name and a different signature.
		// Matched by signature, not by name: a second function of the same name and
		// a different signature is an overload, which was legal long before
		// declarations were.
		//
		// A definition fills a declaration only when both are in the same module
		// (LANGUAGE.md section 3.5): the module's files are the text a bodyless
		// declaration may be satisfied from. A declaration in no module keeps the
		// old rule - refused where it is called, checked by emit_function.
		FunctionSig* earlier = null;
		foreach (&existing : self.functions)
		{
			if (existing.decl.name != decl.name) continue;
			if (existing.decl.module_name != decl.module_name) continue;
			if (!signatures_agree(existing, &sig)) continue;
			earlier = existing;
			break;
		}

		if (!earlier)
		{
			self.functions.push(sig);
			continue;
		}

		bool earlier_has_body  = earlier.decl.function.body != null;
		bool declared_has_body = decl.function.body != null;

		// The declaration's marker survives the fill: it is a claim about the
		// module, and the definition does not withdraw it.
		sig.required = sig.required || earlier.required;
		sig.hole     = sig.hole || earlier.hole;
		if (!sig.hole_decl) sig.hole_decl = earlier.hole_decl;

		// A fallback is an answer the template already has, and `@required` says
		// the text must bring its own. Filling one with the other would make a
		// required hole optional without saying so.
		if ((sig.fallback || earlier.fallback) && sig.required)
		{
			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` is @required at %s, so a @fallback cannot fill it - drop @required to make the hole optional",
				decl.name, self.where(earlier.required ? earlier.decl.line : decl.line)));
			return CODEGEN_ERROR~;
		}

		if (earlier_has_body && declared_has_body)
		{
			// Unreachable since the twin check above, which refuses or folds every
			// pair of bodies; kept so the three cases below stay exhaustive.
			self.functions.push(sig);
			continue;
		}
		if (!earlier_has_body && !declared_has_body)
		{
			// Two interfaces may share a member signature, and that is one
			// obligation, not a duplicate declaration. A plain declaration
			// repeated still says nothing new and stays refused.
			if (decl.interface_member || earlier.decl.interface_member) continue;

			self.fail(decl.line, decl.column, string::format(self.allocator,
				"`%s` is declared twice, and nothing defines it", decl.name));
			return CODEGEN_ERROR~;
		}

		// The definition fills the declaration, in the declaration's place, so the
		// first mention of the name is still where it stands in the module.
		if (declared_has_body) *earlier = sig;
	}
}

<*
 Do two declarations describe the same function? A declaration and the definition
 that fills it do; an overload of the same name does not.
*>
fn bool signatures_agree(FunctionSig* declared, FunctionSig* defined) @private
{
	if (declared.params.len != defined.params.len) return false;
	if (declared.return_type != defined.return_type) return false;
	if (declared.has_receiver != defined.has_receiver) return false;
	if (declared.receiver_ref != defined.receiver_ref) return false;

	foreach (i, type : declared.params)
	{
		if (defined.params[i] != type) return false;
		if (declared.refs[i] != defined.refs[i]) return false;
		if (declared.outs[i] != defined.outs[i]) return false;
	}
	return true;
}

<*
 A template's hole has one signature, and every definition of its name has it.

 Without this a mistyped hole is an overload: `fn float4 shade(Surface s)` next
 to a `@fallback` `fn float3 shade(Surface s)` compiles, and the fallback is what
 runs - the author's function is never called and nothing says so. With a
 `@required` hole the same mistake was "nothing defines it", at the template's
 line, about a function the author can see they wrote. Both are refused at the
 author's definition instead, quoting the signature it has to have.

 Holes are matched by name within the module, as filling is.
*>
fn void? Codegen.check_holes(&self)
{
	foreach (&hole : self.functions)
	{
		if (!hole.hole) continue;
		foreach (&other : self.functions)
		{
			if (other == hole) continue;
			if (other.decl.name != hole.decl.name) continue;
			if (other.decl.module_name != hole.decl.module_name) continue;
			if (signatures_agree(hole, other)) continue;
			self.fail(other.decl.line, other.decl.column, string::format(self.allocator,
				"`%s` is a hole the template declares as `%s` (%s), so a definition of it must have that signature",
				hole.decl.name, hole.hole_decl.signature_text(self.allocator), self.where(hole.hole_decl.line)));
			return CODEGEN_ERROR~;
		}
	}
}

<*
 Every `@required` function has a definition.

 Asked of the signatures and not of the call sites, which is the difference
 between this and a plain declaration: a declaration nobody filled is only wrong
 if something calls it, and a *required* one is wrong because the module said it
 needs it. The ordinary declaration keeps its old behaviour - refused where it is
 called - because a module may declare a function it only sometimes provides.
*>
fn void? Codegen.check_required(&self)
{
	foreach (&sig : self.functions)
	{
		if (!sig.required || sig.decl.function.body) continue;
		// `check_holes` ran first, so a definition of this name with another
		// signature has already been named; this is the case where there is none.
		self.fail(sig.decl.line, sig.decl.column, string::format(self.allocator,
			"`%s` is @required, and nothing in this module defines it", sig.decl.name));
		return CODEGEN_ERROR~;
	}
}

<*
 Every bodyless declaration a module carries has a definition in that module.

 A module is one text made of several files (LANGUAGE.md section 3.5), so the
 check runs when the whole text is in hand: one file declares a function,
 another defines it, and both belong to the module. A declaration in no module
 keeps the older rule - refused where it is called - and `@required` keeps its
 own check, for the same reason it always had one.
*>
fn void? Codegen.check_modules(&self)
{
	foreach (&sig : self.functions)
	{
		if (sig.decl.function.body) continue;
		if (!sig.decl.module_name.len) continue;

		self.fail(sig.decl.line, sig.decl.column, string::format(self.allocator,
			"`%s` is declared in module `%s`, and no file of `%s` defines it",
			sig.decl.name, sig.decl.module_name, sig.decl.module_name));
		return CODEGEN_ERROR~;
	}
}

fn bool Codegen.has_function(&self, String name)
{
	foreach (&sig : self.functions) if (sig.decl.name == name) return true;
	return false;
}

<*
 Can an argument of `arg` be passed to a parameter of `param`?

 The rules mirror `coerce`, so anything overload resolution accepts can also be
 converted at the call site.
*>
fn bool Codegen.accepts(&self, Type* param, Type* arg)
{
	if (param == arg) return true;
	if (param.kind == FLOAT && arg.kind == INT) return true;
	if (param.kind == VECTOR && arg.is_scalar()) return true;
	return false;
}

<*
 Does `sig` accept these arguments, with `receiver` first when there is one?
*>
fn bool Codegen.matches(&self, FunctionSig* sig, Value* receiver, Type*[] arg_types)
{
	usz offset = 0;
	if (receiver)
	{
		if (sig.params.len != arg_types.len + 1) return false;
		if (!self.accepts(sig.params[0], receiver.type)) return false;
		offset = 1;
	}
	else
	{
		// A `&self` method has no value receiver, so it cannot be called
		// without one.
		if (sig.has_receiver && sig.receiver_ref) return false;
		if (sig.params.len != arg_types.len) return false;
	}

	foreach (i, arg_type : arg_types)
	{
		if (!self.accepts(sig.params[(usz)i + offset], arg_type)) return false;
	}
	return true;
}

<*
 Pick the function `name` that these argument types call.

 A member call prefers a declared method, then falls back to a free function
 whose first parameter is the receiver. Overloading is by arity and argument
 type; two candidates matching is an error rather than a first-wins guess.
*>
fn FunctionSig* Codegen.select_function(&self, String name, Value* receiver, Type*[] arg_types, Expr* expr)
{
	if (receiver)
	{
		FunctionSig* method = null;
		foreach (&sig : self.functions)
		{
			if (sig.decl.name != name || !sig.has_receiver) continue;
			if (!self.matches(sig, receiver, arg_types)) continue;

			if (method)
			{
				self.fail(expr.line, expr.column, string::format(self.allocator,
					"`%s` matches more than one overload with these arguments", name));
				return null;
			}
			method = sig;
		}
		if (method) return method;
	}

	FunctionSig* found = null;
	foreach (&sig : self.functions)
	{
		if (sig.decl.name != name) continue;
		if (receiver && sig.has_receiver) continue; // methods were tried above
		if (!self.matches(sig, receiver, arg_types)) continue;

		if (found)
		{
			self.fail(expr.line, expr.column, string::format(self.allocator,
				"`%s` matches more than one overload with these arguments", name));
			return null;
		}
		found = sig;
	}

	if (!found)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "no `%s` takes these arguments", name));
		return null;
	}
	return found;
}

<*
 Emit one non-entry function, on first use.

 Emitting callees here rather than in a pass of its own is what puts a
 definition before its callers without a call graph: a body that calls `g`
 emits `g` before it finishes itself. `emitting` catches the one case that
 would otherwise recurse forever.
*>
fn void? Codegen.emit_function(&self, FunctionSig* sig)
{
	if (sig.emitted) return;
	if (sig.emitting)
	{
		self.fail(sig.decl.line, sig.decl.column, string::format(self.allocator,
			"`%s` calls itself - recursion is not supported", sig.decl.name));
		return CODEGEN_ERROR~;
	}
	if (!sig.decl.function.body)
	{
		self.fail(sig.decl.line, sig.decl.column, string::format(self.allocator,
			"`%s` is declared without a body, and nothing in this module defines it", sig.decl.name));
		return CODEGEN_ERROR~;
	}
	sig.emitting = true;

	Decl* decl = sig.decl;

	Id[] param_ids = self.new_ids(sig.params.len);
	foreach (i, param : sig.params)
	{
		bool by_ref = (sig.has_receiver && sig.receiver_ref && i == 0) || sig.refs[i];
		param_ids[i] = by_ref
			? self.pointer_to(StorageClass.FUNCTION, param)
			: self.type_id(param);
	}
	Id fn_type = self.mod.type_function(self.type_id(sig.return_type), param_ids);

	Function function = self.mod.begin_function(self.type_id(sig.return_type), fn_type);
	sig.func_id = function.id;

	// Save the caller's context: locals are one list shared by every function
	// being emitted, and `emit_return` reads `outputs` to tell an entry point's
	// scatter-to-stage-I/O from a helper's plain return.
	Function*     saved_func       = self.func;
	Type*         saved_return     = self.fn_return;
	bool          saved_terminated = self.terminated;
	StageVarList  saved_inputs     = self.inputs;
	StageVarList  saved_outputs    = self.outputs;
	usz           saved_locals     = (usz)self.locals.len();
	Reach*        saved_reach      = self.reach;

	self.func       = &function;
	self.fn_return  = sig.return_type;
	self.terminated = false;
	self.inputs     = {};
	self.outputs    = {};
	sig.reach       = self.new_reach(false);
	self.reach      = sig.reach;

	usz at = 0;
	if (sig.has_receiver)
	{
		Type* receiver = sig.params[0];
		if (sig.receiver_ref)
		{
			// The parameter already is a pointer into the caller's storage, so
			// the receiver's members are reached through it directly.
			Id pid = function.param(self.pointer_to(StorageClass.FUNCTION, receiver));
			self.bind_local(sig.receiver_name, receiver, pid);
		}
		else
		{
			Id pid     = function.param(self.type_id(receiver));
			Id pointer = function.local(self.pointer_to(StorageClass.FUNCTION, receiver));
			function.store(pointer, pid);
			self.bind_local(sig.receiver_name, receiver, pointer);
		}
		at = 1;
	}

	for (usz i = at; i < sig.params.len; i++)
	{
		Type* param = sig.params[i];
		if (sig.refs[i])
		{
			// An `out`/`inout` parameter already is a pointer into the caller's
			// storage, so the name is bound straight to it.
			Id pid = function.param(self.pointer_to(StorageClass.FUNCTION, param));
			self.bind_local(sig.names[i], param, pid);
		}
		else
		{
			Id pid     = function.param(self.type_id(param));
			Id pointer = function.local(self.pointer_to(StorageClass.FUNCTION, param));
			function.store(pointer, pid);
			self.bind_local(sig.names[i], param, pointer);
		}
	}

	self.statement(decl.function.body)!;

	if (!self.terminated)
	{
		if (sig.return_type.kind != VOID)
		{
			self.fail(decl.line, decl.column,
				string::format(self.allocator, "`%s` does not return a value on every path", decl.name));
			return CODEGEN_ERROR~;
		}
		function.ret();
	}

	function.end();
	self.mod.name(function.id, decl.name);

	self.func       = saved_func;
	self.fn_return  = saved_return;
	self.terminated = saved_terminated;
	self.inputs     = saved_inputs;
	self.outputs    = saved_outputs;
	self.locals.size = (sz)saved_locals;
	self.reach      = saved_reach;

	sig.emitted  = true;
	sig.emitting = false;
}

<*
 Call a user function, with or without a receiver.

 `receiver` non-null is a method call: `image.Sample(uv)` is `Sample(image, uv)`,
 so a method is an ordinary function whose first parameter is the receiver.
*>
fn Value? Codegen.user_call(&self, Expr* expr, String name, Value* receiver)
{
	ValueList args;
	args.init(self.allocator, expr.call.args.len + 1);
	foreach (arg : expr.call.args) args.push(self.expression(arg)!);

	Type*[] arg_types = self.new_types((usz)args.len());
	foreach (i, value : args) arg_types[i] = value.type;

	FunctionSig* sig = self.select_function(name, receiver, arg_types, expr);
	if (!sig) return CODEGEN_ERROR~;

	self.emit_function(sig)!;
	self.note_callee(sig);

	usz  total     = (usz)args.len() + (receiver ? (usz)1 : (usz)0);
	Id[] call_args = self.new_ids(total);
	usz  at        = 0;
	usz  offset    = 0;

	// Arguments passed through a temporary, written back once the call returns.
	WritebackList writebacks;
	writebacks.init(self.allocator, 2);

	if (receiver)
	{
		if (sig.has_receiver && sig.receiver_ref)
		{
			call_args[at++] = self.receiver_pointer(*receiver, &writebacks);
		}
		else
		{
			call_args[at++] = self.coerce(*receiver, sig.params[0], expr)!;
		}
		offset = 1;
	}
	foreach (i, value : args)
	{
		usz index = (usz)i + offset;
		if (sig.refs[index])
		{
			if (value.pointer == NO_ID || !passes_by_reference(value.storage))
			{
				self.fail(expr.line, expr.column, "an out or inout argument must be a variable");
				return CODEGEN_ERROR~;
			}
			call_args[at++] = self.pass_by_reference(value, &writebacks);
		}
		else
		{
			call_args[at++] = self.coerce(value, sig.params[index], expr)!;
		}
	}

	Id result = self.func.call(self.type_id(sig.return_type), sig.func_id, call_args);
	foreach (&writeback : writebacks)
	{
		self.store(writeback.target, self.func.load(self.type_id(writeback.target.type), writeback.temporary));
	}
	return (Value) { .type = sig.return_type, .id = result };
}

struct Writeback
{
	Value target;
	Id    temporary;
}

alias WritebackList = List{Writeback};

<*
 The storage classes an `out` or `inout` argument may live in. A parameter is a
 Function pointer, so a Function variable is passed as itself; a ray-tracing
 stage's incoming payload or callable data is named like a variable too, and is
 passed through a Function copy that is written back after the call.
*>
fn bool passes_by_reference(StorageClass storage) @private
{
	return storage == StorageClass.FUNCTION
		|| storage == StorageClass.INCOMING_RAY_PAYLOAD
		|| storage == StorageClass.INCOMING_CALLABLE_DATA;
}

<*
 The Function pointer a by-reference argument is passed as: the variable's own,
 or a copy that `writebacks` returns to it after the call.
*>
fn Id Codegen.pass_by_reference(&self, Value value, WritebackList* writebacks)
{
	if (value.storage == StorageClass.FUNCTION) return value.pointer;

	Id temporary = self.func.local(self.pointer_to(StorageClass.FUNCTION, value.type));
	self.func.store(temporary, self.rvalue(value));
	writebacks.push({ .target = value, .temporary = temporary });
	return temporary;
}

<*
 The pointer a `&self` receiver is passed as.

 A value already in Function storage is passed by its own address, so writes
 through it would reach the caller, and a ray-tracing payload is passed through
 a copy that is written back. Anything else - a temporary, or a struct reached
 through a device address - is copied into a Function local first, which makes
 `&self` on those read-only for now.
*>
fn Id Codegen.receiver_pointer(&self, Value base, WritebackList* writebacks)
{
	if (base.pointer != NO_ID && passes_by_reference(base.storage)) return self.pass_by_reference(base, writebacks);

	Id id  = self.rvalue(base);
	Id ptr = self.func.local(self.pointer_to(StorageClass.FUNCTION, base.type));
	self.func.store(ptr, id);
	return ptr;
}

// --- Calls -------------------------------------------------------------------

<*
 A call is one of four things, told apart by the callee rather than by a
 keyword: a type name is a constructor, a member call on a texture is a sample,
 a name declared as a function is a call, and anything else is a builtin.
*>
fn Value? Codegen.call_expression(&self, Expr* expr)
{
	Expr* callee = expr.call.callee;

	if (callee.kind == MEMBER)
	{
		Value base = self.expression(callee.member.value)!;
		if (base.type.kind == TEXTURE || base.type.kind == SAMPLED_IMAGE)
		{
			return self.texture_method(expr, base, callee.member.name);
		}
		if (base.type.kind == RAY_QUERY) return self.ray_query_method(expr, base, callee.member.name);
		if (self.has_function(callee.member.name)) return self.user_call(expr, callee.member.name, &base);

		self.fail(expr.line, expr.column,
			string::format(self.allocator, "`%s` is not callable on a %s", callee.member.name, base.type.name));
		return CODEGEN_ERROR~;
	}

	if (callee.kind != IDENT)
	{
		self.fail(expr.line, expr.column, "only named functions and constructors can be called");
		return CODEGEN_ERROR~;
	}

	String name = callee.ident.name;

	if (Type* type = self.types.find(name)) return self.construct(expr, type);
	if (self.has_function(name)) return self.user_call(expr, name, null);

	if (name == "mul") return self.mul_call(expr);
	if (name == "mod" || name == "fmod") return self.mod_call(expr, name);
	if (name == "select") return self.select_call(expr);
	if (name == "coop_load") return self.coop_load_call(expr);
	if (name == "coop_store") return self.coop_store_call(expr);
	if (name == "coop_muladd") return self.coop_muladd_call(expr);
	if (name == "barrier" || name == "workgroup_barrier") return self.workgroup_barrier(expr);
	if (name == "InterlockedAdd") return self.atomic_add_call(expr);
	if (name == "NonUniformResourceIndex") return self.non_uniform_call(expr);
	if (name == "trace_ray") return self.trace_ray_call(expr);
	if (name == "execute_callable") return self.execute_callable_call(expr);
	if (name == "report_intersection") return self.report_intersection_call(expr);
	if (name == "ignore_intersection" || name == "terminate_ray")
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`%s()` ends the shader, so it is a statement of its own", name));
		return CODEGEN_ERROR~;
	}

	return self.builtin_call(expr, name);
}

<*
 `barrier()`: every invocation in the workgroup reaches this point, and every
 write to shared memory or to a storage buffer before it is visible to the
 workgroup after it.

 The three operands are the ones the SPIR-V environment wants spelled out: the
 execution scope that synchronises, the memory scope whose writes are ordered,
 and the semantics of that ordering. Workgroup for the first two because a
 workgroup is the only thing that can meet at a barrier, and `AcquireRelease`
 over `WorkgroupMemory` and `UniformMemory` for the third - shared memory and
 buffers both, which is GLSL's `barrier()` after a `memoryBarrier()`. Ordering
 shared memory alone would let one invocation read a buffer element another
 wrote before the barrier and see the old value. The ordering carries into the
 function rather than inlining, so a body can put the barrier in a helper.

 A Vulkan-memory-model module (one with a cooperative matrix in it) would
 also want `MakeAvailable | MakeVisible` for the writes to be seen, and
 `NonPrivatePointer` on the accesses. The model is decided only once a coopmat
 appears, possibly after a barrier is written, so that is not done yet.

 The result is void: an expression statement is the only place this call can
 be written, which is the point of it being a statement in the language.
*>
fn Value? Codegen.workgroup_barrier(&self, Expr* expr)
{
	if (expr.call.args.len != 0)
	{
		self.fail(expr.line, expr.column, "`barrier` takes no arguments");
		return CODEGEN_ERROR~;
	}

	Type* uint_t = self.types.find("uint");
	Id scope_execution = self.mod.const_u32(self.type_id(uint_t), 2); // Workgroup
	Id scope_memory    = self.mod.const_u32(self.type_id(uint_t), 2);
	Id semantics       = self.mod.const_u32(self.type_id(uint_t),
		(uint)MemorySemantics.ACQUIRE_RELEASE | (uint)MemorySemantics.WORKGROUP_MEMORY | (uint)MemorySemantics.UNIFORM_MEMORY);

	// OpControlBarrier carries no result type and no result id, so it is
	// emitted by hand rather than through `Function.emit`.
	self.func.control_barrier(scope_execution, scope_memory, semantics, semantics);

	// A barrier has no value; the statement is the only place it can be.
	Type* void_t = self.types.find("void");
	return (Value) { .type = void_t, .id = NO_ID };
}

<*
 The scope id a coopmat names, as the constant SPIR-V wants.
*>
fn Id Codegen.scope_constant(&self, uint scope)
{
	Type* uint_t = self.types.find("uint");
	return self.mod.const_u32(self.type_id(uint_t), scope);
}

<*
 Declare the cooperative-matrix capability and, for a module older than 1.6,
 the extension that added the opcodes. Asked once per module it matters to.
*>
fn void Codegen.coopmat_capability(&self)
{
	if (!self.mod.has_extension("SPV_KHR_cooperative_matrix"))
	{
		self.mod.extension("SPV_KHR_cooperative_matrix");
	}
	self.mod.capability(Capability.COOPERATIVE_MATRIX_KHR);

	// The capability is only legal next to the Vulkan memory model: SPIR-V
	// says so in one sentence, and the validator quotes it back at anyone who
	// declares one without the other. A module that has a coopmat in it is
	// therefore a Vulkan-memory-model module, which also means its barriers
	// carry release-acquire semantics rather than "everything".
	self.mod.extension("SPV_KHR_vulkan_memory_model");
	self.mod.capability(Capability.VULKAN_MEMORY_MODEL);
	self.mod.set_memory_model(AddressingModel.LOGICAL, MemoryModel.VULKAN);

	// SPV_KHR_vulkan_memory_model wants a 1.3 module, and a coopmat module is
	// the only kind that has one, so the version is raised here rather than at
	// the top of every compile.
	self.mod.require_version(VERSION_1_3);
}

<*
 Declare inline ray queries. Both ray-tracing extensions depend on
 VK_KHR_spirv_1_4, so a module using either is a 1.4 module - which is also what
 makes its entry points list every global they reach (see reach.c3).
*>
fn void Codegen.ray_query_capability(&self)
{
	self.mod.extension(EXTENSION_RAY_QUERY);
	self.mod.capability(Capability.RAY_QUERY_KHR);
	self.mod.require_version(VERSION_1_4);
}

<*
 Declare the ray-tracing pipeline stages, for the same version reason.
*>
fn void Codegen.ray_tracing_capability(&self)
{
	self.mod.extension(EXTENSION_RAY_TRACING);
	self.mod.capability(Capability.RAY_TRACING_KHR);
	self.mod.require_version(VERSION_1_4);
}

<*
 The layout operand of a tile load or store: row-major unless a fourth
 argument names `column_major` (or says `row_major` outright). SPIR-V wants
 the layout as a constant id, and a literal 0 in that position would read as
 "no id", so it travels as a constant either way.
*>
fn Id? Codegen.coop_layout(&self, Expr* expr, String verb)
{
	uint layout = 0; // RowMajorKHR
	if (expr.call.args.len == 4)
	{
		Expr* arg = expr.call.args[3];
		if (arg.kind != IDENT || (arg.ident.name != "column_major" && arg.ident.name != "row_major"))
		{
			self.fail(arg.line, arg.column,
				string::format(self.allocator, "`%s`'s fourth argument is `row_major` or `column_major`", verb));
			return CODEGEN_ERROR~;
		}
		if (arg.ident.name == "column_major") layout = 1; // ColumnMajorKHR
	}
	return self.mod.const_u32(self.type_id(self.types.find("uint")), layout);
}

<*
 `coop_load(matrix, pointer)`: one tile of a cooperative matrix, read through a
 pointer - `coop_load(tile, &tile_array[0])`.

 The matrix type is the destination's, because the tile's shape is the
 compiler's to know and the pointer's to not; the load reads `OpCooperativeMatrixLoadKHR`
 with no memory operand, which is the memory-model-free spelling.
*>
fn Value? Codegen.coop_load_call(&self, Expr* expr)
{
	if (expr.call.args.len != 3 && expr.call.args.len != 4)
	{
		self.fail(expr.line, expr.column, "`coop_load` takes a matrix, a pointer, a stride and optionally a layout");
		return CODEGEN_ERROR~;
	}
	Value target = self.expression(expr.call.args[0])!;
	Value source = self.expression(expr.call.args[1])!;
	Value stride = self.expression(expr.call.args[2])!;

	if (target.type.kind != COOPMAT)
	{
		self.fail(expr.line, expr.column, "`coop_load` writes a coopmat");
		return CODEGEN_ERROR~;
	}
	if (source.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "`coop_load` reads through a pointer");
		return CODEGEN_ERROR~;
	}

	if (stride.type.kind != UINT && target.type.kind != COOPMAT)
	{
		self.fail(expr.line, expr.column, "`coop_load` wants a whole-number stride");
		return CODEGEN_ERROR~;
	}

	// OpCooperativeMatrixLoadKHR: pointer, layout, stride. The stride is the
	// caller's, because a tile is a window onto an array rather than an array
	// of its own: the step between rows, or between columns when column-major.
	Id layout = self.coop_layout(expr, "coop_load")!;
	Id result = self.func.emit(Opcode.COOPERATIVE_MATRIX_LOAD_KHR, self.type_id(target.type),
		source.pointer, layout, self.rvalue(stride));
	self.coopmat_capability();
	self.store(target, result);
	return (Value) { .type = target.type, .id = result };
}

<*
 `coop_store(pointer, matrix)`: the mirror of `coop_load`, one tile written
 through a pointer.
*>
fn Value? Codegen.coop_store_call(&self, Expr* expr)
{
	if (expr.call.args.len != 3 && expr.call.args.len != 4)
	{
		self.fail(expr.line, expr.column, "`coop_store` takes a pointer, a matrix, a stride and optionally a layout");
		return CODEGEN_ERROR~;
	}
	Value target = self.expression(expr.call.args[0])!;
	Value value  = self.expression(expr.call.args[1])!;
	Value stride = self.expression(expr.call.args[2])!;

	if (value.type.kind != COOPMAT)
	{
		self.fail(expr.line, expr.column, "`coop_store` writes a coopmat");
		return CODEGEN_ERROR~;
	}
	if (target.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "`coop_store` writes through a pointer");
		return CODEGEN_ERROR~;
	}

	Id layout = self.coop_layout(expr, "coop_store")!;
	self.func.emit_void3(Opcode.COOPERATIVE_MATRIX_STORE_KHR, target.pointer, self.rvalue(value),
		layout, self.rvalue(stride));
	self.coopmat_capability();

	Type* void_t = self.types.find("void");
	return (Value) { .type = void_t, .id = NO_ID };
}

<*
 `coop_muladd(a, b, c, result)`: `result = a * b + c`, the whole point of a
 cooperative matrix.

 The four arguments are the three operand tiles and the tile the answer goes
 in, in that order, and every one of them is a coopmat local. The shape check
 is the one matrix multiplication requires - `a`'s columns against `b`'s rows
 - done here so the driver is handed a valid instruction rather than left to
 say so.
*>
fn Value? Codegen.coop_muladd_call(&self, Expr* expr)
{
	if (expr.call.args.len != 4)
	{
		self.fail(expr.line, expr.column, "`coop_muladd` takes a, b, c and the result tile");
		return CODEGEN_ERROR~;
	}
	Value a = self.expression(expr.call.args[0])!;
	Value b = self.expression(expr.call.args[1])!;
	Value c = self.expression(expr.call.args[2])!;
	Value r = self.expression(expr.call.args[3])!;

	foreach (tile : (Value[]) { a, b, c, r })
	{
		if (tile.type.kind != COOPMAT)
		{
			self.fail(expr.line, expr.column, "`coop_muladd` works on coopmat tiles");
			return CODEGEN_ERROR~;
		}
	}
	if (a.type.count != b.type.rows || r.type.rows != a.type.rows || r.type.count != b.type.count
		|| c.type.rows != r.type.rows || c.type.count != r.type.count
		|| r.type.element != c.type.element)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`coop_muladd` cannot multiply %s by %s into %s", a.type.name, b.type.name, r.type.name));
		return CODEGEN_ERROR~;
	}

	// The trailing operand is the cooperative-matrix operand mask; zero is
	// "nothing special", and the signed-component bits are a host-side
	// property of the data rather than of the multiply.
	uint no_operands = 0;
	Id result = self.func.emit(Opcode.COOPERATIVE_MATRIX_MUL_ADD_KHR, self.type_id(r.type),
		self.rvalue(a), self.rvalue(b), self.rvalue(c), no_operands);
	self.coopmat_capability();
	self.store(r, result);
	return (Value) { .type = r.type, .id = result };
}

<*
 `NonUniformResourceIndex(i)`: the index is not the same across the invocations
 of a wave, so the descriptor it selects may differ lane by lane. It decorates
 the index and yields it unchanged, marked so the descriptor array it indexes
 decorates the access chain, the loaded descriptor and the sampled image too.

 The decoration is what tells the driver not to hoist one descriptor for the
 whole wave, which is exactly the mistake a material body reading a map inside
 a branch would otherwise invite. Vulkan wants it on the operand the image
 instruction reads, so the call has to be written inside the brackets: an index
 kept in a local first loses the mark, as it would in HLSL.
*>
fn Value? Codegen.non_uniform_call(&self, Expr* expr)
{
	if (expr.call.args.len != 1)
	{
		self.fail(expr.line, expr.column, "`NonUniformResourceIndex` takes one index");
		return CODEGEN_ERROR~;
	}
	Value index = self.expression(expr.call.args[0])!;
	if (!index.type.is_numeric() || index.type.kind == FLOAT)
	{
		self.fail(expr.line, expr.column, "`NonUniformResourceIndex` needs an integer index");
		return CODEGEN_ERROR~;
	}

	Id id = self.rvalue(index);
	self.mod.decorate(id, Decoration.NON_UNIFORM);
	self.mod.capability(Capability.SHADER_NON_UNIFORM);
	self.mod.extension("SPV_EXT_descriptor_indexing");
	return (Value) { .type = index.type, .id = id, .non_uniform = true };
}

<*
 `InterlockedAdd(dest, value)`: an atomic add on device memory, yielding the
 value the destination held before. HLSL's name, because that is what a ported
 body writes; the result may be ignored.

 Device scope and relaxed ordering: a counter shared between workgroups needs
 the read-modify-write to be atomic, not ordered against other memory, and
 Vulkan forbids `SequentiallyConsistent` outright. Anything stronger belongs to
 a barrier rather than the increment.
*>
fn Value? Codegen.atomic_add_call(&self, Expr* expr)
{
	if (expr.call.args.len != 2)
	{
		self.fail(expr.line, expr.column, "`InterlockedAdd` takes a destination and a value");
		return CODEGEN_ERROR~;
	}
	Value dest  = self.expression(expr.call.args[0])!;
	Value value = self.expression(expr.call.args[1])!;

	if (dest.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "the destination of `InterlockedAdd` must be a variable");
		return CODEGEN_ERROR~;
	}
	if (dest.type.kind != UINT || value.type.kind != UINT)
	{
		self.fail(expr.line, expr.column, "`InterlockedAdd` works on 32-bit uints");
		return CODEGEN_ERROR~;
	}

	Type* uint_t    = self.types.find("uint");
	Id    scope     = self.mod.const_u32(self.type_id(uint_t), 1); // Device
	Id    semantics = self.mod.const_u32(self.type_id(uint_t), 0); // Relaxed
	Id    result    = self.func.emit(Opcode.ATOMIC_I_ADD, self.type_id(uint_t),
		dest.pointer, scope, semantics, self.rvalue(value));
	return (Value) { .type = uint_t, .id = result };
}

<*
 `mul(a, b)`: the matrix products spelled the way HLSL and Slang spell them.
 It is `a * b` with the same operand rules, kept because the alternative is
 rewriting every matrix product in a ported body.
*>
fn Value? Codegen.mul_call(&self, Expr* expr)
{
	if (expr.call.args.len != 2)
	{
		self.fail(expr.line, expr.column, "`mul` takes two arguments");
		return CODEGEN_ERROR~;
	}
	Value left  = self.expression(expr.call.args[0])!;
	Value right = self.expression(expr.call.args[1])!;
	Id    id    = self.arithmetic(STAR, left, right, expr)!;
	return (Value) { .type = self.result_type(STAR, left.type, right.type), .id = id };
}

<*
 `mod(x, y)` and `fmod(x, y)`: the two remainders, which differ only when the
 operands' signs do.

 `mod` is GLSL's: floored, so the result takes the sign of `y` and
 `mod(-7.5, 2.0)` is 0.5 - what wrapping an angle or a texture coordinate
 wants. `fmod` is HLSL's and is `%` spelled as a call: truncated, so the result
 takes the sign of `x` and `fmod(-7.5, 2.0)` is -1.5. For a uint the two agree.

 A scalar on either side is splatted to the other's vector, as `mod(v, 2.0)`
 is written.
*>
fn Value? Codegen.mod_call(&self, Expr* expr, String name)
{
	if (expr.call.args.len != 2)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator, "`%s` takes two arguments", name));
		return CODEGEN_ERROR~;
	}
	Value left  = self.expression(expr.call.args[0])!;
	Value right = self.expression(expr.call.args[1])!;
	left  = self.adapt_literal(left, expr.call.args[0], right.type);
	right = self.adapt_literal(right, expr.call.args[1], left.type);

	Type* scalar = left.type.scalar();
	bool  shaped = (left.type.kind == VECTOR || left.type.is_scalar())
		&& (right.type.kind == VECTOR || right.type.is_scalar());
	if (!shaped || !scalar.is_numeric() || scalar != right.type.scalar()
		|| (left.type.kind == VECTOR && right.type.kind == VECTOR && left.type != right.type))
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`%s` takes two numbers of the same kind, got a %s and a %s", name, left.type.name, right.type.name));
		return CODEGEN_ERROR~;
	}

	Type* result   = left.type.kind == VECTOR ? left.type : right.type;
	Id    left_id  = self.rvalue(left);
	Id    right_id = self.rvalue(right);
	if (result.kind == VECTOR && left.type.is_scalar())  left_id  = self.splat(result, left_id);
	if (result.kind == VECTOR && right.type.is_scalar()) right_id = self.splat(result, right_id);

	bool   floored = name == "mod";
	Opcode opcode;
	switch (scalar.kind)
	{
		case FLOAT: opcode = floored ? Opcode.F_MOD : Opcode.F_REM;
		case INT:   opcode = floored ? Opcode.S_MOD : Opcode.S_REM;
		default:    opcode = Opcode.U_MOD;
	}
	return (Value) { .type = result, .id = self.func.binop(opcode, self.type_id(result), left_id, right_id) };
}

<*
 `select(when_false, when_true, condition)` - `condition ? when_true : when_false`,
 the same order as HLSL's `select`.
*>
fn Value? Codegen.select_call(&self, Expr* expr)
{
	if (expr.call.args.len != 3)
	{
		self.fail(expr.line, expr.column, "`select` takes three arguments");
		return CODEGEN_ERROR~;
	}
	Value when_false = self.expression(expr.call.args[0])!;
	Value when_true  = self.expression(expr.call.args[1])!;
	Value condition  = self.expression(expr.call.args[2])!;

	Type* result       = when_true.type;
	Id    condition_id = self.condition(condition, expr.call.args[2]);

	// OpSelect wants a condition of the same shape as its result, so a scalar
	// bool against a vector is broadcast.
	if (result.kind == VECTOR && condition.type.is_scalar())
	{
		condition_id = self.splat(self.vector_of(self.types.find("bool"), result.count), condition_id);
	}

	Id id = self.func.emit(Opcode.SELECT, self.type_id(result),
		condition_id, self.rvalue(when_true), self.rvalue(when_false));
	return (Value) { .type = result, .id = id };
}

<*
 Build a vector, matrix or scalar from arguments.

 Arguments are flattened to scalars and consumed left to right until the
 component count is filled, which is what makes `float4(xyz, 1.0)` work - the
 mixed form Kongruent's typer has no rule for.
*>
fn Value? Codegen.construct(&self, Expr* expr, Type* type)
{
	Expr*[] args = expr.call.args;

	if (args.len == 0)
	{
		self.fail(expr.line, expr.column, "a constructor needs at least one argument");
		return CODEGEN_ERROR~;
	}

	// Scalar conversion: float(i), int(f), uint(i), uint8(i).
	//
	// The same path a `(uint8)x` cast takes, so a narrowing is a narrowing
	// whichever spelling reaches it - and `int` to `uint` stays the
	// reinterpretation it is rather than becoming a conversion here and a
	// reinterpretation there.
	if (type.is_scalar())
	{
		Value source = self.expression(args[0])!;
		if (source.type == type) return (Value) { .type = type, .id = self.rvalue(source) };
		return (Value) { .type = type, .id = self.convert_scalar(self.rvalue(source), source.type.scalar(), type) };
	}

	if (type.kind == MATRIX)
	{
		@pool() {
			Id[] columns = alloc::alloc_array(tmem, Id, args.len);
			foreach (i, arg : args) columns[i] = self.rvalue(self.expression(arg)!);
			if (args.len != type.count)
			{
				self.fail(expr.line, expr.column,
					string::format(self.allocator, "%s needs %d columns, got %d", type.name, type.count, args.len));
				return CODEGEN_ERROR~;
			}
			return (Value) { .type = type, .id = self.func.composite_construct(self.type_id(type), columns) };
		};
	}

	if (type.kind != VECTOR)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "`%s` cannot be constructed", type.name));
		return CODEGEN_ERROR~;
	}

	// Splat: one scalar fills every component.
	if (args.len == 1)
	{
		Value only = self.expression(args[0])!;
		if (only.type.is_scalar())
		{
			return (Value) { .type = type, .id = self.splat(type, self.rvalue(only)) };
		}
	}

	IdListC components;
	components.init(self.allocator, 4);

	foreach (arg : args)
	{
		Value value = self.expression(arg)!;
		Id    id    = self.rvalue(value);

		if (value.type.is_scalar())
		{
			components.push(self.convert_scalar(id, value.type, type.element));
			continue;
		}
		if (value.type.kind != VECTOR)
		{
			self.fail(arg.line, arg.column, "a constructor argument must be a scalar or a vector");
			return CODEGEN_ERROR~;
		}
		for (uint i = 0; i < value.type.count; i++)
		{
			Id component = self.func.composite_extract(self.type_id(value.type.element), id, i);
			components.push(self.convert_scalar(component, value.type.element, type.element));
		}
	}

	if (components.len() != type.count)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "%s needs %d components, got %d", type.name, type.count, components.len()));
		return CODEGEN_ERROR~;
	}

	return (Value) { .type = type, .id = self.func.composite_construct(self.type_id(type), components.array_view()) };
}

fn Id Codegen.convert_scalar(&self, Id id, Type* from, Type* to)
{
	if (from == to) return id;
	// `half(x)` and `float(h)`: a float to a float of another width rounds or
	// widens, and `OpFConvert` is both, the result type saying which.
	if (to.kind == FLOAT && from.kind == FLOAT && to.width() != from.width())
	{
		return self.func.unop(Opcode.F_CONVERT, self.type_id(to), id);
	}
	if (to.kind == FLOAT && from.kind != FLOAT)
	{
		return self.func.unop(from.kind == UINT ? Opcode.CONVERT_U_TO_F : Opcode.CONVERT_S_TO_F, self.type_id(to), id);
	}
	if (to.kind != FLOAT && from.kind == FLOAT)
	{
		return self.func.unop(to.kind == UINT ? Opcode.CONVERT_F_TO_U : Opcode.CONVERT_F_TO_S, self.type_id(to), id);
	}
	// int and uint are both 32 bits, so the bits move unchanged.
	if (to.kind != FLOAT && from.kind != FLOAT && to != from && to.is_scalar() && from.is_scalar())
	{
		if (to.width() != from.width())
		{
			// A different width is a real conversion, not a reinterpretation:
			// `uint8(300)` keeps the low byte, and sign matters on the way up.
			// `OpUConvert` and `OpSConvert` are the same instruction whichever
			// way the width moves - the result type says which.
			return self.func.unop(to.kind == INT ? Opcode.S_CONVERT : Opcode.U_CONVERT,
				self.type_id(to), id);
		}
		return self.func.unop(Opcode.BITCAST, self.type_id(to), id);
	}
	return id;
}

<*
 The canonical name of a texture method, accepting the Slang/HLSL spelling a
 ported body writes as well as the lowercase one. Empty for anything else.

 `Gather`, `GatherRed` and the rest are one method with the component fixed by
 the name (see `gather_component`), and `Load` is `load` with the mip level
 packed into the coordinate's last component.
*>
fn String texture_method_name(String written)
{
	switch (written)
	{
		case "sample":
		case "Sample":                return "sample";
		case "sample_bias":
		case "SampleBias":            return "sample_bias";
		case "sample_lod":
		case "SampleLevel":           return "sample_lod";
		case "sample_grad":
		case "SampleGrad":            return "sample_grad";
		case "sample_cmp":
		case "SampleCmp":             return "sample_cmp";
		case "sample_cmp_lod":
		case "SampleCmpLevel":        return "sample_cmp_lod";
		case "sample_cmp_level_zero":
		case "SampleCmpLevelZero":    return "sample_cmp_level_zero";
		case "gather":
		case "Gather":
		case "GatherRed":
		case "GatherGreen":
		case "GatherBlue":
		case "GatherAlpha":           return "gather";
		case "gather_cmp":
		case "GatherCmp":
		case "GatherCmpRed":          return "gather_cmp";
		case "load":                  return "load";
		case "Load":                  return "load_packed";
		case "size":                  return "size";
		case "levels":                return "levels";
		default:                      return "";
	}
}

<*
 The component a Slang gather spelling names, or -1 when the component is an
 argument - the lowercase `gather(uv, component)`.
*>
fn int gather_component(String written)
{
	switch (written)
	{
		case "Gather":
		case "GatherRed":   return 0;
		case "GatherGreen": return 1;
		case "GatherBlue":  return 2;
		case "GatherAlpha": return 3;
		default:            return -1;
	}
}

<*
 The optional operands of an image instruction, NO_ID when absent. Written in
 this order because that is the order SPIR-V wants their ids in after the mask:
 ascending bit order, Bias then Lod then Grad then ConstOffset.
*>
struct ImageOperands
{
	Id bias;
	Id lod;
	Id grad_x;
	Id grad_y;
	Id offset;
}

<*
 Emit a sample, fetch or gather: the image, the coordinate, the third operand
 some of them take - the depth reference, or the gather component - and then
 the image operand mask with its ids.
*>
fn Id Codegen.image_instruction(&self, Opcode opcode, Type* result, Id image, Id coordinate, Id third, ImageOperands operands)
{
	Id[10] words;
	usz    count = 0;
	words[count++] = image;
	words[count++] = coordinate;
	if (third != NO_ID) words[count++] = third;

	uint mask = 0;
	if (operands.bias   != NO_ID) mask |= (uint)ImageOperand.BIAS;
	if (operands.lod    != NO_ID) mask |= (uint)ImageOperand.LOD;
	if (operands.grad_x != NO_ID) mask |= (uint)ImageOperand.GRAD;
	if (operands.offset != NO_ID) mask |= (uint)ImageOperand.CONST_OFFSET;
	if (mask)
	{
		words[count++] = (Id)mask;
		if (operands.bias   != NO_ID) words[count++] = operands.bias;
		if (operands.lod    != NO_ID) words[count++] = operands.lod;
		if (operands.grad_x != NO_ID) { words[count++] = operands.grad_x; words[count++] = operands.grad_y; }
		if (operands.offset != NO_ID) words[count++] = operands.offset;
	}
	return self.func.emit_slice(opcode, self.type_id(result), words[0:count]);
}

<*
 `tex.method(...)` on any texture: the sampling, comparison and gather family,
 texel fetches, and the size queries.

 Two shapes reach here. A separate texture (`texture2d` and the rest) is paired
 with a sampler at the point of use, so its sampling methods name the sampler
 first; a combined one (`Sampler2D` and the rest) is a sampled image already.
 Fetches and queries read the image alone and take no sampler on either.
*>
fn Value? Codegen.texture_method(&self, Expr* expr, Value texture, String written)
{
	if (written == "GetDimensions")
	{
		self.fail(expr.line, expr.column,
			"`GetDimensions` is spelled `size(lod)`, which returns the extent, and `levels()`, which counts the mips");
		return CODEGEN_ERROR~;
	}

	String method = texture_method_name(written);
	switch (method)
	{
		case "":
			self.fail(expr.line, expr.column,
				string::format(self.allocator, "a %s has no method `%s`", texture.type.name, written));
			return CODEGEN_ERROR~;
		case "size":        return self.texture_size(expr, texture);
		case "levels":      return self.texture_levels(expr, texture);
		case "load":
		case "load_packed": return self.texture_load(expr, texture, method == "load_packed", written);
		default:            return self.texture_sample(expr, texture, method, written);
	}
}

<*
 The sampling family: sample, its bias, lod and gradient forms, the depth
 comparisons, and the gathers.

 Whether a method compares has to agree with the sampler it runs through. A
 shadow type or a `sampler_cmp` was made with a compare op, so it serves only
 the `_cmp` methods; any other sampler serves only the rest. Vulkan leaves the
 mismatch undefined, which is why it is refused here by name.
*>
fn Value? Codegen.texture_sample(&self, Expr* expr, Value texture, String method, String written)
{
	Type*   image     = texture.type;
	Expr*[] args      = expr.call.args;
	bool    separate  = image.kind == TEXTURE;
	bool    compares  = method.starts_with("sample_cmp") || method == "gather_cmp";
	bool    gathers   = method.starts_with("gather");
	int     component = gather_component(written);

	Value sampler;
	if (separate)
	{
		if (args.len == 0 || (sampler = self.expression(args[0])!).type.kind != SAMPLER)
		{
			self.fail(expr.line, expr.column, string::format(self.allocator,
				"`%s` on a %s takes its sampler first - a %s is paired with one where it is sampled",
				written, image.name, image.name));
			return CODEGEN_ERROR~;
		}
		args = args[1..];
	}

	bool comparison_sampler = separate ? sampler.type.depth != 0 : image.depth != 0;
	if (compares && !comparison_sampler)
	{
		self.fail(expr.line, expr.column, separate
			? string::format(self.allocator, "`%s` compares, so its sampler is a `sampler_cmp`", written)
			: string::format(self.allocator,
				"`%s` compares, so it needs a comparison sampler such as Sampler2DShadow, not a %s", written, image.name));
		return CODEGEN_ERROR~;
	}
	if (!compares && comparison_sampler)
	{
		self.fail(expr.line, expr.column, separate
			? string::format(self.allocator, "a `sampler_cmp` only compares - `%s` takes a `sampler`", written)
			: string::format(self.allocator,
				"a %s compares - write `sample_cmp`, `sample_cmp_level_zero` or `gather_cmp`", image.name));
		return CODEGEN_ERROR~;
	}
	if (compares && image.dim == Dim.D3)
	{
		self.fail(expr.line, expr.column, "a 3D texture has no depth comparison");
		return CODEGEN_ERROR~;
	}
	if (gathers && image.dim != Dim.D2 && image.dim != Dim.CUBE)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`%s` gathers from a 2D or cube texture, not a %s", written, image.name));
		return CODEGEN_ERROR~;
	}

	// The arguments after the coordinate, before an optional texel offset.
	usz extra;
	switch (method)
	{
		case "sample":                extra = 0;
		case "sample_grad":           extra = 2;
		case "sample_cmp_lod":        extra = 2;
		case "gather":                extra = component < 0 ? 1 : 0;
		default:                      extra = 1; // bias, lod or the depth reference
	}
	usz  fixed     = 1 + extra;
	bool offsets   = image.dim != Dim.CUBE;
	usz  sampler_n = separate ? 1 : 0;
	if (args.len != fixed && !(offsets && args.len == fixed + 1))
	{
		if (args.len == fixed + 1)
		{
			self.fail(args[fixed].line, args[fixed].column, "a cube map takes no texel offset");
			return CODEGEN_ERROR~;
		}
		self.fail(expr.line, expr.column, offsets
			? string::format(self.allocator, "`%s` takes %d arguments, or %d with a texel offset",
				written, fixed + sampler_n, fixed + sampler_n + 1)
			: string::format(self.allocator, "`%s` takes %d arguments", written, fixed + sampler_n));
		return CODEGEN_ERROR~;
	}

	// The implicit-LOD forms take their level from screen-space derivatives,
	// and only a fragment shader has those.
	bool implicit = method == "sample" || method == "sample_bias" || method == "sample_cmp";
	if (implicit)
	{
		self.require_stages(Stage.FRAGMENT.bit(), expr.line, expr.column, string::format(self.allocator,
			"`%s` takes its level from screen-space derivatives, which only a fragment shader has - write `%s` with an explicit level",
			written, method == "sample_cmp" ? "sample_cmp_lod" : "sample_lod"))!;
	}

	Type* float_t = self.types.find("float");
	Type* float4  = self.types.find("float4");
	Id    coord   = self.texture_coordinate(args[0], image, written)!;

	ImageOperands operands;
	Id third = NO_ID;
	switch (method)
	{
		case "sample_bias":
			operands.bias = self.texture_float(args[1], "bias", written)!;
		case "sample_lod":
			operands.lod = self.texture_float(args[1], "level", written)!;
		case "sample_grad":
			operands.grad_x = self.texture_gradient(args[1], image, written)!;
			operands.grad_y = self.texture_gradient(args[2], image, written)!;
		case "sample_cmp":
		case "gather_cmp":
			third = self.texture_float(args[1], "reference", written)!;
		case "sample_cmp_lod":
			third = self.texture_float(args[1], "reference", written)!;
			operands.lod = self.texture_float(args[2], "level", written)!;
		case "sample_cmp_level_zero":
			third = self.texture_float(args[1], "reference", written)!;
			operands.lod = self.const_float(0.0);
		case "gather":
			if (component >= 0)
			{
				third = self.const_int(component);
				break;
			}
			Expr* written_component = args[1];
			if (written_component.kind != INT_LITERAL || written_component.literal.value > 3)
			{
				self.fail(written_component.line, written_component.column,
					"`gather`'s component is a literal from 0 to 3 - red, green, blue or alpha");
				return CODEGEN_ERROR~;
			}
			third = self.const_int((int)written_component.literal.value);
		default:
			break;
	}
	if (args.len == fixed + 1) operands.offset = self.texel_offset(args[fixed], image)!;

	Opcode opcode;
	Type*  result = float4;
	switch (method)
	{
		case "sample":
		case "sample_bias":           opcode = Opcode.IMAGE_SAMPLE_IMPLICIT_LOD;
		case "sample_lod":
		case "sample_grad":           opcode = Opcode.IMAGE_SAMPLE_EXPLICIT_LOD;
		case "sample_cmp":            opcode = Opcode.IMAGE_SAMPLE_DREF_IMPLICIT_LOD; result = float_t;
		case "sample_cmp_lod":
		case "sample_cmp_level_zero": opcode = Opcode.IMAGE_SAMPLE_DREF_EXPLICIT_LOD; result = float_t;
		case "gather":                opcode = Opcode.IMAGE_GATHER;
		default:                      opcode = Opcode.IMAGE_DREF_GATHER;
	}

	Id sampled = self.sampled_image_of(texture, separate ? &sampler : null);
	return (Value) { .type = result, .id = self.image_instruction(opcode, result, sampled, coord, third, operands) };
}

<*
 `tex.load(coordinate, level)`, and Slang's `tex.Load(coordinate_and_level)`:
 one texel, read by its integer address without a sampler, so no filtering
 and no wrapping. A cube map is refused - its faces have no single address
 space - and so is a float level, which would be a sample rather than a fetch.
*>
fn Value? Codegen.texture_load(&self, Expr* expr, Value texture, bool packed, String written)
{
	Type*   image = texture.type;
	Expr*[] args  = expr.call.args;
	if (image.dim == Dim.CUBE)
	{
		self.fail(expr.line, expr.column, "a cube map has no texel addresses - sample it with a direction");
		return CODEGEN_ERROR~;
	}

	usz fixed = packed ? 1 : 2;
	if (args.len != fixed && args.len != fixed + 1)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`%s` takes %d arguments, or %d with a texel offset - and no sampler", written, fixed, fixed + 1));
		return CODEGEN_ERROR~;
	}

	uint  width = image.coordinate_components();
	uint  want  = packed ? width + 1 : width;
	Type* int_t = self.types.find("int");
	Value coordinate = self.expression(args[0])!;
	Type* scalar     = coordinate.type.scalar();
	bool  integer    = (scalar.kind == INT || scalar.kind == UINT) && scalar.width() == 32
		&& (coordinate.type.kind == VECTOR || coordinate.type.is_scalar());
	if (!integer || coordinate.type.components() != want)
	{
		Type*  expected = want == 1 ? int_t : self.vector_of(int_t, want);
		String hint     = packed ? " - the mip level is its last component" : (image.arrayed ? " - the last component is the array layer" : "");
		self.fail(args[0].line, args[0].column, string::format(self.allocator,
			"`%s` on a %s takes an %s address, got a %s%s",
			written, image.name, expected.name, coordinate.type.name, hint));
		return CODEGEN_ERROR~;
	}

	ImageOperands operands;
	Id address;
	if (packed)
	{
		// The level rides in the last component; the rest is the address.
		Id whole = self.rvalue(coordinate);
		operands.lod = self.func.composite_extract(self.type_id(scalar), whole, width);
		if (width == 1)
		{
			address = self.func.composite_extract(self.type_id(scalar), whole, 0);
		}
		else
		{
			Id[4] parts;
			for (uint i = 0; i < width; i++) parts[i] = self.func.composite_extract(self.type_id(scalar), whole, i);
			address = self.func.composite_construct(self.type_id(self.vector_of(scalar, width)), parts[0:width]);
		}
	}
	else
	{
		address      = self.rvalue(coordinate);
		operands.lod = self.texel_level(args[1], written)!;
	}
	if (args.len == fixed + 1) operands.offset = self.texel_offset(args[fixed], image)!;

	Type* float4 = self.types.find("float4");
	Id    id     = self.image_instruction(Opcode.IMAGE_FETCH, float4, self.image_of(texture), address, NO_ID, operands);
	return (Value) { .type = float4, .id = id };
}

<*
 `tex.size(level)`: the extent of one mip level, as an int or an int vector -
 one number per dimension, plus the layer count of an arrayed texture. The
 level is optional and 0 by default, the full-size image.
*>
fn Value? Codegen.texture_size(&self, Expr* expr, Value texture)
{
	if (expr.call.args.len > 1)
	{
		self.fail(expr.line, expr.column, "`size` takes at most one argument, the mip level");
		return CODEGEN_ERROR~;
	}
	Id level = expr.call.args.len ? self.texel_level(expr.call.args[0], "size")! : self.const_int(0);

	uint  count  = texture.type.size_components();
	Type* int_t  = self.types.find("int");
	Type* result = count == 1 ? int_t : self.vector_of(int_t, count);
	self.mod.capability(Capability.IMAGE_QUERY);
	Id id = self.func.emit(Opcode.IMAGE_QUERY_SIZE_LOD, self.type_id(result), self.image_of(texture), level);
	return (Value) { .type = result, .id = id };
}

<*
 `tex.levels()`: how many mip levels the bound view has.
*>
fn Value? Codegen.texture_levels(&self, Expr* expr, Value texture)
{
	if (expr.call.args.len)
	{
		self.fail(expr.line, expr.column, "`levels` takes no arguments");
		return CODEGEN_ERROR~;
	}
	Type* int_t = self.types.find("int");
	self.mod.capability(Capability.IMAGE_QUERY);
	Id id = self.func.emit(Opcode.IMAGE_QUERY_LEVELS, self.type_id(int_t), self.image_of(texture));
	return (Value) { .type = int_t, .id = id };
}

<*
 The sampled image a sampling instruction reads. A combined descriptor is one
 already; a separate texture is paired with its sampler here, and the pairing
 is non-uniform when either half was picked by a non-uniform index.
*>
fn Id Codegen.sampled_image_of(&self, Value texture, Value* sampler)
{
	Id image = self.load_descriptor(texture);
	if (!sampler) return image;

	Id sampled = self.func.sampled_image(self.mod.type_sampled_image(self.type_id(texture.type)),
		image, self.load_descriptor(*sampler));
	if (texture.non_uniform || sampler.non_uniform) self.mod.decorate(sampled, Decoration.NON_UNIFORM);
	return sampled;
}

<*
 The image alone, which is what a fetch or a query reads: a separate texture
 is one, and a combined descriptor gives up its image half through OpImage.
*>
fn Id Codegen.image_of(&self, Value texture)
{
	Id loaded = self.load_descriptor(texture);
	if (texture.type.kind == TEXTURE) return loaded;

	Id image = self.func.unop(Opcode.IMAGE, self.image_type_id(texture.type), loaded);
	if (texture.non_uniform) self.mod.decorate(image, Decoration.NON_UNIFORM);
	return image;
}

<*
 A sampling coordinate: a float, or a float vector as wide as the image's
 extent plus its layer. Exactly that wide - SPIR-V would read a wider vector's
 first components and ignore the rest, but a coordinate one too wide or one
 too narrow is almost always a forgotten or a stray array layer.
*>
fn Id? Codegen.texture_coordinate(&self, Expr* arg, Type* image, String written)
{
	uint  width    = image.coordinate_components();
	Type* float_t  = self.types.find("float");
	Type* expected = width == 1 ? float_t : self.vector_of(float_t, width);

	Value value = self.expression(arg)!;
	if (value.type == expected) return self.rvalue(value);
	if (width == 1 && arg.kind == INT_LITERAL) return self.coerce(value, expected, arg);

	self.fail(arg.line, arg.column, string::format(self.allocator,
		"`%s` on a %s takes a %s coordinate, got a %s%s", written, image.name, expected.name, value.type.name,
		image.arrayed ? " - the last component is the array layer" : ""));
	return CODEGEN_ERROR~;
}

<*
 A gradient for `sample_grad`: the rate the coordinate changes per pixel, as
 wide as the image's extent. The layer of an arrayed image has none.
*>
fn Id? Codegen.texture_gradient(&self, Expr* arg, Type* image, String written)
{
	uint  width    = image.extent_components();
	Type* float_t  = self.types.find("float");
	Type* expected = width == 1 ? float_t : self.vector_of(float_t, width);

	Value value = self.expression(arg)!;
	if (value.type == expected) return self.rvalue(value);

	self.fail(arg.line, arg.column, string::format(self.allocator,
		"`%s` on a %s takes a %s gradient, got a %s", written, image.name, expected.name, value.type.name));
	return CODEGEN_ERROR~;
}

<*
 A float operand of a sample - a bias, a level, a depth reference - with an
 integer converted the way an integer literal in a float slot always is, so
 `SampleLevel(uv, 0)` passes the level as the float SPIR-V requires.
*>
fn Id? Codegen.texture_float(&self, Expr* arg, String what, String written)
{
	Type* float_t = self.types.find("float");
	Value value   = self.expression(arg)!;
	if (value.type == float_t || value.type.kind == INT) return self.coerce(value, float_t, arg);

	self.fail(arg.line, arg.column, string::format(self.allocator,
		"`%s`'s %s is a float, got a %s", written, what, value.type.name));
	return CODEGEN_ERROR~;
}

<*
 The mip level a fetch or a size query reads: an integer, because it names a
 level rather than blending between two.
*>
fn Id? Codegen.texel_level(&self, Expr* arg, String written)
{
	Value value = self.expression(arg)!;
	if ((value.type.kind == INT || value.type.kind == UINT) && value.type.width() == 32) return self.rvalue(value);

	self.fail(arg.line, arg.column, string::format(self.allocator,
		"`%s`'s mip level is an integer, got a %s", written, value.type.name));
	return CODEGEN_ERROR~;
}

<*
 A constant texel offset: `int2(1, -1)` on a 2D texture, an `int3` on a 3D
 one, a bare integer on a 1D one. SPIR-V wants a constant here, and a
 constructor or a negation is an instruction that makes one at run time - so
 the offset is read off the syntax and emitted as a constant directly. A
 non-constant offset would need ImageGatherExtended, which is not asked for.
*>
fn Id? Codegen.texel_offset(&self, Expr* expr, Type* image)
{
	uint  width = image.extent_components();
	Type* int_t = self.types.find("int");
	Type* type  = width == 1 ? int_t : self.vector_of(int_t, width);

	int[3] values;
	bool   constant = false;
	if (width == 1)
	{
		constant = offset_literal(expr, &values[0]);
	}
	else if (expr.kind == CALL && expr.call.callee.kind == IDENT && expr.call.callee.ident.name == type.name)
	{
		usz count = expr.call.args.len;
		constant  = count == 1 || count == width;
		for (uint i = 0; constant && i < width; i++)
		{
			constant = offset_literal(expr.call.args[count == 1 ? 0 : i], &values[i]);
		}
	}
	if (!constant)
	{
		String example = width == 1 ? "-1" : (width == 2 ? "int2(1, -1)" : "int3(1, 0, -1)");
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"a texel offset is a constant `%s` of integer literals, such as `%s`", type.name, example));
		return CODEGEN_ERROR~;
	}

	Id[3] ids;
	for (uint i = 0; i < width; i++)
	{
		// The range every device supports; beyond it is the device's
		// minTexelOffset/maxTexelOffset to allow, and the result is
		// undefined where it does not.
		if (values[i] < -8 || values[i] > 7)
		{
			self.warn(expr.line, expr.column, string::format(self.allocator,
				"texel offset %d is outside [-8, 7], the range every device supports", values[i]));
		}
		ids[i] = self.const_int(values[i]);
	}
	if (width == 1) return ids[0];
	return self.mod.const_composite(self.type_id(type), ids[0:width]);
}

<*
 An integer literal, or a negated one: the two spellings of a constant offset
 component.
*>
fn bool offset_literal(Expr* expr, int* out) @private
{
	if (expr.kind == INT_LITERAL)
	{
		*out = (int)expr.literal.value;
		return true;
	}
	if (expr.kind == UNARY && expr.unary.op == MINUS && expr.unary.operand.kind == INT_LITERAL)
	{
		*out = -(int)expr.unary.operand.literal.value;
		return true;
	}
	return false;
}

<*
 Builtin functions. Most are GLSL.std.450 extended instructions; a few are core
 opcodes. Anything not listed is an error, not a guess.
*>
fn Value? Codegen.builtin_call(&self, Expr* expr, String name)
{
	IdListC    args;
	TypePtrList arg_types;
	args.init(self.allocator, 4);
	arg_types.init(self.allocator, 4);
	Type* first = null;

	foreach (arg : expr.call.args)
	{
		Value value = self.expression(arg)!;
		if (!first) first = value.type;
		args.push(self.rvalue(value));
		arg_types.push(value.type);
	}

	if (!first)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator, "`%s` needs arguments", name));
		return CODEGEN_ERROR~;
	}

	Type* float_t = self.types.find("float");

	// Core opcodes that are not extended instructions.
	switch (name)
	{
		case "dot":
			return self.dot_call(expr, args.array_view(), arg_types.array_view());
		case "transpose":
			// A floatCxR transposes to floatRxC.
			Type* result = self.types.find(string::format(self.allocator, "float%dx%d", first.element.count, first.count));
			return (Value) { .type = result, .id = self.func.unop(Opcode.TRANSPOSE, self.type_id(result), args[0]) };
		case "asuint":
		case "asint":
		case "asfloat":
		{
			String name_of = name == "asuint" ? "uint" : (name == "asint" ? "int" : "float");
			Type*  scalar  = self.types.find(name_of);
			Type*  result  = first.components() > 1 ? self.vector_of(scalar, first.components()) : scalar;
			return (Value) { .type = result, .id = self.func.unop(Opcode.BITCAST, self.type_id(result), args[0]) };
		}
		case "ashalf":
		{
			// A half from the low 16 bits of a 32-bit int: a bitcast wants equal
			// widths, so the word becomes a pair of halves and the low one (the
			// first component) is kept. No 16-bit integer type is needed.
			if ((first.kind != INT && first.kind != UINT) || first.width() != 32)
			{
				self.fail(expr.line, expr.column, "`ashalf` takes a 32-bit int or uint, the half in its low 16 bits");
				return CODEGEN_ERROR~;
			}
			Type* half_t = self.types.find("half");
			Id    pair   = self.mod.type_vector(self.type_id(half_t), 2);
			Id    cast   = self.func.unop(Opcode.BITCAST, pair, args[0]);
			return (Value) { .type = half_t, .id = self.func.composite_extract(self.type_id(half_t), cast, 0) };
		}
		case "any":
		case "all":
		{
			Type* bool_t = self.types.find("bool");
			Opcode opcode = name == "any" ? Opcode.ANY : Opcode.ALL;
			return (Value) { .type = bool_t, .id = self.func.unop(opcode, self.type_id(bool_t), args[0]) };
		}
		case "ddx":
		case "ddy":
		case "fwidth":
		{
			// Core opcodes, so they stay out of the GLSL.std.450 dispatch below.
			// The result has the operand's own shape, which is what GLSL's
			// `dFdx` family says as well. `fwidth` is |ddx| + |ddy| in one
			// instruction - the width of a pixel in the operand's units.
			self.require_stages(Stage.FRAGMENT.bit(), expr.line, expr.column, string::format(self.allocator,
				"`%s` is a screen-space derivative, which only a fragment shader has", name))!;
			Opcode opcode;
			switch (name)
			{
				case "ddx": opcode = Opcode.DPDX;
				case "ddy": opcode = Opcode.DPDY;
				default:    opcode = Opcode.FWIDTH;
			}
			return (Value) { .type = first, .id = self.func.unop(opcode, self.type_id(first), args[0]) };
		}
		default:
			break;
	}

	GlslOp instruction;
	Type* result = first;

	// A GLSL.std.450 instruction wants every operand the same type as its
	// result, so a vector operation with a scalar argument takes the vector's
	// shape - `mix(a, b, 0.5)` is the common case.
	foreach (type : arg_types)
	{
		if (type.kind == VECTOR) { result = type; break; }
	}

	// GLSL.std.450 has no unsigned `abs` or `sign`, and neither needs one: a
	// uint is its own absolute value, and its sign is 0 or 1.
	if (result.scalar().kind == UINT && (name == "abs" || name == "sign"))
	{
		if (name == "abs") return (Value) { .type = result, .id = args[0] };
		Id one = self.mod.const_u32(self.type_id(result.scalar()), 1);
		if (result.kind == VECTOR) one = self.splat(result, one);
		return (Value) { .type = result, .id = self.ext_inst(GlslOp.UMIN, result, (Id[]) { args[0], one }) };
	}

	switch (name)
	{
		case "abs":         instruction = self.by_sign(GlslOp.FABS, GlslOp.FABS, GlslOp.SABS, result);
		case "sign":        instruction = self.by_sign(GlslOp.FSIGN, GlslOp.FSIGN, GlslOp.SSIGN, result);
		case "floor":       instruction = GlslOp.FLOOR;
		case "ceil":        instruction = GlslOp.CEIL;
		case "round":       instruction = GlslOp.ROUND;
		case "fract":       instruction = GlslOp.FRACT;
		case "frac":        instruction = GlslOp.FRACT; // Slang's spelling
		case "sin":         instruction = GlslOp.SIN;
		case "cos":         instruction = GlslOp.COS;
		case "tan":         instruction = GlslOp.TAN;
		case "asin":        instruction = GlslOp.ASIN;
		case "acos":        instruction = GlslOp.ACOS;
		case "atan":        instruction = GlslOp.ATAN;
		case "atan2":       instruction = GlslOp.ATAN2;
		case "pow":         instruction = GlslOp.POW;
		case "exp":         instruction = GlslOp.EXP;
		case "log":         instruction = GlslOp.LOG;
		case "exp2":        instruction = GlslOp.EXP2;
		case "log2":        instruction = GlslOp.LOG2;
		case "sqrt":        instruction = GlslOp.SQRT;
		case "inversesqrt": instruction = GlslOp.INVERSE_SQRT;
		case "min":         instruction = self.by_sign(GlslOp.FMIN, GlslOp.UMIN, GlslOp.SMIN, result);
		case "max":         instruction = self.by_sign(GlslOp.FMAX, GlslOp.UMAX, GlslOp.SMAX, result);
		case "clamp":       instruction = self.by_sign(GlslOp.FCLAMP, GlslOp.UCLAMP, GlslOp.SCLAMP, result);
		case "mix":         instruction = GlslOp.FMIX;
		case "lerp":        instruction = GlslOp.FMIX;
		case "rsqrt":       instruction = GlslOp.INVERSE_SQRT;
		case "step":        instruction = GlslOp.STEP;
		case "smoothstep":  instruction = GlslOp.SMOOTHSTEP;
		case "normalize":   instruction = GlslOp.NORMALIZE;
		case "reflect":     instruction = GlslOp.REFLECT;
		case "refract":     instruction = GlslOp.REFRACT;
		case "faceforward": instruction = GlslOp.FACE_FORWARD;
		case "cross":       instruction = GlslOp.CROSS;
		case "inverse":
		case "determinant":
			if (first.kind != MATRIX || first.count != first.element.count)
			{
				self.fail(expr.line, expr.column, string::format(self.allocator,
					"`%s` takes a square matrix, got a %s", name, first.name));
				return CODEGEN_ERROR~;
			}
			instruction = name == "inverse" ? GlslOp.MATRIX_INVERSE : GlslOp.DETERMINANT;
			if (name == "determinant") result = first.scalar();
		case "length":      instruction = GlslOp.LENGTH;   result = float_t;
		case "distance":    instruction = GlslOp.DISTANCE; result = float_t;
		case "saturate":
			// Not a GLSL.std.450 instruction: clamp(x, 0, 1) spelled out.
			Id zero = self.const_float(0.0);
			Id one  = self.const_float(1.0);
			if (first.kind == VECTOR) { zero = self.splat(first, zero); one = self.splat(first, one); }
			return (Value) { .type = first, .id = self.ext_inst(GlslOp.FCLAMP, first, (Id[]) { args[0], zero, one }) };
		default:
			self.fail(expr.line, expr.column, string::format(self.allocator, "unknown function `%s`", name));
			return CODEGEN_ERROR~;
	}

	if (result.kind == VECTOR)
	{
		foreach (i, type : arg_types)
		{
			if (type.is_scalar()) args[i] = self.splat(result, args[i]);
		}
	}

	return (Value) { .type = result, .id = self.ext_inst(instruction, result, args.array_view()) };
}

<*
 `dot(a, b)`. `OpDot` is a float instruction, so an integer dot product is the
 multiply and the sum written out - SPIR-V before 1.6 has nothing shorter. The
 result is the operands' own scalar type, which is what keeps a `half` dot
 product half rather than claiming a float it is not.
*>
fn Value? Codegen.dot_call(&self, Expr* expr, Id[] args, Type*[] types)
{
	if (args.len != 2 || types[0] != types[1] || !types[0].scalar().is_numeric()
		|| (types[0].kind != VECTOR && !types[0].is_scalar()))
	{
		String got = args.len == 2
			? string::format(self.allocator, "a %s and a %s", types[0].name, types[1].name)
			: string::format(self.allocator, "%d arguments", args.len);
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"`dot` takes two numeric vectors of the same type, got %s", got));
		return CODEGEN_ERROR~;
	}

	Type* vector = types[0];
	Type* scalar = vector.scalar();
	bool  floats = scalar.kind == FLOAT;

	if (vector.kind != VECTOR)
	{
		Opcode multiply = floats ? Opcode.F_MUL : Opcode.I_MUL;
		return (Value) { .type = scalar, .id = self.func.binop(multiply, self.type_id(scalar), args[0], args[1]) };
	}
	if (floats)
	{
		return (Value) { .type = scalar, .id = self.func.binop(Opcode.DOT, self.type_id(scalar), args[0], args[1]) };
	}

	Id products = self.func.binop(Opcode.I_MUL, self.type_id(vector), args[0], args[1]);
	Id sum      = self.func.composite_extract(self.type_id(scalar), products, 0);
	for (uint i = 1; i < vector.count; i++)
	{
		Id component = self.func.composite_extract(self.type_id(scalar), products, i);
		sum = self.func.binop(Opcode.I_ADD, self.type_id(scalar), sum, component);
	}
	return (Value) { .type = scalar, .id = sum };
}

fn Id Codegen.ext_inst(&self, GlslOp instruction, Type* result, Id[] args)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 2 + args.len);
		// The instruction number is a word in the operand list, like every
		// other operand: `GlslOp` stops at this boundary.
		operands[0] = self.glsl;
		operands[1] = (Id)instruction;
		if (args.len) operands[2..] = args[..];
		return self.func.emit_slice(Opcode.EXT_INST, self.type_id(result), operands);
	};
}

// --- Statements --------------------------------------------------------------

<*
 Write an initialiser list into an array local, element by element.

 Element-wise rather than one composite constant, so an element may be any
 expression and the array is addressable from the moment it exists.
*>
fn void? Codegen.store_initializer(&self, Id pointer, Type* type, Expr* expr)
{
	if ((usz)type.count != expr.initializer.elements.len)
	{
		self.fail(expr.line, expr.column, string::format(self.allocator,
			"a %s initialiser needs %d elements, got %d",
			type.name, type.count, expr.initializer.elements.len));
		return CODEGEN_ERROR~;
	}

	foreach (i, element : expr.initializer.elements)
	{
		Id slot = self.func.access_chain(
			self.pointer_to(StorageClass.FUNCTION, type.element),
			pointer,
			(Id[]) { self.const_int((int)i) });
		Value value = self.expression(element)!;
		self.func.store(slot, self.coerce(value, type.element, element)!);
	}
}

struct LoopContext
{
	Id   merge;
	Id   continue_target;
	bool broken; // a `break` reached this loop's merge
}

alias LoopList = List{LoopContext};

fn void? Codegen.statement(&self, Stmt* stmt)
{
	switch (stmt.kind)
	{
		case BLOCK:
			usz scope = (usz)self.locals.len();
			foreach (inner : stmt.block.statements)
			{
				if (self.terminated) break; // unreachable code after a return
				self.statement(inner)!;
			}
			// Drop everything the scope declared; List exposes its size directly.
			self.locals.size = (sz)scope;

		case DECL:
			Type* type = self.resolve_type(stmt.decl.type, stmt.line, stmt.column)!;
			if (type.kind == ARRAY && type.runtime)
			{
				self.fail(stmt.line, stmt.column,
					"a runtime-sized array is only a member of an @storage block, where the host decides its length");
				return CODEGEN_ERROR~;
			}
			if (type.kind == RAY_QUERY)
			{
				// A query is the one handle a function holds: its own
				// traversal, started empty and aimed by `init`.
				if (stmt.decl.value)
				{
					self.fail(stmt.line, stmt.column, string::format(self.allocator,
						"`%s` cannot be initialised - a RayQuery starts empty, and `init` aims it", stmt.decl.name));
					return CODEGEN_ERROR~;
				}
			}
			else if (type.holds_handle())
			{
				Type* element = type.kind == ARRAY ? type.element : type;
				self.fail(stmt.line, stmt.column, element.kind == RAY_QUERY
					? string::format(self.allocator, "`%s` cannot be an array of RayQuery - declare one query per traversal", stmt.decl.name)
					: string::format(self.allocator,
						"`%s` cannot be a local - %s is a descriptor, declared at module level where the host binds it",
						stmt.decl.name, element.a_name(self.allocator)));
				return CODEGEN_ERROR~;
			}
			Id pointer = self.func.local(self.pointer_to(StorageClass.FUNCTION, type));
			self.mod.name(pointer, stmt.decl.name);
			if (stmt.decl.value)
			{
				if (type.kind == ARRAY && stmt.decl.value.kind == INITIALIZER)
				{
					self.store_initializer(pointer, type, stmt.decl.value)!;
				}
				else
				{
					Value value = self.expression(stmt.decl.value)!;
					self.func.store(pointer, self.coerce(value, type, stmt.decl.value)!);
				}
			}
			self.bind_local(stmt.decl.name, type, pointer);

		case EXPR:
			if (self.ray_terminator(stmt.expr.value)!) break;
			self.expression(stmt.expr.value)!;

		case RETURN:
			self.emit_return(stmt)!;

		case IF:
			self.emit_if(stmt)!;

		case WHILE:
			self.emit_loop(stmt.line, stmt.column, null, stmt.while_stmt.condition, null, stmt.while_stmt.body)!;

		case FOR:
			usz scope = (usz)self.locals.len();
			if (stmt.for_stmt.init) self.statement(stmt.for_stmt.init)!;
			self.emit_loop(stmt.line, stmt.column, null, stmt.for_stmt.condition, stmt.for_stmt.step, stmt.for_stmt.body)!;
			// Drop everything the scope declared; List exposes its size directly.
			self.locals.size = (sz)scope;

		case DISCARD:
			// OpKill ends a fragment's invocation; no other stage has one to end.
			self.require_stages(Stage.FRAGMENT.bit(), stmt.line, stmt.column,
				"`discard` ends a fragment, which only a fragment shader has - an any-hit shader drops a hit with `ignore_intersection()`")!;
			self.func.discard();
			self.terminated = true;

		case BREAK:
			if (!self.loops.len())
			{
				self.fail(stmt.line, stmt.column, "`break` is not inside a loop");
				return CODEGEN_ERROR~;
			}
			LoopContext* loop = &self.loops[self.loops.len() - 1];
			loop.broken = true;
			self.func.branch(loop.merge);
			self.terminated = true;

		case CONTINUE:
			if (!self.loops.len())
			{
				self.fail(stmt.line, stmt.column, "`continue` is not inside a loop");
				return CODEGEN_ERROR~;
			}
			self.func.branch(self.loops[self.loops.len() - 1].continue_target);
			self.terminated = true;
	}
}

<*
 An entry point returns nothing in SPIR-V: the declared return value is written
 to the stage's output variables instead.
*>
fn void? Codegen.emit_return(&self, Stmt* stmt)
{
	if (!stmt.ret.value)
	{
		// An entry point is emitted as a void function whose value goes to the
		// stage's outputs, so a bare `return;` is only wrong in a helper that
		// promised a value.
		if (self.outputs.len() == 0 && self.fn_return && self.fn_return.kind != VOID)
		{
			self.fail(stmt.line, stmt.column, "this function must return a value");
			return CODEGEN_ERROR~;
		}
		self.func.ret();
		self.terminated = true;
		return;
	}

	// A void function's `return` carries nothing - an entry point's included,
	// whose value would otherwise become an OpReturnValue in a function SPIR-V
	// declares as returning nothing.
	if (self.outputs.len() == 0 && (!self.fn_return || self.fn_return.kind == VOID))
	{
		self.fail(stmt.line, stmt.column, "this function returns void, so `return` takes no value");
		return CODEGEN_ERROR~;
	}

	Value value = self.expression(stmt.ret.value)!;

	if (self.outputs.len() == 0)
	{
		Id result = self.rvalue(value);
		if (self.fn_return && self.fn_return.kind != VOID) result = self.coerce(value, self.fn_return, stmt.ret.value)!;
		self.func.ret_value(result);
		self.terminated = true;
		return;
	}

	// A single output takes the whole value; several mean the value is the
	// output struct and each member goes to its own variable.
	if (self.outputs.len() == 1 && value.type.kind != STRUCT)
	{
		self.func.store(self.outputs[0].id, self.coerce(value, self.outputs[0].type, stmt.ret.value)!);
	}
	else
	{
		Id composite = self.rvalue(value);
		foreach (&output : self.outputs)
		{
			Id member = self.func.composite_extract(self.type_id(output.type), composite, (uint)output.member_index);
			self.func.store(output.id, member);
		}
	}

	self.func.ret();
	self.terminated = true;
}

<*
 A value usable as a branch condition.

 `if (p)` on a device address is `p != 0`, and the comparison is on the address
 as a 64-bit integer rather than on the pointer: Vulkan allows no ordering or
 equality on `PhysicalStorageBuffer` pointers, and an integer is what the
 address already is.

 Everything else has to already be a bool - a bare `if (1)` is refused where it
 is written rather than turned into a condition the branch cannot take.
*>
fn Id Codegen.condition(&self, Value value, Expr* expr)
{
	if (value.type.kind == BOOL) return self.rvalue(value);

	if (value.type.kind == POINTER)
	{
		Id ulong_t = self.mod.type_int(64, false);
		Id address = self.func.unop(Opcode.CONVERT_PTR_TO_U, ulong_t, self.rvalue(value));
		Id zero    = self.mod.const_u64(ulong_t, 0);
		return self.func.binop(Opcode.I_NOT_EQUAL, self.mod.type_bool(), address, zero);
	}

	self.fail(expr.line, expr.column, string::format(self.allocator,
		"a %s is not a condition", value.type.name));
	return self.rvalue(value);
}

fn void? Codegen.emit_if(&self, Stmt* stmt)
{
	Value condition = self.expression(stmt.if_stmt.condition)!;
	Id    test      = self.condition(condition, stmt.if_stmt.condition);

	Id then_label  = self.func.new_label();
	Id else_label  = stmt.if_stmt.else_branch ? self.func.new_label() : NO_ID;
	Id merge_label = self.func.new_label();

	self.func.selection_merge(merge_label);
	self.func.branch_conditional(test, then_label, else_label != NO_ID ? else_label : merge_label);

	self.func.label(then_label);
	self.terminated = false;
	self.statement(stmt.if_stmt.then_branch)!;
	bool then_left = self.terminated;
	if (!self.terminated) self.func.branch(merge_label);

	bool else_left = false;
	if (else_label != NO_ID)
	{
		self.func.label(else_label);
		self.terminated = false;
		self.statement(stmt.if_stmt.else_branch)!;
		else_left = self.terminated;
		if (!self.terminated) self.func.branch(merge_label);
	}

	self.func.label(merge_label);

	// When both arms returned (or broke, or discarded), nothing reaches the
	// merge - and the if as a whole ended its block, which is what lets
	// `if (b) return x; else return y;` close a function that returns a value.
	if (then_left && else_left)
	{
		self.func.unreachable();
		self.terminated = true;
		return;
	}
	self.terminated = false;
}

<*
 Both `while` and `for` lower to the same structured loop, which SPIR-V spells
 out with an explicit header, continue target and merge block.
*>
fn void? Codegen.emit_loop(&self, uint line, uint column, Stmt* unused, Expr* condition, Expr* step, Stmt* body)
{
	Id header_label   = self.func.new_label();
	Id condition_label = self.func.new_label();
	Id body_label     = self.func.new_label();
	Id continue_label = self.func.new_label();
	Id merge_label    = self.func.new_label();

	self.func.branch(header_label);

	self.func.label(header_label);
	self.func.loop_merge(merge_label, continue_label);
	self.func.branch(condition_label);

	// `for (;;)` and `while (true)` never leave through their condition, so
	// they branch straight into the body: the merge is then reached only by a
	// `break`, which is what tells a loop that ends its function from one that
	// falls out of it.
	bool forever = !condition || (condition.kind == BOOL_LITERAL && condition.boolean.value);

	self.func.label(condition_label);
	self.terminated = false;
	if (!forever)
	{
		Value test = self.expression(condition)!;
		self.func.branch_conditional(self.condition(test, condition), body_label, merge_label);
	}
	else
	{
		self.func.branch(body_label);
	}

	self.func.label(body_label);
	self.terminated = false;
	self.loops.push({ .merge = merge_label, .continue_target = continue_label });
	self.statement(body)!;
	bool broken = self.loops[self.loops.len() - 1].broken;
	self.loops.size = (sz)(self.loops.len() - 1);
	if (!self.terminated) self.func.branch(continue_label);

	self.func.label(continue_label);
	self.terminated = false;
	if (step) self.expression(step)!;
	self.func.branch(header_label);

	self.func.label(merge_label);
	if (forever && !broken)
	{
		self.func.unreachable();
		self.terminated = true;
		return;
	}
	self.terminated = false;
}
