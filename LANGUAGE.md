# The shady shader language

A small shader language that reads like C3, compiled to SPIR-V in-process at
runtime. Source files use the `.shady` extension, but the compiler's input is a
string — files are just one way to get one.

This document is the reference the tokenizer and parser are written against.
Where it says *reserved*, the syntax is accepted by neither yet but the design
leaves room for it.

## 1. Lexical structure

Source is UTF-8. Whitespace is insignificant except as a token separator.

```
// line comment
/* block comment, does not nest */
```

**Identifiers** match `[A-Za-z_][A-Za-z0-9_]*`.

**Keywords**: `fn` `struct` `const` `return` `if` `else` `while` `for` `break`
`continue` `discard` `true` `false`.
Reserved for later: `in` `out` `switch` `case` `default` `do`.

`uniform`, `buffer` and `push_constant` are *not* keywords — they used to be,
and are now ordinary identifiers, because what a block is comes from an
attribute on the struct (§3.2). The old spellings are recognised where they
used to appear and rejected with a message saying what to write instead.

Type names are *not* keywords. `float4` is an ordinary identifier that resolves
to a builtin type, so a user struct may shadow one (and gets diagnosed rather
than silently reinterpreted).

**Integer literals**: `123`, `0x7f`, `0b1010`. Underscores are permitted as
separators (`1_000`). Default type `int`; a `u` suffix makes it `uint`.

**Float literals**: `1.0`, `.5`, `1e-3`, `2.5f`. Default type `float`. A digit
is required before `e`. A bare `1` in a float context converts implicitly
(see §5.3).

**Operators and punctuation**:
```
( ) { } [ ] ; , . @
+ - * / %          + = - = * = / = % =   (as +=, -=, *=, /=, %=)
= == != < <= > >=
! && ||
& | ^ << >>
```

**Attributes** start with `@` and take an optional parenthesised argument list:
`@vertex`, `@location(0)`, `@set(1) @binding(0)`, `@threads(32, 1, 1)`.

## 2. Types

### 2.1 Scalars
`bool` `int` `uint` `float`

`int` and `uint` are 32-bit. `float` is 32-bit. `half` and `double` are
*reserved*.

### 2.2 Vectors and matrices
```
float2 float3 float4
int2   int3   int4
uint2  uint3  uint4
bool2  bool3  bool4
float2x2 float2x3 float2x4
float3x2 float3x3 float3x4
float4x2 float4x3 float4x4
```

`floatCxR` is C columns of R rows, matching SPIR-V's `OpTypeMatrix` of column
vectors. `float4x4` is therefore 4 columns of `float4`, emitted `ColMajor`
with `MatrixStride 16`.

### 2.3 Opaque types
```
texture1d texture2d texture3d texturecube texture2d_array texturecube_array
sampler
```
Opaque types may only appear as module-level resource declarations. They cannot
be struct members, locals, parameters, or return types.

### 2.4 Structs
```
struct FragmentIn
{
    float4 position @position;
    float4 color;
    float2 uv;
}
```
No trailing semicolon after the closing brace, as in C3. Members may carry
attributes. Structs may nest and may be used as parameter, return, local and
uniform types.

### 2.5 Pointers
```
Vertex* vertices;
```
A device address (§10). The pointee must be a `buffer`. There is no `&`, no
pointer arithmetic beyond `p[i]`, and no pointer-to-pointer.

### 2.6 Arrays
```
float4[16] palette;
float4 palette[16];   // the declarator form, as in C
```
The length may sit on the type or after the name. Arrays may be locals or
struct members, are indexed by a runtime value, and take an initialiser list:
`float2 taps[2] = { float2(0, 0), float2(1, 1) };`.

Reserved: runtime-sized arrays, needed for storage buffers. An array cannot be
a function parameter or return type - pass a device-address pointer instead.

## 3. Module-level declarations

A shader is a flat list of declarations in any order. Forward references are
allowed: the parser builds the whole list before names are resolved.

### 3.1 Functions
```
fn float4 tint(float4 base, float amount)
{
    return base * amount;
}
```
A function with no stage attribute is an ordinary function, emitted as an
`OpFunction` and called. A function with a stage attribute is an entry point
(§6). A call may appear before the function it names.

Functions may be **overloaded** by arity and parameter type. A call picks the
one candidate whose parameters accept its arguments (exact type, or an integer
literal where a float is wanted, or a scalar where a vector is wanted); a call
that matches none, or more than one, is an error rather than a guess.

A **method** is declared with a qualified name, C3-style:

```
fn float4 Map.Sample(&self, float2 uv)
{
    return tex.sample(s, uv);
}
```

