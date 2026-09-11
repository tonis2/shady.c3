<*
 Type and constant constructors.

 Scalars, vectors, matrices, pointers and function types are shared: SPIR-V
 requires non-aggregate types to be unique. Structs and arrays are not shared,
 because their decorations (Offset, Block, ArrayStride) belong to one specific
 declaration, and two structs with identical members are legitimately two
 different types.
*>
module shady;

import std::core::mem::alloc;

fn Id Module.type_void(&self) => self.unique(OP_TYPE_VOID);
fn Id Module.type_bool(&self) => self.unique(OP_TYPE_BOOL);

<*
 @param width : `bits per component, 8/16/32/64`
 @param is_signed : `signed integers get Signedness 1`
*>
fn Id Module.type_int(&self, uint width = 32, bool is_signed = true)
{
	return self.unique(OP_TYPE_INT, width, is_signed ? 1 : 0);
}

fn Id Module.type_float(&self, uint width = 32) => self.unique(OP_TYPE_FLOAT, width);

fn Id Module.type_vector(&self, Id component, uint count)
{
	return self.unique(OP_TYPE_VECTOR, component, count);
}

<*
 A matrix is a vector of column vectors, so `column` is the *column* type.
 A float4x4 is type_matrix(vec4, 4).
*>
fn Id Module.type_matrix(&self, Id column, uint count)
{
	// OpTypeMatrix needs the Matrix capability, which Shader implies.
	return self.unique(OP_TYPE_MATRIX, column, count);
}

fn Id Module.type_pointer(&self, uint storage_class, Id pointee)
{
	return self.unique(OP_TYPE_POINTER, storage_class, pointee);
}

<*
 Reserve a pointer id and declare its storage class before the pointee exists.

 A buffer struct may hold a pointer to itself, so the pointer type has to be
 nameable before the struct is declared.
*>
fn Id Module.type_forward_pointer(&self, uint storage_class)
{
	Id result = self.id();
	emit(&self.declarations, OP_TYPE_FORWARD_POINTER, result, storage_class);
	return result;
}

<*
 Define a pointer whose id was already reserved by type_forward_pointer.

 Registering it in the dedup cache under the key `type_pointer` uses is what
 stops a later `type_pointer(storage, pointee)` from minting a second pointer
 to the same struct - one that would be missing this one's ArrayStride.
*>
fn void Module.define_forward_pointer(&self, Id pointer, uint storage_class, Id pointee)
{
	emit(&self.declarations, OP_TYPE_POINTER, pointer, storage_class, pointee);
	self.cache_result(OP_TYPE_POINTER, pointer, storage_class, pointee);
}

fn Id Module.type_function(&self, Id return_type, Id[] parameters = {})
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 1 + parameters.len);
		operands[0] = return_type;
		if (parameters.len) operands[1..] = parameters[..];
		return self.unique_slice(OP_TYPE_FUNCTION, operands);
	};
}

<*
 A sampled image type, i.e. a texture. `depth`, `arrayed`, `multisampled` and
 `format` follow the OpTypeImage operand order.
*>
fn Id Module.type_image(&self, Id sampled_type, uint dim = DIM_2D, uint depth = 0, uint arrayed = 0,
                        uint multisampled = 0, uint sampled = IMAGE_SAMPLED_WITH_SAMPLER,
                        uint format = IMAGE_FORMAT_UNKNOWN)
{
	return self.unique(OP_TYPE_IMAGE, sampled_type, dim, depth, arrayed, multisampled, sampled, format);
}

fn Id Module.type_sampler(&self) => self.unique(OP_TYPE_SAMPLER);

fn Id Module.type_sampled_image(&self, Id image) => self.unique(OP_TYPE_SAMPLED_IMAGE, image);

<*
 An array with a compile-time length. `length` is the id of an integer
 constant, not a plain number.

 Not shared with an identical array: ArrayStride belongs to this declaration.
*>
fn Id Module.type_array(&self, Id element, Id length) => self.declare(OP_TYPE_ARRAY, element, length);

fn Id Module.type_runtime_array(&self, Id element) => self.declare(OP_TYPE_RUNTIME_ARRAY, element);

<*
 A struct type. Never shared - see the module comment.
*>
fn Id Module.type_struct(&self, Id[] members)
{
	return self.declare_slice(OP_TYPE_STRUCT, members);
}

// --- Constants ---------------------------------------------------------------

<*
 A 32-bit constant. The value is reinterpreted, not converted: pass the bit
 pattern for floats via const_f32.
*>
fn Id Module.const_u32(&self, Id type, uint bits) => self.unique_typed(OP_CONSTANT, type, bits);

<*
 A 64-bit constant. OpConstant carries a wide literal as two words, low first.
*>
fn Id Module.const_u64(&self, Id type, ulong value)
{
	return self.unique_typed(OP_CONSTANT, type, (uint)value, (uint)(value >> 32));
}

fn Id Module.const_f32(&self, Id float_type, float value)
{
	return self.unique_typed(OP_CONSTANT, float_type, bitcast(value, uint));
}

fn Id Module.const_i32(&self, Id int_type, int value)
{
	return self.unique_typed(OP_CONSTANT, int_type, bitcast(value, uint));
}

fn Id Module.const_true(&self, Id bool_type) => self.unique_typed(OP_CONSTANT_TRUE, bool_type);
fn Id Module.const_false(&self, Id bool_type) => self.unique_typed(OP_CONSTANT_FALSE, bool_type);

<*
 A specialization constant: the value is chosen when the pipeline is created,
 not baked in. Each is its own object - two with the same default but different
 spec ids are two constants - so these are declared unshared and decorated with
 `SpecId`. A 32-bit value is reinterpreted rather than converted, exactly as
 `OpConstant` is here.
*>
fn Id Module.spec_constant_u32(&self, Id type, uint bits, uint spec_id)
{
	Id id = self.declare_typed(OP_SPEC_CONSTANT, type, bits);
	self.decorate(id, DECORATION_SPEC_ID, spec_id);
	return id;
}

fn Id Module.spec_constant_i32(&self, Id type, int value, uint spec_id)
{
	return self.spec_constant_u32(type, bitcast(value, uint), spec_id);
}

fn Id Module.spec_constant_f32(&self, Id type, float value, uint spec_id)
{
	return self.spec_constant_u32(type, bitcast(value, uint), spec_id);
}

fn Id Module.spec_constant_bool(&self, Id type, bool value, uint spec_id)
{
	Id id = self.declare_typed(value ? OP_SPEC_CONSTANT_TRUE : OP_SPEC_CONSTANT_FALSE, type);
	self.decorate(id, DECORATION_SPEC_ID, spec_id);
	return id;
}

<*
 A vector, matrix, array or struct constant built from constant components.
*>
fn Id Module.const_composite(&self, Id type, Id[] components)
{
	return self.unique_typed_slice(OP_CONSTANT_COMPOSITE, type, components);
}

// --- Global variables --------------------------------------------------------

<*
 A variable in any storage class other than Function. Function-local variables
 belong to a Function - see Function.local.
*>
fn Id Module.global_var(&self, Id pointer_type, uint storage_class, Id initializer = NO_ID)
{
	if (initializer != NO_ID) return self.declare_typed(OP_VARIABLE, pointer_type, storage_class, initializer);
	return self.declare_typed(OP_VARIABLE, pointer_type, storage_class);
}
