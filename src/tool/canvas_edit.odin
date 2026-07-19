package tool

// The 2D canvas' editing half (DESIGN.md §6): input handling, hit-testing,
// snapping, the draw tools, node/armature editing, and the per-frame document
// tessellation into the canvas vertex list. Boring on purpose — select /
// move / snap / point drag; everything exotic lives in the sidebar.

import "core:fmt"
import "core:math"
import "core:math/linalg"

import imgui "../../vendor/odin-imgui"

import "../engine"

CLICK_PX :: f32(4)   // drag threshold
PICK_PX :: f32(7)    // component pick tolerance
NODE_PX :: f32(8)    // node grab radius
SNAP_PX :: f32(9)    // point-snap radius

canvas2d_pane :: proc(ed: ^Editor) {
	cv := &ed.cv
	origin_v := imgui.GetCursorScreenPos()
	size_v := imgui.GetContentRegionAvail()
	if size_v.x < 16 || size_v.y < 16 {return}
	origin := [2]f32{origin_v.x, origin_v.y}
	size := [2]f32{size_v.x, size_v.y}

	imgui.Dummy(size_v)
	io := imgui.GetIO()
	hovered := imgui.IsWindowHovered()
	if hovered {ed.hover_pane = .P2D}
	mouse := [2]f32{io.MousePos.x, io.MousePos.y}

	if cv.fit_pending {
		cv.fit_pending = false
		canvas_fit(ed, size)
	}

	// --- camera --------------------------------------------------------------
	if hovered && io.MouseWheel != 0 {
		before := px_to_world(cv.cam, mouse, origin, size)
		cv.cam.zoom = clamp(cv.cam.zoom * math.pow(1.15, io.MouseWheel), 0.05, 400)
		after := px_to_world(cv.cam, mouse, origin, size)
		cv.cam.center += before - after
	}
	space := imgui.IsKeyDown(.Space)
	if hovered && cv.drag == .None &&
	   (imgui.IsMouseClicked(.Middle) || imgui.IsMouseClicked(.Right) ||
	   (space && imgui.IsMouseClicked(.Left))) {
		cv.drag = .Pan
	}
	if cv.drag == .Pan {
		if !(imgui.IsMouseDown(.Middle) || imgui.IsMouseDown(.Right) ||
		   (space && imgui.IsMouseDown(.Left))) {
			cv.drag = .None
		} else {
			cv.cam.center -= [2]f32{io.MouseDelta.x, io.MouseDelta.y} / cv.cam.zoom
		}
	}

	mouse_w := px_to_world(cv.cam, mouse, origin, size)
	grid_minor := grid_step(cv.cam.zoom)

	// --- keys (pane-scoped) ----------------------------------------------------
	if hovered && !io.WantTextInput {
		if imgui.IsKeyPressed(.F, false) {canvas_fit(ed, size)}
		if imgui.IsKeyPressed(.Escape, false) {
			if len(ed.draw_pts) > 0 {
				clear(&ed.draw_pts)
			} else if ed.tool != .Select {
				editor_set_tool(ed, .Select)
			} else {
				select_only(ed, -1)
			}
		}
		if imgui.IsKeyPressed(.Enter, false) && len(ed.draw_pts) > 0 {
			canvas_commit_draw(ed)
		}
		del_idle := cv.drag == .None || cv.drag == .Pan // no structural edits mid-drag
		if del_idle && (imgui.IsKeyPressed(.Delete, false) || imgui.IsKeyPressed(.Backspace, false)) {
			if ed.tool == .Node && len(ed.node_sel) > 0 {
				canvas_delete_nodes(ed)
			} else if len(ed.sel) > 0 {
				editor_delete_sel(ed)
			}
		}
	}

	// --- tool input --------------------------------------------------------------
	if cv.drag != .Pan {
		switch ed.tool {
		case .Select:
			select_input(ed, hovered, mouse, mouse_w, grid_minor)
		case .Node:
			node_input(ed, hovered, mouse, mouse_w, grid_minor)
		case .Draw_Sector, .Draw_Path, .Draw_Solid, .Draw_Bridge, .Draw_Cliff, .Draw_Hint, .Draw_Marker:
			draw_input(ed, hovered, mouse_w, grid_minor)
		}
	}

	// --- build the frame's vertex list -----------------------------------------
	clear(&cv.verts)
	render_grid(cv, origin, size, grid_minor)
	render_document(ed)
	render_overlays(ed, origin, size) // §5 debug overlays (overlay.odin)
	render_node_overlay(ed)
	render_draw_preview(ed, mouse_w, grid_minor)
	if cv.drag == .Rubber {
		lo := linalg.min(cv.rubber_a, cv.rubber_b)
		hi := linalg.max(cv.rubber_a, cv.rubber_b)
		cv_rect_fill(cv, lo, hi, rgba(120, 170, 255, 24))
		px := 1.0 / cv.cam.zoom
		cv_polyline(cv, {lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}, true, px, rgba(120, 170, 255, 180))
	}

	cv.u = Uniforms{mvp = canvas2d_matrix(cv.cam, size)}
	cv.nverts = u32(len(cv.verts))
	cv.want_w, cv.want_h = u32(size.x), u32(size.y)
	cv.live = true

	// composite this frame's target + text labels on top
	dl := imgui.GetWindowDrawList()
	if cv.color != nil {
		imgui.DrawList_AddImage(dl, tex_ref(cv.color), origin_v, origin_v + size_v)
	}
	render_labels(ed, dl, origin, size)
	overlay_pin_labels(ed, dl, origin, size)
}

