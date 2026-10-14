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
`continue` `discard` `true` `false` `interface` `module` `import`.
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

**Quoted names**: `"lighting.shady"`, between double quotes, with no escapes
and no newline. A quoted name is not a value and there is no string type: an
`import` is the only thing that writes one.

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

### 1.1 `#line` directives

```
#line 1 "material"
```

A directive owns its line — it must be the first thing on the line after
whitespace — and renumbers the lines that follow it. The number applies to the
next physical line, and the quoted name becomes the region every position in
that range is reported under: a diagnostic on the third line of the body above
reads `material:3:12` rather than the line it landed on in the generated module.
A later directive renumbers from that point again, which is how generated source
restores the module's own numbering after a spliced body.

`#line` changes no token, only the coordinates a diagnostic is written in. A
`#` anywhere else, and any other directive, is an error — shady has no
preprocessor.

The name may be any text without a quote or a newline. Columns are unchanged: a
generator that splices a body in must not re-indent it, or the caret lands on
the wrong token.

## 2. Types

### 2.1 Scalars
`bool` `int` `uint` `float`

`int` and `uint` are 32-bit. `float` is 32-bit. `half` is a 16-bit float,
and `int8` / `uint8` are bytes; all three exist for cooperative matrices (3.4.2)
but work anywhere a scalar does. `double` is *reserved*.

`half(x)` rounds a float to the nearest half and `float(h)` widens one back.
Half arithmetic stays half, so `h * 2.0` is refused in favour of
`h * half(2.0)`. A storage block with halves in it declares the 16-bit storage
capability, which the host enables with `storageBuffer16BitAccess`; any use of
`half` needs `shaderFloat16`.

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
sampler sampler_cmp

Sampler2D Sampler3D SamplerCube Sampler2DArray SamplerCubeArray
Sampler2DShadow SamplerCubeShadow Sampler2DArrayShadow

image1d<F> image2d<F> image3d<F> imagecube<F> image2d_array<F> imagecube_array<F>

accel RayQuery
```
`texture2d` plus `sampler` are the separate objects, paired only at the point of
use. `sampler_cmp` is the separate path's comparison sampler: the same SPIR-V
sampler, but the one the comparison methods take and the only one they take
(§8). `Sampler2D` and the rest are combined image-and-sampler descriptors, and
the `Shadow` types are their depth-comparison forms.

An `_array` or `Array` type is layered: a coordinate into one carries the layer
as its last component. A cube array needs the `imageCubeArray` device feature.

`image2d<rgba8>` and its family are storage images: textures a shader writes as
well as reads, by integer texel address and without a sampler. The angle
brackets name the texel format, which decides the texel type - `rgba8` reads and
writes `float4`, `r32ui` a `uint` - or name a texel type, as in
`image2d<float4>`, to leave the format to the host. §12 has the formats and the
operations. Without the brackets the family names are ordinary names.

`accel` is a ray-tracing acceleration structure - the scene a ray is traced
against - and `RaytracingAccelerationStructure`, HLSL's name for it, is the same
type. `RayQuery` is an inline ray query's traversal state. Both are §11's.

An opaque type may be an array: `Sampler2D three_textures[]` is a runtime-sized
descriptor array, `Sampler2D four[4]` a fixed one. Either way a descriptor - a
texture, a sampler, a storage image or an `accel` - may only appear as a module-level resource:
never as a struct member, local, parameter, return type, `?:` arm or assignment
target, all of which are refused. Vulkan cannot store one into memory, so each of
those was a module it refuses anyway. A `RayQuery` is the opposite: a local, or
an `inout` parameter, and nothing else (§11.2).

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
A device address (§10). The pointee must be a `buffer`. There is no pointer
arithmetic beyond `p[i]` and no pointer-to-pointer. `&x` exists, but it is the
address a cooperative matrix is loaded through (§3.4.2), not a device address,
and an opaque type or a `RayQuery` has no address.

### 2.6 Arrays
```
float4[16] palette;
float4 palette[16];   // the declarator form, as in C
```
The length may sit on the type or after the name, but not both: an array has
one dimension, and a second (`float[4] a[3]`, `float a[3][4]`) is refused - index
one array as `row * width + column` instead. Arrays may be locals or struct
members, are indexed by a runtime value, and take an initialiser list:
`float2 taps[2] = { float2(0, 0), float2(1, 1) };`.

`T[]` - no length - is a runtime-sized array, and it is only legal as the last
member of a `@storage` block or as the short spelling of one (§3.2). An array
cannot be a function parameter or return type - pass a device-address pointer
instead.

## 3. Module-level declarations

A shader is a flat list of declarations in any order. Forward references are
allowed: the parser builds the whole list before names are resolved.

A file may open with a **module statement**, naming the module it belongs to:

```
module lighting;
module three.render.lighting;   // dotted names are one name, matched whole
```

The name is the file's identity. It is not a namespace yet: imports still name
files by path and everything in the closure resolves in one flat scope (§3.6).
What it decides is where a bodyless declaration may be defined, because a
module's text is all of its files - the one that wrote the statement and every
file an import brings beside it. A declaration in module `lighting` is an error
unless some file of `lighting` defines it (§3.1, §3.5). A file that declares no
module is not checked this way: its bodyless declarations are refused where
they are called, as before.

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

A function may be declared without a body - `fn float4 tint(float4 base);` -
when the definition is somewhere the text does not say. In a module, only the
module's own files may define it (§3), and a declaration no file defines is an
error at the declaration. In a file with no module the older rule stands:
refused where it is called. `@required` is that same need made explicit, for
text the module does not contain either way.

Two **definitions** with the same name and the same signature are an error at
the second one, naming where the first is - whichever modules they are in,
because a call resolves across the whole program. The one exception is
`@fallback` (§3.1.1).

#### 3.1.1 Holes: `@required` and `@fallback`

```
fn float3 shade(Surface s) @fallback { return standard(s); }
fn void displace(inout Vertex v) @fallback { }
fn float4 mesh_fragment(VertexOutput input, bool front_facing) @required;
```

A **template** is a module with holes in it: functions its own code calls and
some other text - spliced in by the program embedding the compiler - defines.

- `@required` is a hole that text must fill. It is a declaration and never a
  definition, and it is refused once, at the declaration, if nothing fills it -
  whether or not anything calls it.
- `@fallback` is a hole with a default already in it. It is a definition, and a
  definition of the same signature anywhere in the program replaces it,
  whether it comes before or after. A hole has one fallback, and a fallback
  cannot fill a `@required` hole: drop `@required` to make a hole optional.

Neither is an entry point, and a function is not both.

**A hole's name is not overloadable.** Every definition of the name in the
hole's module must have the hole's signature, or it is refused at that
definition, quoting the signature it must have. Without the rule a mistyped
`fn float4 shade(Surface s)` would be a new overload, the fallback would run,
and nothing would say so.

`shady::holes(source, allocator)` lists a template's holes with their
signatures written back out, which is what a host needs to wrap a bare body in
one; `shady::defines_functions(text)` tells a bare body from whole functions.

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
| `@storage` | a storage buffer | std430 | yes |
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

A struct carries at most one of these; two is an error. A `@uniform`, `@storage`
or `@pushconstant` struct gets `Block` and per-member `Offset` decorations.

There is at most one `@pushconstant` block per shader, because Vulkan allows
one push constant block per pipeline.

#### Storage buffers

A storage buffer is a `@storage` struct — the buffer's shape as a block, with a
**runtime-sized array** as its last member:

```
struct Weights @storage
{
    float  scale;
    float4 rows[];
}
Weights weights;
```

`T[]` has no length in the source because the host decides it: the descriptor's
range says how many elements the buffer holds, and the shader only ever indexes
(`weights.rows[i]`, `weights.scale`). The array has to be last — nothing may
follow a member the shader cannot size — and its element may be a scalar,
vector, matrix or struct. A struct element is laid out by the block that
contains it, exactly as a nested struct is anywhere else; a runtime-sized
descriptor array (§3.3) is a different thing and is not spelled this way.

Storage buffers are laid out **std430 and nothing else**. A compile may ask for
C3's own packing (`scalar_layout`), and every other block follows it, but a
buffer's bytes are written and read by whoever uploaded them, so its layout
cannot depend on a flag the shader alone was compiled with.

A one-array buffer has a shorter spelling, and it is the one to reach for:

```
float4 rows[];      // the same block, with the array as its only member
```

The compiler generates the block SPIR-V requires and the shader never sees it —
`rows[i]` reads and writes the array. Write the explicit form when the buffer
carries anything beside its array, or when one struct type is shared by two
buffers.

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

Only some types may be bound: a descriptor (any texture, sampler, combined
sampler, storage image or `accel` of §2.3) or an array of one - a descriptor
array, `[]` for a runtime-sized one - a
`@uniform` struct, a `@storage` struct, or a `@pushconstant` struct. A plain
struct has no layout and an `@address` struct is reached through a pointer, so
neither can be a variable. A bare `T[]` is the short spelling of a `@storage`
block (§3.2) and binds the same way.

Bindings are assigned in declaration order within each set, starting at 0.
An explicit `@set(n)` or `@binding(n)` pins that resource; auto-assignment
skips numbers already taken by explicit ones. Mixing the two is allowed;
a collision is an error rather than a silent overwrite. A `@pushconstant`
block takes no binding and does not consume one.

### 3.4 Shared memory

```
shared float tile[64];      // one workgroup's scratch
shared uint  bins[16];
```

`shared Type name;` is a workgroup-storage variable: the scratch space the
invocations of one workgroup share. It is a module-level declaration because
SPIR-V wants it there, and it is not a resource - it has no set, no binding,
and nothing outside the workgroup can reach it.

The length has to be a constant the module can state. A workgroup's memory is
as big as the declaration says it is, so `shared float tile[];` is refused.

**Nothing is guaranteed about what a shared slot holds before it is written**,
and the language cannot promise otherwise: SPIR-V gives a Workgroup variable
nowhere to put an initialiser, and a driver handed one is free to read the
variable as zeroes or as anything else. A loop that accumulates into shared
memory zeroes it first, or writes before it reads.

### 3.4.1 Barriers

```
barrier;        // every invocation has reached this point
barrier();      // the same
```

`barrier` synchronises the workgroup and orders the writes before it against
the reads after it, for shared memory and storage buffers both: its semantics
are `AcquireRelease | WorkgroupMemory | UniformMemory`. In a module that
declares a storage image they add `ImageMemory`, so a texel one invocation
wrote is the one another reads after the barrier (§12.3). Every invocation of
the workgroup has to reach it -
a barrier inside a branch half the workgroup takes leaves the other half
waiting, and a driver that notices reports a hang rather than a wrong number.

It is what makes shared memory usable, so the two travel together: write,
`barrier`, read. A loop that reduces through shared memory needs one barrier
per step, not one per loop, because the next step's read has to see the
previous step's write.

In a Vulkan-memory-model module - one with a cooperative matrix in it (§3.4.2) -
the barrier does not yet add `MakeAvailable | MakeVisible`, which that model
wants for the writes to be seen.

### 3.4.2 Cooperative matrices

```
coopmat<float, 16, 16, workgroup, a>           a_mat;
coopmat<float, 16, 16, workgroup, b>           b_mat;
coopmat<float, 16, 16, workgroup, accumulator> acc;

