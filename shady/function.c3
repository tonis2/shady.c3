<*
 Function and basic-block building.

 SPIR-V requires every Function-storage OpVariable to sit at the top of a
 function's first block, before any other instruction. Callers should not have
 to care about that ordering, so locals are collected separately and spliced in
 when the function is closed.
*>
module shady;

import std::collections::list;

struct Function
{
	Module* mod;
	Id      id;
	Id      result_type;
	Id      type;
	Id      entry_label;

	WordList params;  // OpFunctionParameter, before the first label
	WordList locals;  // Function-storage OpVariable, top of the first block
	WordList body;    // everything else
	bool     closed;
}

<*
 Open a function. The entry block's OpLabel is emitted for you when the
 function is closed, so parameters can still be declared afterwards.
*>
fn Function Module.begin_function(&self, Id result_type, Id function_type, FunctionControl control = FunctionControl.NONE)
{
	Function f = {
		.mod         = self,
		.id          = self.id(),
		.result_type = result_type,
		.type        = function_type,
	};
	f.entry_label = self.id();
	f.params.init(self.allocator, 4);
	f.locals.init(self.allocator, 8);
	f.body.init(self.allocator, 64);
	return f;
}

fn Id Function.param(&self, Id type)
{
	Id result = self.mod.id();
	emit(&self.params, Opcode.FUNCTION_PARAMETER, type, result);
	return result;
}

<*
 Declare a Function-storage variable. Hoisted to the top of the entry block
 regardless of when it is called.
*>
fn Id Function.local(&self, Id pointer_type, Id initializer = NO_ID)
{
	Id result = self.mod.id();
	if (initializer != NO_ID)
	{
		emit(&self.locals, Opcode.VARIABLE, pointer_type, result, (Id)StorageClass.FUNCTION, initializer);
	}
	else
	{
		emit(&self.locals, Opcode.VARIABLE, pointer_type, result, (Id)StorageClass.FUNCTION);
	}
	return result;
}

<*
 Emit an instruction that produces a value.
*>
fn Id Function.emit(&self, Opcode opcode, Id result_type, Id... operands)
{
	Id result = self.mod.id();
	self.body.push(((uint)(3 + operands.len) << 16) | (uint)opcode);
	self.body.push(result_type);
	self.body.push(result);
	foreach (word : operands) self.body.push(word);
	return result;
}

<*
 As `emit`, for operand lists built at runtime.
*>
fn Id Function.emit_slice(&self, Opcode opcode, Id result_type, Id[] operands)
{
	Id result = self.mod.id();
	self.body.push(((uint)(3 + operands.len) << 16) | (uint)opcode);
	self.body.push(result_type);
	self.body.push(result);
	foreach (word : operands) self.body.push(word);
	return result;
}

<*
 Emit an instruction with no result id, such as OpStore or OpBranch.
*>
fn void Function.emit_void(&self, Opcode opcode, Id... operands)
{
	emit_slice(&self.body, opcode, operands);
}

// --- Blocks ------------------------------------------------------------------

<*
 Reserve a label id without opening the block yet, so forward branches can name
 their target.
*>
fn Id Function.new_label(&self) => self.mod.id();

<*
 Open a basic block. Every block must be terminated - by ret, branch,
 branch_conditional, or discard - before the next one opens.
*>
fn void Function.label(&self, Id label)
{
	emit(&self.body, Opcode.LABEL, label);
}

fn void Function.branch(&self, Id target) => emit(&self.body, Opcode.BRANCH, target);

<*
 A conditional branch. In structured control flow this must be preceded by
 selection_merge or loop_merge.
*>
fn void Function.branch_conditional(&self, Id condition, Id true_label, Id false_label)
{
	emit(&self.body, Opcode.BRANCH_CONDITIONAL, condition, true_label, false_label);
}

fn void Function.selection_merge(&self, Id merge_label, SelectionControl control = SelectionControl.NONE)
{
	emit(&self.body, Opcode.SELECTION_MERGE, merge_label, (Id)control);
}

fn void Function.loop_merge(&self, Id merge_label, Id continue_label, LoopControl control = LoopControl.NONE)
{
	emit(&self.body, Opcode.LOOP_MERGE, merge_label, continue_label, (Id)control);
}

fn void Function.ret(&self) => emit(&self.body, Opcode.RETURN);
fn void Function.ret_value(&self, Id value) => emit(&self.body, Opcode.RETURN_VALUE, value);
fn void Function.discard(&self) => emit(&self.body, Opcode.KILL);

// --- Common instructions -----------------------------------------------------

<*
 Load through a pointer.

 A non-zero `alignment` adds the `Aligned` memory operand, which every access
 through a buffer device address must carry.
*>
fn Id Function.load(&self, Id type, Id pointer, uint alignment = 0)
{
	if (alignment) return self.emit(Opcode.LOAD, type, pointer, (Id)MemoryAccess.ALIGNED, alignment);
	return self.emit(Opcode.LOAD, type, pointer);
}