// --- camera helpers ------------------------------------------------------------

canvas_fit :: proc(ed: ^Editor, size: [2]f32) {
	cv := &ed.cv
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	any_pt := false
	for &c in ed.doc.components {
		for &p in c.points {
			lo = linalg.min(lo, p.pos)
			hi = linalg.max(hi, p.pos)
			any_pt = true
		}
	}
	if !any_pt {
		cv.cam = {center = {0, 0}, zoom = 6}
		return
	}
	ext := hi - lo
	cv.cam.center = (lo + hi) * 0.5
	cv.cam.zoom = clamp(min(size.x / max(ext.x, 1e-3), size.y / max(ext.y, 1e-3)) * 0.85, 0.05, 400)
}

// grid_step — zoom-adaptive minor grid spacing: the FINEST 1/2/5·10ⁿ step
// that still paints at ≥ 8 px, so the grid (and its snap quantum) tightens
// as you zoom in. Document units are meters; at a typical fit zoom this
// lands on 1, not the old 18px rule's 2–5.
grid_step :: proc(zoom: f32) -> f32 {
	e := f32(0.001)
	for e < 10000 {
		if e * zoom >= 8 {return e}
		if e * 2 * zoom >= 8 {return e * 2}
		if e * 5 * zoom >= 8 {return e * 5}
		e *= 10
	}
	return e
}

// --- snapping --------------------------------------------------------------------

// snap_point — nearest other-component point within SNAP_PX wins, else the
// grid. `exclude_sel` skips selected components (their points are moving).
snap_point :: proc(ed: ^Editor, w: [2]f32, grid_minor: f32, exclude_sel: bool) -> [2]f32 {
	if !ed.snap {return w}
	zoom := ed.cv.cam.zoom
	best := SNAP_PX / zoom
	out := [2]f32{math.round(w.x / grid_minor) * grid_minor, math.round(w.y / grid_minor) * grid_minor}
	for &c, i in ed.doc.components {
		if exclude_sel && is_selected(ed, i32(i)) {continue}
		for &p in c.points {
			d := linalg.length(p.pos - w)
			if d < best {
				best = d
				out = p.pos
			}
		}
	}
	return out
}

// --- picking --------------------------------------------------------------------

// pick_component — topmost (z-order) component within tolerance: inside a
// closed fill, near an open spine, or near a point glyph.
pick_component :: proc(ed: ^Editor, w: [2]f32) -> i32 {
	tol := PICK_PX / ed.cv.cam.zoom
	order := z_sorted_indices(&ed.doc)
	for k := len(order) - 1; k >= 0; k -= 1 {
		i := order[k]
		c := &ed.doc.components[i]
		cache := cache_get(ed, int(i))
		switch c.kind {
		case .Sector, .Solid, .Bridge, .Cliff:
			if len(cache.flat) >= 3 && engine.polygon_sdist(cache.flat[:], w) < tol {return i}
		case .Path:
			if polyline_dist(cache.flat[:], false, w) < tol {return i}
		case .Hint:
			if len(c.points) == 1 {
				if linalg.length(c.points[0].pos - w) < tol {return i}
			} else if polyline_dist(cache.flat[:], false, w) < tol {
				return i
			}
		case .Marker:
			r := max(c.scale, tol)
			if linalg.length(c.points[0].pos - w) < r + tol {return i}
		}
	}
	return -1
}

polyline_dist :: proc(pts: [][2]f32, closed: bool, w: [2]f32) -> f32 {
	if len(pts) == 0 {return max(f32)}
	if len(pts) == 1 {return linalg.length(pts[0] - w)}
	best := max(f32)
	n := len(pts)
	last := closed ? n : n - 1
	for i in 0 ..< last {
		best = min(best, seg_dist(w, pts[i], pts[(i + 1) % n]))
	}
	return best
}

