<*
 Types and layout for the shady language (see LANGUAGE.md sections 2 and 7).

 The type table is built once per compile: builtins first, then one entry per
 user struct. Types are interned by name, so two references to `float4` are the
 same Type* and comparing types is a pointer comparison.
*>
module shady;

import std::collections::list;

enum TypeKind : char
{
	VOID,
	BOOL,
	INT,
	UINT,
	FLOAT,
	VECTOR,
	MATRIX,
	STRUCT,
	TEXTURE,
	SAMPLER,
	POINTER, // a buffer device address; `element` is the pointee
}

struct StructMember
{
	String      name;
	Type*       type;
	Attribute[] attributes;

	// Filled in by layout and stage lowering.
	uint offset;      // std140 byte offset, uniform blocks only
	uint location;    // stage I/O location
	bool is_position; // carries @position, so it is BuiltIn Position
	bool is_builtin;  // carries @builtin(...)
	uint builtin;     // the SPIR-V BuiltIn, when is_builtin
}

struct Type
{
	TypeKind kind;
	String   name;

	Type* element; // vector component type, or matrix column type
	uint  count;   // vector components, or matrix columns

	StructMember[] members; // STRUCT only
	uint           dim;     // TEXTURE only

	<*
	 A `buffer` struct: laid out std430 and only ever reached through a
	 device address, never bound as a descriptor.
	*>
	bool is_buffer;

	Id id;         // cached SPIR-V id, 0 until emitted
	Id pointer_id; // is_buffer only: the PhysicalStorageBuffer pointer to it
}

alias TypePtrList = List{Type*};

struct TypeTable
{
	Allocator   allocator;
	TypePtrList types;
}

fn Type* TypeTable.add(&self, TypeKind kind, String name, Type* element = null, uint count = 0, uint dim = 0)
{
	Type* type = alloc::new(self.allocator, Type);
	*type = { .kind = kind, .name = name, .element = element, .count = count, .dim = dim };
	self.types.push(type);
	return type;
}

<*
 The device-address pointer type for a buffer struct, created on first use and
 interned under the name `T*` so `Vertex*` written twice is one Type.
*>
fn Type* TypeTable.pointer_to(&self, Type* pointee)
{
	String name = string::format(self.allocator, "%s*", pointee.name);
	if (Type* existing = self.find(name)) return existing;
	return self.add(POINTER, name, pointee);
}

fn Type* TypeTable.find(&self, String name)
{
	foreach (type : self.types)
	{
		if (type.name == name) return type;
	}
	return null;
}

<*
 Register the builtin types. Names are spelled out rather than generated so
 that `find` stays a plain string match and a typo in a shader can never
 accidentally name a type that was never meant to exist.
*>
fn void TypeTable.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.types.init(allocator, 64);

	self.add(VOID, "void");
	Type* bool_t  = self.add(BOOL, "bool");
	Type* int_t   = self.add(INT, "int");
	Type* uint_t  = self.add(UINT, "uint");
	Type* float_t = self.add(FLOAT, "float");

	Type*[4] float_vectors;
	float_vectors[0] = float_t;

	String[3] vector_names = { "float2", "float3", "float4" };
	foreach (i, name : vector_names)
	{
		float_vectors[i + 1] = self.add(VECTOR, name, float_t, (uint)i + 2);
	}

	String[3] int_names  = { "int2", "int3", "int4" };
	String[3] uint_names = { "uint2", "uint3", "uint4" };
	String[3] bool_names = { "bool2", "bool3", "bool4" };
	foreach (i, name : int_names)  self.add(VECTOR, name, int_t, (uint)i + 2);
	foreach (i, name : uint_names) self.add(VECTOR, name, uint_t, (uint)i + 2);
	foreach (i, name : bool_names) self.add(VECTOR, name, bool_t, (uint)i + 2);

	// floatCxR: C columns of R rows, so the column type is floatR.
	for (uint columns = 2; columns <= 4; columns++)
	{
		for (uint rows = 2; rows <= 4; rows++)
		{
			String name = string::format(allocator, "float%dx%d", columns, rows);
			self.add(MATRIX, name, float_vectors[rows - 1], columns);
		}
	}

	self.add(TEXTURE, "texture1d", float_vectors[3], 0, DIM_1D);
	self.add(TEXTURE, "texture2d", float_vectors[3], 0, DIM_2D);
	self.add(TEXTURE, "texture3d", float_vectors[3], 0, DIM_3D);
	self.add(TEXTURE, "texturecube", float_vectors[3], 0, DIM_CUBE);
	self.add(SAMPLER, "sampler");
}

// --- Queries -----------------------------------------------------------------

fn bool Type.is_scalar(&self) => self.kind == BOOL || self.kind == INT || self.kind == UINT || self.kind == FLOAT;
fn bool Type.is_numeric(&self) => self.kind == INT || self.kind == UINT || self.kind == FLOAT;

<*
 Component count for scalars and vectors; 1 for a scalar. Meaningless for
 matrices and structs.
*>
fn uint Type.components(&self) => self.kind == VECTOR ? self.count : 1;

