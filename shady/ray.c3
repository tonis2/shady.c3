<*
 Ray tracing: inline ray queries, the HLSL-named ray constants, and the calls of
 the ray-tracing pipeline stages.

 A ray query is a local the shader drives itself, from any stage: `init` aims
 it, `proceed` steps the traversal, and the `candidate_*` and `committed_*`
 getters read what it found. Every instruction takes the query by pointer, so a
 `RayQuery` is never loaded - it is the variable's address that is passed on,
 to the instructions and to an `inout` parameter.
*>
module shady;

import std::collections::list;

<*
 A getter that reads one intersection: the candidate traversal is looking at,
 or the closest one committed so far. Written once and spelled twice, as
 `candidate_<name>` and `committed_<name>`.
*>
struct RayQueryGetter @local
{
	String name;
	Opcode opcode;
	String result;
}

const RayQueryGetter[*] RAY_QUERY_GETTERS @local = {
	{ "type",                  Opcode.RAY_QUERY_GET_INTERSECTION_TYPE_KHR,                      "uint" },
	{ "t",                     Opcode.RAY_QUERY_GET_INTERSECTION_T_KHR,                         "float" },
	{ "instance_custom_index", Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_CUSTOM_INDEX_KHR,     "uint" },
	{ "instance_id",           Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_ID_KHR,               "uint" },
	{ "sbt_offset",            Opcode.RAY_QUERY_GET_INTERSECTION_INSTANCE_SBT_RECORD_OFFSET_KHR, "uint" },
	{ "geometry_index",        Opcode.RAY_QUERY_GET_INTERSECTION_GEOMETRY_INDEX_KHR,            "uint" },
	{ "primitive_index",       Opcode.RAY_QUERY_GET_INTERSECTION_PRIMITIVE_INDEX_KHR,           "uint" },
	{ "barycentrics",          Opcode.RAY_QUERY_GET_INTERSECTION_BARYCENTRICS_KHR,              "float2" },
	{ "front_face",            Opcode.RAY_QUERY_GET_INTERSECTION_FRONT_FACE_KHR,                "bool" },
	{ "object_ray_origin",     Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_RAY_ORIGIN_KHR,         "float3" },
	{ "object_ray_direction",  Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_RAY_DIRECTION_KHR,      "float3" },
	// Four columns of float3: the 3x4 affine transform of the instance.
	{ "object_to_world",       Opcode.RAY_QUERY_GET_INTERSECTION_OBJECT_TO_WORLD_KHR,           "float4x3" },
	{ "world_to_object",       Opcode.RAY_QUERY_GET_INTERSECTION_WORLD_TO_OBJECT_KHR,           "float4x3" },
};

<*
 A getter about the ray itself rather than an intersection: no operand but the
 query.
*>
const RayQueryGetter[*] RAY_GETTERS @local = {
	{ "ray_flags",             Opcode.RAY_QUERY_GET_RAY_FLAGS_KHR,                            "uint" },
	{ "ray_tmin",              Opcode.RAY_QUERY_GET_RAY_T_MIN_KHR,                            "float" },
	{ "world_ray_origin",      Opcode.RAY_QUERY_GET_WORLD_RAY_ORIGIN_KHR,                     "float3" },
	{ "world_ray_direction",   Opcode.RAY_QUERY_GET_WORLD_RAY_DIRECTION_KHR,                  "float3" },
	// Asked of the candidate alone: whether the AABB being visited is opaque.
	{ "candidate_aabb_opaque", Opcode.RAY_QUERY_GET_INTERSECTION_CANDIDATE_AABB_OPAQUE_KHR,   "bool" },
};

<*
 The constants a ray is traced with and read back by, under HLSL's names: the
 flags, the intersection types the getters answer with, and the hit kinds a
 triangle reports. Resolved after every name the shader declares, so a
 shader's own `RAY_FLAG_NONE` is its own.

 `culls` is set for the two flags that skip whole kinds of geometry, which need
 a capability of their own.
