package tool

// strata CLI entry: thin argument plumbing over the engine compiler
// (document → fields → SDF → mesh/topo) plus `edit`, which opens the editor
// shell (editor.odin). The engine is the vendorable compiler a game wires
// into its own load path; `dump`'s OBJ + sidecar (export_obj.odin) is a
// frontend bolt-on for external viewers, not the game contract. Golden tests
// (§5) drive the headless commands over content/samples/.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "../engine"

USAGE :: `strata — vector-map level synthesis (see DESIGN.md)

  strata [edit] [doc]                    open the editor (M3), optionally on a document
  strata eval <doc> [-step=N]            evaluate document -> mesh stats + checksum
  strata dump <doc> [out.obj] [-step=N]  compile -> OBJ tri-soup + level sidecar txt
                                         (default: <doc stem>.obj / .txt; "-" = obj to stdout)
  strata topo <doc> [-step=N]            walkability/connectivity/clearance oracle
  strata resave <doc> <out>              load + save (writer round-trip check)
  strata assets <dir>                    validate a preview-assets dir (decode everything)

  -step=N       lattice spacing in world units (default 0.5)
  -assets=DIR   editor preview assets (textures/ + models/); also STRATA_ASSETS,
                else an assets/ dir beside the opened document is picked up
`

main :: proc() {
	args := os.args[1:]
	assets_dir := os.get_env("STRATA_ASSETS", context.allocator)
	if len(args) < 1 {
		editor_run("", assets_dir)
		return
	}

	step := f32(0.5)
	rest := make([dynamic]string)
	for a in args[1:] {
		if strings.has_prefix(a, "-step=") {
			if v, ok := strconv.parse_f32(a[6:]); ok && v > 0 {
				step = v
			} else {
				fmt.eprintfln("strata: bad %q", a)
				os.exit(2)
			}
		} else if strings.has_prefix(a, "-assets=") {
			assets_dir = a[8:]
		} else {
			append(&rest, a)
		}
	}

	switch args[0] {
	case "edit":
		editor_run(len(rest) >= 1 ? rest[0] : "", assets_dir)
	case "resave":
		if len(rest) != 2 {usage_exit()}
		doc := load_doc(rest[0])
		if !engine.document_save_svg(&doc, rest[1]) {os.exit(1)}
		fmt.printfln("wrote %s", rest[1])
	case "eval":
		if len(rest) != 1 {usage_exit()}
		cmd_eval(rest[0], step)
	case "dump":
		if len(rest) < 1 || len(rest) > 2 {usage_exit()}
		out := rest[1] if len(rest) == 2 else obj_path_for(rest[0])
		cmd_dump(rest[0], out, step)
	case "topo":
		if len(rest) != 1 {usage_exit()}
		cmd_topo(rest[0], step)
	case "assets":
		if len(rest) != 1 {usage_exit()}
		cmd_assets(rest[0])
	case:
		// `strata <doc>` opens the editor directly
		if strings.has_suffix(args[0], ".svg") || os.exists(args[0]) {
			editor_run(args[0], assets_dir)
			return
		}
		fmt.eprintfln("strata: unknown command %q", args[0])
		usage_exit()
	}
}

// cmd_assets — headless validation of a preview-assets directory: scan and
// fully decode every texture and model, so asset problems surface in CI/
// terminal instead of as silent hash-tint fallbacks in the editor.
cmd_assets :: proc(dir: string) {
	a: Assets
	if !assets_scan(&a, dir) {os.exit(1)}
	fails := 0
	for &e in a.textures {
		if img, ok := image_load_rgba8(e.path); ok {
			fmt.printfln("texture %-24s %dx%d", e.stem, img.w, img.h)
			img := img
			rgba8_destroy(&img)
		} else {
			fmt.printfln("texture %-24s FAILED (%s)", e.stem, e.path)
			fails += 1
		}
	}
	for &e in a.models {
		if mesh, ok := glb_load_file(e.path); ok {
			fmt.printfln("model   %-24s %d verts, %d tris", e.stem, len(mesh.verts), len(mesh.indices) / 3)
			mesh := mesh
			prop_mesh_destroy(&mesh)
		} else {
			fmt.printfln("model   %-24s FAILED (%s)", e.stem, e.path)
			fails += 1
		}
	}
	fmt.printfln("%d texture(s), %d model(s), %d failure(s)", len(a.textures), len(a.models), fails)
	if fails > 0 {os.exit(1)}
}