seg_dist :: proc(p, a, b: [2]f32) -> f32 {
	e := b - a
	t := clamp(linalg.dot(p - a, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
	return linalg.length(p - (a + e * t))
}

// --- select tool -------------------------------------------------------------------

@(private = "file")
select_input :: proc(ed: ^Editor, hovered: bool, mouse, mouse_w: [2]f32, grid_minor: f32) {
	cv := &ed.cv
	io := imgui.GetIO()
	zoom := cv.cam.zoom

	if hovered && cv.drag == .None && imgui.IsMouseClicked(.Left) && !imgui.IsKeyDown(.Space) {
		hit := pick_component(ed, mouse_w)
		cv.press_hit = hit
		cv.press_shift = io.KeyShift
		cv.drag_start = mouse_w
		cv.drag_moved = false
		cv.pending_click = true
		if hit >= 0 {
			if !is_selected(ed, hit) {
				if io.KeyShift {select_toggle(ed, hit)} else {select_only(ed, hit)}
				cv.pending_click = false // selection already applied
			}
			cv.drag = .Move
			capture_orig(ed)
			cv.drag_ref = nearest_comp_point(ed, hit, mouse_w)
		} else {
			cv.drag = .Rubber
			cv.rubber_a = mouse_w
			cv.rubber_b = mouse_w
		}
	}

	#partial switch cv.drag {
	case .Move:
		delta := mouse_w - cv.drag_start
		if !cv.drag_moved && linalg.length(delta) * zoom > CLICK_PX {
			cv.drag_moved = true
			editor_undo_push(ed)
		}
		if cv.drag_moved {
			target := snap_point(ed, cv.drag_ref + delta, grid_minor, true)
			apply_move(ed, target - cv.drag_ref)
			editor_touch(ed)
		}
		if !imgui.IsMouseDown(.Left) {
			if !cv.drag_moved && cv.pending_click && cv.press_hit >= 0 {
				// click on an already-selected component: collapse / shift-toggle
				if cv.press_shift {select_toggle(ed, cv.press_hit)} else {select_only(ed, cv.press_hit)}
			}
			end_drag(cv)
		}
	case .Rubber:
		cv.rubber_b = mouse_w
		if !imgui.IsMouseDown(.Left) {
			lo := linalg.min(cv.rubber_a, cv.rubber_b)
			hi := linalg.max(cv.rubber_a, cv.rubber_b)
			if linalg.length(hi - lo) * zoom <= CLICK_PX {
				if !io.KeyShift {select_only(ed, -1)}
			} else {
				if !io.KeyShift {select_only(ed, -1)}
				for &c, i in ed.doc.components {
					if len(c.points) == 0 {continue}
					all_in := true
					for &p in c.points {
						if p.pos.x < lo.x || p.pos.x > hi.x || p.pos.y < lo.y || p.pos.y > hi.y {
							all_in = false
							break
						}
					}
					if all_in && !is_selected(ed, i32(i)) {
						append(&ed.sel, i32(i))
						ed.primary = i32(i)
					}
				}
			}
			end_drag(cv)
		}
	}
}

@(private = "file")
end_drag :: proc(cv: ^Canvas2D) {
	cv.drag = .None
	cv.drag_moved = false
	cv.pending_click = false
	cv.press_hit = -1
	cv.drag_node = -1
}

// canvas_cancel_drag — the "document structure changed" chokepoint: any drag
// in flight references components/nodes by index (orig_pts, drag_node), so
// undo/redo/delete/open must kill it before those indices go stale.
canvas_cancel_drag :: proc(cv: ^Canvas2D) {
	if cv.drag != .Pan {end_drag(cv)}
	for &o in cv.orig_pts {delete(o.pts)}
	clear(&cv.orig_pts)
}

@(private = "file")
capture_orig :: proc(ed: ^Editor) {
	cv := &ed.cv
	for &o in cv.orig_pts {delete(o.pts)}
	clear(&cv.orig_pts)
	for s in ed.sel {
		o := Orig_Points{comp = s}
		for &p in ed.doc.components[s].points {
			append(&o.pts, Doc_Point_Pos{p.pos, p.handle_in, p.handle_out})
		}
		append(&cv.orig_pts, o)
	}
}

@(private = "file")
apply_move :: proc(ed: ^Editor, delta: [2]f32) {
	for &o in ed.cv.orig_pts {
		comp := &ed.doc.components[o.comp]
		for k in 0 ..< min(len(o.pts), len(comp.points)) {
			comp.points[k].pos = o.pts[k].pos + delta
		}
	}
}

@(private = "file")
nearest_comp_point :: proc(ed: ^Editor, i: i32, w: [2]f32) -> [2]f32 {
	c := &ed.doc.components[i]
	best := max(f32)
	out := w
	for &p in c.points {
		d := linalg.length(p.pos - w)
		if d < best {
			best = d
			out = p.pos
		}
	}
	return out
}

// --- node tool ----------------------------------------------------------------------

node_selected :: proc(ed: ^Editor, i: i32) -> bool {
	for s in ed.node_sel {if s == i {return true}}
	return false
}

@(private = "file")
node_input :: proc(ed: ^Editor, hovered: bool, mouse, mouse_w: [2]f32, grid_minor: f32) {
	cv := &ed.cv
	io := imgui.GetIO()
	zoom := cv.cam.zoom
	tol := NODE_PX / zoom

	if ed.primary < 0 || ed.doc.components[ed.primary].kind == .Marker {
		// no editable primary: clicking picks one
		if hovered && imgui.IsMouseClicked(.Left) {
			if hit := pick_component(ed, mouse_w); hit >= 0 {select_only(ed, hit)}
		}
		return
	}
	comp := &ed.doc.components[ed.primary]

	if hovered && cv.drag == .None && imgui.IsMouseClicked(.Left) && !imgui.IsKeyDown(.Space) {
		// handle knobs of selected nodes take priority
		for s in ed.node_sel {
			p := &comp.points[s]
			if p.handle_out != {} && linalg.length(p.pos + p.handle_out - mouse_w) < tol {
				cv.drag = .Handle_Out
				cv.drag_node = s
				editor_undo_push(ed)
				return
			}
			if p.handle_in != {} && linalg.length(p.pos + p.handle_in - mouse_w) < tol {
				cv.drag = .Handle_In
				cv.drag_node = s
				editor_undo_push(ed)
				return
			}
		}
		// then nodes
		node := i32(-1)
		best := tol
		for &p, k in comp.points {
			d := linalg.length(p.pos - mouse_w)
			if d < best {
				best = d
				node = i32(k)
			}
		}
		if node >= 0 {
			cv.press_shift = io.KeyShift
			cv.pending_click = true
			cv.drag_node = node
			if !node_selected(ed, node) {
				if !io.KeyShift {clear(&ed.node_sel)}
				append(&ed.node_sel, node)
				cv.pending_click = false
			}
			cv.drag = .Node
			cv.drag_start = mouse_w
			cv.drag_moved = false
			capture_orig_primary(ed)
			cv.drag_ref = comp.points[node].pos
			return
		}
		// double-click a segment: insert a node there
		if imgui.IsMouseDoubleClicked(.Left) {
			if seg, t, ok := nearest_segment(ed, ed.primary, mouse_w, PICK_PX / zoom); ok {
				editor_undo_push(ed)
				insert_node(comp, seg, t)
				clear(&ed.node_sel)
				append(&ed.node_sel, i32(seg) + 1)
				editor_touch(ed)
				return
			}
		}
		// otherwise: switch primary or clear
		if hit := pick_component(ed, mouse_w); hit >= 0 && hit != ed.primary {
			select_only(ed, hit)
		} else if hit < 0 {
			clear(&ed.node_sel)
		}
	}

	#partial switch cv.drag {
	case .Node:
		delta := mouse_w - cv.drag_start
		if !cv.drag_moved && linalg.length(delta) * zoom > CLICK_PX {
			cv.drag_moved = true
			editor_undo_push(ed)
		}
		if cv.drag_moved {
			target := snap_point(ed, cv.drag_ref + delta, grid_minor, true)
			d := target - cv.drag_ref
			if len(cv.orig_pts) > 0 {
				o := &cv.orig_pts[0]
				for s in ed.node_sel {
					if int(s) < len(o.pts) {
						comp.points[s].pos = o.pts[s].pos + d
					}
				}
			}
			for s in ed.node_sel {engine.auto_tangents_around(comp, int(s))}
			editor_touch(ed)
		}
		if !imgui.IsMouseDown(.Left) {
			if !cv.drag_moved && cv.pending_click && cv.drag_node >= 0 {
				if cv.press_shift {
					for s, k in ed.node_sel {
						if s == cv.drag_node {unordered_remove(&ed.node_sel, k);break}
					}
				} else {
					clear(&ed.node_sel)
					append(&ed.node_sel, cv.drag_node)
				}
			}
			end_drag(cv)
		}
	case .Handle_In, .Handle_Out:
		p := &comp.points[cv.drag_node]
		h := snap_point(ed, mouse_w, grid_minor, true) - p.pos
		if p.mode == .Auto {p.mode = .Smooth}
		if io.KeyCtrl {p.mode = .Corner}
		if cv.drag == .Handle_Out {
			p.handle_out = h
			if p.mode == .Smooth {
				l := linalg.length(p.handle_in)
				hl := linalg.length(h)
				if l == 0 {l = hl}
				if hl > 1e-6 {p.handle_in = -h / hl * l}
			}
		} else {
			p.handle_in = h
			if p.mode == .Smooth {
				l := linalg.length(p.handle_out)
				hl := linalg.length(h)
				if l == 0 {l = hl}
				if hl > 1e-6 {p.handle_out = -h / hl * l}
			}
		}
		editor_touch(ed)
		if !imgui.IsMouseDown(.Left) {end_drag(cv)}
	}
}

