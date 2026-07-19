package tool

// The value/tweak sidebar (DESIGN.md §6): every exotic idea is a field here,
// not a canvas manipulation paradigm. Selection drives it; edits re-evaluate
// the 3D preview live as a value drags (editor_touch + the frame loop's
// budgeted re-eval). Each widget pushes an undo snapshot on activation.

import "core:fmt"
import "core:strings"

import imgui "../../vendor/odin-imgui"

import "../engine"

sidebar_draw :: proc(ed: ^Editor) {
	imgui.PushStyleVarImVec2(.WindowPadding, {8, 8})
	defer imgui.PopStyleVar()

	if imgui.CollapsingHeader("Components", {.DefaultOpen}) {
		component_list(ed)
	}
	if ed.primary >= 0 && int(ed.primary) < len(ed.doc.components) {
		if imgui.CollapsingHeader("Attributes", {.DefaultOpen}) {
			component_attrs(ed)
		}
		if ed.tool == .Node && len(ed.node_sel) > 0 {
			if imgui.CollapsingHeader("Node", {.DefaultOpen}) {
				node_attrs(ed)
			}
		}
	}
	if imgui.CollapsingHeader("Evaluation", {.DefaultOpen}) {
		eval_section(ed)
	}
	if imgui.CollapsingHeader("Assets") {
		assets_section(ed)
	}
	if imgui.CollapsingHeader("Topo") {
		topo_section(ed)
	}
	// engine diagnostics (parse warnings, eval skips — editor.odin sink).
	// ### keeps the header's ID stable while the label counts change.
	log_label := fmt.ctprintf(
		len(ed.diag_log) > 0 ? "Log (%d)###log" : "Log###log", len(ed.diag_log),
	)
	if imgui.CollapsingHeader(log_label, ed.diag_errors > 0 ? imgui.TreeNodeFlags{.DefaultOpen} : {}) {
		log_section(ed)
	}
}

@(private = "file")
log_section :: proc(ed: ^Editor) {
	if len(ed.diag_log) == 0 {
		imgui.TextDisabled("no diagnostics")
		return
	}
	if imgui.SmallButton("Clear") {editor_diag_clear(ed)}
	// newest last, like a terminal; repeats collapsed with a ×N suffix
	for &l in ed.diag_log {
		text := l.count > 1 ? fmt.ctprintf("%s  ×%d", l.text, l.count) : fmt.ctprintf("%s", l.text)
		if l.level == .Error {
			imgui.PushStyleColorImVec4(.Text, {1.0, 0.45, 0.4, 1})
		} else {
			imgui.PushStyleColorImVec4(.Text, {0.85, 0.75, 0.5, 1})
		}
		imgui.TextWrapped("%s", text)
		imgui.PopStyleColor()
	}
}

// undo_on_activate / touch_on_edit — the per-widget undo/live-eval pattern.
@(private = "file")
widget_commit :: proc(ed: ^Editor, edited: bool) {
	if imgui.IsItemActivated() {editor_undo_push(ed)}
	if edited {editor_touch(ed)}
}

@(private = "file")
input_name32 :: proc(ed: ^Editor, label: cstring, n: ^engine.Name32) {
	edited := imgui.InputText(label, cstring(&n[0]), engine.NAME32 - 1)
	widget_commit(ed, edited)
}

@(private = "file")
component_list :: proc(ed: ^Editor) {
	order := z_sorted_indices(&ed.doc)
	// topmost first, Inkscape-style
	for k := len(order) - 1; k >= 0; k -= 1 {
		i := order[k]
		c := &ed.doc.components[i]
		imgui.PushIDInt(i)
		label := fmt.ctprintf(
			"%s%s", comp_display_name(&ed.doc, i),
			c.is_dynamic ? " (dyn)" : "",
		)
		if imgui.Selectable(label, is_selected(ed, i)) {
			if imgui.GetIO().KeyShift {select_toggle(ed, i)} else {select_only(ed, i)}
		}
		imgui.PopID()
	}
	if ed.primary >= 0 {
		if imgui.SmallButton("Raise") {reorder_primary(ed, +1)}
		imgui.SameLine()
		if imgui.SmallButton("Lower") {reorder_primary(ed, -1)}
	}
}

