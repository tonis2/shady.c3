<*
 Abstract syntax tree for the shady shader language (see LANGUAGE.md).

 Nodes are untyped and unresolved: `TypeRef` holds a name, not a type, and
 identifiers are not bound to anything. Resolution is a later pass, which keeps
 the parser a pure syntax transform and means a parse error can only ever be a
 syntax error.

 The whole tree is allocated from one arena, so `Ast.free` is a single call
 rather than a recursive walk.
*>
module shady;

import std::collections::list;
import std::core::mem::allocators;

// --- Types -------------------------------------------------------------------

<*
 A written type, e.g. `float4` or `float4[16]`. Resolved later against the
 builtin types and the module's structs.
*>
struct TypeRef
{
	String name;
	bool   is_array;
	uint   array_size; // meaningful only when is_array
	bool   is_pointer; // `T*`, a buffer device address
	uint   line;
	uint   column;
}

// --- Attributes --------------------------------------------------------------

struct AttrArg
{
	bool   is_name;  // @builtin(frag_coord) vs @location(0)
	String name;
	double number;
}

struct Attribute
{
	String    name;
	AttrArg[] args;
	uint      line;
	uint      column;
}

<*
 Look up an attribute by name. Returns null when absent, so callers read as
 `if (Attribute* a = find_attribute(attrs, "location")) ...`.
*>
fn Attribute* Attribute[].find(self, String name)
{
	foreach (&attribute : self)
	{
		if (attribute.name == name) return attribute;
	}
	return null;
}

// --- Expressions -------------------------------------------------------------

enum ExprKind : char
{
	INT_LITERAL,
	FLOAT_LITERAL,
	BOOL_LITERAL,
	IDENT,
	UNARY,
	BINARY,
	ASSIGN,
	CALL,
	MEMBER,
	INDEX,
	CONDITIONAL,
	CAST,
	UPDATE,
	INITIALIZER,
}

struct ExprLiteral
{
	double value;
	bool   is_unsigned;
}

struct ExprBool
{
	bool value;
}

struct ExprIdent
{
	String name;
}

struct ExprUnary
{
	TokenKind op;
	Expr*     operand;
}

struct ExprBinary
{
	TokenKind op;
	Expr*     left;
	Expr*     right;
}

<*
 `op` is EQ for plain assignment, or PLUS_EQ and friends for compound.
*>
struct ExprAssign
{
	TokenKind op;
	Expr*     target;
	Expr*     value;
}

<*
 `callee` is an IDENT for `f(x)`, or a MEMBER for `tex.sample(s, uv)`.
*>
struct ExprCall
{
	Expr*   callee;
	Expr*[] args;
}

<*
 Also covers swizzles: `v.xyz` is a MEMBER whose name is "xyz". Telling the two
 apart needs the type of `value`, so it is left to resolution.
*>
struct ExprMember
{
	Expr*  value;
	String name;
}

struct ExprIndex
{
	Expr* value;
	Expr* index;
}

<*
 `condition ? then_value : else_value`, evaluated as a branch rather than a
 select so a side-effecting arm only runs when it is taken.
*>
struct ExprConditional
{
	Expr* condition;
	Expr* then_value;
	Expr* else_value;
}

<*
 A C-style cast: `(float)x`, `(uint3)v`, `(float3x3)pose`. Distinct from a
 constructor because a cast may narrow - `(float3x3)` drops a matrix's fourth
 column and row.
*>
struct ExprCast
{
	TypeRef type;
	Expr*   value;
}

<*
 `++x`, `x++`, `--x`, `x--`. `prefix` decides whether the expression's value is
 the updated one or the old one.
*>
struct ExprUpdate
{
	TokenKind op;
	Expr*     target;
	bool      prefix;
}

<*
 `{ a, b, c }`, an array initialiser.
*>
struct ExprInitializer
{
	Expr*[] elements;
}

struct Expr
{
	ExprKind kind;
	uint     line;
	uint     column;

	union
	{
		ExprLiteral literal;
		ExprBool    boolean;
		ExprIdent   ident;
		ExprUnary   unary;
		ExprBinary  binary;
		ExprAssign  assign;
		ExprCall    call;
		ExprMember  member;
		ExprIndex   index;
		ExprConditional conditional;
		ExprCast    cast_expr;
		ExprUpdate  update;
		ExprInitializer initializer;
	}
}

// --- Statements --------------------------------------------------------------

enum StmtKind : char
{
	BLOCK,
	DECL,
	EXPR,
	RETURN,
	IF,
	WHILE,
	FOR,
	BREAK,
	CONTINUE,
	DISCARD,
}

