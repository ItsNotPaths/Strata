package engine

// The world SDF (DESIGN.md §4): evaluated on demand, never stored. World =
// infinite solid ⊖ voids ⊕ solids, applied in z-order. Each component
// contributes an analytic distance: 2D spline-polygon distance in plan ×
// vertical distance to its band [field(x,y), ceiling].
//
// Overlap = z-order (§1, "later wins per attribute"): each void CARVES its
// band, then FILLS rock back below its floor field (and above its ceiling)
// inside its footprint — so a later, higher shelf overrides an earlier,
// deeper canyon within the intersection, and the derived cliff lands exactly
// on the later shape's drawn outline. (M1 shipped union-of-bands; M2 ramps
// need the designed semantics.)
//
// Blend radius = the smooth-min radius per component (§4): it fillets the
// component's own wall↔floor junction (smooth intersection of plan prism ×
// band slab) AND its junction with earlier geometry. ~0 keeps knife-edged
// masonry. A per-component seeded value-noise displacement breaks the
// extruded look on rock; it is weighted toward steep faces so floors stay
// close to the solved field the topo oracle reasons about.
//
// The composed value is within reject_pad of a conservative lower bound on
// true distance (smooth ops deviate ≤ k/4 per junction, noise ≤ amp); the
// mesher widens its narrow-band chunk rejection by reject_pad.
//
// Ownership: whichever component's op determines the composed value at a
// sample owns it — later components win ties, giving §1's "later wins" for
// materials/provenance.

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"

// SKY_RIM — how far canyon rock rises above the highest sky-ceilinged floor.
// An open-to-sky void has no natural top, so the world AABB (and therefore
// the derived canyon walls) caps this far above the tallest feature.
SKY_RIM :: 8.0

// NOISE_FREQ — base spatial frequency of the rock displacement noise
// (features ~1/NOISE_FREQ world units across).
NOISE_FREQ :: 0.55

// Cliff edge tags (§2) force a wall where the height delta alone wouldn't:
// a rock fin along the tagged segment, growing from whatever is below (like a
// Solid) to CLIFF_HEIGHT above the local floor field — taller than CLEARANCE
// so it always blocks the player.
CLIFF_HEIGHT :: 2.5
CLIFF_THICK :: 0.45 // fin half-thickness in plan

// Eval_Comp — per-component acceleration built once per evaluate: flattened
// outline (+ source-segment map for edge tags), plan AABB, solved height
// field, Hint pins assigned to this shape, resolved material ids.
Eval_Comp :: struct {
	active:     bool, // participates in the static SDF (non-dynamic geometry kinds)
	poly:       [dynamic][2]f32, // closed outline, or the Path centerline
	seg_start:  [dynamic]i32, // source segment s begins at poly[seg_start[s]]
	aabb_min:   [2]f32, // Paths: centerline AABB inflated by max width
	aabb_max:   [2]f32,
	field:      Field, // Sector: floor. Solid/Bridge: top. Path: fmin/fmax only.
	pins:       [dynamic]Field_Pin,
	mat:        [3]u16, // floor/wall/ceiling ids into Eval_World.materials

	// Path sweep acceleration: cumulative arc length per flattened vertex,
	// arc position per SOURCE point (attr lerp runs on source points), total
	// arc (incl. the wrap segment when closed), and the widest half-width.
	arc:        [dynamic]f32,
	pt_arc:     [dynamic]f32,
	arc_total:  f32,
	max_w:      f32,
	// baked effective floor per SOURCE point: the authored per-point floor is
	// an OFFSET riding the resolved surface beneath the point (lowest band —
	// a stream under a bridge follows the ground); absolute in raw rock.
	pt_floor:   [dynamic]f32,

	// incremental re-eval (§6): input digests + padded influence footprint.
	// field_hash covers the harmonic solve's inputs (outline, base, pins,
	// edge tags); attr_hash covers everything else the SDF/mesh reads.
	// Equal hashes against the previous eval ⇒ identical contribution.
	field_hash: u64,
	attr_hash:  u64,
	dirty_min:  [2]f32, // aabb padded by this comp's furthest SDF reach
	dirty_max:  [2]f32,
}

// Eval_World — the evaluated form of a Document. Dynamic components are
// excluded from the static field and listed separately (§4).
Eval_World :: struct {
	doc:           ^Document,
	comps:         []Eval_Comp, // parallel to doc.components
	order:         []i32,       // closed evaluable components, z-order ascending
	step:          f32,
	reject_pad:    f32,      // widen narrow-band rejection: blend + noise slack
	materials:     []Name32, // sorted recipe names; mesh mat = index (texgen contract)
	bounds_min:    [3]f32,   // world-space (x, up, z) meshing bounds
	bounds_max:    [3]f32,
	dynamic_comps: [dynamic]i32, // indices of dynamic components (own islands, §4)

	// incremental re-eval vs the `old` world handed to eval_world_build:
	// dirty_all forces a full re-mesh (no old world, step change, material
	// table drift); otherwise the SDF can only differ from old inside the
	// dirty plan AABB (empty = lo > hi when nothing changed).
	dirty_all:     bool,
	dirty_lo:      [2]f32,
	dirty_hi:      [2]f32,
}

