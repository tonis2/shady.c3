<*
 Storage images: textures a shader writes as well as reads (LANGUAGE.md
 section 12).

 `image2d<rgba8>` names the image's texel format, and the format decides the
 texel type - `rgba8` reads and writes float4, `r32ui` a uint. That is the one
 place the two can be made to agree: SPIR-V requires the image's sampled type
 to match its format, and no validator checks it. `image2d<float4>` leaves the
 format to the host instead, which costs a capability for each direction the
 shader uses it in.

 A texel has an integer address and no sampler, so there is no filtering, no
 wrapping and no level: `load`, `store`, `size`, and indexing - `img[at]` reads,
 `img[at] = v` writes, and `InterlockedAdd(img[at], 1u)` adds atomically.

 The instructions always move four components. Vulkan requires a read to
 return four (VUID-StandaloneSpirv-Result-04780) and a write to carry at least
 as many as the bound view has (VUID-vkCmdDraw-OpImageWrite-04469), so a
 narrower texel is cut down after the read and padded before the write.
*>
module shady;

<*
 A storage-image format under its GLSL name, with the texel type it reads and
 writes as.
*>
struct StorageFormat
{
	String      name;
	ImageFormat format;
	String      texel;
	// Outside the thirteen formats every device stores: needs
	// StorageImageExtendedFormats, and `shaderStorageImageExtendedFormats`.
	bool        extended;
}

const StorageFormat[*] STORAGE_FORMATS @local = {
	{ "rgba32f",        ImageFormat.RGBA32F,        "float4", false },
	{ "rgba16f",        ImageFormat.RGBA16F,        "float4", false },
	{ "r32f",           ImageFormat.R32F,           "float",  false },
	{ "rgba8",          ImageFormat.RGBA8,          "float4", false },
	{ "rgba8_snorm",    ImageFormat.RGBA8_SNORM,    "float4", false },
	{ "rg32f",          ImageFormat.RG32F,          "float2", true },
	{ "rg16f",          ImageFormat.RG16F,          "float2", true },
	{ "r11f_g11f_b10f", ImageFormat.R11F_G11F_B10F, "float3", true },
	{ "r16f",           ImageFormat.R16F,           "float",  true },
	{ "rgba16",         ImageFormat.RGBA16,         "float4", true },
	{ "rgb10_a2",       ImageFormat.RGB10_A2,       "float4", true },
	{ "rg16",           ImageFormat.RG16,           "float2", true },
	{ "rg8",            ImageFormat.RG8,            "float2", true },
	{ "r16",            ImageFormat.R16,            "float",  true },
	{ "r8",             ImageFormat.R8,             "float",  true },
	{ "rgba16_snorm",   ImageFormat.RGBA16_SNORM,   "float4", true },
	{ "rg16_snorm",     ImageFormat.RG16_SNORM,     "float2", true },
	{ "rg8_snorm",      ImageFormat.RG8_SNORM,      "float2", true },
	{ "r16_snorm",      ImageFormat.R16_SNORM,      "float",  true },
	{ "r8_snorm",       ImageFormat.R8_SNORM,       "float",  true },
	{ "rgba32i",        ImageFormat.RGBA32I,        "int4",   false },
	{ "rgba16i",        ImageFormat.RGBA16I,        "int4",   false },
	{ "rgba8i",         ImageFormat.RGBA8I,         "int4",   false },
	{ "r32i",           ImageFormat.R32I,           "int",    false },
	{ "rg32i",          ImageFormat.RG32I,          "int2",   true },
	{ "rg16i",          ImageFormat.RG16I,          "int2",   true },
	{ "rg8i",           ImageFormat.RG8I,           "int2",   true },
	{ "r16i",           ImageFormat.R16I,           "int",    true },
	{ "r8i",            ImageFormat.R8I,            "int",    true },
	{ "rgba32ui",       ImageFormat.RGBA32UI,       "uint4",  false },
	{ "rgba16ui",       ImageFormat.RGBA16UI,       "uint4",  false },
	{ "rgba8ui",        ImageFormat.RGBA8UI,        "uint4",  false },
	{ "r32ui",          ImageFormat.R32UI,          "uint",   false },
	{ "rgb10_a2ui",     ImageFormat.RGB10_A2UI,     "uint4",  true },
	{ "rg32ui",         ImageFormat.RG32UI,         "uint2",  true },
	{ "rg16ui",         ImageFormat.RG16UI,         "uint2",  true },
	{ "rg8ui",          ImageFormat.RG8UI,          "uint2",  true },
	{ "r16ui",          ImageFormat.R16UI,          "uint",   true },
	{ "r8ui",           ImageFormat.R8UI,           "uint",   true },
};

