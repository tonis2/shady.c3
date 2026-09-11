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
	uint  storage; // storage class of `pointer`
}

struct Local
{
	String name;
	Type*  type;
	Id     pointer;
}

struct Resource
{
	String    name;
	Type*     type;
	Id        id;
	uint      storage;
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
}

alias FunctionSigList = List{FunctionSig};
alias ValueList       = List{Value};

alias LocalList    = List{Local};
alias ResourceList = List{Resource};
alias StageVarList = List{StageVar};
alias IdListC      = List{Id};
alias StringList   = List{String};

struct Codegen
{
	Module*    mod;
	TypeTable* types;
	Ast*       ast;
	Allocator  allocator;

	ResourceList resources;
	LocalList    locals;
	FunctionSigList functions;
	LoopList     loops;

	Function*    func;
	Type*        fn_return;
	StageVarList inputs;
	StageVarList outputs;
	IdListC      interface_ids;
	bool         terminated; // current block already has a terminator

	Id glsl; // the GLSL.std.450 import

	<*
	 Set when the shader declares a `buffer`. The addressing model, the
	 capability and the SPIR-V version all change when it is, so it has to be
	 known before the header is written - see `compile`.
	*>
	bool uses_device_addresses;

	String error;
	uint   error_line;
	uint   error_column;
}

fn void Codegen.fail(&self, uint line, uint column, String message)
{
	if (self.error.len) return;
	self.error        = message;
	self.error_line   = line;
	self.error_column = column;
}

// --- Scope -------------------------------------------------------------------

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
		case INT:     type.id = self.mod.type_int(32, true);
		case UINT:    type.id = self.mod.type_int(32, false);
		case FLOAT:   type.id = self.mod.type_float(32);
		case VECTOR:  type.id = self.mod.type_vector(self.type_id(type.element), type.count);
		case MATRIX:  type.id = self.mod.type_matrix(self.type_id(type.element), type.count);
		case ARRAY:
		{
			Id length = self.mod.const_u32(self.type_id(self.types.find("uint")), type.count);
			type.id = self.mod.type_array(self.type_id(type.element), length);
			self.mod.decorate(type.id, DECORATION_ARRAY_STRIDE, type.stride);
			self.mod.name(type.id, type.name);
		}
		case SAMPLER: type.id = self.mod.type_sampler();
		case POINTER:
			// Buffer structs pre-declare their pointer type with
			// OpTypeForwardPointer, so it exists before this is reached.
			type.id = type.element.pointer_id;
		case TEXTURE: type.id = self.mod.type_image(self.type_id(type.element.element), type.dim);
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

fn Id Codegen.pointer_to(&self, uint storage_class, Type* type)
{
	return self.mod.type_pointer(storage_class, self.type_id(type));
}

<*
 A written type, resolved: an array wraps its element, and `T*` wraps an
 `@address` struct. `layout` decides an array's stride, so it must be the layout
 of the place the type sits - a block's, or the default for a local.
*>
fn Type*? Codegen.resolve_type(&self, TypeRef ref, Layout layout, uint line, uint column)
{
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
		return self.types.array_of(type, ref.array_size, layout);
	}

	if (ref.is_pointer)
	{
		if (type.block != ADDRESS)
		{
			self.fail(line, column, string::format(self.allocator,
				"`%s*` is not a device address - mark `%s` with @address to give it one",
				type.name, type.name));
			return CODEGEN_ERROR~;
		}
		return self.types.pointer_to(type);
	}

	return type;
}