coop_load(a_mat, &tile[0], 16u);   // tile, pointer, stride
coop_load(b_mat, &tile[0], 16u);
coop_load(acc,   &tile[0], 16u);
coop_muladd(a_mat, b_mat, acc, acc);   // acc = a * b + acc
coop_store(&tile[0], acc, 16u);
```

A cooperative matrix is a tile one workgroup computes together - the shape the
hardware has an instruction for, rather than a grid of scalar multiplies. The
type names the element, the rows, the columns, the scope (`workgroup` or
`subgroup`), and which side of a product the tile is (`a`, `b` or
`accumulator`). The last one is part of the tile's identity: the hardware lays
the three out differently, so two tiles that differ only in use are two types.

`coop_load(tile, pointer, stride)` reads a tile through a pointer - usually
into shared memory - and the stride is the step between rows, because a tile is
a window onto a bigger array. `coop_store(pointer, tile, stride)` is its
mirror. `coop_muladd(a, b, c, result)` is `result = a * b + c`; the four
arguments are three tiles and the tile the answer goes in, which may be the
accumulator itself.

Its shape rules are matrix multiplication's: `a`'s columns against `b`'s rows,
and the result's shape against the accumulator's. A mismatch is refused by name
rather than left for the driver.

The layout is row-major unless a fourth argument says `column_major`, and then
the stride is the step between columns: `coop_load(b_mat, &tile[0], 40u,
column_major)` reads a `b` tile whose columns are the contiguous runs, which is
how a weight matrix stored a row per output already lies.

What a tile holds is the hardware's business: `uint8` and `int8` tiles are the
integer matmul (a product of byte tiles accumulates in `uint` or `int`), and
`half` and `float` are the other family - `coopmat<half, 16, 16, subgroup, a>`
times a `b` of the same into a `float` accumulator is the float product RDNA3
and most other hardware has. A driver that has none of the shapes refuses the
pipeline, which is the host's to check - `GpuLimits.cooperative_matrix` says
whether the device has the extension at all.

The byte types exist for exactly this. They are spellable anywhere - as a
shared array's element, in a conversion, as a storage block's member - and an
assignment does not narrow: `tile[i] = word;` is refused in favour of
`tile[i] = uint8(word);`, because a truncation nobody wrote down is a kernel
that computes the wrong thing quietly.

A module with a cooperative matrix in it is a **Vulkan-memory-model module**:
the SPIR-V capability is only legal next to `SPV_KHR_vulkan_memory_model`, so
the compiler declares it, raises the module to SPIR-V 1.3 and switches the
memory model for the whole module. A barrier in such a module is still spelled
`barrier`, and still means the same thing.

### 3.5 Constants
```
const float PI = 3.14159;              // an ordinary constant
const bool  SHADOWS  @spec(0) = true;  // a specialization constant
const uint  PCF_TAPS @spec(1) = 4u;
```
A module-level `const` is a scalar whose initialiser is a literal, and its name
resolves wherever it is written. It lowers to an `OpConstant` - except with
`@spec`: a `@spec(id)` constant lowers to an `OpSpecConstant`, or
`OpSpecConstantTrue`/`False` for a bool, decorated with `SpecId`, so the host
may replace its value when it creates the pipeline.

That is how one module serves several variants without recompiling: a bool that
folds a pass away, a uint that bounds a loop, a float that scales a kernel. A
spec constant cannot add or remove a descriptor, change a varying, change an
entry point or change a stage interface - those need a separate module. Spec
ids must be unique within a module.

Only scalars, because a spec constant has to be a single replaceable literal;
a composite or an expression is not.

### 3.6 Interfaces

```
interface AreaAlgorithm
{
    fn AreaTerms area_terms(Light light, float3 position, float3 normal,
                            float3 view, float3 f0, float f90, float a2,
                            float k, float nv);
    fn AreaTerms area_light_terms(...);
}
```

An interface is a named set of function declarations and nothing else - no
bodies, no data, no values.

**It is static.** There is no `any`, no vtable, and no run-time dispatch in a
shader; an interface names a group at compile time, and nothing in the emitted
module would differ if its members had been declared one by one. What it buys
is that a reader sees the whole set in one place, and can import the name
beside the file it lives in (§3.6).

Each member is a function declaration of the module, so a call resolves through
it and a definition fills it exactly as it fills a plain declaration (§3.1).
The obligation is the module's, not the interface's: a member of an interface
declared in module `lighting` must be defined by a file of `lighting`, or the
declaration is an error naming the module and the member (§3). No `implements`
statement is written for it, and none is needed - being a declaration in the
module is the whole claim.

An interface declared in a file with no module claims nothing: its members are
ordinary declarations, refused only where they are called.

A member is a plain function: no receiver, no attributes, no body.

Where a module's text is more than one file (§3.6), the check runs on the
module, not per file: one file may declare the interface and another define a
member.

### 3.7 Imports

```
import "lighting.shady";
import { AreaAlgorithm } from "lighting.shady";
```

An import is a module-level statement and stands alone on its line. Both forms
join the imported file's text to the importing file before either is parsed:
the text that reaches the compiler is the **import closure** of the root.

The braces of the named form name what was read out of the file: every name
must be an interface the file declares, and one the file does not declare is
refused at the import. It is a readability check - the interface is spelled
next to the file it lives in - and not a claim about the module: its members
are checked by the module that declares them (§3.5), wherever they are defined.

```
import { AreaAlgorithm } from "lighting.shady";
```

A file named by both forms is included once: the closure is a set of files,
whichever spelling named it.

The imported file is resolved like every other source - the program embedding
the compiler supplies it, disk first and its embedded copy as fallback in
three.c3 - so the compiler itself never opens a file. Its input is one string;
`shady::resolve_imports` is the pass that turns a root source plus a file supply
into the closure.

Each file keeps its own `#line` region (§1.1), so a diagnostic inside an
imported file names *that* file and its own line rather than a line in the
spliced module.