<*
 The shape a storage-image family name stands for. False for anything else.
*>
fn bool storage_image_shape(String name, Dim* dim, uint* arrayed)
{
	*arrayed = 0;
	switch (name)
	{
		case "image1d":         *dim = Dim.D1;
		case "image2d":         *dim = Dim.D2;
		case "image3d":         *dim = Dim.D3;
		case "imagecube":       *dim = Dim.CUBE;
		case "image2d_array":   *dim = Dim.D2;   *arrayed = 1;
		case "imagecube_array": *dim = Dim.CUBE; *arrayed = 1;
		default:                return false;
	}
	return true;
}

fn bool is_storage_image_family(String name)
{
	Dim  dim;
	uint arrayed;
	return storage_image_shape(name, &dim, &arrayed);
}

fn bool storage_format(String name, StorageFormat* out)
{
	foreach (format : STORAGE_FORMATS)
	{
		if (format.name != name) continue;
		*out = format;
		return true;
	}
	return false;
}

fn bool storage_format_extended(ImageFormat format)
{
	foreach (entry : STORAGE_FORMATS) if (entry.format == format) return entry.extended;
	return false;
}

<*
 The family a storage image of this shape is spelled with, and the texture
 family that samples the same image: `image2d_array` and `texture2d_array`.
*>
fn String storage_family_name(Dim dim, uint arrayed, bool texture = false)
{
	String base;
	switch (dim)
	{
		case Dim.D1: base = texture ? "texture1d" : "image1d";
		case Dim.D2: base = texture ? "texture2d" : "image2d";
		case Dim.D3: base = texture ? "texture3d" : "image3d";
		default:     base = texture ? "texturecube" : "imagecube";
	}
	if (!arrayed) return base;
	return texture
		? (dim == Dim.CUBE ? "texturecube_array" : "texture2d_array")
		: (dim == Dim.CUBE ? "imagecube_array" : "image2d_array");
}

// --- Types -------------------------------------------------------------------

<*
 `image2d<rgba8>` resolved: a format name first, then a texel type for an image
 whose format the host picks.
*>
fn Type*? Codegen.resolve_storage_image(&self, TypeRef ref, uint line, uint column)
{
	Dim  dim;
	uint arrayed;
	storage_image_shape(ref.name, &dim, &arrayed);
	String name = string::format(self.allocator, "%s<%s>", ref.name, ref.image_argument);

	StorageFormat format;
	if (storage_format(ref.image_argument, &format))
	{
		return self.types.storage_image_of(name, dim, arrayed, format.format, self.types.find(format.texel));
	}

	Type* texel = self.types.find(ref.image_argument);
	if (!texel)
	{
		// `rgb8` and its kin: Vulkan stores no three-channel format but the
		// packed float one, so the four-channel spelling is what was meant.
		String argument = ref.image_argument;
		StorageFormat wider;
		if (argument.starts_with("rgb") && !argument.starts_with("rgba")
			&& storage_format(string::format(self.allocator, "rgba%s", argument[3..]), &wider))
		{
			self.fail(line, column, string::format(self.allocator,
				"`%s` is not a storage-image format - Vulkan stores no three-channel format but `r11f_g11f_b10f`; write `%s`",
				argument, wider.name));
			return CODEGEN_ERROR~;
		}
		self.fail(line, column, string::format(self.allocator,
			"`%s` is not a storage-image format - write one such as `rgba8`, `rgba16f`, `r32f` or `r32ui`, or a texel type such as `float4` to let the host pick the format",
			argument));
		return CODEGEN_ERROR~;
	}

	Type* scalar = texel.scalar();
	bool  shaped = texel.is_scalar() || texel.kind == VECTOR;
	bool  numeric = scalar.kind == FLOAT || scalar.kind == INT || scalar.kind == UINT;
	if (!shaped || !numeric || scalar.width() != 32)
	{
		self.fail(line, column, string::format(self.allocator,
			"a storage image's texels are 32-bit: a float, int or uint, or a vector of one - not a %s", texel.name));
		return CODEGEN_ERROR~;
	}
	return self.types.storage_image_of(name, dim, arrayed, ImageFormat.UNKNOWN, texel);
}