// --- Constants ---------------------------------------------------------------

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
	return self.func.load(self.type_id(value.type), value.pointer, self.access_alignment(value));
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
	if (value.storage != STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER) return 0;
	return value.type.align(STD430);
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
		wide = self.func.unop(OP_BITCAST, ulong_t, self.func.unop(OP_S_CONVERT, long_t, self.rvalue(index)));
	}
	else
	{
		wide = self.func.unop(OP_U_CONVERT, ulong_t, self.rvalue(index));
	}

	Id stride  = self.mod.const_u64(ulong_t, element.size(STD430));
	Id address = self.func.unop(OP_CONVERT_PTR_TO_U, ulong_t, self.rvalue(base));
	Id offset  = self.func.binop(OP_I_MUL, ulong_t, wide, stride);
	Id target  = self.func.binop(OP_I_ADD, ulong_t, address, offset);

	Id pointer_type = self.mod.type_pointer(STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER, self.type_id(element));
	Id pointer      = self.func.unop(OP_CONVERT_U_TO_PTR, pointer_type, target);

	return (Value) { .type = element, .pointer = pointer, .storage = STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER };
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
		.storage = STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER,
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
				return (Value) { .type = local.type, .pointer = local.pointer, .storage = STORAGE_CLASS_FUNCTION };
			}
			if (Resource* resource = self.find_resource(expr.ident.name))
			{
				// Textures and samplers stay as pointers; they are only ever
				// loaded at the point of sampling.
				return (Value) { .type = resource.type, .pointer = resource.id, .storage = resource.storage };
			}
			self.fail(expr.line, expr.column, string::format(self.allocator, "unknown name `%s`", expr.ident.name));
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

	Type* member_type = base.type.members[index].type;

	// Addressable base keeps the result addressable, so it can be assigned to.
	if (base.pointer != NO_ID)
	{
		Id ptr = self.func.access_chain(self.mod.type_pointer(base.storage, self.type_id(member_type)),
			base.pointer, (Id[]) { self.const_int((int)index) });
		return (Value) { .type = member_type, .pointer = ptr, .storage = base.storage };
	}

	return (Value) { .type = member_type, .id = self.func.composite_extract(self.type_id(member_type), base.id, (uint)index) };
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
		return (Value) { .type = element, .pointer = ptr, .storage = base.storage };
	}

	self.fail(expr.line, expr.column, "indexing a temporary is not supported yet");
	return CODEGEN_ERROR~;
}

fn Value? Codegen.unary_expression(&self, Expr* expr)
{
	Value operand = self.expression(expr.unary.operand)!;
	Id    id      = self.rvalue(operand);
	Id    type    = self.type_id(operand.type);

	switch (expr.unary.op)
	{
		case MINUS:
			bool is_float = operand.type.scalar().kind == FLOAT;
			return (Value) { .type = operand.type, .id = self.func.unop(is_float ? OP_F_NEGATE : OP_S_NEGATE, type, id) };
		case BANG:
			return (Value) { .type = operand.type, .id = self.func.unop(OP_LOGICAL_NOT, type, id) };
		default:
			self.fail(expr.line, expr.column, "unsupported unary operator");
			return CODEGEN_ERROR~;
	}
}

fn Value? Codegen.assign_expression(&self, Expr* expr)
{
	Value target = self.expression(expr.assign.target)!;
	if (target.pointer == NO_ID)
	{
		self.fail(expr.line, expr.column, "cannot assign to this expression");
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
		TokenKind op;
		switch (expr.assign.op)
		{
			case PLUS_EQ:    op = PLUS;
			case MINUS_EQ:   op = MINUS;
			case STAR_EQ:    op = STAR;
			case SLASH_EQ:   op = SLASH;
			case AMP_EQ:     op = AMP;
			case PIPE_EQ:    op = PIPE;
			case CARET_EQ:   op = CARET;
			case SHL_EQ:     op = SHL;
			case SHR_EQ:     op = SHR;
			default:         op = PERCENT;
		}
		Value current = { .type = target.type, .id = self.rvalue(target) };
		id = self.arithmetic(op, current, value, expr)!;
	}

	self.func.store(target.pointer, id, self.access_alignment(target));
	return (Value) { .type = target.type, .id = id };
}

<*
 `condition ? then : else`, lowered to a real branch so only the taken arm runs.

 The result is written to a local in each arm and read back at the merge, which
 is also why a ternary is addressable.