// reorder_primary swaps the primary component one step in the z-order array
// (array order IS z-order after renumber_z).
@(private = "file")
reorder_primary :: proc(ed: ^Editor, dir: int) {
	i := int(ed.primary)
	j := i + dir
	if i < 0 || j < 0 || j >= len(ed.doc.components) {return}
	editor_undo_push(ed)
	ed.doc.components[i], ed.doc.components[j] = ed.doc.components[j], ed.doc.components[i]
	renumber_z(ed)
	// selection follows the moved component
	for &s in ed.sel {
		if s == i32(i) {s = i32(j)} else if s == i32(j) {s = i32(i)}
	}
	ed.primary = i32(j)
	editor_touch(ed)
}

@(private = "file")
component_attrs :: proc(ed: ^Editor) {
	c := &ed.doc.components[ed.primary]
	imgui.PushIDInt(ed.primary)
	defer imgui.PopID()

	imgui.TextUnformatted(fmt.ctprintf("%v  ·  z %d  ·  %d point(s)", c.kind, c.z_order, len(c.points)))
	input_name32(ed, "name", &c.name)

	seed := i32(c.seed)
	if imgui.DragInt("seed", &seed, 1, 0, 1 << 30) {
		c.seed = u32(max(seed, 0))
	}
	widget_commit(ed, imgui.IsItemEdited())

	if c.kind == .Sector || c.kind == .Path || c.kind == .Solid || c.kind == .Bridge || c.kind == .Cliff {
		if c.kind != .Path {
			base_label: cstring = "floor (field base)"
			if c.kind == .Solid {base_label = "top (field base)"}
			if c.kind == .Bridge {base_label = "deck (bear fallback)"}
			if c.kind == .Cliff {base_label = "top height"}
			widget_commit(ed, imgui.DragFloat(base_label, &c.base, 0.1))
		}
		if c.kind == .Bridge {
			widget_commit(ed, imgui.DragFloat("thickness", &c.thickness, 0.05, 0.1, 20))
			widget_commit(ed, imgui.DragFloat("layer weight", &c.weight, 0.1))
		}
		if c.kind == .Sector {
			sky := c.ceiling == engine.SKY
			if imgui.Checkbox("sky ceiling", &sky) {
				editor_undo_push(ed)
				c.ceiling = sky ? engine.SKY : c.base + 8
				editor_touch(ed)
			}
			if !sky {
				widget_commit(ed, imgui.DragFloat("ceiling", &c.ceiling, 0.1))
			}
		}
		if c.kind == .Path {
			// all-points write-through; per-node overrides live in Node mode.
			// floor is an OFFSET from the surface under each point (engine
			// pass 3.5); ceiling is absolute.
			path_all_points(ed, c)
		}
		if c.kind != .Cliff { // Cliff walls are hard & noiseless by definition
			widget_commit(ed, imgui.DragFloat("blend radius", &c.blend_radius, 0.05, 0, 8))
			widget_commit(ed, imgui.DragFloat("noise amp", &c.noise_amp, 0.02, 0, 3))
		}
		dyn := c.is_dynamic
		if imgui.Checkbox("dynamic", &dyn) {
			editor_undo_push(ed)
			c.is_dynamic = dyn
			editor_touch(ed)
		}
		imgui.SeparatorText("materials")
		input_name32(ed, "floor##mat", &c.mat_floor)
		input_name32(ed, "wall##mat", &c.mat_wall)
		input_name32(ed, "ceiling##mat", &c.mat_ceiling)
	}

	if c.kind == .Hint {
		// a Hint is a fall-line: only the per-node height profile (h). No radius
		// — the tilt fills the shape it overlaps (§3). Per-node h in Node mode.
		h_all := c.points[0].h
		if imgui.DragFloat("h (all points)", &h_all, 0.05) {
			for &p in c.points {p.h = h_all}
			editor_touch(ed)
		}
		if imgui.IsItemActivated() {editor_undo_push(ed)}
	}

	if c.kind == .Marker {
		input_name32(ed, "class", &c.class)
		input_name32(ed, "model", &c.model)
		// picker over the scanned assets/models stems; free text above stays
		// authoritative — a model the assets dir can't preview is still legal
		if len(ed.assets.models) > 0 {
			if imgui.BeginCombo("##modelpick", "pick from assets") {
				cur := engine.name32_str(&c.model)
				for &e in ed.assets.models {
					if imgui.Selectable(
						strings.clone_to_cstring(e.stem, context.temp_allocator),
						e.stem == cur,
					) {
						editor_undo_push(ed)
						c.model = engine.name32(e.stem)
						editor_touch(ed)
					}
				}
				imgui.EndCombo()
			}
		}
		widget_commit(ed, imgui.DragFloat("yaw°", &c.yaw, 1, -360, 360))
		widget_commit(ed, imgui.DragFloat("scale", &c.scale, 0.05, 0.05, 20))
		cover := c.cover
		if imgui.Checkbox("cover", &cover) {
			editor_undo_push(ed)
			c.cover = cover
			editor_touch(ed)
		}
		widget_commit(ed, imgui.InputText("args", cstring(&c.args[0]), engine.MARKER_ARGS - 1))
	}

	if c.closed {
		edge_tag_editor(ed, c)
	}
}