Sdf_Sample :: struct {
	dist:  f32,
	owner: i32, // component index for material/provenance, -1 = base rock
}

// hint_container — the topmost sculptable shape (paint order breaks z ties)
// whose flattened outline contains plan point p, or -1 if p is over raw rock.
// A hint grades whatever surface is on top at p — a Sector's floor, a Solid's
// top, OR a Cliff's own top field — so a fall-line climbing from the room floor
// onto a mesa grades the floor up and the mesa top down to meet it (the wall
// between shrinks to a walkable ramp where the line crosses). Each kind keeps
// its own field and its interior/exterior nature; only Bridges are skipped —
// their deck is a membrane the compiler infers from supports, not a hint target.
hint_container :: proc(w: ^Eval_World, doc: ^Document, p: [2]f32) -> i32 {
	target := i32(-1)
	best_z := min(i32)
	for idx in w.order {
		k := doc.components[idx].kind
		if !doc.components[idx].closed {continue} // Paths can't contain
		if k == .Bridge {continue} // deck is an inferred membrane, not a hint target
		if !w.comps[idx].active {continue} // dynamic comps leave the static field alone
		z := doc.components[idx].z_order
		if z < best_z {continue}
		if polygon_sdist(w.comps[idx].poly[:], p) < 0 {
			target = idx
			best_z = z
		}
	}
	return target
}