*>
fn Value? Codegen.conditional_expression(&self, Expr* expr)
{
	Value condition = self.expression(expr.conditional.condition)!;

	Id then_label  = self.func.new_label();
	Id else_label  = self.func.new_label();
	Id merge_label = self.func.new_label();

	Id    pointer = NO_ID;
	Type* result  = null;

	self.func.selection_merge(merge_label);
	self.func.branch_conditional(self.rvalue(condition), then_label, else_label);

	self.func.label(then_label);
	self.terminated = false;
	Value then_value = self.expression(expr.conditional.then_value)!;
	result  = then_value.type;
	pointer = self.func.local(self.pointer_to(STORAGE_CLASS_FUNCTION, result));
	self.func.store(pointer, self.coerce(then_value, result, expr.conditional.then_value)!);
	if (!self.terminated) self.func.branch(merge_label);

	self.func.label(else_label);
	self.terminated = false;
	Value else_value = self.expression(expr.conditional.else_value)!;
	self.func.store(pointer, self.coerce(else_value, result, expr.conditional.else_value)!);
	if (!self.terminated) self.func.branch(merge_label);

	self.func.label(merge_label);
	self.terminated = false;
	return (Value) { .type = result, .pointer = pointer, .storage = STORAGE_CLASS_FUNCTION };
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
	Id    id    = self.arithmetic(expr.binary.op, left, right, expr)!;

	Type* result = self.result_type(expr.binary.op, left.type, right.type);
	return (Value) { .type = result, .id = id };
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
			return self.func.binop(OP_MATRIX_TIMES_VECTOR, self.type_id(rt), left_id, right_id);
		}
		if (lt.kind == MATRIX && rt.kind == MATRIX)
		{
			return self.func.binop(OP_MATRIX_TIMES_MATRIX, self.type_id(lt), left_id, right_id);
		}
		if (lt.kind == VECTOR && rt.kind == MATRIX)
		{
			return self.func.binop(OP_VECTOR_TIMES_MATRIX, self.type_id(lt), left_id, right_id);
		}
		if (lt.kind == MATRIX && rt.is_scalar())
		{
			return self.func.binop(OP_MATRIX_TIMES_SCALAR, self.type_id(lt), left_id, right_id);
		}
		if (lt.kind == VECTOR && rt.is_scalar())
		{
			return self.func.binop(OP_VECTOR_TIMES_SCALAR, self.type_id(lt), left_id, right_id);
		}
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

	bool is_float = lt.scalar().kind == FLOAT;
	bool is_signed = lt.scalar().kind == INT;
	Id   type      = self.type_id(lt);
	Id   bool_type = self.type_id(self.result_type(op, lt, rt));

	switch (op)
	{
		case PLUS:    return self.func.binop(is_float ? OP_F_ADD : OP_I_ADD, type, left_id, right_id);
		case MINUS:   return self.func.binop(is_float ? OP_F_SUB : OP_I_SUB, type, left_id, right_id);
		case STAR:    return self.func.binop(is_float ? OP_F_MUL : OP_I_MUL, type, left_id, right_id);
		case SLASH:   return self.func.binop(is_float ? OP_F_DIV : OP_S_DIV, type, left_id, right_id);
		case PERCENT: return self.func.binop(is_float ? OP_F_MOD : OP_S_MOD, type, left_id, right_id);
		case AMP:     return self.func.binop(OP_BITWISE_AND, type, left_id, right_id);
		case PIPE:    return self.func.binop(OP_BITWISE_OR, type, left_id, right_id);
		case CARET:   return self.func.binop(OP_BITWISE_XOR, type, left_id, right_id);
		case SHL:     return self.func.binop(OP_SHIFT_LEFT_LOGICAL, type, left_id, right_id);
		case SHR:     return self.func.binop(is_signed ? OP_SHIFT_RIGHT_ARITHMETIC : OP_SHIFT_RIGHT_LOGICAL, type, left_id, right_id);
		case EQ_EQ:   return self.func.binop(is_float ? OP_F_ORD_EQUAL : OP_I_EQUAL, bool_type, left_id, right_id);
		case BANG_EQ: return self.func.binop(is_float ? OP_F_ORD_NOT_EQUAL : OP_I_NOT_EQUAL, bool_type, left_id, right_id);
		case LT:      return self.func.binop(is_float ? OP_F_ORD_LESS_THAN : OP_S_LESS_THAN, bool_type, left_id, right_id);
		case LT_EQ:   return self.func.binop(is_float ? OP_F_ORD_LESS_THAN_EQUAL : OP_S_LESS_THAN_EQUAL, bool_type, left_id, right_id);
		case GT:      return self.func.binop(is_float ? OP_F_ORD_GREATER_THAN : OP_S_GREATER_THAN, bool_type, left_id, right_id);
		case GT_EQ:   return self.func.binop(is_float ? OP_F_ORD_GREATER_THAN_EQUAL : OP_S_GREATER_THAN_EQUAL, bool_type, left_id, right_id);
		case AMP_AMP: return self.func.binop(OP_LOGICAL_AND, bool_type, left_id, right_id);
		case PIPE_PIPE: return self.func.binop(OP_LOGICAL_OR, bool_type, left_id, right_id);
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
		return self.func.unop(OP_CONVERT_S_TO_F, self.type_id(expected), self.rvalue(value));
	}
	if (expected.kind == VECTOR && value.type.is_scalar())
	{
		return self.splat(expected, self.rvalue(value));
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
		if (decl.attributes.find("vertex") || decl.attributes.find("fragment") || decl.attributes.find("compute")) continue;

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
			Type* type = self.resolve_type(written[i].type, STD430, written[i].line, written[i].column)!;
			params[at] = type;
			names[at]  = written[i].name;
			refs[at]   = written[i].by_ref;
			outs[at]   = written[i].is_out;
			at++;
		}

		self.functions.push({
			.decl          = decl,
			.return_type   = return_type,
			.params        = params,
			.names         = names,
			.refs          = refs,
			.outs          = outs,
			.has_receiver  = receiver != null,
			.receiver_ref  = receiver_ref,
			.receiver_name = receiver_name,
		});
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
	sig.emitting = true;

	Decl* decl = sig.decl;

	Id[] param_ids = self.new_ids(sig.params.len);
	foreach (i, param : sig.params)
	{
		bool by_ref = (sig.has_receiver && sig.receiver_ref && i == 0) || sig.refs[i];
		param_ids[i] = by_ref
			? self.pointer_to(STORAGE_CLASS_FUNCTION, param)
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

	self.func       = &function;
	self.fn_return  = sig.return_type;
	self.terminated = false;
	self.inputs     = {};
	self.outputs    = {};

	usz at = 0;
	if (sig.has_receiver)
	{
		Type* receiver = sig.params[0];
		if (sig.receiver_ref)
		{
			// The parameter already is a pointer into the caller's storage, so
			// the receiver's members are reached through it directly.
			Id pid = function.param(self.pointer_to(STORAGE_CLASS_FUNCTION, receiver));
			self.locals.push({ .name = sig.receiver_name, .type = receiver, .pointer = pid });
		}
		else
		{
			Id pid     = function.param(self.type_id(receiver));
			Id pointer = function.local(self.pointer_to(STORAGE_CLASS_FUNCTION, receiver));
			function.store(pointer, pid);
			self.locals.push({ .name = sig.receiver_name, .type = receiver, .pointer = pointer });
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
			Id pid = function.param(self.pointer_to(STORAGE_CLASS_FUNCTION, param));
			self.locals.push({ .name = sig.names[i], .type = param, .pointer = pid });
		}
		else
		{
			Id pid     = function.param(self.type_id(param));
			Id pointer = function.local(self.pointer_to(STORAGE_CLASS_FUNCTION, param));
			function.store(pointer, pid);
			self.locals.push({ .name = sig.names[i], .type = param, .pointer = pointer });
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

	usz  total     = (usz)args.len() + (receiver ? (usz)1 : (usz)0);
	Id[] call_args = self.new_ids(total);
	usz  at        = 0;
	usz  offset    = 0;

	if (receiver)
	{
		if (sig.has_receiver && sig.receiver_ref)
		{
			call_args[at++] = self.receiver_pointer(*receiver);
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
			if (value.pointer == NO_ID || value.storage != STORAGE_CLASS_FUNCTION)
			{
				self.fail(expr.line, expr.column, "an out or inout argument must be a variable");
				return CODEGEN_ERROR~;
			}
			call_args[at++] = value.pointer;
		}
		else
		{
			call_args[at++] = self.coerce(value, sig.params[index], expr)!;
		}
	}

	Id result = self.func.call(self.type_id(sig.return_type), sig.func_id, call_args);
	return (Value) { .type = sig.return_type, .id = result };
}

<*
 The pointer a `&self` receiver is passed as.

 A value already in Function storage is passed by its own address, so writes
 through it would reach the caller. Anything else - a temporary, or a struct
 reached through a device address - is copied into a Function local first,
 which makes `&self` on those read-only for now.
*>
fn Id Codegen.receiver_pointer(&self, Value base)
{
	if (base.pointer != NO_ID && base.storage == STORAGE_CLASS_FUNCTION) return base.pointer;

	Id id  = self.rvalue(base);
	Id ptr = self.func.local(self.pointer_to(STORAGE_CLASS_FUNCTION, base.type));
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
		if (base.type.kind == TEXTURE) return self.sample_expression(expr, base, callee.member.name);
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
	if (name == "select") return self.select_call(expr);

	return self.builtin_call(expr, name);
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
	Id    condition_id = self.rvalue(condition);

	// OpSelect wants a condition of the same shape as its result, so a scalar
	// bool against a vector is broadcast.
	if (result.kind == VECTOR && condition.type.is_scalar())
	{
		condition_id = self.splat(self.vector_of(self.types.find("bool"), result.count), condition_id);
	}

	Id id = self.func.emit(OP_SELECT, self.type_id(result),
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

	// Scalar conversion: float(i), int(f), uint(i).
	if (type.is_scalar())
	{
		Value source = self.expression(args[0])!;
		if (source.type == type) return (Value) { .type = type, .id = self.rvalue(source) };

		uint opcode;
		Type* from = source.type.scalar();
		if (type.kind == FLOAT)     { opcode = from.kind == UINT ? OP_CONVERT_U_TO_F : OP_CONVERT_S_TO_F; }
		else if (from.kind == FLOAT) { opcode = type.kind == UINT ? OP_CONVERT_F_TO_U : OP_CONVERT_F_TO_S; }
		else                        { opcode = OP_BITCAST; }

		return (Value) { .type = type, .id = self.func.unop(opcode, self.type_id(type), self.rvalue(source)) };
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
	if (to.kind == FLOAT && from.kind != FLOAT)
	{
		return self.func.unop(from.kind == UINT ? OP_CONVERT_U_TO_F : OP_CONVERT_S_TO_F, self.type_id(to), id);
	}
	if (to.kind != FLOAT && from.kind == FLOAT)
	{
		return self.func.unop(to.kind == UINT ? OP_CONVERT_F_TO_U : OP_CONVERT_F_TO_S, self.type_id(to), id);
	}
	// int and uint are both 32 bits, so the bits move unchanged.
	if (to.kind != FLOAT && from.kind != FLOAT && to != from && to.is_scalar() && from.is_scalar())
	{
		return self.func.unop(OP_BITCAST, self.type_id(to), id);
	}
	return id;
}

<*
 `tex.sample(sampler, uv)` - the image and sampler are separate objects, paired
 into a sampled image only at the point of use.
*>
fn Value? Codegen.sample_expression(&self, Expr* expr, Value texture, String method)
{
	bool explicit_lod = method == "sample_lod";
	if (!explicit_lod && method != "sample")
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "a texture has no method `%s`", method));
		return CODEGEN_ERROR~;
	}

	usz wanted = explicit_lod ? 3 : 2;
	if (expr.call.args.len != wanted)
	{
		self.fail(expr.line, expr.column,
			string::format(self.allocator, "`%s` takes %d arguments", method, wanted));
		return CODEGEN_ERROR~;
	}

	Value sampler = self.expression(expr.call.args[0])!;
	if (sampler.type.kind != SAMPLER)
	{
		self.fail(expr.line, expr.column, "the first argument to sample must be a sampler");
		return CODEGEN_ERROR~;
	}

	Value coordinate = self.expression(expr.call.args[1])!;

	Id image_id   = self.func.load(self.type_id(texture.type), texture.pointer);
	Id sampler_id = self.func.load(self.type_id(sampler.type), sampler.pointer);

	Type* float4 = self.types.find("float4");
	Id    sampled_type = self.mod.type_sampled_image(self.type_id(texture.type));
	Id    sampled      = self.func.sampled_image(sampled_type, image_id, sampler_id);

	Id result;
	if (explicit_lod)
	{
		Value lod = self.expression(expr.call.args[2])!;
		result = self.func.image_sample_lod(self.type_id(float4), sampled, self.rvalue(coordinate), self.rvalue(lod));
	}
	else
	{
		result = self.func.image_sample(self.type_id(float4), sampled, self.rvalue(coordinate));
	}

	return (Value) { .type = float4, .id = result };
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
			return (Value) { .type = float_t, .id = self.func.binop(OP_DOT, self.type_id(float_t), args[0], args[1]) };
		case "transpose":
			// A floatCxR transposes to floatRxC.
			Type* result = self.types.find(string::format(self.allocator, "float%dx%d", first.element.count, first.count));
			return (Value) { .type = result, .id = self.func.unop(OP_TRANSPOSE, self.type_id(result), args[0]) };
		case "asuint":
		case "asint":
		case "asfloat":
		{
			String name_of = name == "asuint" ? "uint" : (name == "asint" ? "int" : "float");
			Type*  scalar  = self.types.find(name_of);
			Type*  result  = first.components() > 1 ? self.vector_of(scalar, first.components()) : scalar;
			return (Value) { .type = result, .id = self.func.unop(OP_BITCAST, self.type_id(result), args[0]) };
		}
		case "any":
		case "all":
		{
			Type* bool_t = self.types.find("bool");
			uint  opcode = name == "any" ? OP_ANY : OP_ALL;
			return (Value) { .type = bool_t, .id = self.func.unop(opcode, self.type_id(bool_t), args[0]) };
		}
		default:
			break;
	}

	uint  instruction;
	Type* result = first;

	// A GLSL.std.450 instruction wants every operand the same type as its
	// result, so a vector operation with a scalar argument takes the vector's
	// shape - `mix(a, b, 0.5)` is the common case.
	foreach (type : arg_types)
	{
		if (type.kind == VECTOR) { result = type; break; }
	}

	switch (name)
	{
		case "abs":         instruction = GLSL_FABS;
		case "sign":        instruction = GLSL_FSIGN;
		case "floor":       instruction = GLSL_FLOOR;
		case "ceil":        instruction = GLSL_CEIL;
		case "round":       instruction = GLSL_ROUND;
		case "fract":       instruction = GLSL_FRACT;
		case "sin":         instruction = GLSL_SIN;
		case "cos":         instruction = GLSL_COS;
		case "tan":         instruction = GLSL_TAN;
		case "asin":        instruction = GLSL_ASIN;
		case "acos":        instruction = GLSL_ACOS;
		case "atan":        instruction = GLSL_ATAN;
		case "pow":         instruction = GLSL_POW;
		case "exp":         instruction = GLSL_EXP;
		case "log":         instruction = GLSL_LOG;
		case "exp2":        instruction = GLSL_EXP2;
		case "log2":        instruction = GLSL_LOG2;
		case "sqrt":        instruction = GLSL_SQRT;
		case "inversesqrt": instruction = GLSL_INVERSE_SQRT;
		case "min":         instruction = GLSL_FMIN;
		case "max":         instruction = GLSL_FMAX;
		case "clamp":       instruction = GLSL_FCLAMP;
		case "mix":         instruction = GLSL_FMIX;
		case "lerp":        instruction = GLSL_FMIX;
		case "inversesqrt": instruction = GLSL_INVERSE_SQRT;
		case "rsqrt":       instruction = GLSL_INVERSE_SQRT;
		case "step":        instruction = GLSL_STEP;
		case "smoothstep":  instruction = GLSL_SMOOTHSTEP;
		case "normalize":   instruction = GLSL_NORMALIZE;
		case "reflect":     instruction = GLSL_REFLECT;
		case "refract":     instruction = GLSL_REFRACT;
		case "cross":       instruction = GLSL_CROSS;
		case "length":      instruction = GLSL_LENGTH;   result = float_t;
		case "distance":    instruction = GLSL_DISTANCE; result = float_t;
		case "saturate":
			// Not a GLSL.std.450 instruction: clamp(x, 0, 1) spelled out.
			Id zero = self.const_float(0.0);
			Id one  = self.const_float(1.0);
			if (first.kind == VECTOR) { zero = self.splat(first, zero); one = self.splat(first, one); }
			return (Value) { .type = first, .id = self.ext_inst(GLSL_FCLAMP, first, (Id[]) { args[0], zero, one }) };
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

fn Id Codegen.ext_inst(&self, uint instruction, Type* result, Id[] args)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 2 + args.len);
		operands[0] = self.glsl;
		operands[1] = instruction;
		if (args.len) operands[2..] = args[..];
		return self.func.emit_slice(OP_EXT_INST, self.type_id(result), operands);
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
			self.pointer_to(STORAGE_CLASS_FUNCTION, type.element),
			pointer,
			(Id[]) { self.const_int((int)i) });
		Value value = self.expression(element)!;
		self.func.store(slot, self.coerce(value, type.element, element)!);
	}
}