@(private = "file")
path_all_points :: proc(ed: ^Editor, c: ^engine.Component) {
	if len(c.points) == 0 {return}
	fl := c.points[0].floor
	if imgui.DragFloat("floor offset (all)", &fl, 0.05) {
		for &p in c.points {p.floor = fl}
		editor_touch(ed)
	}
	if imgui.IsItemActivated() {editor_undo_push(ed)}
	wd := c.points[0].width
	if imgui.DragFloat("width (all)", &wd, 0.05, 0.1, 50) {
		for &p in c.points {p.width = wd}
		editor_touch(ed)
	}
	if imgui.IsItemActivated() {editor_undo_push(ed)}
	sky := c.points[0].ceiling == engine.SKY
	if imgui.Checkbox("sky ceiling", &sky) {
		editor_undo_push(ed)
		nc := sky ? engine.SKY : c.points[0].floor + 4
		c.ceiling = nc // stays the loader default for array-less files
		for &p in c.points {p.ceiling = nc}
		editor_touch(ed)
	}
	if !sky {
		ce := c.points[0].ceiling
		if imgui.DragFloat("ceiling (all, absolute)", &ce, 0.1) {
			c.ceiling = ce
			for &p in c.points {p.ceiling = ce}
			editor_touch(ed)
		}
		if imgui.IsItemActivated() {editor_undo_push(ed)}
	}
}

