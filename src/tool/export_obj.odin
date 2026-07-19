package tool

// OBJ export — a frontend bolt-on for EXTERNAL viewers (Blender, online obj
// viewers, dymeta's viewer), not the game path. A game that uses strata as
// its level pipeline vendors src/engine and wires document_load_svg →
// eval_world_build → mesh_extract into its own load spots; nothing here is
// part of that contract, which is why this file lives in the tool package.
//
//   obj_write/save        OBJ tri-soup, `usemtl <recipe-name>` per run.
//                         TEXTURES TODO: when texgen lands, emit a sibling
//                         .mtl mapping recipe names to baked images (and
//                         vt/uv only if we ever leave triplanar).
//   level_meta_write/save game-agnostic level sidecar (.txt) beside the obj —
//                         what OBJ can't carry, for external tooling:
//                         document meta lines, material table, markers
//                         (heights resolved via engine.surface_height),
//                         portal edges
//
// Sidecar format: line-oriented, space-separated, args tail to end of line:
//   level    <name>
//   meta     <verbatim line from the document>          (0+)
//   material <index> <recipe-name>
//   marker   <class|-> <x> <y> <z> <yaw> <scale> <cover:0|1> <model|-> [args…]
//   portal   <comp|-> <segment> <x0> <y0> <z0> <x1> <y1> <z1> [args…]
// y is up; (x, z) = document (x, y), matching the OBJ. A marker over raw
// rock (no surface) grounds at y=0.

import "core:fmt"
import "core:os"
import "core:strings"

import "../engine"

// obj_write — the tri-soup as OBJ: positions + normals, one `g` per chunk,
// `usemtl <recipe-name>` runs from the face's first vertex.
obj_write :: proc(w: ^engine.Eval_World, chunks: []engine.Mesh_Chunk, b: ^strings.Builder, note: string) {
	fmt.sbprintfln(b, "# strata dump of %s (step %.4g)", note, w.step)
	fmt.sbprintfln(b, "o strata")
	base := 1 // OBJ indices are 1-based, global across chunks
	for &c in chunks {
		fmt.sbprintfln(b, "g chunk_%d_%d_%d", c.cell.x, c.cell.y, c.cell.z)
		for v in c.verts {
			fmt.sbprintfln(b, "v %.5f %.5f %.5f", v.pos.x, v.pos.y, v.pos.z)
			fmt.sbprintfln(b, "vn %.4f %.4f %.4f", v.normal.x, v.normal.y, v.normal.z)
		}
		cur_mat := u16(max(u16))
		for i := 0; i < len(c.indices); i += 3 {
			i0, i1, i2 := int(c.indices[i]), int(c.indices[i + 1]), int(c.indices[i + 2])
			mat := c.verts[i0].mat
			if mat != cur_mat && int(mat) < len(w.materials) {
				fmt.sbprintfln(b, "usemtl %s", engine.name32_str(&w.materials[mat]))
				cur_mat = mat
			}
			fmt.sbprintfln(b, "f %d//%d %d//%d %d//%d",
				base + i0, base + i0, base + i1, base + i1, base + i2, base + i2)
		}
		base += len(c.verts)
	}
}

obj_save :: proc(w: ^engine.Eval_World, chunks: []engine.Mesh_Chunk, path: string, note: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	obj_write(w, chunks, &b, note)
	if werr := os.write_entire_file(path, b.buf[:]); werr != nil {
		fmt.eprintfln("export: cannot write %q: %v", path, werr)
		return false
	}
	return true
}

// dash_name — a Name32 as one sidecar token: "-" when empty, spaces folded to
// '_' (every field before the args tail must stay a single token).
@(private = "file")
dash_name :: proc(n: ^engine.Name32) -> string {
	s := engine.name32_str(n)
	if s == "" {return "-"}
	if strings.index_byte(s, ' ') < 0 {return s}
	out, _ := strings.replace_all(s, " ", "_", context.temp_allocator)
	return out
}

// level_meta_write — the sidecar txt (format in the header comment).
level_meta_write :: proc(doc: ^engine.Document, w: ^engine.Eval_World, b: ^strings.Builder) {
	fmt.sbprintfln(b, "# strata level sidecar — geometry is in the matching .obj")
	fmt.sbprintfln(b, "level %s", dash_name(&doc.name))
	for line in doc.meta {
		fmt.sbprintfln(b, "meta %s", line)
	}
	for &m, i in w.materials {
		fmt.sbprintfln(b, "material %d %s", i, engine.name32_str(&m))
	}
	for &c in doc.components {
		if c.kind == .Marker && len(c.points) > 0 {
			pos := c.points[0].pos
			y, _ := engine.surface_height(w, pos)
			args := c.args
			args_s := string(cstring(&args[0]))
			fmt.sbprintf(b, "marker %s %.5f %.5f %.5f %.4g %.4g %d %s",
				dash_name(&c.class), pos.x, y, pos.y, c.yaw, c.scale,
				c.cover ? 1 : 0, dash_name(&c.model))
			if args_s != "" {fmt.sbprintf(b, " %s", args_s)}
			fmt.sbprintln(b)
		}
		if !c.closed {continue}
		for &t in c.edge_tags {
			if t.kind != .Portal {continue}
			n := len(c.points)
			if int(t.segment) >= n {continue}
			a := c.points[t.segment].pos
			pb := c.points[(int(t.segment) + 1) % n].pos
			ya, _ := engine.surface_height(w, a)
			yb, _ := engine.surface_height(w, pb)
			tag := t
			fmt.sbprintf(b, "portal %s %d %.5f %.5f %.5f %.5f %.5f %.5f",
				dash_name(&c.name), t.segment, a.x, ya, a.y, pb.x, yb, pb.y)
			if args := engine.name32_str(&tag.args); args != "" {fmt.sbprintf(b, " %s", args)}
			fmt.sbprintln(b)
		}
	}
}

level_meta_save :: proc(doc: ^engine.Document, w: ^engine.Eval_World, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	level_meta_write(doc, w, &b)
	if werr := os.write_entire_file(path, b.buf[:]); werr != nil {
		fmt.eprintfln("export: cannot write %q: %v", path, werr)
		return false
	}
	return true
}
