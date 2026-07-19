package tool

// Minimal binary-glTF (.glb) reader for marker prop PREVIEWS (assets.odin).
// Reads exactly what the 3D pane needs and nothing else: every triangle
// primitive's POSITION + NORMAL + indices, concatenated into one tri-soup.
// Deliberate non-goals (a preview, not an importer): node transforms,
// materials, textures, skins, animation, sparse accessors, external .bin
// buffers — author props with the mesh at the origin (Blender's default glb
// export of a single object works as-is). Forks with a real model format
// replace glb_load and keep the Prop_Mesh contract.

import "core:encoding/json"
import "core:math/linalg"
import "core:os"

import "../engine"

Prop_Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
}

Prop_Mesh :: struct {
	verts:   [dynamic]Prop_Vertex,
	indices: [dynamic]u32,
}

prop_mesh_destroy :: proc(m: ^Prop_Mesh) {
	delete(m.verts)
	delete(m.indices)
	m^ = {}
}

GLB_MAGIC :: u32(0x46546C67) // "glTF"
@(private = "file") CHUNK_JSON :: u32(0x4E4F534A)
@(private = "file") CHUNK_BIN :: u32(0x004E4942)

glb_sniff :: proc(data: []u8) -> bool {
	return len(data) >= 12 && u32le_at(data, 0) == GLB_MAGIC
}

@(private = "file")
u32le_at :: proc(d: []u8, o: int) -> u32 {
	return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24
}

glb_load_file :: proc(path: string) -> (mesh: Prop_Mesh, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		engine.diagf(.Warn, "assets: cannot read %q: %v", path, err)
		return
	}
	return glb_load(data, path)
}

glb_load :: proc(data: []u8, note: string) -> (mesh: Prop_Mesh, ok: bool) {
	fail :: proc(mesh: ^Prop_Mesh, note, why: string) -> (Prop_Mesh, bool) {
		engine.diagf(.Warn, "assets: %s: %s", note, why)
		prop_mesh_destroy(mesh)
		return {}, false
	}
	if !glb_sniff(data) {return fail(&mesh, note, "not a .glb (bad magic)")}
	if u32le_at(data, 4) != 2 {return fail(&mesh, note, "glTF version != 2")}

	// chunk walk: JSON chunk is mandatory and first per spec; BIN optional
	jsn: []u8
	bin: []u8
	for o := 12; o + 8 <= len(data); {
		clen := int(u32le_at(data, o))
		ctype := u32le_at(data, o + 4)
		o += 8
		if o + clen > len(data) {return fail(&mesh, note, "truncated chunk")}
		switch ctype {
		case CHUNK_JSON:
			jsn = data[o:o + clen]
		case CHUNK_BIN:
			bin = data[o:o + clen]
		}
		o += clen + (4 - clen % 4) % 4 // chunks are 4-aligned; length excludes padding
	}
	if jsn == nil {return fail(&mesh, note, "no JSON chunk")}

	root_v, jerr := json.parse(jsn, allocator = context.temp_allocator)
	if jerr != nil {return fail(&mesh, note, "JSON parse failed")}
	root := jobj(root_v) or_return
	accessors := jarr(root["accessors"])
	views := jarr(root["bufferViews"])
	meshes := jarr(root["meshes"])
	if meshes == nil {return fail(&mesh, note, "no meshes")}

	for mesh_v in meshes {
		m := jobj(mesh_v) or_continue
		for prim_v in jarr(m["primitives"]) {
			prim := jobj(prim_v) or_continue
			if jint(prim["mode"], 4) != 4 {continue} // triangles only
			attrs := jobj(prim["attributes"]) or_continue

			positions := read_vec3(accessors, views, bin, attrs["POSITION"])
			if positions == nil {continue}
			normals := read_vec3(accessors, views, bin, attrs["NORMAL"])
			indices := read_scalar_u32(accessors, views, bin, prim["indices"])
			if indices == nil { // non-indexed: sequential tris
				indices = make([]u32, len(positions), context.temp_allocator)
				for i in 0 ..< len(indices) {indices[i] = u32(i)}
			}

			base := u32(len(mesh.verts))
			if normals != nil && len(normals) == len(positions) {
				for p, i in positions {
					append(&mesh.verts, Prop_Vertex{pos = p, normal = normals[i]})
				}
				for idx in indices {
					if int(idx) >= len(positions) {return fail(&mesh, note, "index out of range")}
					append(&mesh.indices, base + idx)
				}
			} else {
				// no normals: expand to soup with flat face normals
				for i := 0; i + 2 < len(indices); i += 3 {
					ia, ib, ic := int(indices[i]), int(indices[i + 1]), int(indices[i + 2])
					if ia >= len(positions) || ib >= len(positions) || ic >= len(positions) {
						return fail(&mesh, note, "index out of range")
					}
					a, b, c := positions[ia], positions[ib], positions[ic]
					n := flat_normal(a, b, c)
					v := u32(len(mesh.verts))
					append(&mesh.verts, Prop_Vertex{a, n}, Prop_Vertex{b, n}, Prop_Vertex{c, n})
					append(&mesh.indices, v, v + 1, v + 2)
				}
			}
		}
	}
	if len(mesh.indices) == 0 {return fail(&mesh, note, "no triangle data")}
	return mesh, true
}