- A file imported twice, by either form, is included once: the closure is a set
  of files, so a diamond import is one copy.
- Imports may not form a cycle; one is an error naming the cycle.
- Name resolution is unchanged by the splice. The closure is one flat scope,
  so an imported function, struct or constant resolves wherever it is written,
  and a declaration in one file may be filled by a definition in another file
  of its module.
- An import cannot be conditional, there is no include guard, and no other
  directive exists - a `#` anywhere but a `#line` is an error (§1.1).

## 4. Attributes

| Attribute | Applies to | Meaning |
|---|---|---|
| `@vertex` | function | Vertex entry point |
| `@vertex(name)` | function | …published under `name` instead of the function's (§6.1) |
| `@fragment` | function | Fragment entry point |
| `@fragment(name)` | function | …published under `name` |
| `@compute` | function | Compute entry point |
| `@compute(name)` | function | …published under `name` |
| `@raygen` `@closest_hit` `@any_hit` `@miss` `@intersection` `@callable` | function | Ray-tracing pipeline entry points (§11.3), each with an optional name like the rest |
| `@threads(x, y, z)` | `@compute` function | Workgroup size, required on compute and refused elsewhere |
| `@subgroup_size(n)` | `@compute` function | The subgroup size the kernel is written for (below) |
| `@uniform` | struct | A uniform buffer: std140, takes a binding |
| `@storage` | struct | A storage buffer: std430, takes a binding, ends in a runtime-sized array |
| `@pushconstant` | struct | The pipeline's push constants: std430, no binding |
| `@address` | struct | Reached through a device address: std430, no binding |
| `@position` | struct member | `BuiltIn Position` instead of a location |
| `@location(n)` | struct member | Pin the location; others auto-assign around it |
| `@builtin(name)` | struct member | A SPIR-V builtin (§6.4) |
| `@set(n)` | module-level variable | Descriptor set |
| `@binding(n)` | module-level variable | Binding within the set |
| `@spec(n)` | module-level `const` | Specialization constant id (§3.4) |
| `@flat` | struct member | `Flat` interpolation |
| `@required` | function, no body | A hole the module's text must fill (§3.1.1) |
| `@fallback` | function, with a body | A hole with a default another definition replaces (§3.1.1) |

`@subgroup_size(n)` is for a kernel whose tiles are laid out for so many lanes
a subgroup - a cooperative-matrix kernel written for wave32, say. Vulkan chooses
the size when the pipeline is created, not in the module, so the module carries
it as an `OpModuleProcessed` line reading `shady.subgroup_size n` and the host
asks the pipeline for it. `n` is a power of two from 4 to 128.

A struct carries at most one of `@uniform`, `@storage`, `@pushconstant` and
`@address`; two is an error. A function carries at most one stage attribute: one
function is one entry point. Attributes sit between a struct's name and its body, and
after a function's signature, as in C3.

Unknown attributes are an error, not a warning — a typo'd `@framgent` that
silently produced no entry point would be a miserable thing to debug. So is a
known attribute on a declaration it does not apply to (`@binding` on a
function), and a parameter takes none. Both are refused when the text is parsed,
at the attribute.

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
scalar. Repeats are allowed on reads (`v.xxy`). Only a single component can be
assigned (`v.x = 1.0`); a wider swizzle as an assignment target (`v.xy = ...`)
is refused - assign the components one at a time, or rebuild the vector.

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

`+`, `-` and `/` on a matrix are component-wise, against a matrix of the same
type or a float (`m / 2.0`, `1.0 - m`), and unary `-m` negates every component.
SPIR-V has none of these for matrices, so they are emitted a column at a time.
Any other operator on a matrix - `%`, a comparison, a bitwise operator - is
refused.

### 5.5 Remainder

`%` is C3's remainder: the result takes the sign of the left side, so
`-7 % 3 == -1` and `-7.5 % 2.0 == -1.5` (`OpSRem`, `OpFRem`). GLSL's floored
modulo, whose result takes the sign of the right side, is the builtin `mod`:
`mod(-7.5, 2.0) == 0.5` (§8). For a `uint` the two agree.

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

The stages are vertex, fragment and compute (§6.2 on) and the six of the
ray-tracing pipeline (§11.3). An entry point's parameters are its inputs - a
raster or compute stage cannot write them back, so `out` and `inout` are refused
there - and a void one's `return` takes no value.

Each `OpEntryPoint` lists its interface: the stage's inputs and outputs, and -
in a SPIR-V 1.4 module, which is what a ray-tracing feature makes one (§11.4) -
every global variable its call tree uses. A helper is emitted once and counted
for every entry point that reaches it, and so is anything a helper does that only
some stages may: `sample()` in a helper called from a vertex shader is refused at
the call to `sample()`, naming the vertex entry point.

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
up with the vertex stage's outputs. Locations are assigned in member order and
are not cross-checked between the stages, so the simplest way to keep them in
step is the one struct shared by both - the vertex stage returns it and the
fragment stage takes it.