// eval_world_build flattens outlines, assigns Hints, solves fields in
// z-order, resolves the material table, and computes meshing bounds.
//
// `old` (the previous eval of the same document, editor §6) turns the build
// incremental: components whose solve inputs hash identically copy their old
// field instead of relaxing, and w.dirty_lo/hi accumulates the plan AABB
// where the composed SDF may differ — mesh_extract_incr reuses every chunk
// outside it. old is only read, never freed; the caller destroys it after.
eval_world_build :: proc(doc: ^Document, step: f32, old: ^Eval_World = nil) -> (w: Eval_World) {
	w.doc = doc
	w.step = step
	w.dirty_all = true
	w.comps = make([]Eval_Comp, len(doc.components))

	mat_names := make([dynamic]Name32, context.temp_allocator)
	add_mat :: proc(names: ^[dynamic]Name32, n: Name32) {
		if n[0] == 0 {return}
		for have in names {if have == n {return}}
		append(names, n)
	}

	// pass 1: flatten geometry, init flat fields, collect materials
	order := make([dynamic]i32)
	any_active := false
	for &comp, i in doc.components {
		ec := &w.comps[i]
		switch comp.kind {
		case .Sector, .Solid, .Bridge, .Cliff:
			if !comp.closed {
				diagf(.Warn, "eval: %s %q is not closed, skipped",
					comp.kind, name32_str(&comp.name))
				continue
			}
			ec.poly = component_flatten(&comp, step * 0.25, &ec.seg_start)
			if len(ec.poly) < 3 {
				diagf(.Warn, "eval: %s %q degenerates to <3 points, skipped",
					comp.kind, name32_str(&comp.name))
				continue
			}
			ec.field = field_init(&comp, ec.poly[:], step)
			ec.aabb_min, ec.aabb_max = polyline_aabb(ec.poly[:])
		case .Path:
			// swept void: the centerline flattens; per-point width/floor/
			// ceiling lerp along it by arc length (path_attrs).
			if len(comp.points) < 2 {
				diagf(.Warn, "eval: Path %q has <2 points, skipped", name32_str(&comp.name))
				continue
			}
			ec.poly = component_flatten(&comp, step * 0.25, &ec.seg_start)
			if len(ec.poly) < 2 {continue}
			acc := f32(0)
			append(&ec.arc, 0)
			for k in 1 ..< len(ec.poly) {
				acc += linalg.length(ec.poly[k] - ec.poly[k - 1])
				append(&ec.arc, acc)
			}
			if comp.closed {acc += linalg.length(ec.poly[0] - ec.poly[len(ec.poly) - 1])}
			ec.arc_total = acc
			for s in ec.seg_start {append(&ec.pt_arc, ec.arc[s])}
			if !comp.closed {append(&ec.pt_arc, ec.arc_total)} // last point
			fl_lo, fl_hi := max(f32), min(f32)
			for &p in comp.points {
				ec.max_w = max(ec.max_w, p.width)
				fl_lo = min(fl_lo, p.floor)
				fl_hi = max(fl_hi, p.floor)
			}
			ec.max_w = max(ec.max_w, 0.05)
			ec.field.fmin, ec.field.fmax = fl_lo, fl_hi // floor range; no lattice
			ec.aabb_min, ec.aabb_max = polyline_aabb(ec.poly[:])
			ec.aabb_min -= ec.max_w
			ec.aabb_max += ec.max_w
		case .Hint, .Marker:
			// Hints feed the field solve below; Markers don't shape geometry.
			continue
		}
		append(&order, i32(i))
		if comp.is_dynamic {
			// meshed as its own island, toggled at runtime — never part
			// of the static field (§4). TODO(M2.5): island meshing.
			append(&w.dynamic_comps, i32(i))
			continue
		}
		ec.active = true
		any_active = true
		add_mat(&mat_names, comp.mat_floor)
		add_mat(&mat_names, comp.mat_wall)
		add_mat(&mat_names, comp.mat_ceiling)
	}

	if !any_active {
		diagf(.Error, "eval: document has no evaluable components")
		delete(order)
		return
	}

	// z-order ascending, document order breaking ties (= paint order)
	{
		Zi :: struct {
			z, i: i32,
		}
		zs := make([]Zi, len(order), context.temp_allocator)
		for idx, j in order {zs[j] = {doc.components[idx].z_order, idx}}
		slice.sort_by(zs, proc(a, b: Zi) -> bool {
			return a.z < b.z || (a.z == b.z && a.i < b.i)
		})
		for z, j in zs {order[j] = z.i}
	}
	w.order = order[:]

	// pass 2: assign each Hint's samples PER-NODE to the topmost sculptable shape
	// the sample sits over (hint_container — any closed kind but Bridge). A
	// fall-line grades whatever surface is on top: crossing from a sector floor
	// onto a mesa hands the high nodes to the Cliff's own top field and the low
	// ones to the sector floor, so the slope stays continuous across the edge.
	// Samples land in each container in source order, so same-`src` runs stay
	// contiguous and field_relax groups them back into a crest polyline.
	all_pins := make([dynamic]Field_Pin, context.temp_allocator)
	for &comp, i in doc.components {
		if comp.kind != .Hint {continue}
		clear(&all_pins)
		hint_samples(&comp, step, &all_pins, i32(i))
		if len(all_pins) == 0 {continue}
		placed := 0
		for pin in all_pins {
			target := hint_container(&w, doc, pin.pos)
			if target < 0 {continue} // sample over raw rock: no floor to tilt
			append(&w.comps[target].pins, pin)
			placed += 1
		}
		if placed == 0 {
			diagf(.Warn, "eval: Hint %q lies over no sculptable shape, ignored",
				name32_str(&comp.name))
		}
	}

	// pass 2.5: input digests + per-comp change flags vs `old`. Hashes cover
	// exactly what the solve/SDF reads, field-by-field (struct padding bytes
	// are not guaranteed zero, so tagged data hashes per member).
	use_old := old != nil && old.step == step && len(old.comps) > 0
	changed := make([]bool, len(w.comps), context.temp_allocator)
	any_changed := false
	for &comp, i in doc.components {
		ec := &w.comps[i]
		fh := hash.fnv64a(mem.slice_to_bytes(ec.poly[:]))
		fh = hash.fnv64a(mem.slice_to_bytes(ec.seg_start[:]), fh)
		base := comp.base
		fh = hash.fnv64a(mem.ptr_to_bytes(&base), fh)
		fh = hash.fnv64a(mem.slice_to_bytes(ec.pins[:]), fh)
		for &p in comp.points {
			// per-point attrs (poly only covers positions): Path bands ride
			// width/floor/ceiling, hint crests ride h/width
			pa := [4]f32{p.width, p.floor, p.ceiling, p.h}
			fh = hash.fnv64a(mem.ptr_to_bytes(&pa), fh)
		}
		ec.field_hash = tags_hash(comp.edge_tags[:], fh)

		Attr_Key :: struct #packed {
			idx:     i32, // z-order ties break on index (§1 paint order)
			z:       i32,
			ceiling: f32,
			blend:   f32,
			noise:   f32,
			thick:   f32,
			weight:  f32,
			seed:    u32,
			kind:    u8,
			dyn:     u8,
			closed:  u8,
		}
		key := Attr_Key {
			i32(i), comp.z_order, comp.ceiling, comp.blend_radius,
			comp.noise_amp, comp.thickness, comp.weight, comp.seed, u8(comp.kind),
			comp.is_dynamic ? 1 : 0, comp.closed ? 1 : 0,
		}
		ah := hash.fnv64a(mem.ptr_to_bytes(&key))
		ah = hash.fnv64a(comp.mat_floor[:], ah)
		ah = hash.fnv64a(comp.mat_wall[:], ah)
		ah = hash.fnv64a(comp.mat_ceiling[:], ah)
		ec.attr_hash = tags_hash(comp.edge_tags[:], ah)

		if len(ec.poly) >= 2 { // 2 = a straight 2-node Path, still active geometry
			// furthest the comp can flip the composed SDF's sign past its
			// outline, mirroring sdf_sample's early-out (d2 − amp − k >
			// |d| + k + 1 skips): amp + 2k + 1, plus a step of surface slack;
			// cliff fins add their plan reach. The chunk-side sampling apron
			// is mesh_extract's margin, not ours.
			pad := comp.noise_amp + comp.blend_radius + step + 1
			for t in comp.edge_tags {
				if t.kind == .Cliff {pad += CLIFF_THICK;break}
			}
			ec.dirty_min = ec.aabb_min - pad
			ec.dirty_max = ec.aabb_max + pad
		}

		oldc: ^Eval_Comp
		if use_old && i < len(old.comps) {oldc = &old.comps[i]}
		c := oldc == nil || oldc.field_hash != ec.field_hash || oldc.attr_hash != ec.attr_hash
		changed[i] = c
		if c && (ec.active || (oldc != nil && oldc.active)) {any_changed = true}
	}

	// pass 3: harmonic field solves, z-order so ramps read solved neighbors.
	// Unchanged fields copy their old solution AT their z turn, so a ramp
	// that does re-solve still reads flat base from not-yet-reached higher-z
	// fields — bit-identical to a from-scratch build.
	for idx in w.order {
		ec := &w.comps[idx]
		if ec.field.samples == nil {continue} // Path: no lattice to solve
		reuse := use_old && int(idx) < len(old.comps) && !changed[idx] &&
			len(old.comps[idx].field.samples) == len(ec.field.samples)
		if reuse && any_changed && comp_reads_neighbors(&doc.components[idx]) {
			// ramp/bear boundaries read neighbor fields the hash can't see
			reuse = false
		}
		if reuse {
			of := &old.comps[idx].field
			copy(ec.field.samples, of.samples)
			ec.field.fmin, ec.field.fmax = of.fmin, of.fmax
			continue
		}
		field_relax(&w, idx)
		if !changed[idx] {
			// inputs hashed equal but the field re-solved (ramp): dirty only
			// if the solution actually moved
			same := use_old && int(idx) < len(old.comps) &&
				len(old.comps[idx].field.samples) == len(ec.field.samples) &&
				mem.compare(
					mem.slice_to_bytes(old.comps[idx].field.samples),
					mem.slice_to_bytes(ec.field.samples),
				) == 0
			changed[idx] = !same
		}
	}

	// pass 3.5: bake Path floors — the authored per-point floor is an offset
	// on the resolved surface beneath that point ("the compiler sets the
	// height from what the point overlaps"); a path through raw rock keeps
	// the value absolute. Runs AFTER the solves so hints/ramps are in, in
	// z-order so stacked paths read lower ones already baked. The lowest
	// band grounds the path (a stream under a bridge rides the streambed).
	for idx in w.order {
		comp := &doc.components[idx]
		if comp.kind != .Path {continue}
		ec := &w.comps[idx]
		fl_lo, fl_hi := max(f32), min(f32)
		bands: [COL_BANDS]Col_Band
		for &p in comp.points {
			eff := p.floor
			if nb := column_resolve_bands(&w, p.pos, &bands, idx); nb > 0 {
				eff = bands[0].floor + p.floor
			}
			append(&ec.pt_floor, eff)
			fl_lo = min(fl_lo, eff)
			fl_hi = max(fl_hi, eff)
		}
		ec.field.fmin, ec.field.fmax = fl_lo, fl_hi
		if !changed[idx] {
			// surface moved under the path? the baked floors say so
			same := use_old && int(idx) < len(old.comps) &&
				len(old.comps[idx].pt_floor) == len(ec.pt_floor) &&
				mem.compare(
					mem.slice_to_bytes(old.comps[idx].pt_floor[:]),
					mem.slice_to_bytes(ec.pt_floor[:]),
				) == 0
			changed[idx] = !same
		}
	}

	// pass 4: material ids, meshing bounds from the SOLVED fields, reject pad
	slice.sort_by(mat_names[:], proc(a, b: Name32) -> bool {
		aa, bb := a, b
		return name32_str(&aa) < name32_str(&bb)
	})
	w.materials = slice.clone(mat_names[:])

	pad := step * FIELD_PAD
	lo2 := [2]f32{max(f32), max(f32)}
	hi2 := [2]f32{min(f32), min(f32)}
	y_lo, y_hi := max(f32), min(f32)
	for idx in w.order {
		ec := &w.comps[idx]
		if !ec.active {continue}
		comp := &w.doc.components[idx]
		ec.mat = {
			mat_id(w.materials, comp.mat_floor),
			mat_id(w.materials, comp.mat_wall),
			mat_id(w.materials, comp.mat_ceiling),
		}
		slack := pad + comp.noise_amp
		lo2 = linalg.min(lo2, ec.aabb_min - slack)
		hi2 = linalg.max(hi2, ec.aabb_max + slack)
		bottom := ec.field.fmin
		if comp.kind == .Bridge {bottom -= comp.thickness}
		y_lo = min(y_lo, bottom - comp.noise_amp)
		top := ec.field.fmax
		if comp.kind == .Sector {
			top = top + SKY_RIM if comp.ceiling == SKY else max(comp.ceiling, top)
		}
		if comp.kind == .Path {
			sky := false
			for &p in comp.points {
				if p.ceiling == SKY {sky = true} else {top = max(top, p.ceiling)}
			}
			if sky {top = max(top, ec.field.fmax + SKY_RIM)}
		}
		for t in comp.edge_tags {
			if t.kind == .Cliff {top = max(top, ec.field.fmax + CLIFF_HEIGHT)}
		}
		y_hi = max(y_hi, top + comp.noise_amp)
		w.reject_pad = max(w.reject_pad, comp.noise_amp + comp.blend_radius * 0.5)
	}

	vpad := step * 3
	w.bounds_min = {lo2.x, y_lo - vpad, lo2.y}
	w.bounds_max = {hi2.x, y_hi + vpad, hi2.y}

	// incremental dirty region: union of changed components' influence
	// footprints, old AND new (a moved shape dirties both places). Material
	// table drift renumbers mesh mat ids globally → full re-mesh.
	if use_old {
		same_mats := len(w.materials) == len(old.materials)
		if same_mats {
			for m, i in w.materials {
				if m != old.materials[i] {same_mats = false;break}
			}
		}
		if same_mats {
			w.dirty_all = false
			dlo := [2]f32{max(f32), max(f32)}
			dhi := [2]f32{-max(f32), -max(f32)}
			for i in 0 ..< len(w.comps) {
				if !changed[i] {continue}
				ec := &w.comps[i]
				if ec.active && len(ec.poly) >= 2 {
					dlo = linalg.min(dlo, ec.dirty_min)
					dhi = linalg.max(dhi, ec.dirty_max)
				}
				if i < len(old.comps) && old.comps[i].active && len(old.comps[i].poly) >= 2 {
					dlo = linalg.min(dlo, old.comps[i].dirty_min)
					dhi = linalg.max(dhi, old.comps[i].dirty_max)
				}
			}
			for i in len(w.comps) ..< len(old.comps) { // deleted components
				if old.comps[i].active && len(old.comps[i].poly) >= 2 {
					dlo = linalg.min(dlo, old.comps[i].dirty_min)
					dhi = linalg.max(dhi, old.comps[i].dirty_max)
				}
			}
			w.dirty_lo, w.dirty_hi = dlo, dhi
		}
	}
	return
}