@(private = "file")
flat_normal :: proc(a, b, c: [3]f32) -> [3]f32 {
	n := linalg.cross(b - a, c - a)
	l := linalg.length(n)
	if l < 1e-10 {return {0, 1, 0}}
	return n / l
}

// --- JSON helpers (temp-allocated tree from json.parse) -------------------------

@(private = "file")
jobj :: proc(v: json.Value) -> (m: json.Object, ok: bool) {
	m, ok = v.(json.Object)
	return
}

@(private = "file")
jarr :: proc(v: json.Value) -> json.Array {
	if a, ok := v.(json.Array); ok {return a}
	return nil
}

@(private = "file")
jint :: proc(v: json.Value, def: int) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	}
	return def
}

// accessor_slice — resolve accessor index-value -> (raw bytes at element 0,
// stride, count, componentType). Only buffer 0 (the BIN chunk), no sparse.
@(private = "file")
accessor_slice :: proc(
	accessors, views: json.Array,
	bin: []u8,
	acc_v: json.Value,
	elem_size_of_component: proc(ct: int) -> int,
	components: int,
	want_type: string,
) -> (raw: []u8, stride, count, ctype: int, ok: bool) {
	ai := jint(acc_v, -1)
	if ai < 0 || ai >= len(accessors) {return}
	acc := jobj(accessors[ai]) or_return
	if t, tok := acc["type"].(json.String); !tok || string(t) != want_type {return}
	if _, sparse := acc["sparse"]; sparse {return}
	ctype = jint(acc["componentType"], 0)
	csize := elem_size_of_component(ctype)
	if csize == 0 {return}
	count = jint(acc["count"], 0)
	vi := jint(acc["bufferView"], -1)
	if count <= 0 || vi < 0 || vi >= len(views) {return}
	view := jobj(views[vi]) or_return
	if jint(view["buffer"], 0) != 0 {return}
	elem := csize * components
	stride = jint(view["byteStride"], elem)
	if stride < elem {stride = elem}
	off := jint(view["byteOffset"], 0) + jint(acc["byteOffset"], 0)
	need := off + stride * (count - 1) + elem
	if bin == nil || need > len(bin) {return}
	return bin[off:], stride, count, ctype, true
}

@(private = "file")
read_vec3 :: proc(accessors, views: json.Array, bin: []u8, acc_v: json.Value) -> [][3]f32 {
	size_of_ct :: proc(ct: int) -> int {return ct == 5126 ? 4 : 0} // f32 only
	raw, stride, count, _, ok := accessor_slice(accessors, views, bin, acc_v, size_of_ct, 3, "VEC3")
	if !ok {return nil}
	out := make([][3]f32, count, context.temp_allocator)
	for i in 0 ..< count {
		o := i * stride
		out[i] = {f32_le(raw[o:]), f32_le(raw[o + 4:]), f32_le(raw[o + 8:])}
	}
	return out
}

@(private = "file")
read_scalar_u32 :: proc(accessors, views: json.Array, bin: []u8, acc_v: json.Value) -> []u32 {
	size_of_ct :: proc(ct: int) -> int {
		switch ct {
		case 5121: return 1 // u8
		case 5123: return 2 // u16
		case 5125: return 4 // u32
		}
		return 0
	}
	raw, stride, count, ctype, ok := accessor_slice(accessors, views, bin, acc_v, size_of_ct, 1, "SCALAR")
	if !ok {return nil}
	out := make([]u32, count, context.temp_allocator)
	for i in 0 ..< count {
		o := i * stride
		switch ctype {
		case 5121: out[i] = u32(raw[o])
		case 5123: out[i] = u32(raw[o]) | u32(raw[o + 1]) << 8
		case 5125: out[i] = u32le_at(raw, o)
		}
	}
	return out
}

@(private = "file")
f32_le :: proc(d: []u8) -> f32 {
	return transmute(f32)u32le_at(d, 0)
}
