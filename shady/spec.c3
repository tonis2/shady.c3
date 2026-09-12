<*
 The slice of the SPIR-V specification this emitter uses.

 **Every numbering space is its own type.** `Opcode.LOAD` is not a `uint`, and
 neither is `GlslOp.FMIN` or `StorageClass.FUNCTION`, so an opcode cannot be
 passed where an extended instruction belongs and a bare number cannot be
 passed where either does. That is not decoration: the spaces overlap
 numerically - 37 is `FMin` and 137 is `UDiv` and 82 is `CompositeInsert` - and
 nothing but the spelling kept them apart before. The two mistakes this caught
 are the reasons the types exist:

  - `min(uint, uint)` emitted `FMin` with uint operands, because a builtin
    picked its instruction from a table of ints rather than from its operands;
  - `SSign` was written as 6, which is `FSign`, and only `spirv-val` noticed.

 `constdef` rather than `enum` because SPIR-V numbers are not ordinals and C3
 enumerators cannot carry a value. Sizes, counts, versions and literal data stay
 `uint` - they are numbers, not vocabulary.

 Reference: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html
*>
module shady;

// --- Module header -----------------------------------------------------------
const uint MAGIC = 0x07230203;
// 1.0 keeps the output loadable by the widest set of drivers. Raising this is
// a deliberate choice - buffer device address will need 1.3 or the
// SPV_KHR_physical_storage_buffer extension.
const uint VERSION_1_0 = 0x00010000;
const uint VERSION_1_3 = 0x00010300;
const uint VERSION_1_5 = 0x00010500;
// Khronos has not assigned this project a generator id, so use 0 ("unknown").
const uint GENERATOR = 0;