struct StmtBlock
{
	Stmt*[] statements;
}

struct StmtDecl
{
	TypeRef type;
	String  name;
	Expr*   value; // null when uninitialised
}

struct StmtExpr
{
	Expr* value;
}

<*
 A null value is a bare `return;`.
*>
struct StmtReturn
{
	Expr* value;
}

struct StmtIf
{
	Expr* condition;
	Stmt* then_branch;
	Stmt* else_branch; // null when there is no else
}

struct StmtWhile
{
	Expr* condition;
	Stmt* body;
}

<*
 Any of init, condition and step may be null: `for (;;)` is legal.
*>
struct StmtFor
{
	Stmt* init;
	Expr* condition;
	Expr* step;
	Stmt* body;
}

struct Stmt
{
	StmtKind kind;
	uint     line;
	uint     column;

	union
	{
		StmtBlock  block;
		StmtDecl   decl;
		StmtExpr   expr;
		StmtReturn ret;
		StmtIf     if_stmt;
		StmtWhile  while_stmt;
		StmtFor    for_stmt;
	}
}

// --- Declarations ------------------------------------------------------------

struct Member
{
	TypeRef     type;
	String      name;
	Attribute[] attributes;
	uint        line;
	uint        column;
}

struct Param
{
	TypeRef     type;
	String      name;
	Attribute[] attributes;
	uint        line;
	uint        column;

	// `fn R Map.sample(&self, ...)`: the receiver takes no written type, because
	// the qualified name already says what it is.
	bool        is_self;
	bool        by_ref;

	// `out` / `inout`: a by-reference parameter that is not the receiver.
	bool        is_out;
}

enum DeclKind : char
{
	STRUCT,
	FUNCTION,
	RESOURCE, // uniform blocks, textures, samplers
	CONSTANT,
	INTERFACE,  // a named set of function declarations
	IMPLEMENTS, // `implements I;`: this module defines every member of I
}

struct DeclStruct
{
	Member[] members;
}

struct DeclFunction
{
	TypeRef return_type;
	Param[] params;
	Stmt*   body;

	// The receiver type of a method, as written before the dot in the function
	// name: `fn R Map.sample(...)` has `receiver` "Map" and name "sample".
	// Empty for an ordinary function.
	String  receiver;
}

<*
 A module-level variable: `Uniforms uniforms;`, `texture2d tex;`, `Push pc;`.

 What kind of resource it is comes from the type, not from the declaration -
 an opaque type is a descriptor of its own kind, and a struct is whatever its
 `@uniform` or `@pushconstant` attribute says (LANGUAGE.md section 3.3).
*>
struct DeclResource
{
	TypeRef type;
}

struct DeclConstant
{
	TypeRef type;
	Expr*   value;
}

<*
 A named set of function declarations and no bodies.
 
 Each member is also registered as an ordinary top-level function declaration -
 one without a body - so a call resolves through it and a definition fills it
 exactly as it fills a plain declaration. `implements` is what turns a member's
 absence from "only wrong if called" into an error (LANGUAGE.md section 3.5).
*>
struct DeclInterface
{
	Decl*[] members;
}

<*
 `implements I;`, a module-level statement that every member of `I` is defined
 in this module. Checked once, on the whole module's text.
*>
struct DeclImplements
{
	String interface_name;
}

struct Decl
{
	DeclKind    kind;
	String      name;
	Attribute[] attributes;
	uint        line;
	uint        column;

	// Set on a function declared inside an interface. Two interfaces may share
	// a member signature; these are not a duplicate declaration, so they fold
	// into one signature rather than being refused.
	bool        interface_member;

	union
	{
		DeclStruct   struct_decl;
		DeclFunction function;
		DeclResource resource;
		DeclConstant constant;
		DeclInterface interface_decl;
		DeclImplements implements_decl;
	}
}

// --- The tree ----------------------------------------------------------------

<*
 A parsed shader. Everything reachable from `decls` lives in `arena`, and the
 string slices point into the original source, which must outlive the Ast.
*>
struct Ast
{
	Decl*[] decls;
	DynamicArenaAllocator arena;
}

fn void Ast.free(&self)
{
	self.arena.free();
	*self = {};
}

<*
 Find a top-level declaration by name. Linear, which is right for the tens of
 declarations a shader has.
*>
fn Decl* Ast.find(&self, String name)
{
	foreach (decl : self.decls)
	{
		if (decl.name == name) return decl;
	}
	return null;
}
