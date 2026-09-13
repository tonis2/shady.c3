# shady.c3

A shader compiler in [C3](https://c3-lang.org). Source string in, SPIR-V out,
in the same process — no files, no subprocesses, no external toolchain.

```c3
import shady;

shady::Diagnostic diagnostic;
shady::DiagnosticList warnings;
warnings.init(mem, 4);

char[]? spirv = shady::compile(source, &diagnostic, warnings: &warnings);
if (catch spirv)
{
    io::eprintfn("%s", diagnostic.render(tmem)); // heading, source line, caret
    diagnostic.free();
    return;
}
diagnostic.free();
defer free(spirv);
foreach (&warning : warnings) warning.free();
warnings.free();

ShaderModule module = vk::loadShaderModule(device, spirv)!!;
```

Both results are the caller's: the SPIR-V is allocated on the allocator passed
to `compile`, and the diagnostic's message is a copy, since the compiler's own
arenas are gone by the time it returns.

The diagnostic names a region, a line and a column, carries the source line
under it and knows how wide the caret span is. `to_string` gives the
`material:3:12: message` heading; `render` adds the line and a caret, the way a
compiler prints a fault. A `#line 1 "material"` directive renumbers what follows
it, so a body spliced into generated source is reported at its own
coordinates — see [`LANGUAGE.md` §1.1](LANGUAGE.md).

Warnings travel beside the fault rather than in it: a compile that succeeds can
still say, in the same shape, that the spec constant nothing reads is a knob
wired to nothing.

One module holds every entry point, told apart by name, so a vertex and a
fragment stage come out of a single `VkShaderModule` — as do several variants
of the same stage:

```
fn FragmentIn stage_in(VertexIn input) @vertex(main)         { ... }
fn float4 shade_textured(FragmentIn input) @fragment(opaque) { ... }
fn float4 shade_solid(FragmentIn input) @fragment            { ... }
```

An entry point is named after its function unless the stage attribute gives a
name. The host selects one through `pName` in
`VkPipelineShaderStageCreateInfo`.

A bad shader is a fault with a position, never an exit and never a temporary
file, so compiling at startup — or on a file watch, or per frame — is safe.

## The language

C3-shaped, deliberately: `float4`/`float4x4` type names, postfix `@attributes`,
braces without trailing semicolons. [`LANGUAGE.md`](LANGUAGE.md) is the
specification.

```
struct VertexIn
{
    float3 position;
    float4 color;
    float2 uv;
}

struct FragmentIn
{
    float4 position @position;
    float4 color;
    float2 uv;
}

struct Uniforms @uniform
{
    float4x4 projection;
    float4x4 view;
}

Uniforms  uniforms;
texture2d tex;
sampler   tex_sampler;

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.projection * uniforms.view * float4(input.position, 1.0);
    output.color    = input.color;
    output.uv       = input.uv;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    return tex.sample(tex_sampler, input.uv) * input.color;
}
```

A block is an ordinary struct plus an attribute — `@uniform`, `@pushconstant`
or `@address` — which decides its layout, its storage class, and whether it
takes a binding. A module-level variable is then just `Type name;`. There are
no `uniform`, `buffer` or `push_constant` keywords.

Descriptor sets and bindings are assigned in declaration order unless an
explicit `@set`/`@binding` says otherwise; a collision is an error rather than
a silent overwrite.

### Buffer device addresses

An `@address` struct is reached through a 64-bit GPU address instead of a
descriptor — Vulkan's `bufferDeviceAddress`. It lets a vertex shader pull its
own vertices, with no vertex input bindings or attributes at all.

It is neither a uniform buffer nor a storage buffer: it is a raw pointer
target, what GLSL spells `buffer_reference`.

```
struct Vertex @address
{
    float3 position;
    float4 color;
}

struct Push @pushconstant { Vertex* vertices; }
Push pc;

struct VertexIn { uint index @builtin(vertex_index); }

fn FragmentIn vert(VertexIn input) @vertex
{
    Vertex* v = pc.vertices;

    FragmentIn output;
    output.position = mvp * float4(v[input.index].position, 1.0);
    output.color    = v[input.index].color;
    return output;
}
```

Declaring one switches the module to the `PhysicalStorageBuffer64` addressing
model and SPIR-V 1.3, lays the struct out std430, and puts an
`Aligned` operand on every access through the address. See
[`LANGUAGE.md` §10](LANGUAGE.md), which also records why indexing lowers to
explicit 64-bit arithmetic rather than to `OpPtrAccessChain`.

## What works

Structs, uniform blocks with std140 layout, push constants and buffer device
addresses with std430 or C3's scalar packing (`compile(..., scalar_layout:
true)`), textures and samplers, every vector and matrix product,
mixed constructors like `float4(xyz, 1.0)`, swizzles, `if`/`while`/`for`
lowered to structured control flow with `break`/`continue`, ~35 GLSL.std.450
builtins, `discard`, several entry points in one module, plain functions with
overloading, C3-style methods (`fn float4 Map.Sample(&self, float2 uv)`),
ternary, `++`/`--`, compound bitwise assignment, C-style casts, `out`/`inout`
parameters, arrays with initialiser lists, `mul`/`asuint`/`all`/`any`/
`select`/`[unroll]`, device addresses to flat scalar/vector/matrix streams as
well as structs, pointer parameters, locals and reassignment, reads and writes
through an address, matrix add/subtract, `InterlockedAdd`, combined
`Sampler2D`/`Sampler2DShadow` descriptors, runtime-sized descriptor arrays with
`NonUniformResourceIndex`, the `Sample`/`SampleLevel`/`SampleGrad`/`SampleBias`/
`SampleCmpLevelZero` variants, several descriptor sets in one module,
specialization constants (`const bool X @spec(0) = true;`) for one module
serving several variants, interfaces (`interface I { ... }` plus
`provides I;`, a compile-time obligation with no vtables and no dispatch),
`import "file.shady";` with the module's text as its import closure (each file
in its own `#line` region, a cycle refused, a repeated import included once),
`#line` source maps for diagnostics on generated bodies, and warnings reported
on the success path beside the fault.