@(private = "file")
capture_orig_primary :: proc(ed: ^Editor) {
	cv := &ed.cv
	for &o in cv.orig_pts {delete(o.pts)}
	clear(&cv.orig_pts)
	o := Orig_Points{comp = ed.primary}
	for &p in ed.doc.components[ed.primary].points {
		append(&o.pts, Doc_Point_Pos{p.pos, p.handle_in, p.handle_out})
	}
	append(&cv.orig_pts, o)
}

// nearest_segment — closest source segment of a component + the arc-length
// parameter along it, from the flattened cache (seg_start maps runs back to
// source segments).
@(private = "file")
nearest_segment :: proc(ed: ^Editor, ci: i32, w: [2]f32, tol: f32) -> (seg: int, t: f32, ok: bool) {
	c := &ed.doc.components[ci]
	cache := cache_get(ed, int(ci))
	flat := cache.flat[:]
	ns := len(cache.seg_start)
	if ns == 0 || len(flat) < 2 {return}
	best := tol
	for s in 0 ..< ns {
		lo := int(cache.seg_start[s])
		hi := s + 1 < ns ? int(cache.seg_start[s + 1]) : len(flat) - 1
		// wrap run for the closing segment of a closed shape
		count := hi - lo
		if c.closed && s == ns - 1 {count = len(flat) - lo}
		acc := f32(0)
		total := f32(0)
		best_local_at := f32(-1)
		for k in 0 ..< count {
			a := flat[(lo + k) % len(flat)]
			b := flat[(lo + k + 1) % len(flat)]
			d := seg_dist(w, a, b)
			seg_len := linalg.length(b - a)
			if d < best {
				best = d
				// param within this sub-segment
				e := b - a
				tt := clamp(linalg.dot(w - a, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
				best_local_at = acc + tt * seg_len
				seg = s
				ok = true
			}
			acc += seg_len
			total = acc
		}
		if ok && seg == s && best_local_at >= 0 && total > 1e-9 {
			t = best_local_at / total
		}
	}
	return
}

// insert_node splits segment `seg` of the component at parameter t
// (de Casteljau for curved segments), shifting edge tags after it.
insert_node :: proc(comp: ^engine.Component, seg: int, t: f32) {
	n := len(comp.points)
	a := &comp.points[seg]
	b := &comp.points[(seg + 1) % n]
	np: engine.Doc_Point
	if a.handle_out == {} && b.handle_in == {} {
		np.pos = math.lerp(a.pos, b.pos, [2]f32{t, t})
		np.mode = .Corner
	} else {
		p0 := a.pos
		p1 := a.pos + a.handle_out
		p2 := b.pos + b.handle_in
		p3 := b.pos
		q0 := math.lerp(p0, p1, [2]f32{t, t})
		q1 := math.lerp(p1, p2, [2]f32{t, t})
		q2 := math.lerp(p2, p3, [2]f32{t, t})
		r0 := math.lerp(q0, q1, [2]f32{t, t})
		r1 := math.lerp(q1, q2, [2]f32{t, t})
		m := math.lerp(r0, r1, [2]f32{t, t})
		a.handle_out = q0 - p0
		b.handle_in = q2 - p3
		np.pos = m
		np.mode = .Smooth
		np.handle_in = r0 - m
		np.handle_out = r1 - m
	}
	// carry the source point's per-point attrs (width/floor/ceiling/h lerp)
	np.width = math.lerp(a.width, b.width, t)
	np.floor = math.lerp(a.floor, b.floor, t)
	np.ceiling = a.ceiling
	np.h = math.lerp(a.h, b.h, t)
	inject_at(&comp.points, seg + 1, np)
	for &tag in comp.edge_tags {
		if int(tag.segment) > seg {tag.segment += 1}
	}
}

@(private = "file")
inject_at :: proc(pts: ^[dynamic]engine.Doc_Point, at: int, p: engine.Doc_Point) {
	append(pts, p)
	for i := len(pts) - 1; i > at; i -= 1 {
		pts[i] = pts[i - 1]
	}
	pts[at] = p
}

canvas_delete_nodes :: proc(ed: ^Editor) {
	if ed.primary < 0 || len(ed.node_sel) == 0 {return}
	comp := &ed.doc.components[ed.primary]
	min_pts := comp.closed ? 3 : (comp.kind == .Hint || comp.kind == .Marker ? 1 : 2)
	if len(comp.points) <= min_pts {return} // nothing deletable — no undo entry
	editor_undo_push(ed)
	// descending order keeps indices valid
	for len(ed.node_sel) > 0 && len(comp.points) > min_pts {
		hi := i32(-1)
		hi_k := -1
		for s, k in ed.node_sel {
			if s > hi {
				hi = s
				hi_k = k
			}
		}
		unordered_remove(&ed.node_sel, hi_k)
		if int(hi) >= len(comp.points) {continue}
		ordered_remove(&comp.points, int(hi))
		// edge tags: drop the tag on the removed segment, shift later ones
		for k := len(comp.edge_tags) - 1; k >= 0; k -= 1 {
			tag := &comp.edge_tags[k]
			if int(tag.segment) == int(hi) {
				ordered_remove(&comp.edge_tags, k)
			} else if int(tag.segment) > int(hi) {
				tag.segment -= 1
			}
		}
		engine.auto_tangents_around(comp, int(hi))
	}
	clear(&ed.node_sel)
	editor_touch(ed)
}

// --- draw tools --------------------------------------------------------------------

// The single source of tool→shape truth: every draw-tool predicate goes
// through these two, so adding a kind can't miss a call site again (the
// Cliff tool shipped invisible because a hand-written list here omitted it).
tool_is_draw :: proc(t: Tool_Mode) -> bool {
	#partial switch t {
	case .Draw_Sector, .Draw_Path, .Draw_Solid, .Draw_Bridge, .Draw_Cliff, .Draw_Hint, .Draw_Marker:
		return true
	}
	return false
}

tool_draws_closed :: proc(t: Tool_Mode) -> bool {
	#partial switch t {
	case .Draw_Sector, .Draw_Solid, .Draw_Bridge, .Draw_Cliff:
		return true
	}
	return false
}