<*
 The scalar type underneath a scalar, vector or matrix.
*>
fn Type* Type.scalar(&self)
{
	switch (self.kind)
	{
		case VECTOR: return self.element;
		case MATRIX: return self.element.element;
		default:     return self;
	}
}

fn StructMember* Type.member(&self, String name)
{
	foreach (&m : self.members)
	{
		if (m.name == name) return m;
	}
	return null;
}

fn usz Type.member_index(&self, String name)
{
	foreach (i, &m : self.members)
	{
		if (m.name == name) return (usz)i;
	}
	return (usz)-1;
}

// --- Block layout ------------------------------------------------------------

<*
 Which layout rules apply to a block (LANGUAGE.md section 7).

 std140 governs uniform blocks; std430 governs push constants and everything
 reached through a buffer device address. They differ in exactly two places:
 std140 rounds a struct's alignment up to 16 and a matrix column stride up to
 16, std430 does neither.
*>
enum Layout : char
{
	STD140,
	STD430,
}

<*
 Byte alignment of a type under `layout`.

 The rule that catches people out: `float3` occupies 12 bytes but aligns to 16.
*>
fn uint Type.align(&self, Layout layout)
{
	switch (self.kind)
	{
		case BOOL:
		case INT:
		case UINT:
		case FLOAT:
			return 4;
		case VECTOR:
			return self.count == 2 ? 8 : 16;
		case MATRIX:
			// An array of column vectors, so the column's alignment.
			return self.element.align(layout);
		case POINTER:
			return 8; // a 64-bit device address
		case STRUCT:
			uint alignment = 4;
			foreach (&m : self.members)
			{
				uint member_alignment = m.type.align(layout);
				if (member_alignment > alignment) alignment = member_alignment;
			}
			return layout == STD140 ? round_up(alignment, 16) : alignment;
		default:
			return 16;
	}
}

<*
 The stride between the columns of a matrix, i.e. its MatrixStride decoration.
*>
fn uint Type.matrix_stride(&self, Layout layout) => self.element.align(layout);

fn uint Type.size(&self, Layout layout)
{
	switch (self.kind)
	{
		case BOOL:
		case INT:
		case UINT:
		case FLOAT:
			return 4;
		case VECTOR:
			return 4 * self.count;
		case MATRIX:
			return self.matrix_stride(layout) * self.count;
		case POINTER:
			return 8;
		case STRUCT:
			uint size = 0;
			foreach (&m : self.members)
			{
				size = round_up(size, m.type.align(layout));
				size += m.type.size(layout);
			}
			return round_up(size, self.align(layout));
		default:
			return 0;
	}
}

fn uint round_up(uint value, uint multiple) => (value + multiple - 1) / multiple * multiple;

<*
 Assign a block's member offsets, in place. Returns the block's total size,
 which is what a push constant range needs.
*>
fn uint Type.assign_offsets(&self, Layout layout)
{
	uint offset = 0;
	foreach (&m : self.members)
	{
		offset   = round_up(offset, m.type.align(layout));
		m.offset = offset;
		offset  += m.type.size(layout);
	}
	return round_up(offset, self.align(layout));
}

// --- Builtins ----------------------------------------------------------------

<*
 Map a `@builtin(name)` to its SPIR-V BuiltIn. Returns false for an unknown
 name so the caller can report it rather than emitting something wrong.
*>
fn bool builtin_from_name(String name, uint* out)
{
	switch (name)
	{
		case "vertex_index":         *out = BUILTIN_VERTEX_INDEX;
		case "instance_index":       *out = BUILTIN_INSTANCE_INDEX;
		case "frag_coord":           *out = BUILTIN_FRAG_COORD;
		case "global_invocation_id": *out = BUILTIN_GLOBAL_INVOCATION_ID;
		case "local_invocation_id":  *out = BUILTIN_LOCAL_INVOCATION_ID;
		case "workgroup_id":         *out = BUILTIN_WORKGROUP_ID;
		default: return false;
	}
	return true;
}

<*
 Decode a swizzle like "xyz" or "rgba" into component indices.

 Sets may not be mixed, so `v.xg` is rejected here rather than producing a
 confusing type error later.
*>
fn bool swizzle_indices(String text, uint[4]* out, uint* count)
{
	if (text.len == 0 || text.len > 4) return false;

	int set = -1; // 0 = xyzw, 1 = rgba
	foreach (i, c : text)
	{
		uint index;
		int  this_set;
		switch (c)
		{
			case 'x': index = 0; this_set = 0;
			case 'y': index = 1; this_set = 0;
			case 'z': index = 2; this_set = 0;
			case 'w': index = 3; this_set = 0;
			case 'r': index = 0; this_set = 1;
			case 'g': index = 1; this_set = 1;
			case 'b': index = 2; this_set = 1;
			case 'a': index = 3; this_set = 1;
			default: return false;
		}
		if (set == -1) { set = this_set; }
		else if (set != this_set) { return false; }
		(*out)[i] = index;
	}
	*count = (uint)text.len;
	return true;
}
