package tool

// The M3 editor shell (DESIGN.md §6): SDL3 window + GPU device + Dear ImGui
// chrome around two first-class GPU panes — the 2D vector canvas (the only
// editing surface, canvas2d.odin) and the 3D preview (view3d.odin). Layout
// mirrors dymeta's columns: narrow tool strip | view panes | value sidebar;
// the panes split horizontally (2D top / 3D bottom), Tab maximizes the
// hovered pane, the splitter drags.
//
// The document is the single source of truth. Every mutation goes through
// editor_undo_push (whole-document snapshot — documents are tiny) and
// editor_touch (doc_rev bump); the 3D world re-evaluates when doc_rev drifts
// from eval_rev, live during drags while the eval stays under budget.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../engine"
import imgui "../../vendor/odin-imgui"
import imgui_sdl3 "../../vendor/odin-imgui/imgui_impl_sdl3"
import imgui_sdlgpu3 "../../vendor/odin-imgui/imgui_impl_sdlgpu3"

WINDOW_W :: 1600
WINDOW_H :: 900
TOOLSTRIP_W :: f32(44)
SIDEBAR_W :: f32(320)
STATUS_H :: f32(24)

// EVAL_LIVE_MS — while a drag is in progress the world only re-evaluates if
// the last eval fit this budget; slower documents re-evaluate on release.
EVAL_LIVE_MS :: 120.0

Tool_Mode :: enum {
	Select,
	Node,
	Draw_Sector,
	Draw_Path,
	Draw_Solid,
	Draw_Bridge,
	Draw_Cliff,
	Draw_Hint,
	Draw_Marker,
}

Pane_Id :: enum {
	None,
	P2D,
	P3D,
}

// Comp_Cache — per-component flattened outline + fill triangulation, rebuilt
// lazily when doc_rev drifts. Index-parallel with doc.components.
Comp_Cache :: struct {
	flat:      [dynamic][2]f32,
	seg_start: [dynamic]i32,
	tris:      [dynamic]u32,
	rev:       u64,
}

Editor :: struct {
	device:       ^sdl.GPUDevice,
	window:       ^sdl.Window,

	doc:          engine.Document,
	doc_path:     string, // heap copy; "" = untitled
	doc_rev:      u64,    // bumped by editor_touch on every mutation
	saved_rev:    u64,

	caches:       [dynamic]Comp_Cache,

	// selection: component indices; primary drives node mode + the sidebar
	sel:          [dynamic]i32,
	primary:      i32,
	node_sel:     [dynamic]i32, // point indices into the primary component

	tool:         Tool_Mode,
	snap:         bool,
	draw_pts:     [dynamic]engine.Doc_Point, // in-progress draw-tool chain
	seed_counter: u32,                       // fresh component seeds

	cv:           Canvas2D,
	v3:           View3D,
	cam3:         Orbit_Cam,

	// preview assets (assets.odin): optional textures/models directory
	assets:       Assets,
	texscale:     f32, // world units per texture tile in the 3D pane

	// evaluation (the live 3D preview)
	eval_step:    f32,
	auto_eval:    bool,
	world:        engine.Eval_World,
	world_ok:     bool,
	chunks:       [dynamic]engine.Mesh_Chunk,
	eval_rev:     u64,
	eval_ms:      f64,
	mesh_verts:   int,
	mesh_tris:    int,
	topo_text:    string, // heap copy of the last topo report
	topo_warns:   int,
	topo:         engine.Topo_Data, // grid + WARN pins for the 2D overlays (§5)
	topo_ok:      bool,
	remeshed:     int,  // chunks extracted fresh by the last eval
	reused:       int,  // chunks stolen from the previous eval
	verify_incr:  bool, // STRATA_VERIFY_INCR=1: cross-check incr vs full mesh
	fit3_pending: bool, // frame the camera on the next successful eval

	// §5 debug overlays (overlay.odin)
	ov_heat:      bool,
	ov_walls:     bool,
	ov_sdf:       bool,
	ov_chunks:    bool,
	ov_pins:      bool,
	sdf_y:        f32, // world height of the SDF slice overlay
	sdf_y_set:    bool,
	slice:        Sdf_Slice,

	undo_stack:   [dynamic]engine.Document,
	redo_stack:   [dynamic]engine.Document,

	// engine diagnostics (diag.odin sink): captured for the sidebar Log panel
	// so parse/eval feedback is visible in the GUI, not lost to a terminal.
	diag_log:     [dynamic]Diag_Line,
	diag_errors:  int, // .Error entries currently in the log

	split:        f32, // 2D pane's share of the center column height
	maximized:    Pane_Id,
	hover_pane:   Pane_Id, // which pane the mouse was over this frame

	fdlg:         File_Dialog,    // Open / Save As browser (filedialog.odin)
	confirm:      Confirm_Action, // pending action behind the unsaved-changes modal
	confirm_path: [256]u8,        // path payload for Confirm_Action.Open_Path
	quit:         bool,           // set once quitting is allowed/confirmed
}