constdef Opcode : uint
{
	NOP                       = 0,
	UNDEF                     = 1,
	NAME                      = 5,
	MEMBER_NAME               = 6,
	EXTENSION                 = 10,
	EXT_INST_IMPORT           = 11,
	EXT_INST                  = 12,
	MEMORY_MODEL              = 14,
	ENTRY_POINT               = 15,
	EXECUTION_MODE            = 16,
	CAPABILITY                = 17,

	TYPE_VOID                 = 19,
	TYPE_BOOL                 = 20,
	TYPE_INT                  = 21,
	TYPE_FLOAT                = 22,
	TYPE_VECTOR               = 23,
	TYPE_MATRIX               = 24,
	TYPE_IMAGE                = 25,
	TYPE_SAMPLER              = 26,
	TYPE_SAMPLED_IMAGE        = 27,
	TYPE_ARRAY                = 28,
	TYPE_RUNTIME_ARRAY        = 29,
	TYPE_STRUCT               = 30,
	TYPE_POINTER              = 32,
	TYPE_FUNCTION             = 33,
	TYPE_FORWARD_POINTER      = 39,

	CONSTANT_TRUE             = 41,
	CONSTANT_FALSE            = 42,
	CONSTANT                  = 43,
	CONSTANT_COMPOSITE        = 44,
	SPEC_CONSTANT_TRUE        = 48,
	SPEC_CONSTANT_FALSE       = 49,
	SPEC_CONSTANT             = 50,

	FUNCTION                  = 54,
	FUNCTION_PARAMETER        = 55,
	FUNCTION_END              = 56,
	FUNCTION_CALL             = 57,

	VARIABLE                  = 59,
	LOAD                      = 61,
	STORE                     = 62,
	ACCESS_CHAIN              = 65,

	DECORATE                  = 71,
	MEMBER_DECORATE           = 72,

	VECTOR_SHUFFLE            = 79,
	COMPOSITE_CONSTRUCT       = 80,
	COMPOSITE_EXTRACT         = 81,
	COMPOSITE_INSERT          = 82,
	TRANSPOSE                 = 84,

	SAMPLED_IMAGE             = 86,
	IMAGE_SAMPLE_IMPLICIT_LOD = 87,
	IMAGE_SAMPLE_EXPLICIT_LOD = 88,
	IMAGE_SAMPLE_DREF_EXPLICIT_LOD = 90,

	CONVERT_F_TO_U            = 109,
	CONVERT_F_TO_S            = 110,
	CONVERT_S_TO_F            = 111,
	CONVERT_U_TO_F            = 112,
	U_CONVERT                 = 113,
	S_CONVERT                 = 114,
	CONVERT_PTR_TO_U          = 117,
	CONVERT_U_TO_PTR          = 120,
	BITCAST                   = 124,

	S_NEGATE                  = 126,
	F_NEGATE                  = 127,
	I_ADD                     = 128,
	F_ADD                     = 129,
	I_SUB                     = 130,
	F_SUB                     = 131,
	I_MUL                     = 132,
	F_MUL                     = 133,
	U_DIV                     = 134,
	S_DIV                     = 135,
	F_DIV                     = 136,
	U_MOD                     = 137,
	S_MOD                     = 139,
	F_MOD                     = 141,
	VECTOR_TIMES_SCALAR       = 142,
	MATRIX_TIMES_SCALAR       = 143,
	VECTOR_TIMES_MATRIX       = 144,
	MATRIX_TIMES_VECTOR       = 145,
	MATRIX_TIMES_MATRIX       = 146,
	DOT                       = 148,
	ANY                       = 154,
	ALL                       = 155,

	LOGICAL_OR                = 166,
	LOGICAL_AND               = 167,
	LOGICAL_NOT               = 168,
	SELECT                    = 169,
	I_EQUAL                   = 170,
	I_NOT_EQUAL               = 171,
	U_GREATER_THAN            = 172,
	S_GREATER_THAN            = 173,
	U_GREATER_THAN_EQUAL      = 174,
	S_GREATER_THAN_EQUAL      = 175,
	U_LESS_THAN               = 176,
	S_LESS_THAN               = 177,
	U_LESS_THAN_EQUAL         = 178,
	S_LESS_THAN_EQUAL         = 179,
	F_ORD_EQUAL               = 180,
	F_ORD_NOT_EQUAL           = 182,
	F_ORD_LESS_THAN           = 184,
	F_ORD_GREATER_THAN        = 186,
	F_ORD_LESS_THAN_EQUAL     = 188,
	F_ORD_GREATER_THAN_EQUAL  = 190,

	SHIFT_RIGHT_LOGICAL       = 194,
	SHIFT_RIGHT_ARITHMETIC    = 195,
	SHIFT_LEFT_LOGICAL        = 196,
	BITWISE_OR                = 197,
	BITWISE_XOR               = 198,
	BITWISE_AND               = 199,

	// Screen-space derivatives: core opcodes, not GLSL.std.450 instructions.
	DPDX                      = 207,
	DPDY                      = 208,

	ATOMIC_I_ADD              = 234,

	LOOP_MERGE                = 246,
	SELECTION_MERGE           = 247,
	LABEL                     = 248,
	BRANCH                    = 249,
	BRANCH_CONDITIONAL        = 250,
	KILL                      = 252,
	RETURN                    = 253,
	RETURN_VALUE              = 254,
}

// --- Enumerants --------------------------------------------------------------
constdef Capability : uint
{
	MATRIX                             = 0,
	SHADER                             = 1,
	INT64                              = 11,
	SHADER_NON_UNIFORM                 = 5301,
	RUNTIME_DESCRIPTOR_ARRAY           = 5302,
	PHYSICAL_STORAGE_BUFFER_ADDRESSES  = 5347,
}

constdef AddressingModel : uint
{
	LOGICAL                        = 0,
	PHYSICAL_STORAGE_BUFFER64      = 5348,
}

constdef MemoryModel : uint
{
	GLSL450 = 1,
}

constdef ExecutionModel : uint
{
	VERTEX      = 0,
	FRAGMENT    = 4,
	GL_COMPUTE  = 5,
}

constdef ExecutionMode : uint
{
	ORIGIN_UPPER_LEFT = 7,
	LOCAL_SIZE        = 17,
}

constdef StorageClass : uint
{
	UNIFORM_CONSTANT        = 0,
	INPUT                   = 1,
	UNIFORM                 = 2,
	OUTPUT                  = 3,
	WORKGROUP               = 4,
	FUNCTION                = 7,
	PUSH_CONSTANT           = 9,
	STORAGE_BUFFER          = 12,
	PHYSICAL_STORAGE_BUFFER = 5349,
}

