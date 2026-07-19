package tool

// §5 debug overlays: the 2D pane doubles as the evaluator's debugger. Each
// staged intermediate renders over the document — solved floor-field heatmap
// + derived-wall strokes (from the topo oracle's grid, Topo_Data), a
// horizontal slice of the composed SDF, mesh chunk bounds, and the oracle's
// WARN findings as clickable pins. Toggles live in View > Overlays; the pins
// list in the sidebar's Topo section jumps the camera to a finding.

import "core:fmt"

import imgui "../../vendor/odin-imgui"

import "../engine"

// Sdf_Slice — cached plan grid of sdf_sample(x, sdf_y, z), recomputed when
// the eval or the slice height moves. Never sampled against a stale world
// (a mutated document can shrink under w.order): guards eval_rev == doc_rev.
Sdf_Slice :: struct {
	rev:    u64,
	y:      f32,
	origin: [2]f32, // center of cell (0, 0)
	step:   f32,
	nx, nz: int,
	dist:   []f32,
}

sdf_slice_reset :: proc(s: ^Sdf_Slice) {
	delete(s.dist)
	s^ = {}
}

pin_color :: proc(kind: engine.Topo_Pin_Kind) -> [4]u8 {
	switch kind {
	case .Slope:     return rgba(255, 70, 60, 255)
	case .Clearance: return rgba(255, 160, 50, 255)
	case .Region:    return rgba(225, 90, 230, 255)
	case .Start:     return rgba(255, 230, 80, 255)
	}
	return rgba(255, 255, 255, 255)
}

// render_overlays — world-space tessellation into the canvas vertex list,
// drawn between the document and the node/tool glyphs.
render_overlays :: proc(ed: ^Editor, origin, size: [2]f32) {
	cv := &ed.cv
	vlo := px_to_world(cv.cam, origin, origin, size)
	vhi := px_to_world(cv.cam, origin + size, origin, size)

	if ed.ov_heat && ed.topo_ok {render_heatmap(ed, vlo, vhi)}
	if ed.ov_sdf {
		sdf_slice_ensure(ed)
		render_sdf_slice(ed, vlo, vhi)
	}
	if ed.ov_walls && ed.topo_ok {render_derived_walls(ed, vlo, vhi)}
	if ed.ov_chunks && ed.world_ok {render_chunk_bounds(ed)}
	if ed.ov_pins && ed.topo_ok {render_topo_pins(ed)}
}

// cell_window — grid index range covering the visible world rect (+1 apron).
@(private = "file")
cell_window :: proc(o: [2]f32, step: f32, nx, nz: int, vlo, vhi: [2]f32) -> (x0, x1, z0, z1: int) {
	x0 = clamp(int((vlo.x - o.x) / step) - 1, 0, nx - 1)
	x1 = clamp(int((vhi.x - o.x) / step) + 1, 0, nx - 1)
	z0 = clamp(int((vlo.y - o.y) / step) - 1, 0, nz - 1)
	z1 = clamp(int((vhi.y - o.y) / step) + 1, 0, nz - 1)
	return
}

// render_heatmap — solved walk-surface height per open column, hmin→hmax
// mapped blue→red. Closed columns stay untinted.
@(private = "file")
render_heatmap :: proc(ed: ^Editor, vlo, vhi: [2]f32) {
	cv := &ed.cv
	td := &ed.topo
	x0, x1, z0, z1 := cell_window(td.origin, td.step, td.nx, td.nz, vlo, vhi)
	inv_range := 1.0 / max(td.hmax - td.hmin, 1e-6)
	half := td.step * 0.5
	for z in z0 ..= z1 {
		for x in x0 ..= x1 {
			i := z * td.nx + x
			if !td.open[i] {continue}
			t := (td.floor_v[i] - td.hmin) * inv_range
			c := td.origin + [2]f32{f32(x), f32(z)} * td.step
			col := hsv_rgba(0.62 * (1 - t), 0.85, 0.95, 92)
			cv_rect_fill(cv, c - half, c + half, col)
		}
	}
}

// render_derived_walls — strokes where adjacent open columns disagree by more
// than STEP_UP: exactly where the evaluator derives a wall (§2 "walls are
// never stored"). Different owners meeting here is legitimate geometry; the
// stroke shows WHERE the wall lands either way.
@(private = "file")
render_derived_walls :: proc(ed: ^Editor, vlo, vhi: [2]f32) {
	cv := &ed.cv
	td := &ed.topo
	px := 1.0 / cv.cam.zoom
	col := rgba(255, 170, 60, 230)
	x0, x1, z0, z1 := cell_window(td.origin, td.step, td.nx, td.nz, vlo, vhi)
	half := td.step * 0.5
	for z in z0 ..= z1 {
		for x in x0 ..= x1 {
			i := z * td.nx + x
			if !td.open[i] {continue}
			c := td.origin + [2]f32{f32(x), f32(z)} * td.step
			if x + 1 < td.nx && td.open[i + 1] &&
			   abs(td.floor_v[i + 1] - td.floor_v[i]) > engine.STEP_UP {
				cv_line(cv, c + {half, -half}, c + {half, half}, 2 * px, col, px)
			}
			if z + 1 < td.nz && td.open[i + td.nx] &&
			   abs(td.floor_v[i + td.nx] - td.floor_v[i]) > engine.STEP_UP {
				cv_line(cv, c + {-half, half}, c + {half, half}, 2 * px, col, px)
			}
		}
	}
}