@(private = "file")
comp_reads_neighbors :: proc(comp: ^Component) -> bool {
	// Bridges infer their abutments from neighbouring supports (surface_height
	// bearing + over_solid_support cull), so their deck must re-solve whenever
	// anything changed — a cliff they bear on can move or change height without
	// touching the bridge's own hash.
	if comp.kind == .Bridge {return true}
	for t in comp.edge_tags {
		if t.kind == .Ramp || t.kind == .Bear {return true}
	}
	return false
}

// tags_hash — FNV over edge tags member-by-member (Edge_Tag has interior
// padding whose bytes are unspecified).
@(private = "file")
tags_hash :: proc(tags: []Edge_Tag, seed: u64) -> u64 {
	h := seed
	for &t in tags {
		seg := t.segment
		h = hash.fnv64a(mem.ptr_to_bytes(&seg), h)
		k := u8(t.kind)
		h = hash.fnv64a(mem.ptr_to_bytes(&k), h)
		h = hash.fnv64a(t.args[:], h)
	}
	return h
}

@(private = "file")
mat_id :: proc(materials: []Name32, n: Name32) -> u16 {
	for m, i in materials {if m == n {return u16(i)}}
	return 0
}

eval_world_destroy :: proc(w: ^Eval_World) {
	for &ec in w.comps {
		delete(ec.poly)
		delete(ec.seg_start)
		delete(ec.pins)
		delete(ec.arc)
		delete(ec.pt_arc)
		delete(ec.pt_floor)
		field_destroy(&ec.field)
	}
	delete(w.comps)
	delete(w.order)
	delete(w.materials)
	delete(w.dynamic_comps)
	w^ = {}
}