<*
 Memory operands on OpLoad/OpStore. Every access through a
 PhysicalStorageBuffer pointer must carry ALIGNED plus a byte alignment - the
 hardware has no descriptor to tell it the alignment, so the shader states it.

 A bit field in the specification, and single-valued here: one operand at a
 time is all this emitter writes, so a `constdef` says what a mask type would
 not - that these are alternatives rather than flags to combine.
*>
constdef MemoryAccess : uint
{
	NONE    = 0x0,
	ALIGNED = 0x2,
}

<*
 Buffer device addresses were an extension before SPIR-V 1.5 folded them in.
 Emitting 1.3 plus the extension is accepted everywhere that supports the
 feature at all, which is wider than requiring 1.5.
*>
const String EXTENSION_PHYSICAL_STORAGE_BUFFER = "SPV_KHR_physical_storage_buffer";

constdef Decoration : uint
{
	SPEC_ID          = 1,
	BLOCK            = 2,
	ROW_MAJOR        = 4,
	COL_MAJOR        = 5,
	ARRAY_STRIDE     = 6,
	MATRIX_STRIDE    = 7,
	BUILTIN          = 11,
	FLAT             = 14,
	LOCATION         = 30,
	BINDING          = 33,
	DESCRIPTOR_SET   = 34,
	OFFSET           = 35,
	NON_UNIFORM      = 5300,
}

constdef Builtin : uint
{
	POSITION               = 0,
	POINT_SIZE             = 1,
	FRAG_COORD             = 15,
	FRONT_FACING           = 17,
	WORKGROUP_ID           = 26,
	LOCAL_INVOCATION_ID    = 27,
	GLOBAL_INVOCATION_ID   = 28,
	VERTEX_INDEX           = 42,
	INSTANCE_INDEX         = 43,
}

// The three control masks, each of which this emitter only ever writes as NONE.
constdef FunctionControl : uint
{
	NONE = 0,
}

constdef SelectionControl : uint
{
	NONE = 0,
}

constdef LoopControl : uint
{
	NONE = 0,
}

// OpTypeImage operands, spelled the way the specification writes them: `1D`,
// `2D`, `3D` and `Cube`.
constdef Dim : uint
{
	D1   = 0,
	D2   = 1,
	D3   = 2,
	CUBE = 3,
}

constdef ImageFormat : uint
{
	UNKNOWN = 0,
}

// "Sampled" operand of OpTypeImage: 1 = used with a sampler, 2 = storage image.
constdef SampledImage : uint
{
	WITH_SAMPLER = 1,
	STORAGE      = 2,
}

// Image operand bits, on an explicit or implicit sample instruction. Single
// bits here, and each sample instruction carries only one of them.
constdef ImageOperand : uint
{
	BIAS = 1,
	LOD  = 2,
	GRAD = 4,
}

constdef GlslOp : uint
{
	ROUND         = 1,
	TRUNC         = 3,
	FABS          = 4,
	SABS          = 5,
	FSIGN         = 6,
	SSIGN         = 7,
	FLOOR         = 8,
	CEIL          = 9,
	FRACT         = 10,
	SIN           = 13,
	COS           = 14,
	TAN           = 15,
	ASIN          = 16,
	ACOS          = 17,
	ATAN          = 18,
	ATAN2         = 25,
	POW           = 26,
	EXP           = 27,
	LOG           = 28,
	EXP2          = 29,
	LOG2          = 30,
	SQRT          = 31,
	INVERSE_SQRT  = 32,
	FMIN          = 37,
	UMIN          = 38,
	SMIN          = 39,
	FMAX          = 40,
	UMAX          = 41,
	SMAX          = 42,
	FCLAMP        = 43,
	UCLAMP        = 44,
	SCLAMP        = 45,
	FMIX          = 46,
	STEP          = 48,
	SMOOTHSTEP    = 49,
	LENGTH        = 66,
	DISTANCE      = 67,
	CROSS         = 68,
	NORMALIZE     = 69,
	REFLECT       = 71,
	REFRACT       = 72,
}
