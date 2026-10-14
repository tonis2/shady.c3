module shady;

<*
 The entry-point stages, as one vocabulary for both ends of the language.

 The parser reads `@vertex` off a function and the tool writing a module has to
 spell the same word, so the word is written down here once. It used to be two
 tables - three string compares in `Codegen.build` and an enum in the generator
 - which is how a third stage ends up being added in one of them.
*>
enum Stage : char
{
	VERTEX,
	FRAGMENT,
	COMPUTE,
	// The ray-tracing pipeline: a ray is generated, traced through the scene,
	// tested by intersection and any-hit shaders, and ends in a closest-hit or
	// a miss shader. A callable shader is a subroutine the others call through
	// the shader binding table.
	RAYGEN,
	INTERSECTION,
	ANY_HIT,
	CLOSEST_HIT,
	MISS,
	CALLABLE,
}

<*
 The attribute name that declares this stage, without the `@`.
*>
fn String Stage.attribute(Stage self) @inline
{
	switch (self)
	{
		case Stage.VERTEX:       return "vertex";
		case Stage.FRAGMENT:     return "fragment";
		case Stage.COMPUTE:      return "compute";
		case Stage.RAYGEN:       return "raygen";
		case Stage.INTERSECTION: return "intersection";
		case Stage.ANY_HIT:      return "any_hit";
		case Stage.CLOSEST_HIT:  return "closest_hit";
		case Stage.MISS:         return "miss";
		case Stage.CALLABLE:     return "callable";
	}
}

<*
 The stage an attribute name declares. False for every other attribute: a
 member's `@position`, a constant's `@spec` and the rest reach this too, and
 none of them is an entry point.
*>
fn bool stage_from_attribute(String name, Stage* out)
{
	switch (name)
	{
		case "vertex":       *out = Stage.VERTEX;
		case "fragment":     *out = Stage.FRAGMENT;
		case "compute":      *out = Stage.COMPUTE;
		case "raygen":       *out = Stage.RAYGEN;
		case "intersection": *out = Stage.INTERSECTION;
		case "any_hit":      *out = Stage.ANY_HIT;
		case "closest_hit":  *out = Stage.CLOSEST_HIT;
		case "miss":         *out = Stage.MISS;
		case "callable":     *out = Stage.CALLABLE;
		default: return false;
	}
	return true;
}

<*
 The SPIR-V execution model a function of this stage is emitted under.
*>
fn ExecutionModel Stage.execution_model(Stage self) @inline
{
	switch (self)
	{
		case Stage.VERTEX:       return ExecutionModel.VERTEX;
		case Stage.FRAGMENT:     return ExecutionModel.FRAGMENT;
		case Stage.COMPUTE:      return ExecutionModel.GL_COMPUTE;
		case Stage.RAYGEN:       return ExecutionModel.RAY_GENERATION;
		case Stage.INTERSECTION: return ExecutionModel.INTERSECTION;
		case Stage.ANY_HIT:      return ExecutionModel.ANY_HIT;
		case Stage.CLOSEST_HIT:  return ExecutionModel.CLOSEST_HIT;
		case Stage.MISS:         return ExecutionModel.MISS;
		case Stage.CALLABLE:     return ExecutionModel.CALLABLE;
	}
}

<*
 One of the six stages of the ray-tracing pipeline, which have no varyings and
 no execution modes, and talk to each other through payloads instead.
*>
fn bool Stage.is_ray_tracing(Stage self) @inline => self >= Stage.RAYGEN;

<*
 The stage as one bit of a set. A set of stages is how the compiler says where
 something may run: `sample()` with an implicit LOD needs a fragment shader,
 `trace_ray` one of three ray-tracing stages, and a helper that does both can
 only be reached from the stages in both sets.
*>
fn uint Stage.bit(Stage self) @inline => 1u << (uint)self.ordinal;

<*
 The set holding every stage: what a requirement that restricts nothing is.
*>
const uint ALL_STAGES = 0xffff_ffff;

<*
 The stage attribute among `attributes`, and the stage it declares, or null
 when the function is not an entry point.
*>
fn Attribute* stage_attribute(Attribute[] attributes, Stage* out)
{
	foreach (&attribute : attributes)
	{
		if (stage_from_attribute(attribute.name, out)) return attribute;
	}
	return null;
}

<*
 A set of stages as a message spells it: "a fragment", "a closest-hit, any-hit
 or miss". Followed by "shader" where it is used.
*>
fn String stage_list(uint mask, Allocator allocator)
{
	DString text;
	text.init(allocator, 32);
	usz total = 0;
	foreach (stage : Stage::values) if (mask & stage.bit()) total++;

	usz written = 0;
	foreach (stage : Stage::values)
	{
		if (!(mask & stage.bit())) continue;
		if (written == 0)
		{
			char first = stage.noun()[0];
			bool vowel = first == 'a' || first == 'e' || first == 'i' || first == 'o' || first == 'u';
			text.append_string(vowel ? "an " : "a ");
		}
		else
		{
			text.append_string(written + 1 == total ? " or " : ", ");
		}
		text.append_string(stage.noun());
		written++;
	}
	return text.str_view();
}

<*
 The stage as a message names it - "fragment", "closest-hit" - which is not
 always the attribute: an attribute is an identifier, and cannot hold a hyphen.
*>
fn String Stage.noun(Stage self)
{
	switch (self)
	{
		case Stage.VERTEX:       return "vertex";
		case Stage.FRAGMENT:     return "fragment";
		case Stage.COMPUTE:      return "compute";
		case Stage.RAYGEN:       return "ray-generation";
		case Stage.INTERSECTION: return "intersection";
		case Stage.ANY_HIT:      return "any-hit";
		case Stage.CLOSEST_HIT:  return "closest-hit";
		case Stage.MISS:         return "miss";
		case Stage.CALLABLE:     return "callable";
	}
}