The name before the dot is the receiver type. The first parameter is the
receiver: `&self` (a reference) or `self` (a copy) takes its type from the
qualified name, or the type may be written out -
`fn float4 Map.Sample(Map image, float2 uv)`. A call `image.Sample(uv)` passes
the receiver as the first argument.

`&self` arrives as a pointer into the caller's storage, so a write through it
is visible to the caller when the receiver is addressable (a local, or a
parameter). A temporary is copied into a local first, which makes `&self` on
one read-only.

A member call prefers a declared method over a free function spelled the same
way; a bare call still reaches a by-value method, passing the receiver as its
first argument. Methods overload like any other function, so two types may each
have a method of the same name and the receiver type picks between them.

A parameter may be `out` or `inout`, which pass it by reference: the callee
writes through a pointer to the caller's variable. `out` need not be
initialised; `inout` is copied in and out. The matching argument at a call site
must be a variable, not a temporary.

Recursion is not supported: a function that reaches itself is an error, since a
shader has no stack to recurse on.

### 3.2 Blocks

A block is an ordinary `struct` with an attribute. The attribute decides the
struct's layout, its storage class, and whether it takes a descriptor binding.

| Attribute | What the struct becomes | Layout | Binding |
|---|---|---|---|
| *(none)* | an ordinary struct — locals, parameters, stage I/O | — | — |
| `@uniform` | a uniform buffer | std140 | yes |
| `@pushconstant` | the pipeline's push constants | std430 | no |
| `@address` | the target of a device-address pointer (§10) | std430 | no |

Attributes go between the struct's name and its body, as in C3:

```
struct Uniforms @uniform
{
    float4x4 projection;
    float4x4 view;
}

struct Vertex @address
{
    float3 position;
    float4 color;
}

struct Push @pushconstant
{
    Vertex* vertices;
    uint    count;
}
```

A struct carries at most one of these; two is an error. A `@uniform` or
`@pushconstant` struct gets `Block` and per-member `Offset` decorations.

There is at most one `@pushconstant` block per shader, because Vulkan allows
one push constant block per pipeline.

### 3.3 Module-level variables

```
Uniforms  uniforms;                       // set 0, binding 0
texture2d tex;                            // set 0, binding 1
sampler   tex_sampler;                    // set 0, binding 2
Push      pc;                             // no binding: push constants
texture2d shadow_map @set(1) @binding(0);
```

A module-level variable is written `Type name;`. What kind of resource it is
comes entirely from the type — there are no `uniform`, `buffer` or
`push_constant` keywords.

Only some types may be bound: an opaque type (`texture2d`, `sampler`), a
`@uniform` struct, or a `@pushconstant` struct. A plain struct has no layout
and an `@address` struct is reached through a pointer, so neither can be a
variable.

Bindings are assigned in declaration order within each set, starting at 0.
An explicit `@set(n)` or `@binding(n)` pins that resource; auto-assignment
skips numbers already taken by explicit ones. Mixing the two is allowed;
a collision is an error rather than a silent overwrite. A `@pushconstant`
block takes no binding and does not consume one.

### 3.4 Constants
```
const float PI = 3.14159;
const float3 UP = float3(0.0, 1.0, 0.0);
```
Compile-time constants. The initialiser must be a constant expression.

## 4. Attributes

| Attribute | Applies to | Meaning |
|---|---|---|
| `@vertex` | function | Vertex entry point |
| `@vertex(name)` | function | …published under `name` instead of the function's (§6.1) |
| `@fragment` | function | Fragment entry point |
| `@fragment(name)` | function | …published under `name` |
| `@compute` | function | Compute entry point |
| `@compute(name)` | function | …published under `name` |
| `@threads(x, y, z)` | `@compute` function | Workgroup size, required on compute |
| `@uniform` | struct | A uniform buffer: std140, takes a binding |
| `@pushconstant` | struct | The pipeline's push constants: std430, no binding |
| `@address` | struct | Reached through a device address: std430, no binding |
| `@position` | struct member | `BuiltIn Position` instead of a location |
| `@location(n)` | struct member | Pin the location; others auto-assign around it |
| `@builtin(name)` | struct member / parameter | A SPIR-V builtin (§6.4) |
| `@set(n)` | module-level variable | Descriptor set |
| `@binding(n)` | module-level variable | Binding within the set |
| `@flat` | struct member | `Flat` interpolation |

A struct carries at most one of `@uniform`, `@pushconstant` and `@address`;
two is an error. Attributes sit between a struct's name and its body, and
after a function's signature, as in C3.

Unknown attributes are an error, not a warning — a typo'd `@framgent` that
silently produced no entry point would be a miserable thing to debug.