An integer member of that struct is `Flat` on both sides without being asked
(`@flat` says the same thing). Flat is only for the two ends of a varying: an
integer vertex input or fragment output - an integer render target - is not
interpolated, and carries no decoration.

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
| `front_facing` | `bool` | fragment |
| `global_invocation_id` | `uint3` | compute |
| `local_invocation_id` | `uint3` | compute |
| `workgroup_id` | `uint3` | compute |
| `launch_id`, `launch_size` | `uint3` | every ray-tracing stage |
| `world_ray_origin`, `world_ray_direction` | `float3` | intersection, any-hit, closest-hit, miss |
| `ray_tmin`, `ray_tmax` | `float` | intersection, any-hit, closest-hit, miss |
| `incoming_ray_flags` | `uint` | intersection, any-hit, closest-hit, miss |
| `object_ray_origin`, `object_ray_direction` | `float3` | intersection, any-hit, closest-hit |
| `instance_custom_index`, `instance_id`, `primitive_id`, `geometry_index` | `uint` | intersection, any-hit, closest-hit |
| `object_to_world`, `world_to_object` | `float4x3` | intersection, any-hit, closest-hit |
| `hit_kind` | `uint` | any-hit, closest-hit |

Each is checked where the entry point is: a built-in in a stage that does not
have it, of a type Vulkan does not hand it as, or in a returned struct - every
one of these is an input - is refused. An integer built-in may be `int` or `uint`
(`int3` or `uint3`); Vulkan leaves the signedness to the shader. In a hit shader
`ray_tmax` is the distance to the hit being reported.

## 7. Block layout

Two layouts are used by default, and which one applies depends on the block:

| Block | Layout |
|---|---|
| `@uniform` | std140 |
| `@pushconstant` | std430 |
| `@address` (device address) | std430 |

Both share the same base rules:

- `float`, `int`, `uint` — 4 bytes, aligned 4
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

A `bool` has no layout at all: Vulkan forbids one in a uniform, storage,
push-constant or device-address block, so a block that holds one - directly or
in a nested struct - is refused where it is declared. Store a `uint` and
compare it with `0u`.

A struct nested inside a block is laid out by that block, and its members carry
`Offset` (and `MatrixStride`) decorations just as the block's own do. Because a
struct is one type with one layout, the same struct may not be nested in two
blocks that lay it out differently: a std140 uniform block and a std430 push
block sharing one is an error, and each needs its own declaration.

### 7.1 Scalar layout

A compile may instead ask for C3's own packing with `scalar_layout: true`, the
same thing Slang is given as `-force-glsl-scalar-layout`. It applies to every
block kind, and it is what lets a struct generated from the C3 side line up with
the wire format by construction:

- every scalar is 4 bytes aligned 4, and a vector aligns as its component
- `float3` is 12 bytes aligned 4
- a matrix is its columns with no padding, so `float3x3` is 36 bytes with
  `MatrixStride 12`
- an array's stride is the element's size rounded to its alignment
- a struct's alignment is its largest member's; nothing rounds to 16

A scalar-layout module needs `VK_EXT_scalar_block_layout` (or Vulkan 1.2's
`scalarBlockLayout` feature) on the device, because a `float4` may then sit at
an offset std430 forbids. `spirv-val` needs `--scalar-block-layout` to accept
one, which `test/conformance.c3` passes for the modules that ask for it.

Offsets are computed by the compiler and emitted as `Offset` member
decorations. **The host must match the layout** — nothing checks it at run
time, and a mismatch renders garbage rather than failing. §10.2 works one
through.

## 8. Builtin functions

Mapped to GLSL.std.450 unless noted.

**Math**: `abs` `sign` `floor` `ceil` `round` `fract` `frac` `mod` `fmod` `min`
`max` `clamp` `saturate` `mix` `lerp` `step` `smoothstep` `sqrt` `rsqrt`
`inversesqrt` `pow` `exp` `exp2` `log` `log2` `sin` `cos` `tan` `asin` `acos`
`atan` `atan2`

`min`, `max`, `clamp`, `abs` and `sign` pick the float, signed or unsigned form
from their operands. A `uint` has no GLSL `abs` or `sign`: `abs(u)` is `u`, and
`sign(u)` is `min(u, 1u)`. `mod(x, y)` is GLSL's floored modulo and `fmod(x, y)`
HLSL's truncated one, which is `%` (§5.5); either splats a scalar against a
vector.

**Geometry**: `length` `distance` `dot` `cross` `normalize` `reflect` `refract`
`faceforward`

`dot` returns the operands' own scalar type. On int or uint vectors it is the
multiply and the sum written out, since `OpDot` is a float instruction.

**Matrix**: `transpose`, `inverse` and `determinant` (square matrices only), and
`mul(a, b)` for a matrix product spelled the HLSL way.

**Conversion and selection**: `asuint` `asint` `asfloat` (bit-preserving, same
shape), `ashalf(bits)` (the half whose bits are the low 16 of a 32-bit int or
uint), `any` `all` (a bool vector to a bool), `select(when_false, when_true,
condition)`.

**Device memory**: `InterlockedAdd(dest, value)` - an atomic add on a device
address, yielding the value the destination held before. Device scope, relaxed
ordering; anything stronger is a barrier rather than an increment. The
destination may be shared memory - `InterlockedAdd(bins[i], 1)` is how a
histogram in a workgroup is built - or a texel of an `r32ui` storage image,
`InterlockedAdd(counts[at], 1)` (§12.3). The same relaxation applies: reach for
`barrier` when the order of the increments against other reads matters. An
integer literal takes the destination's type, so `1` is a `uint` here.

**Workgroup**: `barrier` (`barrier;` or `barrier()`) - workgroup
synchronisation, described in §3.4.1.

**Texture** (method syntax on the texture):

Every method has a lowercase name and the Slang/HLSL spelling. A combined type
(`Sampler2D` and the rest) samples directly; a separate texture names its
sampler first - `tex.sample(linear, uv)` - and is paired with it where it is
sampled. `off` is an optional constant texel offset (below).

| Lowercase | Slang | Arguments | Result | Notes |
|---|---|---|---|---|
| `sample` | `Sample` | `uv [, off]` | `float4` | fragment only |
| `sample_bias` | `SampleBias` | `uv, bias [, off]` | `float4` | fragment only |
| `sample_lod` | `SampleLevel` | `uv, lod [, off]` | `float4` | |
| `sample_grad` | `SampleGrad` | `uv, dx, dy [, off]` | `float4` | |
| `sample_cmp` | `SampleCmp` | `uv, ref [, off]` | `float` | compares; fragment only |
| `sample_cmp_lod` | `SampleCmpLevel` | `uv, ref, lod [, off]` | `float` | compares |
| `sample_cmp_level_zero` | `SampleCmpLevelZero` | `uv, ref [, off]` | `float` | compares |
| `gather` | `Gather`, `GatherRed/Green/Blue/Alpha` | `uv, component [, off]`; Slang: `uv [, off]` | `float4` | 2D and cube only |
| `gather_cmp` | `GatherCmp` | `uv, ref [, off]` | `float4` | compares; 2D and cube only |
| `load` | `Load` | `address, level [, off]`; Slang packs the level last | `float4` | no sampler; not a cube |
| `size` | — | `[level]` | `int`, `int2` or `int3` | the extent, plus the layer count |
| `levels` | — | none | `int` | the mip count |