// --- diagnostics ---------------------------------------------------------------

DIAG_LOG_MAX :: 200

Diag_Line :: struct {
	level: engine.Diag_Level,
	text:  string, // heap clone
	count: int,    // consecutive repeats collapsed (re-evals repeat warnings)
}

// editor_diag_sink — engine.Diag_Sink: mirror to stderr (terminal users keep
// today's behavior), collapse consecutive repeats, cap the log.
editor_diag_sink :: proc(level: engine.Diag_Level, text: string, user: rawptr) {
	ed := (^Editor)(user)
	fmt.eprintln(text)
	if n := len(ed.diag_log); n > 0 {
		last := &ed.diag_log[n - 1]
		if last.level == level && last.text == text {
			last.count += 1
			return
		}
	}
	if len(ed.diag_log) >= DIAG_LOG_MAX {
		if ed.diag_log[0].level == .Error {ed.diag_errors -= 1}
		delete(ed.diag_log[0].text)
		ordered_remove(&ed.diag_log, 0)
	}
	append(&ed.diag_log, Diag_Line{level = level, text = strings.clone(text), count = 1})
	if level == .Error {ed.diag_errors += 1}
}

editor_diag_clear :: proc(ed: ^Editor) {
	for &l in ed.diag_log {delete(l.text)}
	clear(&ed.diag_log)
	ed.diag_errors = 0
}

// --- document plumbing --------------------------------------------------------

doc_clone :: proc(doc: ^engine.Document) -> (out: engine.Document) {
	out.name = doc.name
	for &c in doc.components {
		append(&out.components, engine.component_clone(&c))
	}
	for line in doc.meta {
		append(&out.meta, strings.clone(line))
	}
	return
}

// editor_touch marks the document changed: caches + eval go stale.
editor_touch :: proc(ed: ^Editor) {
	ed.doc_rev += 1
}

editor_undo_push :: proc(ed: ^Editor) {
	append(&ed.undo_stack, doc_clone(&ed.doc))
	if len(ed.undo_stack) > 64 {
		engine.document_destroy(&ed.undo_stack[0])
		ordered_remove(&ed.undo_stack, 0)
	}
	for &d in ed.redo_stack {engine.document_destroy(&d)}
	clear(&ed.redo_stack)
}

editor_undo :: proc(ed: ^Editor) {
	if len(ed.undo_stack) == 0 {return}
	append(&ed.redo_stack, ed.doc)
	ed.doc = pop(&ed.undo_stack)
	editor_after_doc_swap(ed)
}

editor_redo :: proc(ed: ^Editor) {
	if len(ed.redo_stack) == 0 {return}
	append(&ed.undo_stack, ed.doc)
	ed.doc = pop(&ed.redo_stack)
	editor_after_doc_swap(ed)
}

// editor_after_doc_swap — selection may point past the end of the restored
// component list. The world is NOT dropped: its per-component snapshots
// (polylines, pins, fields, hashes) are self-owned, so the next re-eval runs
// incrementally against it — undo of a local edit re-meshes only that region.
// (The stale world must not be SDF-sampled before that re-eval; the slice
// overlay guards on eval_rev == doc_rev.)
@(private = "file")
editor_after_doc_swap :: proc(ed: ^Editor) {
	editor_touch(ed)
	canvas_cancel_drag(&ed.cv)
	n := i32(len(ed.doc.components))
	for i := len(ed.sel) - 1; i >= 0; i -= 1 {
		if ed.sel[i] >= n {unordered_remove(&ed.sel, i)}
	}
	if ed.primary >= n {ed.primary = -1}
	clear(&ed.node_sel)
}

editor_drop_world :: proc(ed: ^Editor) {
	if ed.world_ok {
		engine.eval_world_destroy(&ed.world)
		ed.world_ok = false
	}
	for &c in ed.chunks {engine.mesh_chunk_destroy(&c)}
	clear(&ed.chunks)
	if ed.topo_ok {
		engine.topo_data_destroy(&ed.topo)
		ed.topo_ok = false
	}
	sdf_slice_reset(&ed.slice)
}

