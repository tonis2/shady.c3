<*
 What the compiler has to say, and where.

 A compile reports through one record: a kind, a message, and a position. The
 position is in the numbering the *writer* used - a `#line` directive renumbers
 the lines that follow it, so a body spliced into generated source is reported
 at its own coordinates - and it carries the line itself, so a caller can show
 it without still holding the source.

 Everything here is the caller's: `Diagnostic.free` releases the message, the
 region name and the source line together.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

enum DiagnosticKind : char
{
	ERROR,
	WARNING,
}

struct Diagnostic
{
	DiagnosticKind kind;
	String         message;
	// The name a `#line` directive gave the region. Empty when the source is
	// one piece and its physical numbering is its own.
	String name;
	// The offending line without its newline, for a caller that shows it.
	// Empty when the position is not on a line the source has.
	String line_text;
	uint   line;   // 1-based, in the region's numbering
	uint   column; // 1-based, in bytes
	uint   length; // caret width in bytes; 0 means one character
}

alias DiagnosticList = List{Diagnostic};

fn void Diagnostic.free(&self)
{
	if (self.message.len) free(self.message);
	if (self.name.len) free(self.name);
	if (self.line_text.len) free(self.line_text);
	*self = {};
}

<*
 `material:3:12: <message>`, or `<line>:<column>: <message>` when the source never
 named a region. A warning says so in front. The heading without the source
 line; `render` adds that.
*>
fn String Diagnostic.to_string(&self, Allocator allocator)
{
	if (!self.message.len) return "";

	String where = self.name.len
		? string::format(allocator, "%s:%d:%d", self.name, self.line, self.column)
		: string::format(allocator, "%d:%d", self.line, self.column);

	return string::format(allocator, "%s%s: %s",
		self.kind == WARNING ? "warning: " : "", where, self.message);
}

<*
 The whole thing: the heading, the source line, and a caret under the span.

     material:3:12: unknown name `nonesuch`
      3 |     return nonesuch;
                    ^^^^^^^^

 The caret line is measured from the printed gutter, so it lines up for a
 one-digit and a four-digit line number alike. This is the shape a caller wants
 to show a person - and the reason `line_text` and `length` are carried at all.
*>
fn String Diagnostic.render(&self, Allocator allocator)
{
	DString out;
	out.tinit(256);
	out.append_string(self.to_string(tmem));

	if (self.line_text.len)
	{
		String number = string::format(tmem, "%d", self.line);
		String prefix = string::format(tmem, " %s | ", number);

		out.append_char('\n');
		out.append_string(prefix);
		out.append_string(self.line_text);

		// The caret sits under the reported column, clamped to the line: a
		// position past the end - an error at EOF - still gets a caret.
		usz column = self.column > 0 ? (usz)self.column - 1 : 0;
		if (column > self.line_text.len) column = self.line_text.len;

		usz carets = self.length > 0 ? (usz)self.length : 1;
		out.append_char('\n');
		for (usz i = 0; i < prefix.len; i++) out.append_char(' ');
		for (usz i = 0; i < column; i++) out.append_char(' ');
		for (usz i = 0; i < carets; i++) out.append_char('^');
	}

	return out.copy_str(allocator);
}

<*
 One `#line <n> "<name>"` directive, as a rule for the lines after it: a
 physical line `L` is reported as `L + offset` under `name`.

 The offset is stored rather than the assigned number because every lookup
 starts from a physical line - nothing has to remember where a region began,
 only how far it is shifted.
*>
struct LineDirective
{
	uint   physical; // the line the directive sits on
	int    offset;   // reported line - physical line
	String name;     // slice of the source, which outlives every use
}

<*
 Every directive in one source, in the order they appear.

 There are few - one per spliced body - so a lookup scans from the end: the
 last directive before a line is the one that renumbers it.
*>
struct LineMap
{
	List{LineDirective} lines;
}

fn void LineMap.init(&self, Allocator allocator)
{
	self.lines.init(allocator, 8);
}

fn void LineMap.add(&self, uint physical, int offset, String name)
{
	self.lines.push({ .physical = physical, .offset = offset, .name = name });
}

fn LineDirective* LineMap.find(&self, uint physical)
{
	for (sz i = self.lines.len() - 1; i >= 0; i--)
	{
		if (self.lines[i].physical < physical) return &self.lines[i];
	}
	return null;
}

<*
 The text of one 1-based line, without its newline.

 An empty string for a line the source does not have, which is the answer a
 caller wants: a diagnostic is already an explanation, and one that faults
 while being built is worse than one that is missing its echo.
*>
fn String source_line(String source, uint line)
{
	if (line == 0) return "";

	usz start = 0;
	for (uint at = 1; at < line; at++)
	{
		usz end = start;
		while (end < source.len && source[end] != '\n') end++;
		// The source has fewer lines than asked for.
		if (end >= source.len) return "";
		start = end + 1;
	}

	usz end = start;
	while (end < source.len && source[end] != '\n') end++;
	usz stop = end;
	if (stop > start && source[stop - 1] == '\r') stop--;
	// Ranges in C3 include their end, and an empty line has nothing to include.
	if (stop <= start) return "";
	usz last = stop - 1;
	return source[start..last];
}

<*
 A diagnostic for a *physical* position, mapped through the source's `#line`
 directives, with its message and source line copied onto `allocator`.

 Every pass keeps physical positions and the translation happens once, here.
 The alternative - mapping where the fault is found - would mean each pass
 holding the map, and the map's lifetime is the compile's, not the pass's.
*>
fn Diagnostic diagnostic_at(
	Allocator allocator,
	String source,
	LineMap* map,
	DiagnosticKind kind,
	uint line,
	uint column,
	uint length,
	String message)
{
	Diagnostic diagnostic = {
		.kind    = kind,
		.message = message.len ? message.copy(allocator) : "",
		.column  = column,
		.length  = length,
	};

	LineDirective* region = map ? map.find(line) : null;
	if (region)
	{
		diagnostic.line = (uint)((int)line + region.offset);
		if (region.name.len) diagnostic.name = region.name.copy(allocator);
	}
	else
	{
		diagnostic.line = line;
	}

	String text = source_line(source, line);
	if (text.len) diagnostic.line_text = text.copy(allocator);

	return diagnostic;
}