The *fragment only* methods take their level from screen-space derivatives,
which only a fragment shader has; anywhere else they are refused in favour of
the explicit-level form. `GetDimensions` is refused, pointing at `size` and
`levels`.

**Comparison.** The methods that compare need a sampler made with a compare op:
a `Shadow` type, or a `sampler_cmp` on the separate path. The others need one
made without, so `shadow.Sample(uv)` and `tex.sample_cmp(linear, ...)` are both
refused. The reference is its own `float` argument, never packed into the
coordinate, and a 3D texture has no comparison.

**Coordinates.** A sampling coordinate is a float vector as wide as the
texture, plus the layer for a layered one:

| Texture | Coordinate | Gradient, offset | `load` address | `size()` |
|---|---|---|---|---|
| 1D | `float` | `float`, `int` | `int` | `int` |
| 2D | `float2` | `float2`, `int2` | `int2` | `int2` |
| 2D array | `float3` | `float2`, `int2` | `int3` | `int3` |
| 3D | `float3` | `float3`, `int3` | `int3` | `int3` |
| Cube | `float3` | `float3`, none | refused | `int2` |
| Cube array | `float4` | `float3`, none | refused | `int3` |

Exactly that wide: a coordinate one component short or long is refused, since
it is almost always a forgotten or a stray layer. A `load` address may be `int`
or `uint`, and its level is an integer.

**Texel offsets** are constants: an `int2(1, -1)` of integer literals (an
`int3` for a 3D texture, a bare literal for 1D). A cube takes none. An offset
outside [-8, 7], the range every device supports, compiles with a warning.

**Non-uniform indexing.** An index into a descriptor array that is not uniform
across the invocations of a wave goes through `NonUniformResourceIndex(index)`,
written inside the brackets - `maps[NonUniformResourceIndex(i)]`. The decoration
then follows the descriptor to the image instruction (the access chain, the
load, the sampled image), which is where the driver reads it; an index stored
in a local first loses the mark. The host enables
`shaderSampledImageArrayNonUniformIndexing`.

**Storage images** (`image2d<rgba8>` and the rest): `load(address)`,
`store(address, texel)`, `size()`, and indexing - `img[address]` reads,
`img[address] = texel` writes. §12.2.

**Derivatives** (fragment only): `ddx` `ddy` `fwidth`

**Ray tracing**: the `RayQuery` methods, the `RAY_FLAG_*` and intersection-type
constants, and `trace_ray`, `execute_callable`, `report_intersection`,
`ignore_intersection` and `terminate_ray` are in §11.

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
ignore_intersection();       // any-hit only, §11.3
terminate_ray();             // any-hit only, §11.3
```

`discard` and the two any-hit calls end the invocation where they stand, so they
are statements: `ignore_intersection()` inside an expression is refused. Each is
refused in a stage that does not have it, in a helper too - `discard` in an
any-hit shader points at `ignore_intersection()`.

Blocks introduce a scope, and a declaration in an inner scope shadows an outer
local or a parameter of the same name until the scope ends. A redeclaration in
the *same* scope is not refused yet; the later declaration is the one names
resolve to.

`for` and `while` lower to structured control flow with `OpLoopMerge`; `if`
lowers with `OpSelectionMerge`. An `if` whose branches both `return` ends the
function as far as the "every path returns" rule is concerned, and so does a
`while (true)` or `for (;;)` with no `break`.

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

`T*` is a device address. `T` is an `@address` struct, or a scalar, vector or
matrix - a mesh's streams are flat arrays of `float3`, `uint4` and `float4x4`,
not arrays of structs. Any other pointee is an error.

The pointer grammar is exactly one trailing `*`. There is no pointer arithmetic
beyond indexing and no pointer-to-pointer, and `&x` never makes a device
address - it is only the address of a cooperative-matrix tile (§3.4.2).

Pointers may appear as:

- a member of a `@pushconstant` or `@uniform` block,
- a member of an `@address` struct (including a pointer to its own type),
- a local variable or a parameter.

A pointer local may be reassigned, and a ternary chooses between two addresses:
`float4x4* palette = live ? push.live : push.baked;`.

Three operations are defined on a pointer:

| Written | Means |
|---|---|
| `p[i]` | the `i`th element, striding by the pointee's size in the compile's layout |
| `p[i] = v` | writes through the address |
| `p.member` | reads through `p`, the way `->` does in C |

`InterlockedAdd(p[i], v)` is an atomic add on device memory (§8).

A local pointer declaration is `T* name = ...;`. The parser has no type table,
so `T* name` and `a * b` are the same three tokens; it settles the ambiguity on
what follows, and treats the shape as a declaration when an `=` or `;` comes
next. A statement that is only `a * b;` computes a value nothing reads, so
nothing real is lost.

### 10.2 Layout, and the contract with the host

An `@address` struct is laid out **std430**, not std140. The difference from a uniform
block (section 7) is in two places: std430 does not round a struct's alignment
up to 16, and does not round a matrix's column stride up to 16.

Under scalar layout (§7.1) the same struct packs tighter: nothing rounds to 16,
so `float3` is 12 bytes aligned 4. Indexing strides by the element's size
rounded up to its alignment under whichever layout is in force - 12 for a
`float3` scalar-layout stream, 16 under std430.

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
is the accessed type's own alignment under the compile's layout, which holds as
long as **the host aligns the buffer to the pointee's alignment**. A
`VkBuffer`'s device address satisfies this in practice; a hand-computed address
into the middle of one may not.

### 10.3 Push constants

`struct T @pushconstant { ... }` marks the pipeline's push constant block,
laid out std430; `T name;` declares it. A shader may have at most one.

A push constant block is not a descriptor: it takes no set and no binding, and
it does not consume one. `@set` or `@binding` on it is an error.

### 10.4 What the emitter produces

Declaring an `@address` struct changes the module header, not just its body:

- `OpCapability PhysicalStorageBufferAddresses` and `OpCapability Int64`
- `OpExtension "SPV_KHR_physical_storage_buffer"`
- `OpMemoryModel PhysicalStorageBuffer64 GLSL450` instead of `Logical`, keeping
  the `Vulkan` memory model a cooperative matrix chose
- SPIR-V **1.3** instead of 1.0 - or 1.4, if a ray-tracing feature already asked
  for it; a module's version is the highest any feature in it needs

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

## 11. Ray tracing

Rays are traced two ways, and a module may use both:

- **Ray queries** (§11.2) are traced inline, by the shader that wants the
  answer, from any stage. A fragment shader asking whether the sun is visible
  from the point it is shading is a ray query - this is how a rasterizer gets
  ray-traced shadows, ambient occlusion or a reflection probe's visibility.
- **The ray-tracing pipeline** (§11.3) is a set of stages the hardware chains
  together: a ray-generation shader traces a ray, intersection and any-hit
  shaders test the geometry it meets, and a closest-hit or miss shader finishes
  it. This is what a path tracer, or ray-traced reflections and global
  illumination, are built from.

### 11.1 The scene

```
accel scene;                                    // set 0, binding 0
accel scenes[];                                 // a table of them
RaytracingAccelerationStructure world @set(1) @binding(0);
```

An `accel` is the top-level acceleration structure the host built, bound like a
texture (§3.3): a descriptor with a set and a binding, possibly in an array, and
indexed through `NonUniformResourceIndex` when the index varies across a wave.
`RaytracingAccelerationStructure` is HLSL's name for the same type.

### 11.2 Ray queries

```
struct Uniforms @uniform { float4x4 view_projection; float3 sun; }
Uniforms uniforms;
accel    scene;
Sampler2D foliage;