@(private = "file")
draw_input :: proc(ed: ^Editor, hovered: bool, mouse_w: [2]f32, grid_minor: f32) {
	if !hovered {return}
	cv := &ed.cv
	if !imgui.IsMouseClicked(.Left) || imgui.IsKeyDown(.Space) {return}
	w := snap_point(ed, mouse_w, grid_minor, false)
	io := imgui.GetIO()

	if ed.tool == .Draw_Marker {
		editor_undo_push(ed)
		c: engine.Component
		c.kind = .Marker
		c.class = engine.name32("model")
		c.scale = 1
		c.seed = editor_next_seed(ed)
		pt: engine.Doc_Point
		pt.pos = w
		append(&c.points, pt)
		append(&ed.doc.components, c)
		renumber_z(ed)
		select_only(ed, i32(len(ed.doc.components) - 1))
		editor_touch(ed)
		return
	}

	// clicking the first point closes (≥3 points)
	if tool_draws_closed(ed.tool) && len(ed.draw_pts) >= 3 &&
	   linalg.length(w - ed.draw_pts[0].pos) < NODE_PX / cv.cam.zoom {
		canvas_commit_draw(ed)
		return
	}
	p: engine.Doc_Point
	p.pos = w
	p.mode = io.KeyCtrl ? engine.Point_Mode.Corner : engine.Point_Mode.Auto
	switch ed.tool {
	case .Draw_Path:
		p.width = 2
		p.ceiling = engine.SKY // open-air route; floor = offset 0 rides the surface
	case .Draw_Hint:
		p.mode = .Corner
		// fall-line node; height h authored in the sidebar (no radius, §3)
	case .Draw_Sector, .Draw_Solid, .Draw_Bridge, .Draw_Cliff, .Draw_Marker, .Select, .Node:
	}
	append(&ed.draw_pts, p)
}

