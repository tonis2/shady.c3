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
}

<*
 The attribute name that declares this stage, without the `@`.
*>
fn String Stage.attribute(Stage self) @inline
{
	switch (self)
	{
		case Stage.VERTEX:   return "vertex";
		case Stage.FRAGMENT: return "fragment";
		case Stage.COMPUTE:  return "compute";
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
		case "vertex":   *out = Stage.VERTEX;
		case "fragment": *out = Stage.FRAGMENT;
		case "compute":  *out = Stage.COMPUTE;
		default: return false;
	}
	return true;
}

<*
 The SPIR-V execution model a function of this stage is emitted under.
*>
fn uint Stage.execution_model(Stage self) @inline
{
	switch (self)
	{
		case Stage.VERTEX:   return EXECUTION_MODEL_VERTEX;
		case Stage.FRAGMENT: return EXECUTION_MODEL_FRAGMENT;
		case Stage.COMPUTE:  return EXECUTION_MODEL_GLCOMPUTE;
	}
}