<*
 The OpTypeImage behind a storage image, with the capabilities its shape and
 its format need. Neither the 1D nor the cube-array one is implied by Shader,
 and the cube array's is checked where the image is read or written.
*>
fn Id Codegen.storage_image_type_id(&self, Type* type)
{
	if (type.dim == Dim.D1) self.mod.capability(Capability.IMAGE_1D);
	if (type.dim == Dim.CUBE && type.arrayed) self.mod.capability(Capability.IMAGE_CUBE_ARRAY);
	if (storage_format_extended(type.format)) self.mod.capability(Capability.STORAGE_IMAGE_EXTENDED_FORMATS);
	return self.mod.type_image(self.type_id(type.element.scalar()), type.dim, 0, type.arrayed, 0,
		SampledImage.STORAGE, type.format);
}

// --- Methods -----------------------------------------------------------------

<*
 `img.method(...)` on a storage image: `load`, `store` and `size`. The sampling
 family is refused by name - an image is sampled through a texture bound to
 the same memory, not through this descriptor.
*>
fn Value? Codegen.storage_image_method(&self, Expr* expr, Value image, String written)
{
	Expr*[] args  = expr.call.args;
	Expr*   owner = expr.call.callee.member.value;
	Type*   type  = image.type;

	switch (written)
	{
		case "load":
		case "Load":
			if (args.len != 1)
			{
				self.fail(expr.line, expr.column, string::format(self.allocator,
					"`%s` takes one argument, the texel address - a storage image has one level and no sampler", written));
				return CODEGEN_ERROR~;
			}
			Id address = self.texel_address(args[0], type, written)!;
			self.note_image_access(owner, true, false);
			return self.texel_read(image, address);

		case "store":
			if (args.len != 2)
			{
				self.fail(expr.line, expr.column, "`store` takes the texel address and the texel");
				return CODEGEN_ERROR~;
			}
			Id    address = self.texel_address(args[0], type, written)!;
			Value texel   = self.expression(args[1])!;
			self.texel_write(image, address, texel, args[1])!;
			self.note_image_access(owner, false, true);
			return self.void_value();

		case "size":
			if (args.len)
			{
				self.fail(expr.line, expr.column, "`size` on a storage image takes no arguments - it is bound as one level");
				return CODEGEN_ERROR~;
			}
			uint  count  = type.size_components();
			Type* int_t  = self.types.find("int");
			Type* result = count == 1 ? int_t : self.vector_of(int_t, count);
			self.mod.capability(Capability.IMAGE_QUERY);
			Id id = self.func.emit(Opcode.IMAGE_QUERY_SIZE, self.type_id(result), self.load_descriptor(image));
			return { .type = result, .id = id };

		case "levels":
			self.fail(expr.line, expr.column, "a storage image is bound as one mip level, so it has no `levels()`");
			return CODEGEN_ERROR~;

		case "GetDimensions":
			self.fail(expr.line, expr.column, "`GetDimensions` is spelled `size()`, which returns the extent");
			return CODEGEN_ERROR~;

		default:
			if (texture_method_name(written) != "")
			{
				self.fail(expr.line, expr.column, string::format(self.allocator,
					"%s is a storage image and cannot be sampled - bind the image as a `%s` to sample it",
					type.a_name(self.allocator), storage_family_name(type.dim, type.arrayed, texture: true)));
				return CODEGEN_ERROR~;
			}
			self.fail(expr.line, expr.column, string::format(self.allocator,
				"%s has no method `%s` - it has `load`, `store` and `size`", type.a_name(self.allocator), written));
			return CODEGEN_ERROR~;
	}
}

<*
 A texel address: an int or a uint, or a vector of either, one number per
 dimension plus the layer. `written` is the method, or empty for an index.