struct VertexIn   { float3 position; float3 normal; }
struct FragmentIn { float4 position @position; float3 world; float3 normal; }

fn float sun_visibility(float3 position, float3 normal)
{
    RayQuery q;
    q.init(scene, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xFF,
           position + normal * 0.01, 0.0, uniforms.sun, 10000.0);
    while (q.proceed())
    {
        // A non-opaque triangle - a leaf - blocks the sun only where its
        // texture does.
        if (q.candidate_type() == CANDIDATE_NON_OPAQUE_TRIANGLE
            && foliage.sample_lod(q.candidate_barycentrics(), 0.0).a > 0.5)
        {
            q.confirm();
        }
    }
    return q.committed_type() == COMMITTED_NOTHING ? 1.0 : 0.0;
}

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.view_projection * float4(input.position, 1.0);
    output.world = input.position;
    output.normal = input.normal;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    float lit = max(dot(input.normal, uniforms.sun), 0.0) * sun_visibility(input.world, input.normal);
    return float4(float3(0.1) + float3(lit), 1.0);
}
```

A `RayQuery` is the traversal of one ray, driven by the shader: `init` aims it,
`proceed` steps it until it returns `false`, and the getters read what it found.
Opaque triangles commit themselves; a non-opaque one, or a procedural AABB, is a
*candidate* the loop decides about - `confirm()` accepts the triangle being
visited, `generate(t)` a hit inside the AABB. Above, the barycentrics stand in
for the texture coordinate a real alpha test would interpolate from the mesh.

A `RayQuery` is declared as a local, without an initialiser, and handed to a
helper as `inout RayQuery q`. It is traversal state rather than a value, so it is
not assigned, copied, returned, stored in a struct or an array, chosen with `?:`,
or declared at module level or `shared`. It may be used in every stage.

| Method | Result | |
|---|---|---|
| `init(scene, flags, cull_mask, origin, tmin, direction, tmax)` | — | aims the query; `flags` and `cull_mask` are `uint`, the ray `float3`s and `float`s |
| `proceed()` | `bool` | steps the traversal; `false` once it is done |
| `confirm()` | — | accepts the triangle candidate |
| `generate(t)` | — | accepts a hit at `t` in the AABB candidate |
| `terminate()` | — | ends the traversal |
| `ray_flags()` | `uint` | |
| `ray_tmin()` | `float` | |
| `world_ray_origin()`, `world_ray_direction()` | `float3` | |
| `candidate_aabb_opaque()` | `bool` | whether the AABB candidate is opaque |

The getters below come in two spellings, `candidate_` for the intersection being
visited and `committed_` for the closest one accepted so far -
`q.candidate_t()`, `q.committed_t()`:

| Getter | Result |
|---|---|
| `type` | `uint`: `COMMITTED_*` or `CANDIDATE_*`, below |
| `t` | `float`, the distance along the ray |
| `barycentrics` | `float2` |
| `front_face` | `bool` |
| `instance_custom_index`, `instance_id`, `sbt_offset`, `geometry_index`, `primitive_index` | `uint` |
| `object_ray_origin`, `object_ray_direction` | `float3` |
| `object_to_world`, `world_to_object` | `float4x3`, the instance's transform |

A candidate's `t`, `barycentrics` and `front_face` are a triangle's; asked of an
AABB candidate their value is undefined, as `confirm` on an AABB and `generate`
on a triangle are.

**Constants.** The flags and the intersection types use HLSL's names, as `uint`
constants. A shader's own declaration of one of these names wins.

| Constant | Value |
|---|---|
| `RAY_FLAG_NONE` | 0 |
| `RAY_FLAG_FORCE_OPAQUE` | 0x1 |
| `RAY_FLAG_FORCE_NON_OPAQUE` | 0x2 |
| `RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH` | 0x4 |
| `RAY_FLAG_SKIP_CLOSEST_HIT_SHADER` | 0x8 |
| `RAY_FLAG_CULL_BACK_FACING_TRIANGLES` | 0x10 |
| `RAY_FLAG_CULL_FRONT_FACING_TRIANGLES` | 0x20 |
| `RAY_FLAG_CULL_OPAQUE` | 0x40 |
| `RAY_FLAG_CULL_NON_OPAQUE` | 0x80 |
| `RAY_FLAG_SKIP_TRIANGLES` | 0x100 |
| `RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES` | 0x200 |
| `COMMITTED_NOTHING`, `COMMITTED_TRIANGLE_HIT`, `COMMITTED_PROCEDURAL_PRIMITIVE_HIT` | 0, 1, 2 |
| `CANDIDATE_NON_OPAQUE_TRIANGLE`, `CANDIDATE_PROCEDURAL_PRIMITIVE` | 0, 1 |
| `HIT_KIND_TRIANGLE_FRONT_FACE`, `HIT_KIND_TRIANGLE_BACK_FACE` | 0xFE, 0xFF |

The two `SKIP_` flags are a device feature of their own (§11.5).

### 11.3 Pipeline stages

```
struct Camera @uniform { float4x4 inverse_view_projection; float3 position; float3 sun; }
Camera camera;
accel  scene;
image2d<rgba8> image;

struct Payload { float3 color; }
struct Shadow  { bool lit; }

struct LaunchIn { uint3 id @builtin(launch_id); uint3 size @builtin(launch_size); }
struct RayIn    { float3 origin @builtin(world_ray_origin); float3 direction @builtin(world_ray_direction); float t @builtin(ray_tmax); }
struct Triangle { float2 barycentrics; }

fn void generate(LaunchIn at) @raygen
{
    float2 ndc = (float2(at.id.xy) + 0.5) / float2(at.size.xy) * 2.0 - 1.0;
    float4 target = camera.inverse_view_projection * float4(ndc, 1.0, 1.0);

    Payload p;
    p.color = float3(0.0);
    trace_ray(scene, RAY_FLAG_NONE, 0xFF, 0, 1, 0,
              camera.position, 0.001, normalize(target.xyz / target.w - camera.position), 10000.0, p);
    image[at.id.xy] = float4(p.color, 1.0);
}

fn void sky(inout Payload p, RayIn ray) @miss
{
    p.color = mix(float3(1.0), float3(0.4, 0.6, 1.0), ray.direction.y * 0.5 + 0.5);
}

fn void sky_shadow(inout Shadow s) @miss
{
    s.lit = true;
}