## 5. Expressions

### 5.1 Precedence

Highest to lowest. Binary operators are left-associative; assignment is
right-associative. This is C3's table, verified against c3c 0.8.3 rather than
assumed, and it differs from C in two places worth keeping.

```
 1.  postfix          a.b   a[i]   f(x)   a.xyzw   a++
 2.  unary            -a   !a   +a   ++a   --a
 3.  multiplicative   *  /  %
 4.  shift            <<  >>
 5.  bitwise          &  ^  |
 6.  additive         +  -
 7.  relational       <  <=  >  >=
 8.  equality         ==  !=
 9.  logical and      &&
10.  logical or       ||
11.  conditional      a ? b : c
12.  assignment       =  +=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=
```

Two deliberate departures from C, both inherited from C3:

- **Bitwise binds tighter than the comparisons.** `a & b == c` means
  `(a & b) == c`, not C's `a & (b == c)`. C's rule is a well-known footgun.
- **Shift and bitwise bind tighter than `+` and `-`.** `4 + 3 & 1` is
  `4 + (3 & 1)` = 5, and `4 + 3 << 1` is `4 + (3 << 1)` = 10.

And one rule that is not about precedence at all: **mixing two different
bitwise operators without parentheses is an error.** `a | b ^ c` and
`a & b | c` are both rejected, with a message asking for parentheses, exactly
as c3c rejects them. Guessing on that reader's behalf is worse than making
them say what they mean.

### 5.2 Swizzles
```
v.x  v.xy  v.xyz  v.xyzw      position set
v.r  v.rg  v.rgb  v.rgba      colour set
```
Sets may not be mixed (`v.xg` is an error). A swizzle of length 1 yields a
scalar. Repeats are allowed on reads (`v.xxy`); a swizzle used as an assignment
target must not repeat (`v.xx = ...` is an error).

### 5.3 Constructors and conversion
```
float4(1.0, 2.0, 3.0, 4.0)
float4(xyz, 1.0)              // float3 + scalar
float4(1.0)                   // splat
float4x4(c0, c1, c2, c3)      // from column vectors
int(f)  float(i)  uint(i)     // scalar conversion
```
Constructor arguments are consumed left to right until the component count is
filled; supplying too few or too many is an error.

A cast is written `(type)value` and differs from a constructor in that it may
narrow: `(float3x3)mat4` drops the fourth column and the fourth row,
`(uint3)v` converts a vector's components, `(float)i` converts a scalar,
`(float)v` takes a vector's first component. Only builtin type names are casts,
so `(x) - y` stays a subtraction.

Implicit conversion happens only for literals: an untyped integer literal in a
float context becomes a float. `int` to `float` on a *variable* requires an
explicit `float(x)`.

### 5.4 Operators on vectors and matrices
`+ - * /` on two vectors are component-wise. Vector-scalar broadcasts.
`matrix * vector` is `OpMatrixTimesVector`, `matrix * matrix` is
`OpMatrixTimesMatrix` — column-vector convention, so `projection * view * p`
applies `view` first.

## 6. Entry points

Every function carrying a stage attribute becomes an `OpEntryPoint`, and all of
them land in a single SPIR-V module. There is no pipeline declaration; the host
selects a stage by entry point name, through `pName` in
`VkPipelineShaderStageCreateInfo`.

A module may hold as many entry points as it likes, of any stage, including
several of the same stage:

```
fn FragmentIn stage_in(VertexIn input) @vertex(main) { ... }
fn FragmentIn stage_in_shadow(VertexIn input) @vertex { ... }

fn float4 shade_textured(FragmentIn input) @fragment(opaque) { ... }
fn float4 shade_solid(FragmentIn input) @fragment { ... }
```

That compiles to four entry points named `main`, `stage_in_shadow`, `opaque`
and `shade_solid` — one `VkShaderModule`, four things a pipeline can select.

### 6.1 Naming

An entry point is named after its function. A stage attribute may override
that with a single name argument:

```
fn float4 shade(FragmentIn input) @fragment(main)
```

publishes an entry point called `main`. That matters when the host hardcodes a
name, and it lets variants keep readable function names while presenting the
names a pipeline expects.

The function keeps its own name as `OpName`, separately from the name the entry
point publishes, so a disassembly still maps back to the source.

Two entry points may not share a name — the host has nothing else to tell them
apart by — and the argument must be a name, not a number.

### 6.2 Vertex
```
fn FragmentIn vert(VertexIn input) @vertex
```
The parameter struct's members become stage inputs, taking locations 0,1,2… in
declaration order. The return struct's members become stage outputs the same
way, except that a member marked `@position` becomes `BuiltIn Position` and is
skipped when assigning locations.

