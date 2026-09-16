# shady.c3

An in-process shader compiler for [C3](https://c3-lang.org): pass it source and
get SPIR-V back. It creates no temporary files, starts no subprocesses, and
requires no external shader toolchain.

- [Install](#install)
- [Compile a shader](#compile-a-shader)
- [Shader language](#shader-language)
- [Supported features](#supported-features)
- [Tests](#tests)

## Install

Download `shady.c3l` from the
[latest release](https://github.com/tonis2/shady.c3/releases/latest), place it
in your project's `lib/` directory, and add the dependency:

```json
{
  "dependency-search-paths": ["lib"],
  "dependencies": ["shady"]
}
```

To follow the source directly instead, add the repository as a submodule:

```sh
git submodule add https://github.com/tonis2/shady.c3.git lib/shady.c3l
```

The library is pure C3, so there is nothing else to build or link.

## Compile a shader

```c3
import shady;

shady::Diagnostic diagnostic;
char[]? spirv = shady::compile(source, &diagnostic);

if (catch spirv)
{
    io::eprintfn("%s", diagnostic.render(tmem));
    diagnostic.free();
    return;
}

diagnostic.free();
defer free(spirv);

ShaderModule module = vk::loadShaderModule(device, spirv)!!;
```

`compile` returns one SPIR-V module containing every entry point in the source.
Entry points use the function name by default, or the name supplied to the stage
attribute, such as `@fragment(opaque)`.

The returned SPIR-V and diagnostic data belong to the caller. Both use the
allocator passed to `compile` (`mem` by default). Optional warnings can be
collected by passing an initialized `shady::DiagnosticList` through the
`warnings:` argument; free each warning and then the list when finished.

Diagnostics include the source line and caret span. `#line` directives can give
generated or imported source its own file name and line numbering. See
[Language: `#line` directives](LANGUAGE.md#11-line-directives).

## Shader language

The language is intentionally C3-shaped: familiar scalar, vector, and matrix
types; postfix attributes; and braces without trailing semicolons. The complete
reference is in [LANGUAGE.md](LANGUAGE.md).

```c3
struct Uniforms @uniform
{
    float4x4 projection;
    float4x4 view;
}

struct VertexIn
{
    float3 position;
    float2 uv;
}

struct FragmentIn
{
    float4 position @position;
    float2 uv;
}

Uniforms uniforms;
texture2d texture;
sampler texture_sampler;

fn FragmentIn vert(VertexIn input) @vertex
{
    FragmentIn output;
    output.position = uniforms.projection
        * uniforms.view
        * float4(input.position, 1.0);
    output.uv = input.uv;
    return output;
}

fn float4 frag(FragmentIn input) @fragment
{
    return texture.sample(texture_sampler, input.uv);
}
```

Resource blocks are ordinary structs marked with `@uniform`, `@pushconstant`,
or `@address`. Descriptor sets and bindings are assigned in declaration order,
unless `@set` and `@binding` specify them explicitly. Duplicate bindings are
reported as errors.

## Supported features

- Vertex, fragment, and compute entry points; multiple entry points per module.
- Scalars, vectors, matrices, arrays, structs, pointers, swizzles, constructors,
  casts, arithmetic, bitwise operations, and matrix/vector multiplication.
- Uniform blocks (std140), push constants, and buffer device addresses (std430).
  C3-compatible scalar packing is available with `scalar_layout: true`.
- Textures, samplers, combined samplers, descriptor arrays, non-uniform resource
  indices, several descriptor sets, and specialization constants.
- Structured `if`, `while`, and `for` control flow with `break`, `continue`, and
  `discard`, plus common GLSL built-ins and atomic addition.
- Functions, overloads, C3-style methods, `out`/`inout` parameters, modules,
  imports, and interfaces.

Not yet supported: storage buffers and runtime-sized arrays in memory. A
runtime-sized array of descriptors is supported. Unsupported input produces a
positioned diagnostic instead of silently generating invalid SPIR-V.

For the exact syntax and behavior, read the [language specification](LANGUAGE.md).

## Tests

Run the compiler tests with:

```sh
c3c test
```

The suite checks the emitted SPIR-V structure, including entry points, layouts,
descriptor decorations, and addressing models. To validate generated modules
yourself, use Vulkan's rules:

```sh
spirv-val --target-env vulkan1.3 shader.spv
```

The generic `spirv-val` environment accepts some modules that Vulkan rejects.