canvas_commit_draw :: proc(ed: ^Editor) {
	defer clear(&ed.draw_pts)
	n := len(ed.draw_pts)
	if (tool_draws_closed(ed.tool) && n < 3) || (ed.tool == .Draw_Path && n < 2) || n < 1 {return}

	editor_undo_push(ed)
	c: engine.Component
	c.seed = editor_next_seed(ed)
	c.mat_floor = engine.name32("dirt")
	c.mat_wall = engine.name32("rock")
	c.mat_ceiling = engine.name32("rock")
	#partial switch ed.tool {
	case .Draw_Sector:
		c.kind = .Sector
		c.closed = true
		c.base = 0
		c.ceiling = engine.SKY
		c.blend_radius = 1.5
	case .Draw_Solid:
		c.kind = .Solid
		c.closed = true
		c.base = 2
		c.blend_radius = 0.5
	case .Draw_Bridge:
		// deck spans once bear edges are tagged; base is the flat fallback.
		// Low blend: a thin slab melts fast under a big smooth-min radius.
		c.kind = .Bridge
		c.closed = true
		c.base = 4
		c.thickness = 1
		c.blend_radius = 0.3
	case .Draw_Cliff:
		// vertical rock column: flat top at base, hard walls (no blend/noise)
		c.kind = .Cliff
		c.closed = true
		c.base = 6
	case .Draw_Path:
		c.kind = .Path
		c.base = 0
		c.ceiling = engine.SKY
	case .Draw_Hint:
		c.kind = .Hint
	}
	append(&c.points, ..ed.draw_pts[:])
	for i in 0 ..< len(c.points) {engine.auto_tangents(&c, i)}
	append(&ed.doc.components, c)
	renumber_z(ed)
	select_only(ed, i32(len(ed.doc.components) - 1))
	editor_touch(ed)
}

// --- rendering -------------------------------------------------------------------

