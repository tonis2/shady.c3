# shady.c3

**A shader compiler for [C3](https://c3-lang.org) that runs inside your program.**
Pass it source text and get SPIR-V back. It needs no temporary files, no
subprocesses and no external toolchain.

[Install](#install) · [Usage](#usage) · [Language](#language) ·
[Features](#features) · [Limitations](#limitations) · [Tests](#tests) ·
[Full spec](LANGUAGE.md)

## Install

Download `shady.c3l` from the
[latest release](https://github.com/tonis2/shady.c3/releases/latest) into your
project's `lib/` folder, then add it to `project.json`:

```json
{
  "dependency-search-paths": ["lib"],
  "dependencies": ["shady"]
}
```

To track the source instead, add it as a submodule:

```sh
git submodule add https://github.com/tonis2/shady.c3.git lib/shady.c3l
```

The library is pure C3, so there is nothing else to build or link.

## Usage

```c3
import shady;

shady::Diagnostic diagnostic;
char[]? spirv = shady::compile(source, &diagnostic);
if (catch spirv)
{
    io::eprintfn("%s", diagnostic.render(tmem)); // file:line:col, source line and caret
    diagnostic.free();
    return;
}
diagnostic.free();
defer free(spirv);

// Pass `spirv` to vkCreateShaderModule.
```

- **One module, every entry point.** Each entry point is named after its
  function unless the stage attribute names it, as in `@fragment(opaque)`.
- **You own the output.** The SPIR-V and the diagnostic use the `allocator:`
  argument (`mem` by default) and are yours to free.
- **Optional arguments:** `scalar_layout: true` packs blocks with C3's own
  layout. `warnings: &list` collects warnings into a `shady::DiagnosticList`.
- **Imports:** `shady::resolve_imports` resolves them through a loader you
  supply, so the compiler never reads files itself.

## Language

The language is C3-shaped. It has `float4`/`float4x4` types and postfix
attributes, and a struct needs no semicolon after its closing brace.

**Graphics**

```c3
struct Uniforms @uniform { float4x4 mvp; }

struct VertexIn   { float3 position; float2 uv; }
struct FragmentIn { float4 position @position; float2 uv; }

Uniforms  uniforms;
texture2d texture;
sampler   texture_sampler;

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.mvp * float4(input.position, 1.0);
    output.uv = input.uv;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    return texture.sample(texture_sampler, input.uv);
}
```

**Compute**

```c3
struct Push @pushconstant { uint count; }

float input[];    // a storage buffer holding a runtime-sized array
float output[];
Push  push;

struct ComputeIn { uint3 id @builtin(global_invocation_id); }

fn void main(ComputeIn at) @compute @threads(64, 1, 1)
{
    uint i = at.id.x;
    if (i >= push.count) return;
    output[i] = input[i] * 2.0;
}
```

Resources bind in declaration order. Use `@set(n) @binding(n)` to pin one
explicitly; a duplicate binding is an error.

## Features

| Area | What's supported |
|---|---|
| **Stages** | Vertex, fragment and compute (`@threads`, `@subgroup_size`). A module can hold any number of entry points. |
| **Types** | `bool` `int` `uint` `float` `half` `int8` `uint8`, vectors, matrices, arrays, structs and device pointers |
| **Buffers** | Uniform buffers (std140), storage buffers (std430) with runtime-sized arrays, push constants and buffer device addresses |
| **Textures** | 1D, 2D, 3D, cube and layered textures, separate or combined (`Sampler2D`, `SamplerCube`, `Sampler2DArray`, shadow types…). Sampling with bias, level or gradients, depth comparison, gather, texel `load`, `size`/`levels` queries, constant texel offsets, and bindless arrays with `NonUniformResourceIndex` |
| **Compute** | `shared` workgroup memory, `barrier`, `InterlockedAdd` and cooperative matrices (`coopmat`, `coop_load`, `coop_muladd`, `coop_store`) |
| **Layout** | std140 and std430 by default, or C3-compatible packing with `scalar_layout: true` |
| **Control flow** | `if`, `while`, `for`, `break`, `continue`, `discard` and `?:` |
| **Functions** | Overloads, C3-style methods, `out`/`inout` parameters and forward declarations |
| **Code organization** | Modules, `import`, interfaces, and templates with `@required`/`@fallback` holes |
| **Variants** | Specialization constants with `@spec(id)` |
| **Built-ins** | GLSL.std.450 math and geometry, `mod`/`fmod`, `inverse`/`determinant`, derivatives (`ddx`, `ddy`, `fwidth`) and bit casts (`asuint`, `asfloat`, `ashalf`, …) |
| **Diagnostics** | The source line with a caret, `#line` remapping and optional warnings. Unsupported input is reported as an error instead of producing invalid SPIR-V. |

## Limitations

- Only vertex, fragment and compute stages are supported. There are no
  geometry, tessellation, mesh or ray-tracing stages.
- There are no storage images (writable textures), no integer or multisampled
  textures, no `switch` and no `double`.
- Arrays have one dimension.
- The only atomic is `InterlockedAdd`, on 32-bit `uint`.
- Recursion isn't supported.

## Tests

```sh
c3c test
```

This runs the unit tests and a conformance corpus in `test/conformance/`. Each
shader in the corpus is compiled and validated with
`spirv-val --target-env vulkan1.3`. If `spirv-val` isn't on your `PATH`,
validation is skipped.

Validate your own output with the same Vulkan target, because generic
`spirv-val` accepts some modules that Vulkan rejects.

## License

[GPL-3.0](LICENSE)