*>
fn bool ray_constant(String name, uint* value, bool* culls)
{
	*culls = false;
	switch (name)
	{
		case "RAY_FLAG_NONE":                            *value = (uint)RayFlags.NONE;
		case "RAY_FLAG_FORCE_OPAQUE":                    *value = (uint)RayFlags.OPAQUE;
		case "RAY_FLAG_FORCE_NON_OPAQUE":                *value = (uint)RayFlags.NO_OPAQUE;
		case "RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH": *value = (uint)RayFlags.TERMINATE_ON_FIRST_HIT;
		case "RAY_FLAG_SKIP_CLOSEST_HIT_SHADER":         *value = (uint)RayFlags.SKIP_CLOSEST_HIT_SHADER;
		case "RAY_FLAG_CULL_BACK_FACING_TRIANGLES":      *value = (uint)RayFlags.CULL_BACK_FACING;
		case "RAY_FLAG_CULL_FRONT_FACING_TRIANGLES":     *value = (uint)RayFlags.CULL_FRONT_FACING;
		case "RAY_FLAG_CULL_OPAQUE":                     *value = (uint)RayFlags.CULL_OPAQUE;
		case "RAY_FLAG_CULL_NON_OPAQUE":                 *value = (uint)RayFlags.CULL_NO_OPAQUE;
		case "RAY_FLAG_SKIP_TRIANGLES":
			*value = (uint)RayFlags.SKIP_TRIANGLES;
			*culls = true;
		case "RAY_FLAG_SKIP_PROCEDURAL_PRIMITIVES":
			*value = (uint)RayFlags.SKIP_AABBS;
			*culls = true;
		case "COMMITTED_NOTHING":                        *value = 0;
		case "COMMITTED_TRIANGLE_HIT":                   *value = 1;
		case "COMMITTED_PROCEDURAL_PRIMITIVE_HIT":       *value = 2;
		case "CANDIDATE_NON_OPAQUE_TRIANGLE":            *value = 0;
		case "CANDIDATE_PROCEDURAL_PRIMITIVE":           *value = 1;
		case "HIT_KIND_TRIANGLE_FRONT_FACE":             *value = 0xFE;
		case "HIT_KIND_TRIANGLE_BACK_FACE":              *value = 0xFF;
		default: return false;
	}
	return true;
}

fn Value Codegen.void_value(&self) => { .type = self.types.find("void"), .id = NO_ID };

<*
 `count` arguments, or a message naming the method and how many it takes.
*>
fn void? Codegen.ray_arguments(&self, Expr* expr, String written, usz count)
{
	if (expr.call.args.len == count) return;
	self.fail(expr.line, expr.column, count == 0
		? string::format(self.allocator, "`%s` takes no arguments", written)
		: string::format(self.allocator, "`%s` takes %d argument%s", written, count, count == 1 ? "" : "s"));
	return CODEGEN_ERROR~;
}

<*
 An argument converted to `type_name` the way any argument is: an integer
 literal or an int becomes a uint, an int a float, a scalar a vector.
*>
fn Id? Codegen.ray_operand(&self, Expr* arg, String type_name)
{
	Value value = self.expression(arg)!;
	return self.coerce(value, self.types.find(type_name), arg);
}

<*
 The acceleration structure a ray is traced against, loaded from its variable
 or its slot in a descriptor array.
*>
fn Id? Codegen.ray_scene(&self, Expr* arg, String written)
{
	Value scene = self.expression(arg)!;
	if (scene.type.kind != ACCEL || scene.pointer == NO_ID)
	{
		self.fail(arg.line, arg.column, string::format(self.allocator,
			"`%s` traces against an `accel`, not a %s", written, scene.type.name));
		return CODEGEN_ERROR~;
	}
	return self.load_descriptor(scene);
}

<*
 `query.method(...)` on a `RayQuery`.
