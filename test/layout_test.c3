<*
 Scalar layout: the offsets three.c3's wire structs are built on.

 The shader is embedded from the conformance corpus, so the bytes decoded here
 are the same bytes `spirv-val` accepts in `conformance.c3`. Offsets are read
 back off `OpMemberDecorate ... Offset`, which is what the driver reads too.
*>
module layout_test;

import std::core::test;
import shady;
import shady_support;

const char[*] DRAW        = $embed("conformance/scalar_layout.shady");
const String  DRAW_SOURCE = (String)DRAW[..];

const char[*] POINTERS        = $embed("conformance/pointers.shady");
const String  POINTERS_SOURCE = (String)POINTERS[..];

const uint NOT_FOUND = 0xffffffff;

// --- Reading the module ------------------------------------------------------

<*
 The UTF-8 literal of an `OpName`, decoded out of its 32-bit words.
*>
fn String literal_at(uint* words, usz first, usz last) @private
{
	char[64] buffer;
	usz  n    = 0;
	bool done = false;
	for (usz w = first; w < last && !done; w++)
	{
		uint word = words[w];
		for (int b = 0; b < 4; b++)
		{
			char c = (char)((word >> (b * 8)) & 0xff);
			if (c == 0) { done = true; break; }
			if (n < buffer.len) buffer[n++] = c;
		}
	}
	return (String)buffer[:n];
}

<*
 The id of the named struct type, or 0. Two passes: find the name, then confirm
 what carries it is an `OpTypeStruct` rather than a variable with the same name.
*>
fn uint struct_named(uint* words, usz count, String name) @private
{
	uint named = 0;
	usz  i     = 5; // the five-word header comes first
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.NAME && literal_at(words, i + 2, i + len) == name) named = words[i + 1];
		i += len;
	}
	if (named == 0) return 0;

	i = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.TYPE_STRUCT && words[i + 1] == named) return named;
		i += len;
	}
	return 0;
}

fn uint member_offset(uint* words, usz count, uint struct_id, uint member) @private
{
	usz i = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.MEMBER_DECORATE && words[i + 1] == struct_id
			&& words[i + 2] == member && words[i + 3] == (uint)shady::Decoration.OFFSET)
		{
			return words[i + 4];
		}
		i += len;
	}
	return NOT_FOUND;
}

fn uint draw_offset(char[] spirv, uint member) @private
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint  draw  = struct_named(words, count, "Draw");
	if (draw == 0) return NOT_FOUND;
	return member_offset(words, count, draw, member);
}

<*
 The ArrayStride on the pointer to a struct, which is the struct's size - what
 `declare_structs` writes so tools can read the record stride off the module.
*>
fn uint struct_stride(uint* words, usz count, uint struct_id) @private
{
	uint pointer = 0;
	usz  i       = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.TYPE_POINTER && words[i + 3] == struct_id) pointer = words[i + 1];
		i += len;
	}
	if (pointer == 0) return NOT_FOUND;

	i = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.DECORATE && words[i + 1] == pointer
			&& words[i + 2] == (uint)shady::Decoration.ARRAY_STRIDE)
		{
			return words[i + 3];
		}
		i += len;
	}
	return NOT_FOUND;
}

fn uint offset_of(char[] spirv, String struct_name, uint member) @private
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint  id    = struct_named(words, count, struct_name);
	if (id == 0) return NOT_FOUND;
	return member_offset(words, count, id, member);
}

fn uint stride_of(char[] spirv, String struct_name) @private
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	uint  id    = struct_named(words, count, struct_name);
	if (id == 0) return NOT_FOUND;
	return struct_stride(words, count, id);
}

<*
 Whether any `OpDecorate ... ArrayStride` carries this value, which is how a
 pointer's element stride is read back off the module.