@(private = "file")
sdf_slice_ensure :: proc(ed: ^Editor) {
	if !ed.world_ok || ed.eval_rev != ed.doc_rev {return} // stale world: keep old slice
	s := &ed.slice
	if s.rev == ed.eval_rev && s.y == ed.sdf_y && s.dist != nil {return}
	w := &ed.world
	step := w.step
	nx := max(int((w.bounds_max.x - w.bounds_min.x) / step), 1)
	nz := max(int((w.bounds_max.z - w.bounds_min.z) / step), 1)
	if nx * nz != len(s.dist) {
		delete(s.dist)
		s.dist = make([]f32, nx * nz)
	}
	s.origin = [2]f32{w.bounds_min.x, w.bounds_min.z} + step * 0.5
	s.step = step
	s.nx, s.nz = nx, nz
	for i in 0 ..< nx * nz {
		pos := s.origin + [2]f32{f32(i % nx), f32(i / nx)} * step
		s.dist[i] = engine.sdf_sample(w, {pos.x, ed.sdf_y, pos.y}).dist
	}
	s.rev = ed.eval_rev
	s.y = ed.sdf_y
}

// render_sdf_slice — rock cross-section at sdf_y: solid cells fill warm, the
// zero band (the surface the mesher chases) highlights.
@(private = "file")
render_sdf_slice :: proc(ed: ^Editor, vlo, vhi: [2]f32) {
	cv := &ed.cv
	s := &ed.slice
	if s.dist == nil {return}
	rock := rgba(205, 85, 60, 74)
	band := rgba(255, 220, 90, 150)
	x0, x1, z0, z1 := cell_window(s.origin, s.step, s.nx, s.nz, vlo, vhi)
	half := s.step * 0.5
	for z in z0 ..= z1 {
		for x in x0 ..= x1 {
			d := s.dist[z * s.nx + x]
			in_band := abs(d) < s.step * 0.5
			if d >= 0 && !in_band {continue}
			c := s.origin + [2]f32{f32(x), f32(z)} * s.step
			cv_rect_fill(cv, c - half, c + half, in_band ? band : rock)
		}
	}
}

// render_chunk_bounds — plan footprints of the mesh chunks that survived
// narrow-band rejection (columns dedupe across y).
@(private = "file")
render_chunk_bounds :: proc(ed: ^Editor) {
	cv := &ed.cv
	px := 1.0 / cv.cam.zoom
	col := rgba(90, 200, 240, 90)
	span := ed.world.step * engine.CHUNK_CELLS
	seen := make(map[[2]i32]bool, context.temp_allocator)
	for &c in ed.chunks {
		k := [2]i32{c.cell.x, c.cell.z}
		if k in seen {continue}
		seen[k] = true
		lo := [2]f32{f32(k.x), f32(k.y)} * span
		hi := lo + span
		cv_polyline(cv, {lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}, true, px, col)
	}
}

// render_topo_pins — map-pin glyph (apex on the finding) per WARN.
@(private = "file")
render_topo_pins :: proc(ed: ^Editor) {
	cv := &ed.cv
	px := 1.0 / cv.cam.zoom
	for pin in ed.topo.pins {
		col := pin_color(pin.kind)
		p := pin.pos
		r := 4.5 * px
		cv_tri(cv, p, p + {-r, -2 * r}, p + {r, -2 * r}, col)
		cv_ring(cv, p + {0, -2.7 * r}, 1.6 * px, px, col, 10)
	}
}

// overlay_pin_labels — text for the pins on the imgui drawlist (composited
// over the pane). Skips labels when the finding count would wallpaper the
// view; the sidebar list still names everything.
overlay_pin_labels :: proc(ed: ^Editor, dl: ^imgui.DrawList, origin, size: [2]f32) {
	if !ed.ov_pins || !ed.topo_ok {return}
	if len(ed.topo.pins) > 40 {return}
	for pin in ed.topo.pins {
		p := world_to_px(ed.cv.cam, pin.pos, origin, size)
		c := pin_color(pin.kind)
		// imgui drawlist color is ABGR
		abgr := u32(0xff) << 24 | u32(c.b) << 16 | u32(c.g) << 8 | u32(c.r)
		label: cstring
		switch pin.kind {
		case .Slope:     label = fmt.ctprintf("slope %.3g", pin.val)
		case .Clearance: label = fmt.ctprintf("low headroom")
		case .Region:    label = fmt.ctprintf("region %d (%.0f cells)", pin.id, pin.val)
		case .Start:     label = fmt.ctprintf("start unwalkable")
		}
		imgui.DrawList_AddText(dl, {p.x + 7, p.y - 26}, abgr, label)
	}
}

// pin_summary — one-line description for the sidebar's clickable list.
pin_summary :: proc(ed: ^Editor, pin: engine.Topo_Pin) -> cstring {
	comp := pin.comp >= 0 ? comp_display_name(&ed.doc, pin.comp) : ""
	switch pin.kind {
	case .Slope:
		return fmt.ctprintf("slope %.3g at (%.4g %.4g) on %s", pin.val, pin.pos.x, pin.pos.y, comp)
	case .Clearance:
		return fmt.ctprintf("low headroom at (%.4g %.4g)", pin.pos.x, pin.pos.y)
	case .Region:
		return fmt.ctprintf("region %d unreachable (%.0f cells) at (%.4g %.4g)", pin.id, pin.val, pin.pos.x, pin.pos.y)
	case .Start:
		return fmt.ctprintf("gamestart %s off walkable ground", comp)
	}
	return "?"
}
