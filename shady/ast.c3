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
fn Attribute* find_attribute(Attribute[] attributes, String name)
{
	foreach (&attribute : attributes)
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
}

enum DeclKind : char
{
	STRUCT,
	FUNCTION,
	RESOURCE, // uniform blocks, textures, samplers
	CONSTANT,
}

<*
 `is_buffer` marks a `buffer` declaration: a struct laid out std430 that is
 only ever reached through a device address.
*>
struct DeclStruct
{
	Member[] members;
	bool     is_buffer;
}

struct DeclFunction
{
	TypeRef return_type;
	Param[] params;
	Stmt*   body;
}

<*
 `is_uniform` distinguishes `uniform T name;` from `texture2d name;`, and
 `is_push_constant` marks `push_constant T name;` - a block with no descriptor
 binding at all.
*>
struct DeclResource
{
	TypeRef type;
	bool    is_uniform;
	bool    is_push_constant;
}

struct DeclConstant
{
	TypeRef type;
	Expr*   value;
}

struct Decl
{
	DeclKind    kind;
	String      name;
	Attribute[] attributes;
	uint        line;
	uint        column;

	union
	{
		DeclStruct   struct_decl;
		DeclFunction function;
		DeclResource resource;
		DeclConstant constant;
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