@(private = "file")
render_grid :: proc(cv: ^Canvas2D, origin, size: [2]f32, minor: f32) {
	lo := px_to_world(cv.cam, origin, origin, size)
	hi := px_to_world(cv.cam, origin + size, origin, size)
	px := 1.0 / cv.cam.zoom
	major := minor * 5

	minor_col := rgba(255, 255, 255, 9)
	major_col := rgba(255, 255, 255, 20)
	axis_col := rgba(255, 255, 255, 46)

	x := math.floor(lo.x / minor) * minor
	for ; x <= hi.x; x += minor {
		is_major := math.abs(math.mod(x, major)) < minor * 0.5 || math.abs(math.mod(x, major)) > major - minor * 0.5
		cv_line(cv, {x, lo.y}, {x, hi.y}, px, is_major ? major_col : minor_col)
	}
	y := math.floor(lo.y / minor) * minor
	for ; y <= hi.y; y += minor {
		is_major := math.abs(math.mod(y, major)) < minor * 0.5 || math.abs(math.mod(y, major)) > major - minor * 0.5
		cv_line(cv, {lo.x, y}, {hi.x, y}, px, is_major ? major_col : minor_col)
	}
	if lo.x < 0 && hi.x > 0 {cv_line(cv, {0, lo.y}, {0, hi.y}, px * 1.5, axis_col)}
	if lo.y < 0 && hi.y > 0 {cv_line(cv, {lo.x, 0}, {hi.x, 0}, px * 1.5, axis_col)}
}

@(private = "file")
render_document :: proc(ed: ^Editor) {
	cv := &ed.cv
	px := 1.0 / cv.cam.zoom
	order := z_sorted_indices(&ed.doc)
	for i in order {
		c := &ed.doc.components[i]
		cache := cache_get(ed, int(i))
		sel := is_selected(ed, i)
		hue := engine.comp_hue(c.kind, c.seed, int(i))
		fill := hsv_rgba(hue, 0.55, 0.85, sel ? 96 : 56)
		line := hsv_rgba(hue, 0.6, 1.0, sel ? 255 : 170)
		lw := (sel ? f32(2.2) : 1.4) * px

		switch c.kind {
		case .Sector, .Solid, .Bridge, .Cliff:
			for k := 0; k + 2 < len(cache.tris); k += 3 {
				cv_tri(cv, cache.flat[cache.tris[k]], cache.flat[cache.tris[k + 1]], cache.flat[cache.tris[k + 2]], fill)
			}
			cv_polyline(cv, cache.flat[:], true, lw, line, px)
			render_edge_tags(ed, i, cache)
		case .Path:
			cv_polyline(cv, cache.flat[:], c.closed, lw * 1.3, line, px)
			for &p in c.points {
				if p.width > 0 {cv_ring(cv, p.pos, p.width, px, hsv_rgba(hue, 0.5, 0.9, 60))}
			}
		case .Hint:
			// a fall-line: just the crest polyline + per-node height diamonds.
			// No radius disc — the tilt fills the shape it overlaps (§3).
			hcol := hsv_rgba(hue, 0.55, 1.0, sel ? 255 : 190)
			if len(c.points) > 1 {
				cv_polyline(cv, cache.flat[:], false, px, hcol)
			}
			for &p in c.points {
				cv_diamond(cv, p.pos, 5 * px, hcol)
			}
		case .Marker:
			mcol := hsv_rgba(hue, 0.7, 1.0, sel ? 255 : 200)
			p := c.points[0].pos
			r := max(c.scale, 7 * px)
			cv_ring(cv, p, r, 1.4 * px, mcol)
			cv_circle_fill(cv, p, 2.2 * px, mcol)
			yaw := math.to_radians(c.yaw)
			cv_line(cv, p, p + [2]f32{math.cos(yaw), math.sin(yaw)} * r * 1.35, 1.4 * px, mcol)
			if c.cover {cv_ring(cv, p, r * 0.6, px, mcol)}
		}
	}
}


@(private = "file")
render_edge_tags :: proc(ed: ^Editor, ci: i32, cache: ^Comp_Cache) {
	cv := &ed.cv
	c := &ed.doc.components[ci]
	if len(c.edge_tags) == 0 || len(cache.seg_start) == 0 {return}
	px := 1.0 / cv.cam.zoom
	nf := len(cache.flat)
	ns := len(cache.seg_start)
	for &tag in c.edge_tags {
		s := int(tag.segment)
		if s < 0 || s >= ns {continue}
		col: [4]u8
		switch tag.kind {
		case .Ramp:
			col = rgba(110, 230, 130, 220)
		case .Cliff:
			col = rgba(240, 90, 70, 220)
		case .Portal:
			col = rgba(90, 210, 240, 220)
		case .Bear:
			col = rgba(250, 200, 90, 220)
		case .Bleed:
			col = rgba(180, 120, 240, 220)
		case .None:
			continue
		}
		lo := int(cache.seg_start[s])
		count := s + 1 < ns ? int(cache.seg_start[s + 1]) - lo : nf - lo
		for k in 0 ..< count {
			a := cache.flat[(lo + k) % nf]
			b := cache.flat[(lo + k + 1) % nf]
			cv_line(cv, a, b, 3 * px, col, px)
		}
	}
}