*>
fn Value? Codegen.ray_query_method(&self, Expr* expr, Value query, String name)
{
	Expr*[] args = expr.call.args;
	String written = name;

	switch (name)
	{
		case "init":
			// Aim the query: the scene, the flags, which instances the cull
			// mask lets through, then the ray as origin, near distance,
			// direction and far distance - the order HLSL's RayDesc has.
			self.ray_arguments(expr, written, 7)!;
			Id scene     = self.ray_scene(args[0], written)!;
			Id flags     = self.ray_operand(args[1], "uint")!;
			Id cull_mask = self.ray_operand(args[2], "uint")!;
			Id origin    = self.ray_operand(args[3], "float3")!;
			Id tmin      = self.ray_operand(args[4], "float")!;
			Id direction = self.ray_operand(args[5], "float3")!;
			Id tmax      = self.ray_operand(args[6], "float")!;
			self.func.emit_void(Opcode.RAY_QUERY_INITIALIZE_KHR,
				query.pointer, scene, flags, cull_mask, origin, tmin, direction, tmax);
			return self.void_value();

		case "proceed":
			self.ray_arguments(expr, written, 0)!;
			Type* bool_t = self.types.find("bool");
			return { .type = bool_t, .id = self.func.emit(Opcode.RAY_QUERY_PROCEED_KHR, self.type_id(bool_t), query.pointer) };

		case "terminate":
			self.ray_arguments(expr, written, 0)!;
			self.func.emit_void(Opcode.RAY_QUERY_TERMINATE_KHR, query.pointer);
			return self.void_value();

		case "confirm":
			// Accept the triangle candidate being visited - an alpha test
			// that passed. Only meaningful for a triangle; an AABB is
			// accepted with `generate`.
			self.ray_arguments(expr, written, 0)!;
			self.func.emit_void(Opcode.RAY_QUERY_CONFIRM_INTERSECTION_KHR, query.pointer);
			return self.void_value();

		case "generate":
			// Accept a hit at `t` inside the AABB candidate being visited.
			self.ray_arguments(expr, written, 1)!;
			Id t = self.ray_operand(args[0], "float")!;
			self.func.emit_void(Opcode.RAY_QUERY_GENERATE_INTERSECTION_KHR, query.pointer, t);
			return self.void_value();
	}

	foreach (getter : RAY_GETTERS)
	{
		if (getter.name != name) continue;
		self.ray_arguments(expr, written, 0)!;
		Type* result = self.types.find(getter.result);
		return { .type = result, .id = self.func.emit(getter.opcode, self.type_id(result), query.pointer) };
	}

	RayQueryIntersection which;
	String rest;
	if (name.starts_with("candidate_"))
	{
		which = RayQueryIntersection.CANDIDATE;
		rest  = name["candidate_".len..];
	}
	else if (name.starts_with("committed_"))
	{
		which = RayQueryIntersection.COMMITTED;
		rest  = name["committed_".len..];
	}
	if (rest.len)
	{
		foreach (getter : RAY_QUERY_GETTERS)
		{
			if (getter.name != rest) continue;
			self.ray_arguments(expr, written, 0)!;
			Type* result = self.types.find(getter.result);
			Id intersection = self.mod.const_u32(self.type_id(self.types.find("uint")), (uint)which);
			return { .type = result, .id = self.func.emit(getter.opcode, self.type_id(result), query.pointer, intersection) };
		}
	}

	self.fail(expr.line, expr.column, string::format(self.allocator, "a RayQuery has no method `%s`", name));
	return CODEGEN_ERROR~;
}

// --- The ray-tracing pipeline ------------------------------------------------

<*
 A variable the pipeline's calls pass through: the payload a ray carries, the
 data a callable shader gets, the attributes an intersection reports - and each
 one's incoming side. The shader never names one: a payload is a local the
 shader passes to `trace_ray`, and the stage's `inout` parameter, and these are
 what they are copied into and bound to.
*>
struct RayGlobal
{
	StorageClass storage;
	Type*        type;
	Id           id;
}

alias RayGlobalList = List{RayGlobal};

<*
 The variable of `storage` holding a `type`, one per pair in the module. Every
 one of these lives as long as one invocation, so two calls - or two entry
 points - with the same payload type share it safely.