// editor_autodetect_assets — no explicit -assets/env dir: adopt (or drop) an
// `assets` directory beside the opened document.
editor_autodetect_assets :: proc(ed: ^Editor, doc_path: string) {
	if ed.assets.explicit || doc_path == "" {return}
	// filepath.dir returns a SLICE of doc_path (new core:path API — no
	// allocation), so it must not be deleted
	dir := fmt.tprintf("%s/assets", filepath.dir(doc_path))
	editor_rescan_assets(ed, os.is_directory(dir) ? dir : "")
}

// editor_rescan_assets — point the store at `dir` (may equal the current one:
// that's the Reload path) and drop every GPU cache derived from it.
editor_rescan_assets :: proc(ed: ^Editor, dir: string) {
	assets_scan(&ed.assets, dir)
	prop_store_reset(ed) // palette follows via the gen-keyed palette_ensure
	if ed.assets.dir != "" {
		fmt.eprintfln("assets: %s (%d textures, %d models)",
			ed.assets.dir, len(ed.assets.textures), len(ed.assets.models))
	}
}

// editor_set_doc replaces the document (New / Open), resetting everything
// derived from it.
editor_set_doc :: proc(ed: ^Editor, doc: engine.Document, path: string) {
	editor_drop_world(ed)
	editor_autodetect_assets(ed, path)
	engine.document_destroy(&ed.doc)
	ed.doc = doc
	delete(ed.doc_path)
	ed.doc_path = strings.clone(path)
	for &u in ed.undo_stack {engine.document_destroy(&u)}
	clear(&ed.undo_stack)
	for &r in ed.redo_stack {engine.document_destroy(&r)}
	clear(&ed.redo_stack)
	clear(&ed.sel)
	ed.primary = -1
	clear(&ed.node_sel)
	clear(&ed.draw_pts)
	ed.tool = .Select
	editor_touch(ed)
	ed.saved_rev = ed.doc_rev
	ed.fit3_pending = true
	ed.cv.fit_pending = true
}

editor_save :: proc(ed: ^Editor, path: string) -> bool {
	if path == "" {return false}
	if !engine.document_save_svg(&ed.doc, path) {return false}
	if path != ed.doc_path {
		delete(ed.doc_path)
		ed.doc_path = strings.clone(path)
	}
	ed.saved_rev = ed.doc_rev
	return true
}

// cache_get returns the component's flatten/fill cache, rebuilding if stale.
FLATTEN_TOL :: f32(0.02)

cache_get :: proc(ed: ^Editor, i: int) -> ^Comp_Cache {
	for len(ed.caches) < len(ed.doc.components) {append(&ed.caches, Comp_Cache{})}
	c := &ed.caches[i]
	if c.rev == ed.doc_rev && c.rev != 0 {return c}
	clear(&c.flat)
	clear(&c.seg_start)
	clear(&c.tris)
	comp := &ed.doc.components[i]
	flat := engine.component_flatten(comp, FLATTEN_TOL, &c.seg_start)
	append(&c.flat, ..flat[:])
	delete(flat)
	if comp.closed && len(c.flat) >= 3 {
		earcut(c.flat[:], &c.tris)
	}
	c.rev = ed.doc_rev
	return c
}

// z_sorted_indices — component indices in ascending z_order (stable), the
// paint + evaluation order. Temp-allocated.
z_sorted_indices :: proc(doc: ^engine.Document) -> []i32 {
	idx := make([]i32, len(doc.components), context.temp_allocator)
	for i in 0 ..< len(idx) {idx[i] = i32(i)}
	// insertion sort, stable, tiny n
	for i in 1 ..< len(idx) {
		j := i
		for j > 0 && doc.components[idx[j - 1]].z_order > doc.components[idx[j]].z_order {
			idx[j - 1], idx[j] = idx[j], idx[j - 1]
			j -= 1
		}
	}
	return idx
}

is_selected :: proc(ed: ^Editor, i: i32) -> bool {
	for s in ed.sel {if s == i {return true}}
	return false
}

select_only :: proc(ed: ^Editor, i: i32) {
	clear(&ed.sel)
	if i >= 0 {append(&ed.sel, i)}
	ed.primary = i
	clear(&ed.node_sel)
}

select_toggle :: proc(ed: ^Editor, i: i32) {
	for s, k in ed.sel {
		if s == i {
			unordered_remove(&ed.sel, k)
			if ed.primary == i {
				ed.primary = len(ed.sel) > 0 ? ed.sel[len(ed.sel) - 1] : -1
				clear(&ed.node_sel) // node indices belonged to the old primary
			}
			return
		}
	}
	append(&ed.sel, i)
	ed.primary = i
	clear(&ed.node_sel)
}

// --- evaluation ----------------------------------------------------------------