@(private = "file")
edge_tag_editor :: proc(ed: ^Editor, c: ^engine.Component) {
	imgui.SeparatorText("edge tags")
	seg_max := i32(len(c.points)) - 1
	remove_at := -1
	for &t, k in c.edge_tags {
		imgui.PushIDInt(i32(k))
		imgui.SetNextItemWidth(70)
		widget_commit(ed, imgui.DragInt("##seg", &t.segment, 0.1, 0, seg_max))
		imgui.SameLine()
		imgui.SetNextItemWidth(80)
		kinds := [5]cstring{"ramp", "cliff", "portal", "bear", "bleed"}
		cur: cstring = "?"
		#partial switch t.kind {
		case .Ramp:   cur = kinds[0]
		case .Cliff:  cur = kinds[1]
		case .Portal: cur = kinds[2]
		case .Bear:   cur = kinds[3]
		case .Bleed:  cur = kinds[4]
		}
		if imgui.BeginCombo("##kind", cur) {
			if imgui.Selectable(kinds[0], t.kind == .Ramp) {editor_undo_push(ed);t.kind = .Ramp;editor_touch(ed)}
			if imgui.Selectable(kinds[1], t.kind == .Cliff) {editor_undo_push(ed);t.kind = .Cliff;editor_touch(ed)}
			if imgui.Selectable(kinds[2], t.kind == .Portal) {editor_undo_push(ed);t.kind = .Portal;editor_touch(ed)}
			if imgui.Selectable(kinds[3], t.kind == .Bear) {editor_undo_push(ed);t.kind = .Bear;editor_touch(ed)}
			if imgui.Selectable(kinds[4], t.kind == .Bleed) {editor_undo_push(ed);t.kind = .Bleed;editor_touch(ed)}
			imgui.EndCombo()
		}
		if t.kind == .Portal {
			imgui.SetNextItemWidth(-30)
			widget_commit(ed, imgui.InputText("##args", cstring(&t.args[0]), engine.NAME32 - 1))
			imgui.SameLine()
		} else {
			imgui.SameLine()
		}
		if imgui.SmallButton("x") {remove_at = k}
		imgui.PopID()
	}
	if remove_at >= 0 {
		editor_undo_push(ed)
		ordered_remove(&c.edge_tags, remove_at)
		editor_touch(ed)
	}
	if imgui.SmallButton("+ tag") {
		editor_undo_push(ed)
		append(&c.edge_tags, engine.Edge_Tag{segment = 0, kind = .Ramp})
		editor_touch(ed)
	}
}

@(private = "file")
node_attrs :: proc(ed: ^Editor) {
	c := &ed.doc.components[ed.primary]
	ni := ed.node_sel[len(ed.node_sel) - 1]
	if int(ni) >= len(c.points) {return}
	p := &c.points[ni]
	imgui.PushIDInt(1000 + ni)
	defer imgui.PopID()

	imgui.TextUnformatted(fmt.ctprintf("node %d of %d", ni, len(c.points)))
	if imgui.DragFloat2("pos", &p.pos, 0.1) {
		engine.auto_tangents_around(c, int(ni))
		editor_touch(ed)
	}
	if imgui.IsItemActivated() {editor_undo_push(ed)}

	modes := [3]cstring{"auto", "smooth", "corner"}
	cur := modes[int(p.mode)]
	if imgui.BeginCombo("mode", cur) {
		if imgui.Selectable(modes[0], p.mode == .Auto) {
			editor_undo_push(ed)
			p.mode = .Auto
			engine.auto_tangents(c, int(ni))
			editor_touch(ed)
		}
		if imgui.Selectable(modes[1], p.mode == .Smooth) {
			editor_undo_push(ed)
			if p.handle_in == {} && p.handle_out == {} {
				// seed handles so the knobs exist to grab
				save := p.mode
				p.mode = .Auto
				engine.auto_tangents(c, int(ni))
				p.mode = save
			}
			p.mode = .Smooth
			editor_touch(ed)
		}
		if imgui.Selectable(modes[2], p.mode == .Corner) {
			editor_undo_push(ed)
			p.mode = .Corner
			editor_touch(ed)
		}
		imgui.EndCombo()
	}

	#partial switch c.kind {
	case .Path:
		widget_commit(ed, imgui.DragFloat("width", &p.width, 0.05, 0.1, 50))
		widget_commit(ed, imgui.DragFloat("floor offset", &p.floor, 0.1))
		widget_commit(ed, imgui.DragFloat("ceiling", &p.ceiling, 0.1))
	case .Hint:
		widget_commit(ed, imgui.DragFloat("h", &p.h, 0.05))
	}
}