fn void surface(inout Payload p, Triangle hit, RayIn ray) @closest_hit
{
    float3 position = ray.origin + ray.direction * ray.t;
    Shadow s;
    s.lit = false;
    // Miss shader 1 is `sky_shadow`; no closest-hit shader runs for a shadow ray.
    trace_ray(scene, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER, 0xFF, 0, 1, 1,
              position, 0.001, camera.sun, 10000.0, s);
    float3 albedo = float3(hit.barycentrics, 1.0 - hit.barycentrics.x - hit.barycentrics.y);
    p.color = s.lit ? albedo : albedo * 0.2;
}
```

| Attribute | Stage | Its `inout` parameter | May call |
|---|---|---|---|
| `@raygen` | ray generation | none | `trace_ray`, `execute_callable` |
| `@miss` | miss | the payload | `trace_ray`, `execute_callable` |
| `@closest_hit` | closest hit | the payload | `trace_ray`, `execute_callable` |
| `@any_hit` | any hit | the payload | `ignore_intersection`, `terminate_ray` |
| `@intersection` | intersection | none | `report_intersection` |
| `@callable` | callable | the callable data | `execute_callable` |

A ray-tracing entry point returns `void`, has no execution modes - `@threads` is
refused on one - and no varyings. Its parameters are told apart by their shape:

- an **`inout` struct** is the payload the ray carries, or in a callable shader
  the data its caller passed. It is the caller's, reached in place: what the
  shader writes is what the caller reads back. `out` is refused - the payload
  arrives holding what it was traced with.
- a **struct of `@builtin` members** is the stage's built-ins (§6.4).
- a **struct with no built-ins** is the hit attributes, in a closest-hit or
  any-hit shader: for a triangle the `float2` barycentrics of the hit, for a
  procedural primitive whatever its intersection shader reported. The shader gets
  a copy, since the attributes themselves are read-only there. Vulkan
  guarantees 32 bytes of them; a larger struct compiles with a warning.

Each kind is one parameter at most, and a payload, callable data or hit
attributes are a plain struct rather than a block.

**Calls.**

- `trace_ray(scene, flags, cull_mask, sbt_offset, sbt_stride, miss_index,
  origin, tmin, direction, tmax, payload)` sends a ray through the pipeline - the
  operands of `traceRayEXT` and `OpTraceRayKHR`, in their order. The integer
  operands are `uint`. `payload` is a struct variable - a local, or the shader's
  own payload when a closest-hit shader traces again - and is copied into the
  ray and back out once its hit or miss shader has run.
- `execute_callable(index, data)` runs the callable shader at `index` in the
  shader binding table, with `data` copied in and back out the same way.
- `report_intersection(t, hit_kind[, attributes])` - an intersection shader
  found a hit at `t`. `hit_kind` is a `uint` the hit shaders read back (a
  procedural one is 0 to 127); `attributes` is the struct they take. The result
  says whether the hit was accepted - an any-hit shader may still ignore it. An
  intersection shader reports one attribute type, through helpers too.
- `ignore_intersection()` drops the hit an any-hit shader is looking at, and
  `terminate_ray()` accepts it and ends the ray's traversal. Both end the shader
  where they stand, like `discard` (§9).

Each call is refused outside the stages in the table, and a helper that makes one
is refused in the entry points that cannot.

A payload handed to a helper as `inout`, or used as a `&self` receiver, travels
through a copy that is written back when the call returns, so the helper's writes
reach the caller.

The pipeline ties stages together on the host, not in the module: the miss
index, the hit group a closest-hit, any-hit and intersection shader form, and
the shader binding table are the host's. A hit group's shaders must agree on the
payload and on the hit-attribute type; nothing in one module can check that.

```
accel scene;
Sampler2D cutout;
struct Payload { float3 color; }
struct Triangle { float2 barycentrics; }
struct Sphere { float3 normal; }
struct ObjectRay { float3 origin @builtin(object_ray_origin); float3 direction @builtin(object_ray_direction); }

fn void alpha_test(inout Payload p, Triangle hit) @any_hit
{
    if (cutout.sample_lod(hit.barycentrics, 0.0).a < 0.5) ignore_intersection();
}

fn void ball(ObjectRay ray) @intersection
{
    // A unit sphere at the instance's origin.
    float b = dot(ray.origin, ray.direction);
    float c = dot(ray.origin, ray.origin) - 1.0;
    float d = b * b - c;
    if (d < 0.0) return;
    float t = -b - sqrt(d);
    Sphere s;
    s.normal = normalize(ray.origin + ray.direction * t);
    report_intersection(t, 0u, s);
}

struct Material { float3 albedo; float roughness; }
fn void rough(inout Material m) @callable
{
    m.albedo = m.albedo * (1.0 - 0.5 * m.roughness);
}
```

### 11.4 What the emitter produces

- SPIR-V **1.4**: `VK_KHR_ray_query` and `VK_KHR_ray_tracing_pipeline` both
  depend on `VK_KHR_spirv_1_4`. A module with any ray feature in it is 1.4,
  its raster and compute entry points included.
- From 1.4, every `OpEntryPoint` lists every global variable its call tree uses,
  and only those: a uniform block one entry point reads is not in another's
  interface, and each hit or miss shader lists exactly its own payload.
- A ray query: `OpCapability RayQueryKHR` and `SPV_KHR_ray_query`. An `accel`
  nothing traces against is declared the same way.
- A pipeline stage: `OpCapability RayTracingKHR` and `SPV_KHR_ray_tracing`.
- `RAY_FLAG_SKIP_TRIANGLES` or `RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES`:
  `OpCapability RayTraversalPrimitiveCullingKHR`.
- A payload, callable data and hit attributes are each one variable of their
  storage class per struct type, named after the type (`payload.Payload`,
  `incoming_payload.Payload`, `hit_attributes.Triangle`).

### 11.5 What the host has to do

1. Enable `VK_KHR_acceleration_structure` (which needs
   `VK_KHR_deferred_host_operations` and `bufferDeviceAddress`) and build the
   scene's acceleration structures.
2. For ray queries, enable `VK_KHR_ray_query` and its `rayQuery` feature; for
   the pipeline stages, `VK_KHR_ray_tracing_pipeline` and `rayTracingPipeline`.
   On Vulkan 1.1, enable `VK_KHR_spirv_1_4` too.
3. Enable `rayTraversalPrimitiveCulling` for a module using a `SKIP_` flag, and
   `runtimeDescriptorArray` for an `accel` table.
4. Bind each `accel` as `VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR`.
5. For the pipeline, create the shader groups and the shader binding table: the
   module's entry points are found by name, as any other stage's are.

## 12. Storage images

A storage image is a texture the shader writes. It is how a compute pass
post-processes a frame, how a ray-generation shader puts its pixels down, and
how a histogram or a splat lands in an image rather than a buffer:

```
image2d<rgba16f> hdr;
image2d<rgba8>   ldr;
image2d<r32ui>   histogram;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