Exactly one member of a vertex output struct must be `@position`.

### 6.3 Fragment
```
fn float4 frag(FragmentIn input) @fragment
```
The parameter struct's members become stage inputs. Their locations must line
up with the vertex stage's outputs; since both stages are in one module this is
checked at compile time.

Returning `float4` writes location 0. Returning a struct writes one output per
member. `OriginUpperLeft` is always emitted.

`@position` means different things on the two sides of the interface, the way
`SV_Position` does in HLSL:

- as a **vertex output** it is `BuiltIn Position`, the clip-space position;
- as a **fragment input** it is `BuiltIn FragCoord`, the window-space fragment
  coordinate.

This is a translation, not a convenience: Vulkan rejects `BuiltIn Position` in a
fragment shader outright (`VUID-Position-Position-04318`), so one struct shared
between the two stages could not otherwise work. Note that the *generic* SPIR-V
validator accepts it and only `spirv-val --target-env vulkan1.3` catches it, so
validate against the Vulkan environment.

### 6.4 Builtins
Read via `@builtin(name)` on an input struct member:

| Name | Type | Stages |
|---|---|---|
| `vertex_index` | `uint` | vertex |
| `instance_index` | `uint` | vertex |
| `frag_coord` | `float4` | fragment |
| `global_invocation_id` | `uint3` | compute |
| `local_invocation_id` | `uint3` | compute |
| `workgroup_id` | `uint3` | compute |

## 7. Block layout

Two layouts are used, and which one applies depends on the block:

| Block | Layout |
|---|---|
| `@uniform` | std140 |
| `@pushconstant` | std430 |
| `@address` (device address) | std430 |

Both share the same base rules:

- `float`, `int`, `uint`, `bool` — 4 bytes, aligned 4
- `float2` — 8 bytes, aligned 8
- `float3` — 12 bytes, aligned 16
- `float4` — 16 bytes, aligned 16
- a pointer — 8 bytes, aligned 8
- matrices — an array of column vectors, `MatrixStride` being the column's
  alignment, so `float4x4` is 64 bytes with `MatrixStride 16`
- structs — aligned to the largest member alignment

std140 then adds two roundings that std430 does not:

- a struct's alignment is rounded up to 16
- a matrix's column stride is rounded up to 16

So a `float2x2` is 16 bytes in std430 and 32 in std140, and a struct of three
floats aligns to 4 in std430 and 16 in std140.

Offsets are computed by the compiler and emitted as `Offset` member
decorations. **The host must match the layout** — nothing checks it at run
time, and a mismatch renders garbage rather than failing. §10.2 works one
through.

## 8. Builtin functions

Mapped to GLSL.std.450 unless noted.

**Math**: `abs` `sign` `floor` `ceil` `round` `fract` `mod` `min` `max` `clamp`
`saturate` `mix` `lerp` `step` `smoothstep` `sqrt` `rsqrt` `inversesqrt` `pow`
`exp` `exp2` `log` `log2` `sin` `cos` `tan` `asin` `acos` `atan` `atan2`

**Geometry**: `length` `distance` `dot` `cross` `normalize` `reflect` `refract`
`faceforward`

**Matrix**: `transpose` `inverse` `determinant`, and `mul(a, b)` for a matrix
product spelled the HLSL way.

**Conversion and selection**: `asuint` `asint` `asfloat` (bit-preserving, same
shape), `any` `all` (a bool vector to a bool), `select(when_false, when_true,
condition)`.

**Texture** (method syntax on the texture): 
```
tex.sample(tex_sampler, uv)          // OpImageSampleImplicitLod, fragment only
tex.sample_lod(tex_sampler, uv, lod) // OpImageSampleExplicitLod
```

**Derivatives** (fragment only): `ddx` `ddy` `fwidth`

## 9. Statements

```
float4 c = input.color;      // declaration, type required
c *= 2.0;                    // compound assignment
if (c.a > 0.5) { ... } else { ... }
while (i < 4) { ... }
for (int i = 0; i < 4; i++) { ... }
break; continue;
return c;
discard;                     // fragment only, OpKill
```

Blocks introduce a scope. Shadowing an outer local is an error.

`for` and `while` lower to structured control flow with `OpLoopMerge`; `if`
lowers with `OpSelectionMerge`.

## 10. Buffer device addresses

An `@address` struct is never bound as a descriptor. It is reached through a
64-bit GPU address the host hands in, usually as a push constant. This is
Vulkan's `bufferDeviceAddress` feature.

