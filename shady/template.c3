<*
 What a program embedding the compiler can ask of a template before it splices
 anything into one.

 A template is a module with holes in it: functions it calls and does not
 define (`@required`), or defines only as a default (`@fallback`). The host
 fills a hole with text an author wrote. These are the questions that host has
 to ask first - what the holes are and what each one's signature is, whether a
 piece of text already defines functions or is only a body, whether a name is
 one the language keeps for itself - answered from the same parser the compile
 uses, so the two cannot disagree.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

<*
 One hole of a template, as the template wrote it.
*>
struct Hole
{
	String name;
	bool   fallback;  // `@fallback` (optional) rather than `@required`
	String signature; // `fn void displace(inout Vertex v)`, no attributes
	String region;    // the `#line` region the hole is declared in, or ""
	uint   line;      // its line in that region
}

<*
 A function declaration's signature, written back out as source:
 `fn float3 shade(Surface s)`, `fn float4 Map.Sample(&self, float2 uv)`.

 Without attributes and without a body, so it can head a body the host wraps -
 which is what it is for - and be quoted in a message about the hole.
*>
fn String Decl.signature_text(&self, Allocator allocator)
{
	DString out;
	out.init(allocator, 64);
	out.append_string("fn ");
	append_type_ref(&out, self.function.return_type);
	out.append_char(' ');
	if (self.function.receiver.len)
	{
		out.append_string(self.function.receiver);
		out.append_char('.');
	}
	out.append_string(self.name);
	out.append_char('(');
	foreach (i, param : self.function.params)
	{
		if (i > 0) out.append_string(", ");
		if (param.is_self)
		{
			out.append_string(param.by_ref ? "&self" : "self");
			continue;
		}
		if (param.is_out) out.append_string(param.is_inout ? "inout " : "out ");
		append_type_ref(&out, param.type);
		out.append_char(' ');
		out.append_string(param.name);
	}
	out.append_char(')');
	return out.str_view();
}

fn void append_type_ref(DString* out, TypeRef type) @local
{
	if (type.is_coopmat)
	{
		out.appendf("coopmat<%s, %d, %d, %s, %s>", type.coopmat_element, type.coopmat_rows,
			type.coopmat_columns, type.coopmat_scope, type.coopmat_use);
	}
	else
	{
		out.append_string(type.name);
	}
	if (type.is_pointer) out.append_char('*');
	if (type.is_array)
	{
		if (type.array_size)
		{
			out.appendf("[%d]", type.array_size);
		}
		else
		{
			out.append_string("[]");
		}
	}
}

<*
 The holes a template declares, in the order it declares them.

 Parsed, not compiled: a template is not a whole program until its holes are
 filled, so this asks the parser only - which also holds it to the attribute
 rules, so a template with a misspelt `@requird` is refused here rather than
 listing no hole. Every string is copied onto `allocator`; the source need not
 outlive the answer.

 `source` is import-resolved text (`resolve_imports`), as for `compile`.
*>
fn Hole[]? holes(String source, Allocator allocator)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 16 * 1024);
	defer arena.free();

	LineMap map;
	map.init(&arena);

	Parser parser;
	Ast? parsed = parse(source, &parser, &map);
	if (catch err = parsed)
	{
		if (parser.error.len) free(parser.error);
		return err~;
	}
	Ast ast = parsed;
	defer ast.free();

	List{Hole} found;
	found.init(allocator, 4);
	foreach (decl : ast.decls)
	{
		if (decl.kind != DeclKind.FUNCTION) continue;
		bool fallback = decl.attributes.find("fallback") != null;
		if (!fallback && !decl.attributes.find("required")) continue;

		LineDirective* directive = map.find(decl.line);
		found.push({
			.name      = decl.name.copy(allocator),
			.fallback  = fallback,
			.signature = decl.signature_text(allocator),
			.region    = directive ? directive.name.copy(allocator) : "",
			.line      = directive ? (uint)((int)decl.line + directive.offset) : decl.line,
		});
	}
	return found.array_view();
}

<*
 Whether a piece of text defines or declares any function - whether it holds an
 `fn` token, comments and strings aside.

 This is how a host tells the two spellings of a hole's text apart: whole
 functions (`fn float3 shade(Surface s) { ... }`, with any helpers beside it),
 or only the statements of one body (`return s.albedo;`), which can never hold
 an `fn` because a body cannot declare a function.
*>
fn bool? defines_functions(String source)
{
	TokenList tokens = tokenize(source, mem)!;
	defer tokens.free();
	foreach (token : tokens)
	{
		if (token.kind == FN) return true;
	}
	return false;
}

<*
 Every name the text declares at the top level - functions, structs, constants,
 resources and shared variables - copied onto `allocator`, in order, with each
 name once. For a host that injects names of its own beside a template and has
 to know which ones the template already took.
*>
fn String[]? top_level_names(String source, Allocator allocator)
{
	Parser parser;
	Ast? parsed = parse(source, &parser);
	if (catch err = parsed)
	{
		if (parser.error.len) free(parser.error);
		return err~;
	}
	Ast ast = parsed;
	defer ast.free();

	List{String} names;
	names.init(allocator, 32);
	foreach (decl : ast.decls)
	{
		if (decl.kind == DeclKind.MODULE || decl.kind == DeclKind.INTERFACE) continue;
		if (!decl.name.len) continue;
		bool seen = false;
		foreach (name : names) if (name == decl.name) { seen = true; break; }
		if (!seen) names.push(decl.name.copy(allocator));
	}
	return names.array_view();
}
