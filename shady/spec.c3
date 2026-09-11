<*
 The slice of the SPIR-V specification this emitter uses.

 Only what is actually emitted is listed. Everything is a plain constant rather
 than an enum so that new opcodes can be dropped in without touching a type,
 and so operand words never need casting.

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

// --- Opcodes -----------------------------------------------------------------
const uint OP_NOP                       = 0;
const uint OP_UNDEF                     = 1;
const uint OP_NAME                      = 5;
const uint OP_MEMBER_NAME               = 6;
const uint OP_EXT_INST_IMPORT           = 11;
const uint OP_EXT_INST                  = 12;
const uint OP_MEMORY_MODEL              = 14;
const uint OP_ENTRY_POINT               = 15;
const uint OP_EXECUTION_MODE            = 16;
const uint OP_CAPABILITY                = 17;
const uint OP_EXTENSION                 = 10;

const uint OP_TYPE_VOID                 = 19;
const uint OP_TYPE_BOOL                 = 20;
const uint OP_TYPE_INT                  = 21;
const uint OP_TYPE_FLOAT                = 22;
const uint OP_TYPE_VECTOR               = 23;
const uint OP_TYPE_MATRIX               = 24;
const uint OP_TYPE_IMAGE                = 25;
const uint OP_TYPE_SAMPLER              = 26;
const uint OP_TYPE_SAMPLED_IMAGE        = 27;
const uint OP_TYPE_ARRAY                = 28;
const uint OP_TYPE_RUNTIME_ARRAY        = 29;
const uint OP_TYPE_STRUCT               = 30;
const uint OP_TYPE_POINTER              = 32;
const uint OP_TYPE_FUNCTION             = 33;
const uint OP_TYPE_FORWARD_POINTER      = 39;

const uint OP_CONSTANT_TRUE             = 41;
const uint OP_CONSTANT_FALSE            = 42;
const uint OP_CONSTANT                  = 43;
const uint OP_CONSTANT_COMPOSITE        = 44;
const uint OP_SPEC_CONSTANT_TRUE        = 48;
const uint OP_SPEC_CONSTANT_FALSE       = 49;
const uint OP_SPEC_CONSTANT             = 50;

const uint OP_FUNCTION                  = 54;
const uint OP_FUNCTION_PARAMETER        = 55;
const uint OP_FUNCTION_END              = 56;
const uint OP_FUNCTION_CALL             = 57;

const uint OP_VARIABLE                  = 59;
const uint OP_LOAD                      = 61;
const uint OP_STORE                     = 62;
const uint OP_ACCESS_CHAIN              = 65;

const uint OP_DECORATE                  = 71;
const uint OP_MEMBER_DECORATE           = 72;

const uint OP_VECTOR_SHUFFLE            = 79;
const uint OP_COMPOSITE_CONSTRUCT       = 80;
const uint OP_COMPOSITE_EXTRACT         = 81;

const uint OP_SAMPLED_IMAGE             = 86;
const uint OP_IMAGE_SAMPLE_IMPLICIT_LOD = 87;
const uint OP_IMAGE_SAMPLE_EXPLICIT_LOD = 88;
const uint OP_IMAGE_SAMPLE_DREF_EXPLICIT_LOD = 90;

const uint OP_CONVERT_F_TO_U            = 109;
const uint OP_CONVERT_F_TO_S            = 110;
const uint OP_CONVERT_S_TO_F            = 111;
const uint OP_CONVERT_U_TO_F            = 112;
const uint OP_U_CONVERT                 = 113;
const uint OP_S_CONVERT                 = 114;
const uint OP_CONVERT_PTR_TO_U          = 117;
const uint OP_CONVERT_U_TO_PTR          = 120;
const uint OP_BITCAST                   = 124;
const uint OP_ANY                       = 154;
const uint OP_ALL                       = 155;
const uint OP_SELECT                    = 169;
const uint OP_ATOMIC_I_ADD              = 234;