*>
fn Id Codegen.ray_global(&self, StorageClass storage, Type* type)
{
	foreach (&global : self.ray_globals)
	{
		if (global.storage != storage || global.type != type) continue;
		self.use_global(global.id);
		return global.id;
	}

	String role;
	switch (storage)
	{
		case StorageClass.RAY_PAYLOAD:            role = "payload";
		case StorageClass.INCOMING_RAY_PAYLOAD:   role = "incoming_payload";
		case StorageClass.HIT_ATTRIBUTE:          role = "hit_attributes";
		case StorageClass.CALLABLE_DATA:          role = "callable_data";
		default:                                  role = "incoming_callable_data";
	}
	Id id = self.mod.global_var(self.pointer_to(storage, type), storage);
	self.mod.name(id, string::format(self.allocator, "%s.%s", role, type.name));
	self.ray_globals.push({ .storage = storage, .type = type, .id = id });
	self.use_global(id);
	return id;
}

<*
 The payload or callable data a call passes: a plain struct variable, since
 the callee's writes come back into it.
*>
fn Value? Codegen.ray_data(&self, Expr* arg, String written, String what)
{
	Value data = self.expression(arg)!;
	if (data.type.kind != STRUCT || data.type.block != NONE)
	{
		self.fail(arg.line, arg.column, string::format(self.allocator,
			"`%s` passes %s as a plain struct, not %s", written, what, data.type.a_name(self.allocator)));
		return CODEGEN_ERROR~;
	}
	bool variable = data.pointer != NO_ID && (data.storage == StorageClass.FUNCTION
		|| data.storage == StorageClass.INCOMING_RAY_PAYLOAD || data.storage == StorageClass.INCOMING_CALLABLE_DATA);
	if (!variable)
	{
		self.fail(arg.line, arg.column, string::format(self.allocator,
			"`%s` writes %s back, so it must be a variable", written, what));
		return CODEGEN_ERROR~;
	}
	return data;
}

<*
 `trace_ray(scene, flags, cull_mask, sbt_offset, sbt_stride, miss_index,
 origin, tmin, direction, tmax, payload)`: send a ray through the pipeline. The
 operands are OpTraceRayKHR's, in its order - GLSL's `traceRayEXT` too - and the
 payload is copied into the ray's payload variable and back out once the hit or
 miss shader has written it.
*>
fn Value? Codegen.trace_ray_call(&self, Expr* expr)
{
	String written = "trace_ray";
	self.ray_arguments(expr, written, 11)!;
	self.require_stages(Stage.RAYGEN.bit() | Stage.CLOSEST_HIT.bit() | Stage.MISS.bit(), expr.line, expr.column,
		"`trace_ray` starts a ray, which only a ray-generation, closest-hit or miss shader does")!;
	self.ray_tracing_capability();

	Expr*[] args = expr.call.args;
	Id scene      = self.ray_scene(args[0], written)!;
	Id flags      = self.ray_operand(args[1], "uint")!;
	Id cull_mask  = self.ray_operand(args[2], "uint")!;
	Id sbt_offset = self.ray_operand(args[3], "uint")!;
	Id sbt_stride = self.ray_operand(args[4], "uint")!;
	Id miss_index = self.ray_operand(args[5], "uint")!;
	Id origin     = self.ray_operand(args[6], "float3")!;
	Id tmin       = self.ray_operand(args[7], "float")!;
	Id direction  = self.ray_operand(args[8], "float3")!;
	Id tmax       = self.ray_operand(args[9], "float")!;
	Value payload = self.ray_data(args[10], written, "the payload")!;

	Id global = self.ray_global(StorageClass.RAY_PAYLOAD, payload.type);
	self.func.store(global, self.rvalue(payload));
	self.func.emit_void(Opcode.TRACE_RAY_KHR, scene, flags, cull_mask, sbt_offset, sbt_stride, miss_index,
		origin, tmin, direction, tmax, global);
	self.store(payload, self.func.load(self.type_id(payload.type), global));
	return self.void_value();
}

<*
 `execute_callable(index, data)`: run the callable shader at `index` in the
 shader binding table, with `data` copied in and back out.