// surface_height — the walk-surface height at a plan point: the TOPMOST void
// band's floor ("assume highest"). Used by ramp and bear edges ("the
// neighbor's height", field.odin) and single-band callers; `exclude` skips
// the asking component. Reads fields as currently solved.
surface_height :: proc(w: ^Eval_World, plan: [2]f32, exclude := i32(-1)) -> (h: f32, ok: bool) {
	f, _, _, open := column_resolve(w, plan, exclude)
	return f, open
}

// swept_query — distance from a plan point to a Path's flattened centerline,
// plus the arc-length parameter of the closest point (path_attrs' key).
swept_query :: proc(ec: ^Eval_Comp, closed: bool, p: [2]f32) -> (dist, s: f32) {
	n := len(ec.poly)
	if n == 0 {return 1e9, 0}
	if n == 1 {return linalg.length(p - ec.poly[0]), 0}
	best := max(f32)
	segs := n if closed else n - 1
	for i in 0 ..< segs {
		a := ec.poly[i]
		b := ec.poly[(i + 1) % n]
		e := b - a
		t := clamp(linalg.dot(p - a, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
		v := p - (a + e * t)
		d2 := linalg.dot(v, v)
		if d2 < best {
			best = d2
			la := ec.arc[i]
			lb := ec.arc[i + 1] if i + 1 < n else ec.arc_total
			s = math.lerp(la, lb, t)
		}
	}
	return math.sqrt(best), s
}

// path_attrs — width/floor/ceiling at arc position s, lerped between the
// bracketing SOURCE points. SKY ceilings don't lerp: either end sky = sky.
path_attrs :: proc(comp: ^Component, ec: ^Eval_Comp, s: f32) -> (wd, fl, ce: f32) {
	n := len(comp.points)
	if n == 1 || len(ec.pt_arc) == 0 {
		p := &comp.points[0]
		return max(p.width, 0.05), p.floor, p.ceiling
	}
	j := 0
	for j + 1 < len(ec.pt_arc) && s > ec.pt_arc[j + 1] {j += 1}
	a := &comp.points[j]
	bi := j + 1 if j + 1 < n else (0 if comp.closed else n - 1)
	b := &comp.points[bi]
	s1 := ec.pt_arc[j]
	s2 := ec.pt_arc[j + 1] if j + 1 < len(ec.pt_arc) else ec.arc_total
	t := clamp((s - s1) / (s2 - s1), 0, 1) if s2 > s1 else 0
	wd = max(math.lerp(a.width, b.width, t), 0.05)
	fa, fb := a.floor, b.floor
	if len(ec.pt_floor) == n { // baked surface-relative floors (pass 3.5)
		fa = ec.pt_floor[j]
		fb = ec.pt_floor[bi]
	}
	fl = math.lerp(fa, fb, t)
	if a.ceiling == SKY || b.ceiling == SKY {
		ce = SKY
	} else {
		ce = math.lerp(a.ceiling, b.ceiling, t)
	}
	return
}

COL_BANDS :: 3

Col_Band :: struct {
	floor, ceil: f32,
	owner:       i32,
}

// column_resolve_bands — the vertical VOID intervals at a plan point under
// "later wins" (§1), ascending by floor: a containing Sector/Path REPLACES
// the column with its band; a Solid raises band floors through its top; a
// Bridge slab splits the band it floats in (deck top becomes the upper
// band's floor/owner — walkable above, passable below). At most COL_BANDS
// kept, topmost preferred. Returns the count; 0 = solid rock.
column_resolve_bands :: proc(
	w: ^Eval_World,
	plan: [2]f32,
	bands: ^[COL_BANDS]Col_Band,
	exclude := i32(-1),
) -> (n: int) {
	for idx in w.order {
		if idx == exclude {continue}
		ec := &w.comps[idx]
		if !ec.active {continue}
		if plan.x < ec.aabb_min.x || plan.y < ec.aabb_min.y ||
		   plan.x > ec.aabb_max.x || plan.y > ec.aabb_max.y {continue}
		comp := &w.doc.components[idx]
		switch comp.kind {
		case .Sector:
			if polygon_sdist(ec.poly[:], plan) >= 0 {continue}
			bands[0] = {
				field_sample(&ec.field, plan),
				f32(1e9) if comp.ceiling == SKY else comp.ceiling,
				idx,
			}
			n = 1
		case .Path:
			dc, s := swept_query(ec, comp.closed, plan)
			wd, fl, ce := path_attrs(comp, ec, s)
			if dc - wd >= 0 {continue}
			bands[0] = {fl, f32(1e9) if ce == SKY else ce, idx}
			n = 1
		case .Solid, .Cliff:
			// rock up to the top raises (or swallows) the walkable band; a Cliff
			// is the same, its top being the flat `base` field.
			if n == 0 {continue}
			if polygon_sdist(ec.poly[:], plan) >= 0 {continue}
			top := field_sample(&ec.field, plan)
			m := 0
			for b in 0 ..< n {
				bb := bands[b]
				if bb.ceil <= top {continue} // swallowed by the rock
				if bb.floor < top {
					bb.floor = top
					bb.owner = idx
				}
				bands[m] = bb
				m += 1
			}
			n = m
		case .Bridge:
			if n == 0 {continue}
			if polygon_sdist(ec.poly[:], plan) >= 0 {continue}
			top := field_sample(&ec.field, plan)
			bot := top - comp.thickness
			tmp: [COL_BANDS * 2]Col_Band // every band can split in two
			m := 0
			for b in 0 ..< n {
				bb := bands[b]
				if bb.ceil <= bot || bb.floor >= top {
					tmp[m] = bb
					m += 1
					continue
				}
				if bb.floor < bot {
					tmp[m] = {bb.floor, bot, bb.owner}
					m += 1
				}
				if bb.ceil > top {
					tmp[m] = {top, bb.ceil, idx}
					m += 1
				}
			}
			// keep the topmost COL_BANDS
			first := max(m - COL_BANDS, 0)
			n = m - first
			for b in 0 ..< n {bands[b] = tmp[first + b]}
		case .Hint, .Marker:
		}
	}
	m := 0
	for b in 0 ..< n {
		if bands[b].ceil - bands[b].floor >= 0.01 {
			bands[m] = bands[b]
			m += 1
		}
	}
	return m
}

// column_resolve — the topmost band only, for single-surface callers
// (ramp/bear pinning, gamestart floor). Same results as the M2 single-band
// resolver on bridge-free documents.
column_resolve :: proc(w: ^Eval_World, plan: [2]f32, exclude := i32(-1)) -> (floor, ceil: f32, owner: i32, open: bool) {
	bands: [COL_BANDS]Col_Band
	n := column_resolve_bands(w, plan, &bands, exclude)
	owner = -1
	if n == 0 {return}
	top := bands[n - 1]
	return top.floor, top.ceil, top.owner, true
}

// --- smooth CSG + displacement noise -----------------------------------------

// smin/smax — polynomial smooth min/max, radius k (k ≤ 0 → hard). Deviation
// from hard min/max is ≤ k/4, bounded regardless of operand magnitudes.
@(private = "file")
smin :: #force_inline proc(a, b, k: f32) -> f32 {
	if k <= 1e-6 {return min(a, b)}
	h := clamp(0.5 + 0.5 * (b - a) / k, 0, 1)
	return linalg.lerp(b, a, h) - k * h * (1 - h)
}

@(private = "file")
smax :: #force_inline proc(a, b, k: f32) -> f32 {
	if k <= 1e-6 {return max(a, b)}
	h := clamp(0.5 - 0.5 * (b - a) / k, 0, 1)
	return linalg.lerp(b, a, h) + k * h * (1 - h)
}