usage_exit :: proc() {
	fmt.print(USAGE)
	os.exit(2)
}

// load_doc + build_world: the Eval_World keeps a pointer to the document, so
// the document must live in the CALLER's frame — never return both by value.
load_doc :: proc(doc_path: string) -> engine.Document {
	doc, ok := engine.document_load_svg(doc_path)
	if !ok {os.exit(1)}
	return doc
}

build_world :: proc(doc: ^engine.Document, step: f32) -> engine.Eval_World {
	world := engine.eval_world_build(doc, step)
	if len(world.comps) == 0 {os.exit(1)}
	return world
}

cmd_eval :: proc(doc_path: string, step: f32) {
	doc := load_doc(doc_path)
	world := build_world(&doc, step)
	chunks := engine.mesh_extract(&world)

	verts, tris := 0, 0
	for &c in chunks {
		verts += len(c.verts)
		tris += len(c.indices) / 3
	}
	fmt.printfln("document   %s (%d components)", engine.name32_str(&doc.name), len(doc.components))
	for &comp, i in doc.components {
		ec := &world.comps[i]
		if ec.field.samples != nil {
			fmt.printfln("  %-8v %q z=%d base=%.4g points=%d field=[%.4g %.4g] pins=%d",
				comp.kind, engine.name32_str(&comp.name), comp.z_order, comp.base,
				len(comp.points), ec.field.fmin, ec.field.fmax, len(ec.pins))
		} else {
			fmt.printfln("  %-8v %q z=%d base=%.4g points=%d",
				comp.kind, engine.name32_str(&comp.name), comp.z_order, comp.base, len(comp.points))
		}
	}
	fmt.printfln("step       %.4g", step)
	fmt.printfln("bounds     (%.4g %.4g %.4g) .. (%.4g %.4g %.4g)",
		world.bounds_min.x, world.bounds_min.y, world.bounds_min.z,
		world.bounds_max.x, world.bounds_max.y, world.bounds_max.z)
	fmt.printfln("materials  %d", len(world.materials))
	for &m, i in world.materials {
		fmt.printfln("  [%d] %s", i, engine.name32_str(&m))
	}
	fmt.printfln("mesh       %d chunks, %d verts, %d tris", len(chunks), verts, tris)
	fmt.printfln("checksum   %08x", engine.mesh_checksum(chunks[:]))
}

cmd_topo :: proc(doc_path: string, step: f32) {
	doc := load_doc(doc_path)
	world := build_world(&doc, step)
	b := strings.builder_make()
	engine.topo_report(&world, &b)
	fmt.print(strings.to_string(b))
}

cmd_dump :: proc(doc_path, out_path: string, step: f32) {
	doc := load_doc(doc_path)
	world := build_world(&doc, step)
	chunks := engine.mesh_extract(&world)

	if out_path == "-" {
		b := strings.builder_make()
		obj_write(&world, chunks[:], &b, doc_path)
		fmt.print(strings.to_string(b))
		return
	}
	if !obj_save(&world, chunks[:], out_path, doc_path) {os.exit(1)}
	meta_path := swap_ext(out_path, ".txt")
	if !level_meta_save(&doc, &world, meta_path) {os.exit(1)}

	verts, tris := 0, 0
	for &c in chunks {
		verts += len(c.verts)
		tris += len(c.indices) / 3
	}
	fmt.printfln("wrote %s (%d verts, %d tris, %d chunks) + %s",
		out_path, verts, tris, len(chunks), meta_path)
}

// obj_path_for — "content/samples/canyon.strata.svg" → "content/samples/canyon.obj"
obj_path_for :: proc(doc_path: string) -> string {
	stem := doc_path
	if strings.has_suffix(stem, ".strata.svg") {
		stem = stem[:len(stem) - len(".strata.svg")]
	} else if i := strings.last_index_byte(stem, '.'); i > 0 {
		stem = stem[:i]
	}
	return strings.concatenate({stem, ".obj"})
}

swap_ext :: proc(path, ext: string) -> string {
	stem := path
	if i := strings.last_index_byte(stem, '.'); i > 0 {stem = stem[:i]}
	return strings.concatenate({stem, ext})
}