*>
fn Id? Codegen.texel_address(&self, Expr* arg, Type* image, String written)
{
	uint  width   = image.texel_address_components();
	Value address = self.expression(arg)!;
	Type* scalar  = address.type.scalar();
	bool  integer = (scalar.kind == INT || scalar.kind == UINT) && scalar.width() == 32
		&& (address.type.kind == VECTOR || address.type.is_scalar());
	if (integer && address.type.components() == width) return self.rvalue(address);

	String expected = width == 1 ? "an int or a uint" : string::format(self.allocator, "an int%d or a uint%d", width, width);
	String subject  = written == ""
		? string::format(self.allocator, "%s is indexed by", image.a_name(self.allocator))
		: string::format(self.allocator, "`%s` on %s takes", written, image.a_name(self.allocator));

	String hint = "";
	if (scalar.kind == FLOAT)
	{
		hint = " - a storage image is addressed by texel, not by uv";
	}
	else if (image.dim == Dim.CUBE)
	{
		hint = image.arrayed ? " - (x, y, layer * 6 + face)" : " - (x, y, face)";
	}
	else if (image.arrayed)
	{
		hint = " - the last component is the array layer";
	}
	self.fail(arg.line, arg.column, string::format(self.allocator,
		"%s %s texel address, got %s%s", subject, expected, address.type.a_name(self.allocator), hint));
	return CODEGEN_ERROR~;
}

<*
 Read one texel: four components, as Vulkan requires, cut down to the image's
 texel type. A format the host picks is one the device has to read without
 knowing it, which is a capability of its own.
*>
fn Value Codegen.texel_read(&self, Value image, Id address)
{
	Type* texel  = image.type.element;
	Type* scalar = texel.scalar();
	if (image.type.format == ImageFormat.UNKNOWN) self.mod.capability(Capability.STORAGE_IMAGE_READ_WITHOUT_FORMAT);

	Id read = self.func.emit(Opcode.IMAGE_READ, self.type_id(self.vector_of(scalar, 4)), self.load_descriptor(image), address);
	Id id;
	switch (texel.components())
	{
		case 4:  id = read;
		case 1:  id = self.func.composite_extract(self.type_id(scalar), read, 0);
		case 2:  id = self.func.vector_shuffle(self.type_id(texel), read, read, 0, 1);
		default: id = self.func.vector_shuffle(self.type_id(texel), read, read, 0, 1, 2);
	}
	return { .type = texel, .id = id, .texel = true };
}

<*
 Write one texel, given as the image's texel type and padded to four
 components: zero for a missing colour, one for a missing alpha - what a read
 of a format without them answers. Returns the texel as written, before the
 padding, which is the value of an assignment.
*>
fn Id? Codegen.texel_write(&self, Value image, Id address, Value value, Expr* expr)
{
	Type* texel  = image.type.element;
	Type* scalar = texel.scalar();
	Type* wide   = self.vector_of(scalar, 4);
	Id    id     = self.coerce(value, texel, expr)!;
	if (image.type.format == ImageFormat.UNKNOWN) self.mod.capability(Capability.STORAGE_IMAGE_WRITE_WITHOUT_FORMAT);

	Id zero;
	Id one;
	switch (scalar.kind)
	{
		case FLOAT:
			zero = self.const_float(0.0);
			one  = self.const_float(1.0);
		case INT:
			zero = self.const_int(0);
			one  = self.const_int(1);
		default:
			zero = self.mod.const_u32(self.type_id(scalar), 0);
			one  = self.mod.const_u32(self.type_id(scalar), 1);
	}

	Id texel4;
	switch (texel.components())
	{
		case 4:
			texel4 = id;
		case 1:
			texel4 = self.func.composite_construct(self.type_id(wide), (Id[]) { id, zero, zero, one });
		default:
			// The texel's own components, then the padding's from a constant
			// (0, 0, 0, 1): its z and w for a pair, its w for a triple.
			Id padding = self.mod.const_composite(self.type_id(wide), (Id[]) { zero, zero, zero, one });
			uint n = texel.components();
			texel4 = n == 2
				? self.func.vector_shuffle(self.type_id(wide), id, padding, 0, 1, n + 2, n + 3)
				: self.func.vector_shuffle(self.type_id(wide), id, padding, 0, 1, 2, n + 3);
	}

	self.func.emit_void(Opcode.IMAGE_WRITE, self.load_descriptor(image), address, texel4);
	return id;
}

// --- Indexing ----------------------------------------------------------------

<*
 `img[at]` read as a value.
*>
fn Value? Codegen.texel_index_read(&self, Value image, Expr* expr)
{
	Id address = self.texel_address(expr.index.index, image.type, "")!;
	self.note_image_access(expr.index.value, true, false);
	return self.texel_read(image, address);
}