@(private = "file")
hash3 :: #force_inline proc(x, y, z: i32, seed: u32) -> f32 {
	h := seed ~ 0x9e3779b9
	h ~= transmute(u32)x * 0x8da6b343
	h ~= transmute(u32)y * 0xd8163841
	h ~= transmute(u32)z * 0xcb1ab31f
	h = (h ~ (h >> 13)) * 0x9e3779b1
	h ~= h >> 16
	return f32(h & 0xffffff) * (1.0 / f32(0x800000)) - 1
}

@(private = "file")
vnoise3 :: proc(p: [3]f32, seed: u32) -> f32 {
	fx, fy, fz := math.floor(p.x), math.floor(p.y), math.floor(p.z)
	ix, iy, iz := i32(fx), i32(fy), i32(fz)
	t := [3]f32{p.x - fx, p.y - fy, p.z - fz}
	t = t * t * (3 - 2 * t)
	c00 := math.lerp(hash3(ix, iy, iz, seed), hash3(ix + 1, iy, iz, seed), t.x)
	c10 := math.lerp(hash3(ix, iy + 1, iz, seed), hash3(ix + 1, iy + 1, iz, seed), t.x)
	c01 := math.lerp(hash3(ix, iy, iz + 1, seed), hash3(ix + 1, iy, iz + 1, seed), t.x)
	c11 := math.lerp(hash3(ix, iy + 1, iz + 1, seed), hash3(ix + 1, iy + 1, iz + 1, seed), t.x)
	return math.lerp(math.lerp(c00, c10, t.y), math.lerp(c01, c11, t.y), t.z)
}