const uint OP_S_NEGATE                  = 126;
const uint OP_F_NEGATE                  = 127;
const uint OP_I_ADD                     = 128;
const uint OP_F_ADD                     = 129;
const uint OP_I_SUB                     = 130;
const uint OP_F_SUB                     = 131;
const uint OP_I_MUL                     = 132;
const uint OP_F_MUL                     = 133;
const uint OP_S_DIV                     = 135;
const uint OP_F_DIV                     = 136;
const uint OP_S_MOD                     = 139;
const uint OP_F_MOD                     = 141;
const uint OP_VECTOR_TIMES_SCALAR       = 142;
const uint OP_MATRIX_TIMES_SCALAR       = 143;
const uint OP_VECTOR_TIMES_MATRIX       = 144;
const uint OP_MATRIX_TIMES_VECTOR       = 145;
const uint OP_MATRIX_TIMES_MATRIX       = 146;
const uint OP_DOT                       = 148;

const uint OP_LOGICAL_OR                = 166;
const uint OP_LOGICAL_AND               = 167;
const uint OP_LOGICAL_NOT               = 168;
const uint OP_I_EQUAL                   = 170;
const uint OP_I_NOT_EQUAL               = 171;
const uint OP_F_ORD_EQUAL               = 180;
const uint OP_F_ORD_NOT_EQUAL           = 182;
const uint OP_F_ORD_LESS_THAN           = 184;
const uint OP_F_ORD_GREATER_THAN        = 186;
const uint OP_F_ORD_LESS_THAN_EQUAL     = 188;
const uint OP_F_ORD_GREATER_THAN_EQUAL  = 190;
const uint OP_S_LESS_THAN               = 177;
const uint OP_S_GREATER_THAN            = 173;
const uint OP_S_LESS_THAN_EQUAL         = 179;
const uint OP_S_GREATER_THAN_EQUAL      = 175;

const uint OP_LABEL                     = 248;
const uint OP_BRANCH                    = 249;
const uint OP_BRANCH_CONDITIONAL        = 250;
const uint OP_RETURN                    = 253;
const uint OP_RETURN_VALUE              = 254;
const uint OP_KILL                      = 252;
const uint OP_SELECTION_MERGE           = 247;
const uint OP_LOOP_MERGE                = 246;

// --- Enumerants --------------------------------------------------------------
const uint CAPABILITY_SHADER                          = 1;
const uint CAPABILITY_INT64                           = 11;
const uint CAPABILITY_MATRIX                          = 0;
const uint CAPABILITY_PHYSICAL_STORAGE_BUFFER_ADDRESSES = 5347;

const uint ADDRESSING_MODEL_LOGICAL                   = 0;
const uint ADDRESSING_MODEL_PHYSICAL_STORAGE_BUFFER64 = 5348;
const uint MEMORY_MODEL_GLSL450                       = 1;

const uint EXECUTION_MODEL_VERTEX    = 0;
const uint EXECUTION_MODEL_FRAGMENT  = 4;
const uint EXECUTION_MODEL_GLCOMPUTE = 5;

const uint EXECUTION_MODE_ORIGIN_UPPER_LEFT = 7;
const uint EXECUTION_MODE_LOCAL_SIZE        = 17;

const uint STORAGE_CLASS_UNIFORM_CONSTANT        = 0;
const uint STORAGE_CLASS_INPUT                   = 1;
const uint STORAGE_CLASS_UNIFORM                 = 2;
const uint STORAGE_CLASS_OUTPUT                  = 3;
const uint STORAGE_CLASS_WORKGROUP               = 4;
const uint STORAGE_CLASS_PUSH_CONSTANT           = 9;
const uint STORAGE_CLASS_STORAGE_BUFFER          = 12;
const uint STORAGE_CLASS_FUNCTION                = 7;
const uint STORAGE_CLASS_PHYSICAL_STORAGE_BUFFER = 5349;

<*
 Memory operands on OpLoad/OpStore. Every access through a
 PhysicalStorageBuffer pointer must carry ALIGNED plus a byte alignment - the
 hardware has no descriptor to tell it the alignment, so the shader states it.
*>
const uint MEMORY_ACCESS_NONE    = 0x0;
const uint MEMORY_ACCESS_ALIGNED = 0x2;

<*
 Buffer device addresses were an extension before SPIR-V 1.5 folded them in.
 Emitting 1.3 plus the extension is accepted everywhere that supports the
 feature at all, which is wider than requiring 1.5.
*>
const String EXTENSION_PHYSICAL_STORAGE_BUFFER = "SPV_KHR_physical_storage_buffer";

