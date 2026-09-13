<*
 `import "file.shady";`, resolved before parsing (LANGUAGE.md section 3.6).

 A module's text is its import closure: every imported file's text joins the
 module, each under its own `#line` region so a diagnostic names the file it is
 in rather than a line in a spliced blob. The compiler itself never touches the
 disk - a caller supplies the text of each name through an `ImportResolver`, and
 three.c3's `load_source` is one.

 Cycles are refused. A file imported twice is included once: the closure is a
 set of files, so the second import of a name has nothing left to add. Both
 rules need state that spans the whole recursion, which is why resolution -
 unlike parsing - owns the walk.

 The result is always a new string on `allocator`, even when there is nothing
 to resolve, so a caller can free what it is handed without asking where it
 came from.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

faultdef IMPORT_ERROR;

<*
 Where an import's text comes from. Returns the text for `name`, allocated from
 `allocator`, or raises a fault when there is no such import. `resolve_imports`
 passes the walk's own scratch allocator, which it releases when it is done, so
 the text only has to survive until it has been copied into the closure.
*>
alias ImportResolver = fn String?(String name, Allocator allocator);

// One `import "name";`, as the line it sits on.
struct ImportSite @local
{
	uint   line;
	uint   column;
	uint   length;
	String name;
}

struct ImportContext @local
{
	ImportResolver resolver;
	// Scratch: the token lists, sites and cycle chains of the walk. An arena
	// of the call's own rather than a `@pool`, because the pool would reset
	// allocations the caller made on its temporary before calling in - the
	// result itself, when that temporary is the allocator.
	Allocator scratch;
	// The files being expanded right now, outermost first. A name reaching
	// this list again is a cycle.
	List{String} open;
	// The files already in the closure. A name here is skipped, so a diamond
	// import is one copy of the file.
	List{String} included;
}

<*
 The module's text with every import resolved.

 @param source : `The file's text. Imported files arrive through the resolver.`
 @param name : `What diagnostics call this file's own region, and the name a cycle is recognised by. Empty is legal for a string with no file behind it.`
 @param resolver : `The text of each imported name - see ImportResolver.`
 @param diagnostic : `Filled in with the position of the offending import when resolution fails. Its strings are allocated from the same allocator as the result and are the caller's to free.`
 @return ? IMPORT_ERROR : `An import is missing, malformed, cyclic, or the file supply itself raised.`
 @return `The closure, on the caller's allocator.`
*>
fn String? resolve_imports(
	String source,
	String name,
	ImportResolver resolver,
	Diagnostic* diagnostic = null,
	Allocator allocator = mem)
{
	if (diagnostic) *diagnostic = {};
	if (!mentions_import(source)) return source.copy(allocator);

	// The walk's own memory is an arena freed on every path - not a `@pool`,
	// which would reset temporary allocations the caller made before this
	// call and still owns after it.
	DynamicArenaAllocator arena;
	arena.init(mem, 64 * 1024);
	defer arena.free();

	ImportContext context;
	context.resolver = resolver;
	context.scratch  = &arena;
	context.open.init(&arena, 4);
	context.included.init(&arena, 4);
	if (name.len) context.open.push(name);

	DString out;
	out.init(allocator, source.len + 64);
	bool complete = false;
	defer if (!complete) out.free();

	expand(&context, source, name, &out, diagnostic, allocator)!;

	// A copy, not the builder's own view: `str_view` points inside the
	// DString's padded allocation, and the caller owns what it is handed.
	String resolved = out.copy_str(allocator);
	out.free();
	complete = true;
	return resolved;
}

<*
 Whether the text could contain an import at all.

 A scan rather than a tokenize, because this runs on every file a caller loads -
 including the Slang templates three.c3 still hands `load_source` - and those do
 not lex as shady at all. The shape looked for is `import` followed by blanks
 and a quote, which is specific enough that no shipped template contains it.
*>
fn bool mentions_import(String source) @local
{
	usz at = 0;
	while (at < source.len)
	{
		if (source[at] != 'i')
		{
			at++;
			continue;
		}
		if (!source[at..].starts_with("import"))
		{
			at++;
			continue;
		}

		usz after = at + 6;
		while (after < source.len
			&& (source[after] == ' ' || source[after] == '\t' || source[after] == '\r' || source[after] == '\n'))
		{
			after++;
		}
		if (after < source.len && source[after] == '"') return true;
		at++;
	}
	return false;
}