struct LoopContext
{
	Id merge;
	Id continue_target;
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
			Type* type = self.resolve_type(stmt.decl.type, STD430, stmt.line, stmt.column)!;
			Id pointer = self.func.local(self.pointer_to(STORAGE_CLASS_FUNCTION, type));
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
			self.locals.push({ .name = stmt.decl.name, .type = type, .pointer = pointer });

		case EXPR:
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
			self.func.discard();
			self.terminated = true;

		case BREAK:
			if (!self.loops.len())
			{
				self.fail(stmt.line, stmt.column, "`break` is not inside a loop");
				return CODEGEN_ERROR~;
			}
			self.func.branch(self.loops[self.loops.len() - 1].merge);
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

fn void? Codegen.emit_if(&self, Stmt* stmt)
{
	Value condition = self.expression(stmt.if_stmt.condition)!;

	Id then_label  = self.func.new_label();
	Id else_label  = stmt.if_stmt.else_branch ? self.func.new_label() : NO_ID;
	Id merge_label = self.func.new_label();

	self.func.selection_merge(merge_label);
	self.func.branch_conditional(self.rvalue(condition), then_label, else_label != NO_ID ? else_label : merge_label);

	self.func.label(then_label);
	self.terminated = false;
	self.statement(stmt.if_stmt.then_branch)!;
	if (!self.terminated) self.func.branch(merge_label);

	if (else_label != NO_ID)
	{
		self.func.label(else_label);
		self.terminated = false;
		self.statement(stmt.if_stmt.else_branch)!;
		if (!self.terminated) self.func.branch(merge_label);
	}

	self.func.label(merge_label);
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

	self.func.label(condition_label);
	self.terminated = false;
	if (condition)
	{
		Value test = self.expression(condition)!;
		self.func.branch_conditional(self.rvalue(test), body_label, merge_label);
	}
	else
	{
		self.func.branch(body_label);
	}

	self.func.label(body_label);
	self.terminated = false;
	self.loops.push({ .merge = merge_label, .continue_target = continue_label });
	self.statement(body)!;
	self.loops.size = (sz)(self.loops.len() - 1);
	if (!self.terminated) self.func.branch(continue_label);

	self.func.label(continue_label);
	self.terminated = false;
	if (step) self.expression(step)!;
	self.func.branch(header_label);

	self.func.label(merge_label);
	self.terminated = false;
}