fn void tonemap(ComputeIn at) @compute @threads(8, 8, 1)
{
    int2 extent = ldr.size();
    if (at.id.x >= uint(extent.x) || at.id.y >= uint(extent.y)) return;

    float4 c = hdr[at.id.xy];
    ldr[at.id.xy] = float4(c.rgb / (c.rgb + 1.0), 1.0);

    float luma = dot(c.rgb, float3(0.2126, 0.7152, 0.0722));
    InterlockedAdd(histogram[int2(int(clamp(luma, 0.0, 1.0) * 255.0), 0)], 1);
}
```

A texel has an integer address and no sampler: there is no filtering, no
wrapping and no mip level. An image that is sampled in one pass and written in
another is bound twice, as a `texture2d` and as an `image2d<…>`.

### 12.1 Declaring

| Type | Address | `size()` |
|---|---|---|
| `image1d<F>` | `int` | `int` |
| `image2d<F>` | `int2` | `int2` |
| `image3d<F>` | `int3` | `int3` |
| `image2d_array<F>` | `int3`: x, y, layer | `int3`: the extent and the layer count |
| `imagecube<F>` | `int3`: x, y, face | `int2`: one face |
| `imagecube_array<F>` | `int3`: x, y, layer × 6 + face | `int3`: one face and the cube count |

An address may be signed or unsigned - `at.id.xy` addresses a 2D image as it
is - and is exactly as wide as the table says.

`F` is a format, under GLSL's name, and the format decides the texel type: what
a read returns and a write takes. The suffix says the scalar - `i` an `int`,
`ui` a `uint`, anything else a `float` - and the channels say how many:

| Texel | Formats |
|---|---|
| `float4` | `rgba32f` `rgba16f` `rgba8` `rgba8_snorm` · `rgba16` `rgba16_snorm` `rgb10_a2` |
| `float3` | · `r11f_g11f_b10f` |
| `float2` | · `rg32f` `rg16f` `rg16` `rg16_snorm` `rg8` `rg8_snorm` |
| `float` | `r32f` · `r16f` `r16` `r16_snorm` `r8` `r8_snorm` |
| `int4` | `rgba32i` `rgba16i` `rgba8i` |
| `int2` | · `rg32i` `rg16i` `rg8i` |
| `int` | `r32i` · `r16i` `r8i` |
| `uint4` | `rgba32ui` `rgba16ui` `rgba8ui` · `rgb10_a2ui` |
| `uint2` | · `rg32ui` `rg16ui` `rg8ui` |
| `uint` | `r32ui` · `r16ui` `r8ui` |

The formats before the `·` are the thirteen every device stores; the ones after
it are the extended formats. Vulkan has no three-channel storage format but
`r11f_g11f_b10f`, so `rgb8` is refused with a pointer at `rgba8`.

In place of a format, the brackets may hold a texel type - a 32-bit `float`,
`int` or `uint`, or a vector of one - and the host picks the format:
`image2d<float4> any;`. Such an image costs a device feature for each direction
it is used in (§12.5).

The texel type is never written separately, because the two have to agree:
SPIR-V requires an image's sampled type to match its format, and nothing checks
it but the compiler that wrote both.

A storage image binds like any other descriptor (§3.3), and may be an array -
`image2d<rgba8> targets[];` is a bindless table, indexed through
`NonUniformResourceIndex` when the index varies across a wave. Like every
descriptor it is a module-level variable and nothing else (§2.3).

### 12.2 Reading and writing

| Written | Is |
|---|---|
| `img[address]` | the texel, as the texel type |
| `img.load(address)`, `img.Load(address)` | the same |
| `img[address] = texel` | a write; the expression's value is the texel |
| `img.store(address, texel)` | a write, as a statement |
| `img[address] op= value` | a read, the operator, and a write |
| `img.size()` | the extent, as in §12.1 |

The texel is the image's texel type: `rgba8`'s is a `float4`, so
`ldr[at] = 1.0` writes white (a scalar fills a vector, as in an assignment) and
`ldr[at] = int4(1)` is refused. An indexed texel is a value - `img[at].rgb`
reads three channels - but a copy: `img[at].x = 1.0` is refused, since writing
one channel back would mean writing the others too. Read it into a local, change
it, and write it back.

A compound assignment is two operations, and another invocation can come
between them, as with any other memory; `InterlockedAdd` (§12.3) is the atomic
one.

`size()` takes no level, and `levels()` is refused: a storage image is bound as
one mip level. The sampling methods are refused on a storage image, and `store`
and indexing on a texture - the refusal names the type that does it.

Any stage may read or write a storage image; §12.5 has the device features a
vertex or fragment shader's writes need.

### 12.3 Atomics and barriers

`InterlockedAdd(img[address], value)` adds to one texel atomically and yields
the value it held before, exactly as on a buffer (§8): device scope, relaxed
ordering. The image is an `r32ui` one - Vulkan's image atomics are on a single
32-bit channel of a format the shader names, and the language's
`InterlockedAdd` is on `uint`s - so a host-picked format is refused too.

In a module that declares a storage image, `barrier` (§3.4.1) orders image
memory as well as shared memory and buffers: a texel one invocation of the
workgroup writes before the barrier is the one another reads after it. Between
workgroups nothing is ordered within one dispatch; the host's pipeline barrier
between dispatches is what orders those.

### 12.4 What the emitter produces

- `OpTypeImage` with the format's scalar, `Sampled 2` and the format; a
  host-picked one is `Unknown`. The variable is `UniformConstant`, with its
  `DescriptorSet` and `Binding`.
- A read is `OpImageRead` of a four-component vector, cut down to the texel
  type; a write is `OpImageWrite` of four components, a narrower texel padded
  with 0 and an alpha of 1. Vulkan requires a read to return four
  (VUID-StandaloneSpirv-Result-04780) and a write to carry at least as many as
  the bound view has, which four always does.
- `size()` is `OpImageQuerySize`, with `OpCapability ImageQuery`.
- An atomic is `OpImageTexelPointer` and `OpAtomicIAdd`.
- An image the module never reads is decorated `NonReadable`, one it never
  writes `NonWritable` - GLSL's `writeonly` and `readonly`, from what the
  shader does rather than from a keyword.
- Capabilities, each only where it is needed: `Image1D`, `ImageCubeArray`,
  `StorageImageExtendedFormats` for an extended format,
  `StorageImageReadWithoutFormat` and `StorageImageWriteWithoutFormat` for a
  host-picked format read or written, and
  `StorageImageArrayNonUniformIndexing` for a table indexed non-uniformly.
- A barrier's semantics gain `ImageMemory`.

### 12.5 What the host has to do

1. Create the image with `VK_IMAGE_USAGE_STORAGE_BIT`, and a view whose format
   is the declared one (`rgba8` is `VK_FORMAT_R8G8B8A8_UNORM`, `r32ui` is
   `VK_FORMAT_R32_UINT`, and so on) and whose format features include
   `VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT` - and
   `VK_FORMAT_FEATURE_STORAGE_IMAGE_ATOMIC_BIT` for an atomic.
2. Bind it as `VK_DESCRIPTOR_TYPE_STORAGE_IMAGE`, in
   `VK_IMAGE_LAYOUT_GENERAL`.
3. Enable the features the module's capabilities name:
   `shaderStorageImageExtendedFormats` for an extended format,
   `shaderStorageImageReadWithoutFormat` and
   `shaderStorageImageWriteWithoutFormat` for a host-picked one,
   `imageCubeArray` for a cube array.
4. Enable `fragmentStoresAndAtomics` for a fragment shader that writes one, and
   `vertexPipelineStoresAndAtomics` for a vertex shader.
5. For a table: `shaderStorageImageArrayDynamicIndexing` for a fixed-size one
   indexed by a variable, `runtimeDescriptorArray` for `[]`, and
   `shaderStorageImageArrayNonUniformIndexing` for a non-uniform index.
6. Put a pipeline barrier (`SHADER_WRITE` to `SHADER_READ`, or to whatever reads
   the image next) between a pass that writes an image and one that reads it.