*>
fn bool has_array_stride(char[] spirv, uint value) @private
{
	uint* words = (uint*)spirv.ptr;
	usz   count = (usz)spirv.len / 4;
	usz   i     = 5;
	while (i < count)
	{
		uint word   = words[i];
		shady::Opcode opcode = (shady::Opcode)(word & 0xffff);
		usz  len    = (usz)(word >> 16);
		if (opcode == shady::Opcode.DECORATE && words[i + 2] == (uint)shady::Decoration.ARRAY_STRIDE
			&& words[i + 3] == value)
		{
			return true;
		}
		i += len;
	}
	return false;
}

// --- The pins ----------------------------------------------------------------

<*
 Every offset three.c3's `DrawRecord` relies on, read back from the module.
 A generator that lays the record out any other way reads geometry at the wrong
 address, so the whole struct is pinned rather than a sample of it.
*>
fn void scalar_layout_matches_the_wire_offsets() @test
{
	char[] spirv = shady_support::build(DRAW_SOURCE, scalar_layout: true);
	defer free(spirv);

	test::@check(draw_offset(spirv, 0) == 0, "addresses should start the record; got %d", draw_offset(spirv, 0));
	test::@check(draw_offset(spirv, 1) == 80, "base_color should be at 80; got %d", draw_offset(spirv, 1));
	test::@check(draw_offset(spirv, 2) == 96, "flags should be at 96; got %d", draw_offset(spirv, 2));
	test::@check(draw_offset(spirv, 3) == 100, "skin_stride should be at 100; got %d", draw_offset(spirv, 3));
	test::@check(draw_offset(spirv, 4) == 104, "morph_targets should be at 104; got %d", draw_offset(spirv, 4));
	test::@check(draw_offset(spirv, 5) == 108, "uv_transform should be at 108; got %d", draw_offset(spirv, 5));
	test::@check(draw_offset(spirv, 6) == 124, "surface should be at 124; got %d", draw_offset(spirv, 6));
	test::@check(draw_offset(spirv, 7) == 140, "uv_variant_count should be at 140; got %d", draw_offset(spirv, 7));
	test::@check(draw_offset(spirv, 8) == 144, "uv_variants should be at 144; got %d", draw_offset(spirv, 8));
	test::@check(draw_offset(spirv, 9) == 272, "emissive should be at 272; got %d", draw_offset(spirv, 9));
	test::@check(draw_offset(spirv, 10) == 288, "texture_index should be at 288; got %d", draw_offset(spirv, 10));

	// The two members that separate scalar layout from std430, seen through the
	// fields that follow them: a 36-byte float3x3 and 12-byte float3 taps.
	test::@check(draw_offset(spirv, 11) == 384, "basis should be at 384; got %d", draw_offset(spirv, 11));
	test::@check(draw_offset(spirv, 12) == 420, "taps should be at 420; got %d", draw_offset(spirv, 12));
	test::@check(draw_offset(spirv, 13) == 444, "after_taps should be at 444; got %d", draw_offset(spirv, 13));
}

<*
 The same struct laid out std140/std430: a float3 member aligns to 16, so
 `uv_transform` lands at 112 and the matrix and array both grow. This is the
 difference scalar mode exists to remove, stated as a test.
*>
fn void std430_rounds_a_float3_up_to_16() @test
{
	char[] spirv = shady_support::build(DRAW_SOURCE);
	defer free(spirv);

	test::@check(draw_offset(spirv, 1) == 80, "base_color should still be at 80; got %d", draw_offset(spirv, 1));
	test::@check(draw_offset(spirv, 5) == 112, "std430 should push uv_transform to 112; got %d", draw_offset(spirv, 5));
	test::@check(draw_offset(spirv, 10) == 304, "std430 should push texture_index to 304; got %d", draw_offset(spirv, 10));
	test::@check(draw_offset(spirv, 11) == 400, "std430 basis should start at 400; got %d", draw_offset(spirv, 11));
	test::@check(draw_offset(spirv, 12) == 448, "std430 taps should start at 448; got %d", draw_offset(spirv, 12));
	test::@check(draw_offset(spirv, 13) == 480, "std430 should end the record at 480; got %d", draw_offset(spirv, 13));
}