<*
 Expand one file into `out`, recursing into its imports.

 The walk is line by line because that is what keeps positions honest: an
 import line is replaced by `#line 1 "<imported>"`, the imported text, and a
 `#line <n> "<this file>"` that hands this file's own numbering back. Inserting
 directives and comments changes only physical lines, and every reported
 position comes from a directive, so nothing downstream has to know.
*>
fn void? expand(
	ImportContext* context,
	String source,
	String name,
	DString* out,
	Diagnostic* diagnostic,
	Allocator allocator) @local
{
	Lexer failed;
	TokenList? tokenized = tokenize(source, context.scratch, null, &failed);
	if (catch err = tokenized)
	{
		import_fail(diagnostic, allocator, source, name,
			failed.error_line, failed.error_column, 0, failed.error);
		return IMPORT_ERROR~;
	}
	TokenList tokens = tokenized;

	List{ImportSite} sites;
	sites.init(context.scratch, 4);

	uint depth = 0;
	sz   i     = 0;
	while (i < tokens.len() && tokens[i].kind != EOF)
	{
		Token token = tokens[i];
		if (token.kind == LBRACE)
		{
			depth++;
		}
		else if (token.kind == RBRACE)
		{
			if (depth > 0) depth--;
		}
		else if (token.kind == IMPORT)
		{
			if (depth != 0)
			{
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)token.text.len, "`import` is a module-level statement");
				return IMPORT_ERROR~;
			}
			if (tokens[i + 1].kind != STRING)
			{
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)token.text.len, "expected a quoted file name after `import`");
				return IMPORT_ERROR~;
			}

			String imported = tokens[i + 1].text;
			if (imported.len == 0)
			{
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)tokens[i + 1].text.len + 2, "an import needs a file name");
				return IMPORT_ERROR~;
			}

			// The line is replaced whole, so nothing else may stand on it.
			bool starts_line = i == 0 || tokens[i - 1].line < token.line;
			if (!starts_line)
			{
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)token.text.len, "an import stands alone on its line");
				return IMPORT_ERROR~;
			}

			if (tokens[i + 2].kind != SEMICOLON)
			{
				bool ends_line = tokens[i + 2].kind == EOF || tokens[i + 2].line > token.line;
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)tokens[i + 1].text.len + 2,
					ends_line
						? "expected `;` after the imported file name"
						: "an import stands alone on its line");
				return IMPORT_ERROR~;
			}

			bool ends_line = tokens[i + 3].kind == EOF || tokens[i + 3].line > token.line;
			if (!ends_line)
			{
				import_fail(diagnostic, allocator, source, name, token.line, token.column,
					(uint)tokens[i + 2].text.len, "an import stands alone on its line");
				return IMPORT_ERROR~;
			}

			sites.push({
				.line   = token.line,
				.column = token.column,
				.length = (uint)imported.len + 2,
				.name   = imported,
			});
			i += 3;
			continue;
		}
		i++;
	}

	if (sites.len() == 0)
	{
		out.append_string(source);
		return;
	}

	uint physical   = 1;
	uint report     = 1; // the line number the next line written is reported as
	String region   = name;
	usz  line_start = 0;
	sz   site_at    = 0;

	while (line_start < source.len)
	{
		usz line_end = line_start;
		while (line_end < source.len && source[line_end] != '\n') line_end++;
		String line = line_end > line_start ? source[line_start..line_end - 1] : "";
		usz next = line_end < source.len ? line_end + 1 : line_end;

		if (site_at < sites.len() && sites[site_at].line == physical)
		{
			ImportSite site = sites[site_at++];

			String cycle = import_cycle(context, site.name);
			if (cycle.len)
			{
				import_fail(diagnostic, allocator, source, name, site.line, site.column, site.length,
					string::format(tmem, "the import of `%s` closes an import cycle: %s", site.name, cycle));
				return IMPORT_ERROR~;
			}

			if (!string_list_has(&context.included, site.name))
			{
				// The text is the walk's until it has been copied: the scratch
				// allocator owns it, so a resolver may hand over anything it
				// allocated there without agreeing on a free.
				String? fetched = context.resolver(site.name, context.scratch);
				if (catch fetched)
				{
					import_fail(diagnostic, allocator, source, name, site.line, site.column, site.length,
						string::format(tmem,
							"the import `%s` was not found - the program supplying imports has no file by that name",
							site.name));
					return IMPORT_ERROR~;
				}
				String imported = fetched;

				out.append_string("#line 1 \"");
				out.append_string(site.name);
				out.append_string("\"\n");

				context.open.push(site.name);
				expand(context, imported, site.name, out, diagnostic, allocator)!;
				(void)context.open.pop();
				context.included.push(site.name);

				if (out.len() == 0 || out.str_view()[out.len() - 1] != '\n') out.append_char('\n');
				out.appendf("#line %d \"%s\"\n", (int)(report + 1), region);
			}

			report++;
			physical++;
			line_start = next;
			continue;
		}

		uint   directive_number;
		String directive_name;
		if (line_directive(line, &directive_number, &directive_name))
		{
			report = directive_number;
			region = directive_name;
		}
		else
		{
			report++;
		}
		out.append_string(line);
		out.append_char('\n');
		physical++;
		line_start = next;
	}
}