// fbm3 — two octaves of seeded value noise in [-1, 1]; per-component seed
// keeps displacement deterministic and stable across sessions (§5).
@(private = "file")
fbm3 :: proc(p: [3]f32, seed: u32) -> f32 {
	return vnoise3(p, seed) * 0.65 +
		vnoise3(p * 2.17 + {31.7, 17.3, 11.9}, seed ~ 0x51abcd0f) * 0.35
}

// noise_weight — full displacement on steep faces (plan distance dominates),
// reduced on floors/tops so walk surfaces stay near the solved field.
@(private = "file")
noise_weight :: #force_inline proc(d2, dz: f32) -> f32 {
	t := clamp((d2 - dz) * (1.0 / 1.5) + 0.5, 0, 1)
	t = t * t * (3 - 2 * t)
	return 0.35 + 0.65 * t
}

// sdf_sample — signed distance at a world point (x, up, z); negative inside
// rock. Plan mapping: world (x, z) = document (x, y).
sdf_sample :: proc(w: ^Eval_World, p: [3]f32) -> Sdf_Sample {
	return sdf_sample_scoped(w, p, w.order)
}

// sdf_sample_scoped — sdf_sample over a SUBSET of w.order (kept in z-order).
// The mesher passes each chunk's influence-culled component list: a component
// whose padded plan footprint (dirty_min/max — the same "can flip the
// composed sign" bound the incremental dirty region uses) misses the chunk's
// sampling rect contributes exactly nothing there (its CSG op is identity
// outside the pad), so the result is bit-identical to the full loop and the
// per-sample cost stops scaling with total component count.
sdf_sample_scoped :: proc(w: ^Eval_World, p: [3]f32, order: []i32) -> Sdf_Sample {
	plan := [2]f32{p.x, p.z}
	d := f32(-1e9) // infinite solid rock (§1: draw the void)
	owner := i32(-1)

	for idx in order {
		ec := &w.comps[idx]
		if !ec.active {continue}
		comp := &w.doc.components[idx]
		k := comp.blend_radius * 0.5
		amp := comp.noise_amp

		// per-kind plan distance + band. NOTE: a Path's swept distance
		// (centerline distance − width(t)) understates true distance where
		// the width shrinks along the sweep; folly's gentle profiles stay
		// well inside the early-out/reject slack.
		d2: f32
		h: f32  // floor / top field value
		hi: f32 // band ceiling (Sector/Path)
		if comp.kind == .Path {
			dc, s := swept_query(ec, comp.closed, plan)
			wd, fl, ce := path_attrs(comp, ec, s)
			d2 = dc - wd
			// too far in plan to move the composed value (ops deviate ≤ k,
			// noise ≤ amp)
			if d2 - amp - k > abs(d) + k + 1 {continue}
			h = fl
			hi = f32(1e9) if ce == SKY else ce
		} else {
			d2 = polygon_sdist(ec.poly[:], plan)
			// (cliff fins reach CLIFF_THICK outward, inside the same slack)
			if d2 - amp - k > abs(d) + k + 1 {continue}
			h = field_sample(&ec.field, plan)
			hi = f32(1e9) if comp.ceiling == SKY else comp.ceiling
		}
		nz := fbm3(p * NOISE_FREQ, comp.seed) * amp if amp > 0 else 0

		#partial switch comp.kind {
		case .Solid:
			// top is the field; the base extends down into whatever is below,
			// so the union snaps it to the surface (§3).
			dz := p.y - h
			dc := smax(d2, dz, k) + nz * noise_weight(d2, dz)
			if dc <= d {owner = idx}
			d = smin(d, dc, k)
		case .Cliff:
			// vertical rock column: flat top at `base` (h is its flat field),
			// HARD walls (k=0, no noise → crisp vertical edges), unioned down to
			// the lowest level. The "cliff blob" — a mesa/butte with sheer sides.
			dz := p.y - h
			dc := max(d2, dz) // hard smax: rock inside the outline AND below top
			if dc <= d {owner = idx}
			d = min(d, dc) // hard union — no blend with neighbouring geometry
		case .Bridge:
			// CULL: where the blob overlaps a Cliff/Solid, that support owns the
			// surface — drop the slab so the deck meets the support edge flush
			// (the field already bears at the support height there) instead of
			// unioning its slab over the rock and humping the junction. Also
			// yield to a higher-weight bridge sharing this space (§4 crisscross).
			if over_solid_support(w, idx, plan) || over_higher_bridge(w, idx, p, comp.weight) {continue}
			// floating slab [top − thickness, top]: rock unioned into the
			// void it spans — walkable above, passable below.
			dz := max((h - comp.thickness) - p.y, p.y - h)
			dc := smax(d2, dz, k) + nz * noise_weight(d2, dz)
			if dc <= d {owner = idx}
			d = smin(d, dc, k)
		case .Sector, .Path:
			// carve the band [floor, ceiling]
			dzb := max(h - p.y, p.y - hi)
			dc := smax(d2, dzb, k) + nz * noise_weight(d2, dzb)
			if -dc >= d {owner = idx}
			d = smax(d, -dc, k)

			// later-wins fill (§1): rock back below the floor field inside
			// the footprint, overriding earlier deeper voids — the derived
			// cliff sits on this shape's outline. Noise signs match so the
			// carve and fill agree on the displaced floor surface.
			dzf := p.y - h
			fill := smax(d2, dzf, k) - nz * noise_weight(d2, dzf)
			if fill <= d {owner = idx}
			d = smin(d, fill, k)

			if hi < 1e8 {
				dzc := hi - p.y
				fillc := smax(d2, dzc, k) - nz * noise_weight(d2, dzc)
				if fillc <= d {owner = idx}
				d = smin(d, fillc, k)
			}

			// cliff edges: forced rock fin along the tagged segment, growing
			// from below (Solid-style) to CLIFF_HEIGHT above the floor field.
			for t in comp.edge_tags {
				if t.kind != .Cliff {continue}
				if int(t.segment) >= len(ec.seg_start) {continue}
				df := edge_segment_dist(ec, int(t.segment), plan) - CLIFF_THICK
				dw := smax(df, p.y - (h + CLIFF_HEIGHT), k) + nz
				if dw <= d {owner = idx}
				d = smin(d, dw, k)
			}
		}
	}
	return {d, owner}
}