@(private = "file")
eval_section :: proc(ed: ^Editor) {
	if imgui.SliderFloat("step", &ed.eval_step, 0.25, 2.0, "%.2f") {
		ed.eval_rev = max(u64) // force re-eval at the new resolution
	}
	imgui.DragFloat("tex scale", &ed.texscale, 0.1, 0.5, 64) // view state, no undo/touch
	imgui.Checkbox("auto", &ed.auto_eval)
	imgui.SameLine()
	if imgui.Button("Re-evaluate") {editor_reeval(ed)}
	imgui.TextUnformatted(fmt.ctprintf("eval %.0f ms", ed.eval_ms))
	imgui.TextUnformatted(
		fmt.ctprintf("%d chunks  %d verts  %d tris", len(ed.chunks), ed.mesh_verts, ed.mesh_tris),
	)
	imgui.TextUnformatted(
		fmt.ctprintf("remesh: %d fresh, %d reused", ed.remeshed, ed.reused),
	)
	if ed.ov_sdf {
		imgui.SetNextItemWidth(160)
		imgui.DragFloat("slice y", &ed.sdf_y, 0.1) // view state, no undo/touch
	}
	if ed.world_ok {
		imgui.TextUnformatted(
			fmt.ctprintf(
				"bounds (%.3g %.3g %.3g)..(%.3g %.3g %.3g)",
				ed.world.bounds_min.x, ed.world.bounds_min.y, ed.world.bounds_min.z,
				ed.world.bounds_max.x, ed.world.bounds_max.y, ed.world.bounds_max.z,
			),
		)
	}
}

// assets_section — preview-asset status: where they come from (assets.odin
// header comment: -assets flag > STRATA_ASSETS > assets/ beside the doc) and
// what the scan found. Rescan re-reads the directory AND drops GPU caches.
@(private = "file")
assets_section :: proc(ed: ^Editor) {
	if ed.assets.dir == "" {
		imgui.TextDisabled("none — pass -assets=DIR or put assets/ beside the doc")
		return
	}
	imgui.TextUnformatted(fmt.ctprintf("%s%s", ed.assets.dir, ed.assets.explicit ? " (explicit)" : ""))
	imgui.TextUnformatted(
		fmt.ctprintf("%d texture(s), %d model(s)", len(ed.assets.textures), len(ed.assets.models)),
	)
	if imgui.SmallButton("Rescan") {editor_rescan_assets(ed, ed.assets.dir)}
}

@(private = "file")
topo_section :: proc(ed: ^Editor) {
	if ed.topo_warns > 0 {
		imgui.TextColored({1, 0.55, 0.3, 1}, "%s", fmt.ctprintf("%d warning(s)", ed.topo_warns))
	} else {
		imgui.TextDisabled("no warnings")
	}
	// findings as a clickable list: jump the 2D camera to the pin (§5)
	if ed.topo_ok && len(ed.topo.pins) > 0 {
		PIN_LIST_MAX :: 12
		for pin, k in ed.topo.pins {
			if k >= PIN_LIST_MAX {
				imgui.TextDisabled(fmt.ctprintf("… %d more", len(ed.topo.pins) - PIN_LIST_MAX))
				break
			}
			imgui.PushIDInt(i32(k))
			c := pin_color(pin.kind)
			imgui.PushStyleColorImVec4(.Text, {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, 1})
			if imgui.Selectable(pin_summary(ed, pin)) {
				ed.cv.cam.center = pin.pos
				if pin.comp >= 0 && int(pin.comp) < len(ed.doc.components) {
					select_only(ed, pin.comp)
				}
			}
			imgui.PopStyleColor()
			imgui.PopID()
		}
	}
	if ed.topo_text != "" {
		if imgui.BeginChild("##topo", {0, 220}, {.Borders}) {
			imgui.TextUnformatted(
				strings.clone_to_cstring(ed.topo_text, context.temp_allocator),
			)
		}
		imgui.EndChild()
	}
}