@(private = "file")
render_node_overlay :: proc(ed: ^Editor) {
	if ed.tool != .Node || ed.primary < 0 {return}
	cv := &ed.cv
	c := &ed.doc.components[ed.primary]
	if c.kind == .Marker {return}
	px := 1.0 / cv.cam.zoom

	knob := rgba(255, 190, 90, 255)
	sel_col := rgba(255, 170, 40, 255)
	node_col := rgba(200, 220, 255, 230)

	for &p, k in c.points {
		selected := node_selected(ed, i32(k))
		if selected {
			// handle sticks + knobs
			if p.handle_in != {} {
				cv_line(cv, p.pos, p.pos + p.handle_in, px, rgba(255, 190, 90, 160))
				cv_circle_fill(cv, p.pos + p.handle_in, 3 * px, knob, 12)
			}
			if p.handle_out != {} {
				cv_line(cv, p.pos, p.pos + p.handle_out, px, rgba(255, 190, 90, 160))
				cv_circle_fill(cv, p.pos + p.handle_out, 3 * px, knob, 12)
			}
		}
		col := selected ? sel_col : node_col
		switch p.mode {
		case .Corner:
			cv_square(cv, p.pos, 3.4 * px, col)
		case .Smooth:
			cv_circle_fill(cv, p.pos, 3.6 * px, col, 14)
		case .Auto:
			cv_circle_fill(cv, p.pos, 2.6 * px, col, 12)
		}
	}
}

@(private = "file")
render_draw_preview :: proc(ed: ^Editor, mouse_w: [2]f32, grid_minor: f32) {
	cv := &ed.cv
	px := 1.0 / cv.cam.zoom
	if !tool_is_draw(ed.tool) {return}

	w := snap_point(ed, mouse_w, grid_minor, false)
	// snap cursor cross
	cross := 5 * px
	ccol := rgba(255, 255, 255, 150)
	cv_line(cv, w - {cross, 0}, w + {cross, 0}, px, ccol)
	cv_line(cv, w - {0, cross}, w + {0, cross}, px, ccol)

	if len(ed.draw_pts) == 0 {return}
	col := rgba(255, 230, 120, 230)
	pts := make([dynamic][2]f32, context.temp_allocator)
	for &p in ed.draw_pts {append(&pts, p.pos)}
	cv_polyline(cv, pts[:], false, 1.5 * px, col, px)
	cv_line(cv, pts[len(pts) - 1], w, 1.5 * px, rgba(255, 230, 120, 120), px)
	if tool_draws_closed(ed.tool) && len(pts) >= 3 {
		cv_line(cv, w, pts[0], px, rgba(255, 230, 120, 60))
		cv_ring(cv, pts[0], NODE_PX * px, px, rgba(255, 230, 120, 160))
	}
	for p in pts {cv_circle_fill(cv, p, 2.5 * px, col, 10)}
}

// render_labels — text on the imgui drawlist over the composited pane: marker
// classes, selected component names, hint heights.
@(private = "file")
render_labels :: proc(ed: ^Editor, dl: ^imgui.DrawList, origin, size: [2]f32) {
	cv := &ed.cv
	for &c, i in ed.doc.components {
		if len(c.points) == 0 {continue}
		sel := is_selected(ed, i32(i))
		#partial switch c.kind {
		case .Marker:
			if cv.cam.zoom < 1.2 && !sel {continue}
			p := world_to_px(cv.cam, c.points[0].pos, origin, size)
			label := fmt.ctprintf("%s", engine.name32_str(&c.class))
			imgui.DrawList_AddText(dl, {p.x + 8, p.y - 16}, 0xffd8f0ff, label)
		case .Hint:
			if !sel {continue}
			for &pt in c.points {
				p := world_to_px(cv.cam, pt.pos, origin, size)
				imgui.DrawList_AddText(dl, {p.x + 7, p.y - 15}, 0xffe0b8f8, fmt.ctprintf("h=%.3g", pt.h))
			}
		case:
			if !sel {continue}
			p := world_to_px(cv.cam, c.points[0].pos, origin, size)
			name := comp_display_name(&ed.doc, i32(i))
			imgui.DrawList_AddText(dl, {p.x + 6, p.y - 18}, 0xffffffff, fmt.ctprintf("%s", name))
		}
	}
	if len(ed.draw_pts) > 0 {
		imgui.DrawList_AddText(
			dl, {origin.x + 10, origin.y + 8}, 0xffc8e8ff,
			fmt.ctprintf("%d point(s) — click to add, Enter to commit, Esc to cancel", len(ed.draw_pts)),
		)
	}
}
