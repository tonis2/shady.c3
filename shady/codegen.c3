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

	if (base.type.kind != VECTOR && base.type.kind != MATRIX)
	{
		self.fail(expr.line, expr.column, "only vectors, matrices and device addresses can be indexed");
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
			default:         op = PERCENT;
		}
		Value current = { .type = target.type, .id = self.rvalue(target) };
		id = self.arithmetic(op, current, value, expr)!;
	}

	self.func.store(target.pointer, id, self.access_alignment(target));
	return (Value) { .type = target.type, .id = id };
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
			return self.types.find("bool");
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

// --- Calls -------------------------------------------------------------------

<*
 A call is one of three things, told apart by the callee rather than by a
 keyword: a type name is a constructor, a member call on a texture is a sample,
 and a plain name is a builtin function.
*>
fn Value? Codegen.call_expression(&self, Expr* expr)
{
	Expr* callee = expr.call.callee;

	if (callee.kind == MEMBER)
	{
		Value base = self.expression(callee.member.value)!;
		if (base.type.kind == TEXTURE) return self.sample_expression(expr, base, callee.member.name);

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

	return self.builtin_call(expr, name);
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
	IdListC args;
	args.init(self.allocator, 4);
	Type* first = null;

	foreach (arg : expr.call.args)
	{
		Value value = self.expression(arg)!;
		if (!first) first = value.type;
		args.push(self.rvalue(value));
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
		default:
			break;
	}

	uint  instruction;
	Type* result = first;

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

struct LoopContext
{
	Id merge;
	Id continue_target;
}

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
			Type* type = self.types.find(stmt.decl.type.name);
			if (!type)
			{
				self.fail(stmt.line, stmt.column,
					string::format(self.allocator, "unknown type `%s`", stmt.decl.type.name));
				return CODEGEN_ERROR~;
			}
			if (stmt.decl.type.is_pointer)
			{
				if (type.block != ADDRESS)
				{
					self.fail(stmt.line, stmt.column, string::format(self.allocator,
						"`%s*` is not a device address - mark `%s` with @address to give it one",
						type.name, type.name));
					return CODEGEN_ERROR~;
				}
				type = self.types.pointer_to(type);
			}
			Id pointer = self.func.local(self.pointer_to(STORAGE_CLASS_FUNCTION, type));
			self.mod.name(pointer, stmt.decl.name);
			if (stmt.decl.value)
			{
				Value value = self.expression(stmt.decl.value)!;
				self.func.store(pointer, self.coerce(value, type, stmt.decl.value)!);
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
		case CONTINUE:
			self.fail(stmt.line, stmt.column, "break and continue are not implemented yet");
			return CODEGEN_ERROR~;
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
		self.func.ret();
		self.terminated = true;
		return;
	}

	Value value = self.expression(stmt.ret.value)!;

	if (self.outputs.len() == 0)
	{
		self.func.ret_value(self.rvalue(value));
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
	self.statement(body)!;
	if (!self.terminated) self.func.branch(continue_label);

	self.func.label(continue_label);
	self.terminated = false;
	if (step) self.expression(step)!;
	self.func.branch(header_label);

	self.func.label(merge_label);
	self.terminated = false;
}