fn void Function.store(&self, Id pointer, Id value, uint alignment = 0)
{
	if (alignment) { self.emit_void(Opcode.STORE, pointer, value, (Id)MemoryAccess.ALIGNED, alignment); return; }
	self.emit_void(Opcode.STORE, pointer, value);
}

<*
 Walk into a composite through a pointer. `indices` are ids of integer
 constants, not plain numbers - that is what SPIR-V wants.
*>
fn Id Function.access_chain(&self, Id pointer_type, Id base, Id[] indices)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 1 + indices.len);
		operands[0] = base;
		if (indices.len) operands[1..] = indices[..];
		return self.emit_slice(Opcode.ACCESS_CHAIN, pointer_type, operands);
	};
}

fn Id Function.composite_construct(&self, Id type, Id[] components)
{
	return self.emit_slice(Opcode.COMPOSITE_CONSTRUCT, type, components);
}

<*
 Extract from a value (not a pointer). `indices` are literal numbers here, not
 constant ids - OpCompositeExtract differs from OpAccessChain in that respect.
*>
fn Id Function.composite_extract(&self, Id type, Id composite, uint... indices)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 1 + indices.len);
		operands[0] = composite;
		foreach (i, index : indices) operands[1 + i] = index;
		return self.emit_slice(Opcode.COMPOSITE_EXTRACT, type, operands);
	};
}

<*
 Write a value into a composite: `insert(v, x, i)` is `v` with component `i`
 replaced. The inverse of `composite_extract`, and the only way SPIR-V has to
 write into a vector.
*>
fn Id Function.composite_insert(&self, Id type, Id composite, Id object, uint... indices)
{
	@pool() {
		// Object first, composite second: that is the order the instruction
		// takes them in, unlike `composite_extract`.
		Id[] operands = alloc::alloc_array(tmem, Id, 2 + indices.len);
		operands[0] = object;
		operands[1] = composite;
		foreach (i, index : indices) operands[2 + i] = index;
		return self.emit_slice(Opcode.COMPOSITE_INSERT, type, operands);
	};
}

<*
 Build a vector by picking components out of one or two vectors. Component
 indices run across `a` then `b`.
*>
fn Id Function.vector_shuffle(&self, Id type, Id a, Id b, uint... components)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 2 + components.len);
		operands[0] = a;
		operands[1] = b;
		foreach (i, component : components) operands[2 + i] = component;
		return self.emit_slice(Opcode.VECTOR_SHUFFLE, type, operands);
	};
}

fn Id Function.binop(&self, Opcode opcode, Id type, Id left, Id right)
{
	return self.emit(opcode, type, left, right);
}

fn Id Function.unop(&self, Opcode opcode, Id type, Id operand) => self.emit(opcode, type, operand);

<*
 Call a function. `function` is the id of an OpFunction, which is emitted
 before this by Codegen.emit_function.
*>
fn Id Function.call(&self, Id result_type, Id function, Id[] args)
{
	@pool() {
		Id[] operands = alloc::alloc_array(tmem, Id, 1 + args.len);
		operands[0] = function;
		if (args.len) operands[1..] = args[..];
		return self.emit_slice(Opcode.FUNCTION_CALL, result_type, operands);
	};
}

// --- Texturing ---------------------------------------------------------------

<*
 Pair a loaded image with a loaded sampler. Kongruent keeps them separate too,
 which is why the host binds SAMPLED_IMAGE and SAMPLER rather than a combined
 image sampler.
*>
fn Id Function.sampled_image(&self, Id sampled_image_type, Id image, Id sampler)
{
	return self.emit(Opcode.SAMPLED_IMAGE, sampled_image_type, image, sampler);
}

<*
 Sample with an implicit LOD. Only legal in a fragment shader - other stages
 have no derivatives, and the validator will say so.
*>
fn Id Function.image_sample(&self, Id result_type, Id sampled_image, Id coordinate)
{
	return self.emit(Opcode.IMAGE_SAMPLE_IMPLICIT_LOD, result_type, sampled_image, coordinate);
}

fn Id Function.image_sample_lod(&self, Id result_type, Id sampled_image, Id coordinate, Id lod)
{
	// 2 = the Lod image operand bit.
	return self.emit(Opcode.IMAGE_SAMPLE_EXPLICIT_LOD, result_type, sampled_image, coordinate, 2, lod);
}

// --- Closing -----------------------------------------------------------------

<*
 Finish the function and append it to the module.

 Assembles it in the order SPIR-V demands: OpFunction, parameters, the entry
 OpLabel, hoisted locals, then the body.
*>
fn void Function.end(&self)
{
	if (self.closed) return;
	self.closed = true;

	WordList* out = &self.mod.functions;

	emit(out, Opcode.FUNCTION, self.result_type, self.id, (Id)FunctionControl.NONE, self.type);
	out.push_all(self.params.array_view());
	emit(out, Opcode.LABEL, self.entry_label);
	out.push_all(self.locals.array_view());
	out.push_all(self.body.array_view());
	emit(out, Opcode.FUNCTION_END);

	self.params.free();
	self.locals.free();
	self.body.free();
}