// editor_can_eval — the evaluator needs at least one geometry component.
editor_can_eval :: proc(ed: ^Editor) -> bool {
	for &c in ed.doc.components {
		switch c.kind {
		case .Sector, .Solid, .Bridge, .Cliff:
			if c.closed && len(c.points) >= 3 {return true}
		case .Path:
			if len(c.points) >= 2 {return true}
		case .Hint, .Marker:
		}
	}
	return false
}

editor_reeval :: proc(ed: ^Editor) {
	start := time.tick_now()
	ed.eval_rev = ed.doc_rev
	if !editor_can_eval(ed) {
		editor_drop_world(ed)
		view3d_set_chunks(&ed.v3, ed.device, nil)
		ed.mesh_verts, ed.mesh_tris = 0, 0
		ed.remeshed, ed.reused = 0, 0
		delete(ed.topo_text)
		ed.topo_text = {} // zero string, not "" — the next delete must not free rodata
		ed.topo_warns = 0
		return
	}

	// incremental (§6): build against the previous world — unchanged fields
	// copy their solve, and only chunks inside the dirty plan AABB re-mesh.
	old_world := ed.world
	had_world := ed.world_ok
	ed.world = engine.eval_world_build(&ed.doc, ed.eval_step, had_world ? &old_world : nil)
	ed.world_ok = true

	ed.reused = 0
	old_chunks := ed.chunks
	if ed.world.dirty_all {
		ed.chunks = engine.mesh_extract(&ed.world)
		for &c in old_chunks {engine.mesh_chunk_destroy(&c)}
	} else {
		ed.chunks = engine.mesh_extract_incr(
			&ed.world, &old_chunks, ed.world.dirty_lo, ed.world.dirty_hi,
			old_world.bounds_min, old_world.bounds_max, &ed.reused,
		)
	}
	delete(old_chunks)
	ed.remeshed = len(ed.chunks) - ed.reused
	if had_world {engine.eval_world_destroy(&old_world)}

	if ed.verify_incr && !ed.world.dirty_all {
		full := engine.mesh_extract(&ed.world)
		ci, cf := engine.mesh_checksum(ed.chunks[:]), engine.mesh_checksum(full[:])
		if ci != cf {
			fmt.eprintfln("VERIFY_INCR MISMATCH incr %08x (%d chunks) vs full %08x (%d chunks)",
				ci, len(ed.chunks), cf, len(full))
		} else {
			fmt.eprintfln("verify incr ok %08x (%d chunks, %d reused)", ci, len(ed.chunks), ed.reused)
		}
		for &c in full {engine.mesh_chunk_destroy(&c)}
		delete(full)
	}

	ed.mesh_verts, ed.mesh_tris = 0, 0
	for &c in ed.chunks {
		ed.mesh_verts += len(c.verts)
		ed.mesh_tris += len(c.indices) / 3
	}
	view3d_set_chunks(&ed.v3, ed.device, ed.chunks[:])

	if ed.topo_ok {engine.topo_data_destroy(&ed.topo)}
	ed.topo = engine.topo_data_build(&ed.world)
	ed.topo_ok = true
	b := strings.builder_make(context.temp_allocator)
	engine.topo_report_data(&ed.world, &ed.topo, &b)
	delete(ed.topo_text)
	ed.topo_text = strings.clone(strings.to_string(b))
	ed.topo_warns = strings.count(ed.topo_text, "WARN")

	if !ed.sdf_y_set {
		ed.sdf_y_set = true
		ed.sdf_y = (ed.world.bounds_min.y + ed.world.bounds_max.y) * 0.5
	}

	ed.eval_ms = time.duration_milliseconds(time.tick_since(start))

	if ed.fit3_pending {
		ed.fit3_pending = false
		editor_frame3(ed)
	}
}

// editor_frame3 — frame the orbit camera on the evaluated world's bounds.
editor_frame3 :: proc(ed: ^Editor) {
	if !ed.world_ok {return}
	c := (ed.world.bounds_min + ed.world.bounds_max) * 0.5
	ext := ed.world.bounds_max - ed.world.bounds_min
	ed.cam3 = orbit_cam_default(c)
	ed.cam3.dist = clamp(
		max(ext.x, ext.y, ext.z) * 1.2, CAM_DIST_MIN, CAM_DIST_MAX,
	)
}

// --- entry ----------------------------------------------------------------------