<*
 The open stack as a readable chain when it already contains `name`, or the
 empty string when it does not.
*>
fn String import_cycle(ImportContext* context, String name) @local
{
	bool cycle = false;
	foreach (open : context.open)
	{
		if (open == name)
		{
			cycle = true;
			break;
		}
	}
	if (!cycle) return "";

	DString chain;
	chain.init(context.scratch, 64);
	foreach (open : context.open)
	{
		if (chain.len() > 0) chain.append_string(" -> ");
		chain.append_string(open);
	}
	if (chain.len() > 0) chain.append_string(" -> ");
	chain.append_string(name);
	return chain.str_view();
}

fn bool string_list_has(List{String}* list, String value) @local
{
	foreach (entry : *list) if (entry == value) return true;
	return false;
}

<*
 Parse a `#line <n> "<name>"` line. False for anything else; the lexer has
 already refused malformed directives, so this only has to read them back.
*>
fn bool line_directive(String line, uint* number, String* name) @local
{
	String text = line.trim();
	if (text.len == 0 || text[0] != '#') return false;

	usz at = 1;
	while (at < text.len && (text[at] == ' ' || text[at] == '\t')) at++;
	if (!text[at..].starts_with("line")) return false;
	at += 4;
	if (at >= text.len || (text[at] != ' ' && text[at] != '\t')) return false;
	while (at < text.len && (text[at] == ' ' || text[at] == '\t')) at++;

	uint value  = 0;
	bool digits = false;
	while (at < text.len && text[at] >= '0' && text[at] <= '9')
	{
		value = value * 10 + (uint)(text[at] - '0');
		at++;
		digits = true;
	}
	if (!digits) return false;

	while (at < text.len && (text[at] == ' ' || text[at] == '\t')) at++;
	if (at >= text.len || text[at] != '"') return false;
	at++;

	usz start = at;
	while (at < text.len && text[at] != '"') at++;
	if (at >= text.len) return false;

	*number = value;
	*name   = text[start..at - 1];
	return true;
}

fn void import_fail(
	Diagnostic* diagnostic,
	Allocator allocator,
	String source,
	String name,
	uint line,
	uint column,
	uint length,
	String message) @local
{
	if (!diagnostic) return;

	// The reported line and region are this file's own, mapped through its
	// `#line` directives the way diagnostic_at maps a compile's positions:
	// the last directive before the offending line owns it.
	uint   reported = line;
	String region   = name;
	uint   physical = 1;
	usz    at       = 0;
	while (at < source.len && physical < line)
	{
		usz end = at;
		while (end < source.len && source[end] != '\n') end++;

		uint   directive_number;
		String directive_name;
		String row = end > at ? source[at..end - 1] : "";
		if (line_directive(row, &directive_number, &directive_name))
		{
			reported = directive_number + (line - physical - 1);
			region   = directive_name;
		}

		at = end < source.len ? end + 1 : end;
		physical++;
	}

	*diagnostic = {
		.kind    = ERROR,
		.message = message.copy(allocator),
		.line    = reported,
		.column  = column,
		.length  = length,
	};
	if (region.len) diagnostic.name = region.copy(allocator);

	String text = source_line(source, line);
	if (text.len) diagnostic.line_text = text.copy(allocator);
}