<*
 The other two wire structs the engine hands a shader, and the stride a skinned
 vertex is read at: `SkinnedVertex` is two `float3`, 24 bytes, which is what the
 posed-vertex array is indexed by.
*>
fn void the_push_blocks_and_the_skinned_vertex_stride() @test
{
	char[] spirv = shady_support::build(DRAW_SOURCE, scalar_layout: true);
	defer free(spirv);

	test::@check(offset_of(spirv, "MeshPush", 0) == 0, "MeshPush.frame should be at 0; got %d", offset_of(spirv, "MeshPush", 0));
	test::@check(offset_of(spirv, "MeshPush", 1) == 8, "MeshPush.instances should be at 8; got %d", offset_of(spirv, "MeshPush", 1));
	test::@check(offset_of(spirv, "MeshPush", 2) == 16, "MeshPush.draw should be at 16; got %d", offset_of(spirv, "MeshPush", 2));
	test::@check(stride_of(spirv, "MeshPush") == 24, "MeshPush should be 24 bytes; got %d", stride_of(spirv, "MeshPush"));

	test::@check(offset_of(spirv, "SkinnedVertex", 0) == 0, "SkinnedVertex.position should be at 0; got %d", offset_of(spirv, "SkinnedVertex", 0));
	test::@check(offset_of(spirv, "SkinnedVertex", 1) == 12, "SkinnedVertex.normal should be at 12; got %d", offset_of(spirv, "SkinnedVertex", 1));
	test::@check(stride_of(spirv, "SkinnedVertex") == 24, "SkinnedVertex should be 24 bytes; got %d", stride_of(spirv, "SkinnedVertex"));

	test::@check(offset_of(spirv, "PostPush", 0) == 0, "PostPush.info should be at 0; got %d", offset_of(spirv, "PostPush", 0));
	test::@check(offset_of(spirv, "PostPush", 1) == 16, "PostPush.planes should be at 16; got %d", offset_of(spirv, "PostPush", 1));
	test::@check(stride_of(spirv, "PostPush") == 24, "PostPush should be 24 bytes; got %d", stride_of(spirv, "PostPush"));
}

<*
 Indexing a device address strides by the pointee's size in the compile's
 layout, so `float3*` steps 12 bytes under scalar packing and 16 under std430 -
 the difference between reading every vertex and reading every third one.
 Read back off the `ArrayStride` decorations the pointer types carry.
*>
fn void pointer_strides_follow_the_layout() @test
{
	char[] scalar = shady_support::build(POINTERS_SOURCE, scalar_layout: true);
	defer free(scalar);

	test::@check(has_array_stride(scalar, 12), "a float3* should stride by 12 under scalar layout");
	test::@check(has_array_stride(scalar, 24), "a Vertex* should stride by 24 under scalar layout");
	test::@check(has_array_stride(scalar, 64), "a float4x4* should stride by 64 either way");

	char[] std430 = shady_support::build(POINTERS_SOURCE);
	defer free(std430);

	test::@check(has_array_stride(std430, 32), "a Vertex* should stride by 32 under std430");
	test::@check(!has_array_stride(std430, 12), "nothing should stride by 12 under std430");
	test::@check(has_array_stride(std430, 64), "a float4x4* should stride by 64 either way");
}

<*
 A struct nested inside a block is laid out by that block, and its members are
 decorated too - a `Block` cover its own members, but every struct inside one
 needs offsets of its own.