editor_run :: proc(doc_path: string, assets_dir: string = "") {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("strata", WINDOW_W, WINDOW_H, {.RESIZABLE})
	if window == nil {
		fmt.eprintfln("CreateWindow failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyWindow(window)

	device := sdl.CreateGPUDevice({.SPIRV}, true, nil)
	if device == nil {
		fmt.eprintfln("CreateGPUDevice failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.DestroyGPUDevice(device)
	if !sdl.ClaimWindowForGPUDevice(device, window) {
		fmt.eprintfln("ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer sdl.ReleaseWindowFromGPUDevice(device, window)

	imgui.CHECKVERSION()
	imgui.CreateContext()
	defer imgui.DestroyContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard}
	imgui.StyleColorsDark()

	imgui_sdl3.InitForSDLGPU(window)
	defer imgui_sdl3.Shutdown()
	init_info := imgui_sdlgpu3.InitInfo {
		Device               = device,
		ColorTargetFormat    = sdl.GetGPUSwapchainTextureFormat(device, window),
		MSAASamples          = ._1,
		SwapchainComposition = .SDR,
		PresentMode          = .VSYNC,
	}
	imgui_sdlgpu3.Init(&init_info)
	defer imgui_sdlgpu3.Shutdown()

	// NOTE (M2 lesson, main.odin): Eval_World holds ^Document — ed owns the
	// doc and both live in THIS frame for the whole session.
	ed: Editor
	ed.device = device
	ed.window = window
	ed.primary = -1
	ed.snap = true
	ed.eval_step = 1.0
	ed.auto_eval = true
	ed.split = 0.55
	ed.seed_counter = 1
	ed.cam3 = orbit_cam_default({0, 0, 0})
	ed.ov_pins = true // WARN pins on by default — the editor is the debugger (§5)
	ed.verify_incr = os.get_env("STRATA_VERIFY_INCR", context.temp_allocator) != ""
	ed.texscale = 4
	if assets_dir != "" {
		ed.assets.explicit = true // flag/env dir survives every doc open
	}

	// route engine diagnostics into the sidebar Log for the session (the sink
	// also mirrors to stderr); &ed is stable for the whole session frame
	engine.diag_set_sink(editor_diag_sink, &ed)
	defer {
		engine.diag_set_sink(nil)
		editor_diag_clear(&ed)
		delete(ed.diag_log)
	}

	if !canvas2d_init(&ed.cv, device) {
		fmt.eprintfln("canvas2d_init failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer canvas2d_free(device, &ed.cv)
	if !view3d_init(&ed.v3, device) {
		fmt.eprintfln("view3d_init failed: %s", sdl.GetError())
		os.exit(1)
	}
	defer view3d_free(device, &ed.v3)

	if assets_dir != "" {
		editor_rescan_assets(&ed, assets_dir)
	}

	if doc_path != "" {
		if doc, ok := engine.document_load_svg(doc_path); ok {
			editor_set_doc(&ed, doc, doc_path)
		} else {
			fmt.eprintfln("strata: cannot load %q, starting empty", doc_path)
		}
	}

	for running := true; running; {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			imgui_sdl3.ProcessEvent(&ev)
			#partial switch ev.type {
			case .QUIT:
				// dirty documents get the unsaved-changes modal first
				editor_request(&ed, .Quit)
			}
		}
		if ed.quit {running = false}

		// live re-eval: stale doc + (idle, or fast enough to track the drag)
		if ed.auto_eval && ed.doc_rev != ed.eval_rev {
			dragging := imgui.IsMouseDown(.Left) || imgui.IsMouseDown(.Right)
			if !dragging || ed.eval_ms < EVAL_LIVE_MS {
				editor_reeval(&ed)
			}
		}

		canvas2d_ensure_target(&ed.cv, device)
		view3d_ensure_target(&ed.v3, device)

		imgui_sdlgpu3.NewFrame()
		imgui_sdl3.NewFrame()
		imgui.NewFrame()
		build_shell(&ed)
		imgui.Render()

		draw_data := imgui.GetDrawData()
		minimized := draw_data.DisplaySize.x <= 0 || draw_data.DisplaySize.y <= 0

		if cmd := sdl.AcquireGPUCommandBuffer(device); cmd != nil {
			canvas2d_draw(&ed.cv, device, cmd) // uploads + offscreen pass
			view3d_upload_grid(&ed.v3, device, cmd)
			view3d_draw(&ed.v3, cmd)
			sc_tex: ^sdl.GPUTexture
			if sdl.WaitAndAcquireGPUSwapchainTexture(cmd, window, &sc_tex, nil, nil) &&
			   sc_tex != nil && !minimized {
				imgui_sdlgpu3.PrepareDrawData(draw_data, cmd)
				ct := sdl.GPUColorTargetInfo {
					texture     = sc_tex,
					clear_color = {0.05, 0.05, 0.06, 1.0},
					load_op     = .CLEAR,
					store_op    = .STORE,
				}
				rp := sdl.BeginGPURenderPass(cmd, &ct, 1, nil)
				imgui_sdlgpu3.RenderDrawData(draw_data, cmd, rp, nil)
				sdl.EndGPURenderPass(rp)
			}
			_ = sdl.SubmitGPUCommandBuffer(cmd)
		}

		free_all(context.temp_allocator)
	}

	_ = sdl.WaitForGPUIdle(device)
	editor_drop_world(&ed)
	assets_destroy(&ed.assets)
	fd_destroy(&ed.fdlg)
}

tex_ref :: proc(t: ^sdl.GPUTexture) -> imgui.TextureRef {
	return imgui.TextureRef{_TexID = imgui.TextureID(uintptr(t))}
}

// --- shell ----------------------------------------------------------------------

@(private = "file")
build_shell :: proc(ed: ^Editor) {
	io := imgui.GetIO()

	if imgui.BeginMainMenuBar() {
		if imgui.BeginMenu("File") {
			if imgui.MenuItem("New") {
				editor_request(ed, .New)
			}
			if imgui.BeginMenu("Open") {
				open_menu(ed)
				imgui.EndMenu()
			}
			if imgui.MenuItem("Save", "Ctrl+S") {
				editor_save_or_ask(ed)
			}
			if imgui.MenuItem("Save As...") { // ASCII: the UI font has no U+2026
				fd_open(ed, .Save)
			}
			imgui.EndMenu()
		}
		if imgui.BeginMenu("Edit") {
			if imgui.MenuItem("Undo", "Ctrl+Z", false, len(ed.undo_stack) > 0) {editor_undo(ed)}
			if imgui.MenuItem("Redo", "Ctrl+Y", false, len(ed.redo_stack) > 0) {editor_redo(ed)}
			imgui.Separator()
			if imgui.MenuItem("Duplicate", "Ctrl+D", false, len(ed.sel) > 0) {editor_duplicate_sel(ed)}
			if imgui.MenuItem("Delete", "Del", false, len(ed.sel) > 0) {editor_delete_sel(ed)}
			imgui.EndMenu()
		}
		if imgui.BeginMenu("View") {
			if imgui.MenuItem("Fit 2D", "F", false, len(ed.doc.components) > 0) {ed.cv.fit_pending = true}
			if imgui.MenuItem("Frame 3D", nil, false, ed.world_ok) {editor_frame3(ed)}
			imgui.Separator()
			imgui.MenuItemBoolPtr("Snap", "X", &ed.snap)
			imgui.MenuItemBoolPtr("Auto eval", nil, &ed.auto_eval)
			if imgui.MenuItem("Re-evaluate now", "F5") {editor_reeval(ed)}
			if imgui.MenuItem("Reload assets", nil, false, ed.assets.dir != "") {
				editor_rescan_assets(ed, ed.assets.dir)
			}
			imgui.SeparatorText("Overlays")
			imgui.MenuItemBoolPtr("Field heatmap", nil, &ed.ov_heat)
			imgui.MenuItemBoolPtr("Derived walls", nil, &ed.ov_walls)
			imgui.MenuItemBoolPtr("SDF slice", nil, &ed.ov_sdf)
			imgui.MenuItemBoolPtr("Chunk bounds", nil, &ed.ov_chunks)
			imgui.MenuItemBoolPtr("Topo pins", nil, &ed.ov_pins)
			imgui.EndMenu()
		}
		imgui.EndMainMenuBar()
	}

	// global shortcuts (never while typing in a field)
	if !io.WantTextInput {
		ctrl := io.KeyCtrl
		// structural edits wait for an active drag to end — a mid-drag undo or
		// duplicate would yank the components the drag indexes by position
		idle := ed.cv.drag == .None || ed.cv.drag == .Pan
		if ctrl && imgui.IsKeyPressed(.S, false) {editor_save_or_ask(ed)}
		if idle && ctrl && imgui.IsKeyPressed(.Z, false) {editor_undo(ed)}
		if idle && ctrl && imgui.IsKeyPressed(.Y, false) {editor_redo(ed)}
		if idle && ctrl && imgui.IsKeyPressed(.D, false) {editor_duplicate_sel(ed)}
		if imgui.IsKeyPressed(.F5, false) {editor_reeval(ed)}
		if imgui.IsKeyPressed(.X, false) {ed.snap = !ed.snap}
		if imgui.IsKeyPressed(._1, false) {editor_set_tool(ed, .Select)}
		if imgui.IsKeyPressed(._2, false) {editor_set_tool(ed, .Node)}
		if imgui.IsKeyPressed(._3, false) {editor_set_tool(ed, .Draw_Sector)}
		if imgui.IsKeyPressed(._4, false) {editor_set_tool(ed, .Draw_Path)}
		if imgui.IsKeyPressed(._5, false) {editor_set_tool(ed, .Draw_Solid)}
		if imgui.IsKeyPressed(._6, false) {editor_set_tool(ed, .Draw_Bridge)}
		if imgui.IsKeyPressed(._7, false) {editor_set_tool(ed, .Draw_Hint)}
		if imgui.IsKeyPressed(._8, false) {editor_set_tool(ed, .Draw_Marker)}
		if imgui.IsKeyPressed(._9, false) {editor_set_tool(ed, .Draw_Cliff)}
		if imgui.IsKeyPressed(.Tab, false) && ed.hover_pane != .None {
			ed.maximized = ed.maximized == .None ? ed.hover_pane : .None
		}
	}

	mv := imgui.GetMainViewport()
	imgui.SetNextWindowPos(mv.WorkPos)
	imgui.SetNextWindowSize(mv.WorkSize)
	flags := imgui.WindowFlags {
		.NoTitleBar, .NoResize, .NoMove, .NoCollapse, .NoBringToFrontOnFocus,
	}
	imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
	imgui.PushStyleVar(.WindowRounding, 0)
	if imgui.Begin("##shell", nil, flags) {
		body_h := imgui.GetContentRegionAvail().y - STATUS_H
		ed.hover_pane = .None

		if imgui.BeginChild("##strip", {TOOLSTRIP_W, body_h}, {.Borders}) {
			tool_strip(ed)
		}
		imgui.EndChild()
		imgui.SameLine()

		center_w := imgui.GetContentRegionAvail().x - SIDEBAR_W
		if imgui.BeginChild("##center", {center_w, body_h}, {}) {
			avail := imgui.GetContentRegionAvail()
			splitter_h := f32(6)
			h2d := (avail.y - splitter_h) * ed.split
			h3d := avail.y - splitter_h - h2d
			show2d := ed.maximized != .P3D
			show3d := ed.maximized != .P2D
			if ed.maximized == .P2D {h2d = avail.y}
			if ed.maximized == .P3D {h3d = avail.y}

			if show2d {
				if imgui.BeginChild("##pane2d", {0, h2d}, {.Borders}) {
					canvas2d_pane(ed)
				}
				imgui.EndChild()
			}
			if show2d && show3d {
				imgui.InvisibleButton("##split", {-1, splitter_h})
				if imgui.IsItemActive() {
					ed.split = clamp(
						ed.split + imgui.GetIO().MouseDelta.y / max(avail.y - splitter_h, 1),
						0.1, 0.9,
					)
				}
				if imgui.IsItemHovered() {imgui.SetMouseCursor(.ResizeNS)}
			}
			if show3d {
				if imgui.BeginChild("##pane3d", {0, show2d ? h3d : avail.y}, {.Borders}) {
					view3d_pane(ed)
				}
				imgui.EndChild()
			}
		}
		imgui.EndChild()
		imgui.SameLine()

		if imgui.BeginChild("##sidebar", {0, body_h}, {.Borders}) {
			sidebar_draw(ed)
		}
		imgui.EndChild()

		status_bar(ed)
	}
	imgui.End()
	imgui.PopStyleVar(2)

	// modals after the style pop so they keep normal window padding
	fd_draw(ed)
	fd_confirm_modal(ed)
}

// editor_save_or_ask — Ctrl+S / File > Save: straight save when the document
// has a path, otherwise route through the Save dialog.
editor_save_or_ask :: proc(ed: ^Editor) {
	if ed.doc_path != "" {
		_ = editor_save(ed, ed.doc_path)
	} else {
		fd_open(ed, .Save)
	}
}

editor_set_tool :: proc(ed: ^Editor, t: Tool_Mode) {
	if ed.tool != t {clear(&ed.draw_pts)}
	ed.tool = t
	if t != .Node {clear(&ed.node_sel)}
}

@(private = "file")
tool_strip :: proc(ed: ^Editor) {
	tool_button :: proc(ed: ^Editor, label: cstring, t: Tool_Mode, tip: cstring) {
		active := ed.tool == t
		if active {
			imgui.PushStyleColorImVec4(.Button, {0.26, 0.46, 0.72, 1})
		}
		if imgui.Button(label, {TOOLSTRIP_W - 10, 32}) {editor_set_tool(ed, t)}
		if active {imgui.PopStyleColor()}
		if imgui.IsItemHovered() {imgui.SetTooltip("%s", tip)}
	}
	tool_button(ed, "S", .Select, "Select / move (1)")
	tool_button(ed, "N", .Node, "Node editing (2)")
	imgui.Separator()
	tool_button(ed, "Se", .Draw_Sector, "Draw Sector — playspace void (3)")
	tool_button(ed, "Pa", .Draw_Path, "Draw Path — swept void (4)")
	tool_button(ed, "So", .Draw_Solid, "Draw Solid — rock island (5)")
	tool_button(ed, "Br", .Draw_Bridge, "Draw Bridge — floating slab, tag bear edges (6)")
	tool_button(ed, "Cl", .Draw_Cliff, "Draw Cliff — vertical rock blob, flat top at base (9)")
	tool_button(ed, "Hi", .Draw_Hint, "Draw Hint — swept height profile (7)")
	tool_button(ed, "Mk", .Draw_Marker, "Place Marker (8)")
}

@(private = "file")
status_bar :: proc(ed: ^Editor) {
	imgui.PushStyleVarImVec2(.WindowPadding, {8, 3})
	if imgui.BeginChild("##status", {0, 0}, {.Borders}) {
		dirty := ed.doc_rev != ed.saved_rev ? "*" : ""
		path := ed.doc_path != "" ? ed.doc_path : "untitled"
		// NOTE: imgui.Text formats via C vsnprintf — Odin verbs/types crash it,
		// so pre-format with ctprintf and hand it plain text.
		imgui.TextUnformatted(
			fmt.ctprintf(
				"%s%s   |   %v   snap %s   step %.2g   |   eval %.0f ms   %d tris   %d warn%s%s",
				path, dirty, ed.tool, ed.snap ? "on" : "off",
				ed.eval_step, ed.eval_ms, ed.mesh_tris, ed.topo_warns,
				ed.doc_rev != ed.eval_rev ? " (stale)" : "",
				ed.diag_errors > 0 ? "   [log has errors]" : "",
			),
		)
	}
	imgui.EndChild()
	imgui.PopStyleVar()
}

@(private = "file")
open_menu :: proc(ed: ^Editor) {
	if imgui.MenuItem("Browse...") {
		editor_request(ed, .Open_Browse)
	}
	matches, gerr := filepath.glob("content/samples/*.strata.svg", context.temp_allocator)
	if gerr == nil && len(matches) > 0 {
		imgui.SeparatorText("samples")
		for path in matches {
			cpath := strings.clone_to_cstring(path, context.temp_allocator)
			if imgui.MenuItem(cpath) {
				editor_request(ed, .Open_Path, path)
			}
		}
	}
}

// --- selection ops ---------------------------------------------------------------

editor_delete_sel :: proc(ed: ^Editor) {
	if len(ed.sel) == 0 {return}
	canvas_cancel_drag(&ed.cv)
	editor_undo_push(ed)
	// remove in descending index order so indices stay valid
	for {
		hi := i32(-1)
		for s in ed.sel {if s > hi {hi = s}}
		if hi < 0 {break}
		for s, k in ed.sel {
			if s == hi {unordered_remove(&ed.sel, k);break}
		}
		c := &ed.doc.components[hi]
		delete(c.points)
		delete(c.edge_tags)
		ordered_remove(&ed.doc.components, int(hi))
	}
	renumber_z(ed)
	select_only(ed, -1)
	editor_touch(ed)
}

editor_duplicate_sel :: proc(ed: ^Editor) {
	if len(ed.sel) == 0 {return}
	editor_undo_push(ed)
	src := make([dynamic]i32, context.temp_allocator)
	append(&src, ..ed.sel[:])
	clear(&ed.sel)
	for s in src {
		nc := engine.component_clone(&ed.doc.components[s])
		for &p in nc.points {p.pos += {2, 2}}
		nc.seed = editor_next_seed(ed)
		append(&ed.doc.components, nc)
		append(&ed.sel, i32(len(ed.doc.components) - 1))
	}
	ed.primary = len(ed.sel) > 0 ? ed.sel[len(ed.sel) - 1] : -1
	renumber_z(ed)
	editor_touch(ed)
}

editor_next_seed :: proc(ed: ^Editor) -> u32 {
	ed.seed_counter += 1
	return ed.seed_counter * 2654435761 % 100000
}

// renumber_z rewrites z_order = array index (the loader's convention), keeping
// relative order. Raise/Lower in the sidebar reorders the array itself.
renumber_z :: proc(ed: ^Editor) {
	for &c, i in ed.doc.components {c.z_order = i32(i)}
}

// comp_display_name — the component's name, or kind+index for unnamed ones.
comp_display_name :: proc(doc: ^engine.Document, i: i32) -> string {
	c := &doc.components[i]
	n := engine.name32_str(&c.name)
	if n != "" {return n}
	return fmt.tprintf("%v %d", c.kind, i)
}

// math import kept honest (clamp lives in builtin, math used by callers)
@(private = "file")
_ :: math.PI