*>
fn Value? Codegen.execute_callable_call(&self, Expr* expr)
{
	String written = "execute_callable";
	self.ray_arguments(expr, written, 2)!;
	self.require_stages(Stage.RAYGEN.bit() | Stage.CLOSEST_HIT.bit() | Stage.MISS.bit() | Stage.CALLABLE.bit(),
		expr.line, expr.column,
		"`execute_callable` is a ray-tracing call, which only a ray-generation, closest-hit, miss or callable shader makes")!;
	self.ray_tracing_capability();

	// The index must be unsigned - the one ray operand where an int is refused.
	Id    index = self.ray_operand(expr.call.args[0], "uint")!;
	Value data  = self.ray_data(expr.call.args[1], written, "the callable data")!;

	Id global = self.ray_global(StorageClass.CALLABLE_DATA, data.type);
	self.func.store(global, self.rvalue(data));
	self.func.emit_void(Opcode.EXECUTE_CALLABLE_KHR, index, global);
	self.store(data, self.func.load(self.type_id(data.type), global));
	return self.void_value();
}

<*
 `report_intersection(t, hit_kind[, attributes])`: an intersection shader found
 a hit at distance `t`. The attributes go to the hit shaders; the result says
 whether the hit was accepted - an any-hit shader may still ignore it.
*>
fn Value? Codegen.report_intersection_call(&self, Expr* expr)
{
	String written = "report_intersection";
	if (expr.call.args.len != 2 && expr.call.args.len != 3)
	{
		self.fail(expr.line, expr.column, "`report_intersection` takes a distance, a hit kind, and optionally the hit attributes");
		return CODEGEN_ERROR~;
	}
	self.require_stages(Stage.INTERSECTION.bit(), expr.line, expr.column,
		"`report_intersection` reports a hit, which only an intersection shader does")!;
	self.ray_tracing_capability();

	Id t    = self.ray_operand(expr.call.args[0], "float")!;
	Id kind = self.ray_operand(expr.call.args[1], "uint")!;

	if (expr.call.args.len == 3)
	{
		Expr* arg        = expr.call.args[2];
		Value attributes = self.expression(arg)!;
		if (attributes.type.kind != STRUCT || attributes.type.block != NONE)
		{
			self.fail(arg.line, arg.column, string::format(self.allocator,
				"the hit attributes are a plain struct, not %s", attributes.type.a_name(self.allocator)));
			return CODEGEN_ERROR~;
		}
		// An entry point has one hit-attribute variable, so everything it
		// reaches reports the same type - checked across helpers once every
		// entry point is known (`check_entry_stages`).
		Reach* reach = self.reach;
		if (reach.hit_attribute && reach.hit_attribute != attributes.type)
		{
			self.fail(arg.line, arg.column, string::format(self.allocator,
				"this reports `%s` as the hit attributes, and %s reports `%s` - an intersection shader has one hit-attribute type",
				attributes.type.name, self.where(reach.hit_line), reach.hit_attribute.name));
			return CODEGEN_ERROR~;
		}
		if (!reach.hit_attribute)
		{
			reach.hit_attribute = attributes.type;
			reach.hit_line      = arg.line;
			reach.hit_column    = arg.column;
		}
		Id global = self.ray_global(StorageClass.HIT_ATTRIBUTE, attributes.type);
		self.func.store(global, self.rvalue(attributes));
	}

	Type* bool_t = self.types.find("bool");
	return { .type = bool_t, .id = self.func.emit(Opcode.REPORT_INTERSECTION_KHR, self.type_id(bool_t), t, kind) };
}

<*
 `ignore_intersection()` and `terminate_ray()` written as a statement: an
 any-hit shader dropping the hit it is looking at, or ending the ray's whole
 traversal. Both end the shader where they stand, as `discard` does, so they
 are statements - true when `expr` was one, and handled.
*>
fn bool? Codegen.ray_terminator(&self, Expr* expr)
{
	if (expr.kind != CALL || expr.call.callee.kind != IDENT) return false;
	String name = expr.call.callee.ident.name;
	if (name != "ignore_intersection" && name != "terminate_ray") return false;
	if (self.has_function(name)) return false;

	self.ray_arguments(expr, name, 0)!;
	self.require_stages(Stage.ANY_HIT.bit(), expr.line, expr.column, string::format(self.allocator,
		"`%s` decides about a candidate hit, which only an any-hit shader does", name))!;
	self.ray_tracing_capability();
	self.func.emit_void(name == "ignore_intersection" ? Opcode.IGNORE_INTERSECTION_KHR : Opcode.TERMINATE_RAY_KHR);
	self.terminated = true;
	return true;
}