*>
fn void nested_structs_are_laid_out_by_the_block() @test
{
	char[] scalar = shady_support::build(DRAW_SOURCE, scalar_layout: true);
	defer free(scalar);

	test::@check(offset_of(scalar, "Inner", 1) == 12, "Inner.b should be at 12; got %d", offset_of(scalar, "Inner", 1));
	test::@check(offset_of(scalar, "Outer", 1) == 24, "Outer.tail should be at 24; got %d", offset_of(scalar, "Outer", 1));
	test::@check(stride_of(scalar, "Outer") == 40, "Outer should be 40 bytes; got %d", stride_of(scalar, "Outer"));
	test::@check(stride_of(scalar, "Pair") == 48, "an array of two 24-byte structs should be 48 bytes; got %d", stride_of(scalar, "Pair"));

	char[] std430 = shady_support::build(DRAW_SOURCE);
	defer free(std430);

	test::@check(offset_of(std430, "Inner", 1) == 16, "std430 Inner.b should be at 16; got %d", offset_of(std430, "Inner", 1));
	test::@check(offset_of(std430, "Outer", 1) == 32, "std430 Outer.tail should be at 32; got %d", offset_of(std430, "Outer", 1));
	test::@check(stride_of(std430, "Outer") == 48, "std430 Outer should be 48 bytes; got %d", stride_of(std430, "Outer"));
}

<*
 One struct name cannot be laid out two ways: the type is interned, so the
 second layout would win and half the fields would be read at the wrong offset.
 Declaring it in both a std140 uniform block and a std430 push block is refused
 rather than silently resolved.
*>
fn void a_nested_struct_cannot_be_shared_by_two_layouts() @test
{
	String error = shady_support::compile_error(`
struct Inner { float3 a; }
struct U @uniform { Inner inner; }
U u;
struct P @pushconstant { Inner inner; }
P p;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = float4(u.inner.a + p.inner.a, 1.0); return o; }
`);

	test::@check(error.contains("lays out differently"),
		"sharing a nested struct across differently laid-out blocks should be refused; got '%s'", error);
}

<*
 The same shader under scalar layout: both blocks agree, so the shared struct is
 laid out once and is legal.
*>
fn void scalar_layout_shares_a_nested_struct_happily() @test
{
	String error = shady_support::compile_error(`
struct Inner { float3 a; }
struct U @uniform { Inner inner; }
U u;
struct P @pushconstant { Inner inner; }
P p;

struct Out { float4 position @position; }
fn Out vert() @vertex { Out o; o.position = float4(u.inner.a + p.inner.a, 1.0); return o; }
`, scalar_layout: true);

	test::@check(error == "", "under scalar layout both blocks agree, so sharing is fine; got '%s'", error);
}

<*
 A matrix reached through a device address is read column by column.

 SPIR-V gives a matrix its layout with `ColMajor` and `MatrixStride`, both
 *member* decorations - a bare pointer has no member to carry them, and a plain
 `OpLoad` of a matrix through one leaves the stride unstated, which a driver
 resolves by reading all four columns from the first one's address. Four loads
 at the column stride and an `OpCompositeConstruct` say it with no decoration
 to hang it on, so that is what a matrix behind a pointer lowers to.

 The skin pass was the first shader to index a palette this way, and posed every
 vertex of a character with the same column before this.
*>
fn void a_matrix_behind_a_pointer_is_built_from_its_columns() @test
{
	char[] spirv = shady_support::build(`
struct Push @pushconstant
{
	float4x4* palette;
	uint      index;
}
Push push;

fn float4x4 pose()
{
	return push.palette[push.index];
}

struct Out { float4 position @position; }
fn Out vert() @vertex
{
	Out o;
	o.position = (pose() * float4(1.0, 0.0, 0.0, 1.0)).xyzw;
	return o;
}
`, scalar_layout: true);
	defer free(spirv);

	test::@check(shady_support::has_opcode(spirv, shady::Opcode.COMPOSITE_CONSTRUCT),
		"the matrix is one construct of four loaded columns");

	// The pointer itself carries the element stride, which is what the four
	// column loads are offset by.
	test::@check(shady_support::has_decoration_value(spirv, shady::Decoration.ARRAY_STRIDE, 64),
		"the palette pointer strides by one matrix");

	// And nothing decorates that pointer as a matrix: `ColMajor` on a pointer is
	// what the validator refuses ("can only be applied to structure members").
	test::@check(!shady_support::has_decoration(spirv, shady::Decoration.COL_MAJOR),
		"no ColMajor decoration, because it would have nothing legal to sit on");
}