It has nothing to do with a uniform buffer, and nothing to do with a storage
buffer: it is a raw pointer target, what GLSL spells `buffer_reference`.

```
struct Vertex @address
{
    float3 position;
    float4 color;
    float2 uv;
}

struct Push @pushconstant
{
    Vertex* vertices;
    uint    count;
}

Push pc;

struct VertexIn
{
    uint index @builtin(vertex_index);
}

fn FragmentIn vert(VertexIn input) @vertex
{
    Vertex* v = pc.vertices;

    FragmentIn output;
    output.position = mvp * float4(v[input.index].position, 1.0);
    output.color    = v[input.index].color;
    return output;
}
```

### 10.1 Pointers

`T*` is a device address, and `T` must be an `@address` struct. A pointer to
anything else is an error: only an `@address` struct has a layout and an
address.

The pointer grammar is exactly one trailing `*`. There is no `&`, no pointer
arithmetic beyond indexing, and no pointer-to-pointer.

Pointers may appear as:

- a member of a `@pushconstant` or `@uniform` block,
- a member of an `@address` struct (including a pointer to its own type),
- a local variable.

Two operations are defined on a pointer:

| Written | Means |
|---|---|
| `p[i]` | the `i`th element, striding by the pointee's std430 size |
| `p.member` | reads through `p`, the way `->` does in C |

A local pointer declaration is `T* name = ...;`. The parser has no type table,
so `T* name` and `a * b` are the same three tokens; it settles the ambiguity on
what follows, and treats the shape as a declaration when an `=` or `;` comes
next. A statement that is only `a * b;` computes a value nothing reads, so
nothing real is lost.

### 10.2 Layout, and the contract with the host

An `@address` struct is laid out **std430**, not std140. The difference from a uniform
block (section 7) is in two places: std430 does not round a struct's alignment
up to 16, and does not round a matrix's column stride up to 16.

The `Vertex` above therefore lays out as:

| Member | Type | Offset | Size |
|---|---|---|---|
| `position` | `float3` | 0 | 12 |
| `color` | `float4` | 16 | 16 |
| `uv` | `float2` | 32 | 8 |

with a stride of 48: `float3` occupies 12 bytes but aligns to 16, and the
struct's own 16-byte alignment rounds 40 up to 48. **The host's struct must
match this exactly** - nothing checks it at run time, and a mismatch renders
garbage rather than failing.

Every access through a device address carries an `Aligned` memory operand,
because nothing else describes the memory to the hardware. The alignment stated
is the accessed type's own std430 alignment, which holds as long as **the host
aligns the buffer to the pointee's alignment**. A `VkBuffer`'s device address
satisfies this in practice; a hand-computed address into the middle of one may
not.

### 10.3 Push constants

`struct T @pushconstant { ... }` marks the pipeline's push constant block,
laid out std430; `T name;` declares it. A shader may have at most one.

A push constant block is not a descriptor: it takes no set and no binding, and
it does not consume one. `@set` or `@binding` on it is an error.

### 10.4 What the emitter produces

Declaring an `@address` struct changes the module header, not just its body:

- `OpCapability PhysicalStorageBufferAddresses` and `OpCapability Int64`
- `OpExtension "SPV_KHR_physical_storage_buffer"`
- `OpMemoryModel PhysicalStorageBuffer64 GLSL450` instead of `Logical`
- SPIR-V **1.3** instead of 1.0

`p[i]` lowers to explicit 64-bit arithmetic - `OpConvertPtrToU`, `OpIMul` by
the stride, `OpIAdd`, `OpConvertUToPtr` - rather than to `OpPtrAccessChain`.

That is deliberate, and it was not the first attempt. `OpPtrAccessChain` says
the same thing in one instruction, takes its stride from the pointer type's
`ArrayStride` decoration, and passes `spirv-val --target-env vulkan1.3`. It
also renders nothing on RADV: the stride comes out as zero, so every index
reads element 0. glslang never emits it for buffer references either - it emits
exactly the arithmetic above - which is why that is the path drivers are
actually tested against. The `ArrayStride` decoration is still emitted, because
it accurately describes the pointer and tools read it, but nothing depends on
a driver honouring it.

### 10.5 What the host has to do

1. Enable `bufferDeviceAddress` (`VkPhysicalDeviceVulkan12Features`).
2. Allocate the buffer's memory with `VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT`
   and create it with `VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT`.
3. Get the address with `vkGetBufferDeviceAddress`.
4. Put it in the push constant range, which must be declared in the pipeline
   layout.

`src/main.c3` in this project does all four: it pulls every vertex of its cube
through a device address, with no vertex input bindings or attributes at all.