<*
 `img[at] = v` and `img[at] op= v`. A compound assignment reads the texel,
 combines and writes it back - two instructions another invocation can come
 between, as with any other memory; `InterlockedAdd` is the atomic one.
*>
fn Value? Codegen.texel_assign(&self, Expr* expr, Value image)
{
	Expr* target  = expr.assign.target;
	Type* texel   = image.type.element;
	Id    address = self.texel_address(target.index.index, image.type, "")!;
	Value value   = self.expression(expr.assign.value)!;

	bool compound = expr.assign.op != EQ;
	if (compound)
	{
		Value current = self.texel_read(image, address);
		value = self.adapt_literal(value, expr.assign.value, texel);
		value = { .type = texel, .id = self.arithmetic(compound_op(expr.assign.op), current, value, expr)! };
	}

	Id id = self.texel_write(image, address, value, expr)!;
	self.note_image_access(target.index.value, compound, true);
	return { .type = texel, .id = id };
}

<*
 `InterlockedAdd(img[at], value)`: the texel's address, then the same add a
 buffer gets. Vulkan's image atomics are on one 32-bit channel of a known
 format (VUID-StandaloneSpirv-OpImageTexelPointer-04658), and the language's
 `InterlockedAdd` is on uints, so the image is an `r32ui` one.
*>
fn Value? Codegen.texel_atomic_add(&self, Expr* expr, Value image, Value value)
{
	Expr* dest = expr.call.args[0];
	if (image.type.format != ImageFormat.R32UI)
	{
		self.fail(dest.line, dest.column, string::format(self.allocator,
			"`InterlockedAdd` on an image needs the `r32ui` format - Vulkan's image atomics are on one 32-bit channel - and this is %s",
			image.type.a_name(self.allocator)));
		return CODEGEN_ERROR~;
	}
	Id address = self.texel_address(dest.index.index, image.type, "InterlockedAdd")!;

	Type* uint_t = self.types.find("uint");
	value = self.adapt_literal(value, expr.call.args[1], uint_t);
	if (value.type.kind != UINT)
	{
		self.fail(expr.line, expr.column, "`InterlockedAdd` works on 32-bit uints");
		return CODEGEN_ERROR~;
	}

	Id pointer = self.func.emit(Opcode.IMAGE_TEXEL_POINTER, self.mod.type_pointer(StorageClass.IMAGE, self.type_id(uint_t)),
		image.pointer, address, self.mod.const_u32(self.type_id(uint_t), 0));
	if (image.non_uniform) self.mod.decorate(pointer, Decoration.NON_UNIFORM);

	Id scope     = self.mod.const_u32(self.type_id(uint_t), 1); // Device
	Id semantics = self.mod.const_u32(self.type_id(uint_t), 0); // Relaxed
	Id result    = self.func.emit(Opcode.ATOMIC_I_ADD, self.type_id(uint_t), pointer, scope, semantics, self.rvalue(value));
	self.note_image_access(dest.index.value, true, true);
	return { .type = uint_t, .id = result };
}

// --- Access ------------------------------------------------------------------

<*
 Record that the storage image `expr` names - `img`, or `imgs[i]` - is read or
 written. The module's whole use decides its NonReadable and NonWritable
 decorations, see `decorate_image_access`.
*>
fn void Codegen.note_image_access(&self, Expr* expr, bool reads, bool writes)
{
	while (expr.kind == INDEX) expr = expr.index.value;
	if (expr.kind != IDENT || self.find_local(expr.ident.name)) return;
	Resource* resource = self.find_resource(expr.ident.name);
	if (!resource) return;
	if (reads)  resource.reads  = true;
	if (writes) resource.writes = true;
}

<*
 GLSL's `writeonly` and `readonly`, without writing them: a storage image the
 module never reads is NonReadable, one it never writes NonWritable. A driver
 may skip work for either - a read-back it would otherwise keep coherent, a
 compression it would otherwise undo.
*>
fn void Codegen.decorate_image_access(&self)
{
	foreach (&resource : self.resources)
	{
		Type* type = resource.type.kind == ARRAY ? resource.type.element : resource.type;
		if (type.kind != STORAGE_IMAGE) continue;
		if (!resource.reads)  self.mod.decorate(resource.id, Decoration.NON_READABLE);
		if (!resource.writes) self.mod.decorate(resource.id, Decoration.NON_WRITABLE);
	}
}