Not yet: storage buffers and runtime-sized arrays of memory (as opposed to of
descriptors). Each of these fails with a position and a message rather than
miscompiling.

## Using it

As a C3 dependency, unpacked in your `lib/` directory:

```json
{
  "dependency-search-paths": ["lib"],
  "dependencies": ["shady"]
}
```

Or as a submodule:

```sh
git submodule add https://github.com/tonis2/shady.c3.git lib/shady.c3l
```

There is nothing to build and nothing to link — it is pure C3.

## Tests

```sh
c3c test
```

The tests check emitted SPIR-V structurally: entry points, descriptor
decorations, block offsets, the addressing model. Validate the output with
`spirv-val --target-env vulkan1.3` rather than plain `spirv-val` — the generic
environment accepts things Vulkan rejects.

## Layout

| | |
|---|---|
| `LANGUAGE.md` | the specification |
| `shady/spec.c3` | SPIR-V constants |
| `shady/module.c3` | module assembly, sections, id allocation, dedup |
| `shady/types.c3` | type and constant constructors |
| `shady/function.c3` | function bodies, blocks, instructions |
| `shady/lexer.c3` | tokenizer, `#line` directives |
| `shady/ast.c3` | syntax tree |
| `shady/parser.c3` | recursive descent parser |
| `shady/sema.c3` | type table, std140/std430 layout |
| `shady/diagnostic.c3` | the message record, its rendering, the source map |
| `shady/codegen.c3` | AST to SPIR-V, single pass |
| `shady/compile.c3` | bindings, stage lowering, the public entry point |

Resolution and emission happen together — there is no typed IR, and an
expression's type is worked out as its instructions are emitted. That is why
this is a few thousand lines rather than tens of thousands.