const uint DECORATION_BLOCK          = 2;
const uint DECORATION_ROW_MAJOR      = 4;
const uint DECORATION_COL_MAJOR      = 5;
const uint DECORATION_ARRAY_STRIDE   = 6;
const uint DECORATION_MATRIX_STRIDE  = 7;
const uint DECORATION_BUILTIN        = 11;
const uint DECORATION_FLAT           = 14;
const uint DECORATION_LOCATION       = 30;
const uint DECORATION_BINDING        = 33;
const uint DECORATION_SPEC_ID        = 1;
const uint DECORATION_DESCRIPTOR_SET = 34;
const uint DECORATION_OFFSET         = 35;

const uint BUILTIN_POSITION               = 0;
const uint BUILTIN_POINT_SIZE             = 1;
const uint BUILTIN_FRAG_COORD             = 15;
const uint BUILTIN_VERTEX_INDEX           = 42;
const uint BUILTIN_INSTANCE_INDEX         = 43;
const uint BUILTIN_WORKGROUP_ID           = 26;
const uint BUILTIN_LOCAL_INVOCATION_ID    = 27;
const uint BUILTIN_GLOBAL_INVOCATION_ID   = 28;

const uint FUNCTION_CONTROL_NONE = 0;
const uint SELECTION_CONTROL_NONE = 0;
const uint LOOP_CONTROL_NONE = 0;

// OpTypeImage operands.
const uint DIM_1D   = 0;
const uint DIM_2D   = 1;
const uint DIM_3D   = 2;
const uint DIM_CUBE = 3;

const uint IMAGE_FORMAT_UNKNOWN = 0;

// Image operand bits, on an explicit or implicit sample instruction.
const uint IMAGE_OPERAND_BIAS = 1;
const uint IMAGE_OPERAND_LOD  = 2;
const uint IMAGE_OPERAND_GRAD = 4;

// Descriptor indexing: a runtime-sized descriptor array needs the extension and
// RuntimeDescriptorArray, a non-uniform index into one needs ShaderNonUniform.
const uint CAPABILITY_RUNTIME_DESCRIPTOR_ARRAY = 5302;
const uint CAPABILITY_SHADER_NON_UNIFORM       = 5301;
const uint DECORATION_NON_UNIFORM              = 5300;

// "Sampled" operand of OpTypeImage: 1 = used with a sampler, 2 = storage image.
const uint IMAGE_SAMPLED_WITH_SAMPLER = 1;
const uint IMAGE_SAMPLED_STORAGE      = 2;

// --- GLSL.std.450 extended instructions --------------------------------------
// https://registry.khronos.org/SPIR-V/specs/unified1/GLSL.std.450.html
const uint GLSL_ROUND         = 1;
const uint GLSL_TRUNC         = 3;
const uint GLSL_FABS          = 4;
const uint GLSL_FSIGN         = 6;
const uint GLSL_FLOOR         = 8;
const uint GLSL_CEIL          = 9;
const uint GLSL_FRACT         = 10;
const uint GLSL_SIN           = 13;
const uint GLSL_COS           = 14;
const uint GLSL_TAN           = 15;
const uint GLSL_ASIN          = 16;
const uint GLSL_ACOS          = 17;
const uint GLSL_ATAN          = 18;
const uint GLSL_POW           = 26;
const uint GLSL_EXP           = 27;
const uint GLSL_LOG           = 28;
const uint GLSL_EXP2          = 29;
const uint GLSL_LOG2          = 30;
const uint GLSL_SQRT          = 31;
const uint GLSL_INVERSE_SQRT  = 32;
const uint GLSL_FMIN          = 37;
const uint GLSL_FMAX          = 40;
const uint GLSL_FCLAMP        = 43;
const uint GLSL_FMIX          = 46;
const uint GLSL_STEP          = 48;
const uint GLSL_SMOOTHSTEP    = 49;
const uint GLSL_LENGTH        = 66;
const uint GLSL_DISTANCE      = 67;
const uint GLSL_CROSS         = 68;
const uint GLSL_NORMALIZE     = 69;
const uint GLSL_REFLECT       = 71;
const uint GLSL_REFRACT       = 72;

const uint OP_TRANSPOSE = 84;

// Bitwise and shift, which need the operand types only to pick signedness.
const uint OP_SHIFT_RIGHT_LOGICAL    = 194;
const uint OP_SHIFT_RIGHT_ARITHMETIC = 195;
const uint OP_SHIFT_LEFT_LOGICAL     = 196;
const uint OP_BITWISE_OR             = 197;
const uint OP_BITWISE_XOR            = 198;
const uint OP_BITWISE_AND            = 199;
