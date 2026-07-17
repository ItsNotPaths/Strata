package engine

// Height fields (DESIGN.md §3). Every closed shape's relevant height (Sector
// floor, Solid top) is a scalar field over its interior, solved by harmonic
// (Laplace) interpolation on the sampling lattice: the boundary is pinned to
// the shape's base value, interior Hints are pinned (Dirichlet) constraints,
// and `ramp` edges pin the boundary to the NEIGHBOR's surface height instead,
// so slopes flow through the edge. No Hints and no ramp edges → trivially
// flat, the common case costs nothing.
//
// The iterative Laplacian relaxation is dymeta's mesh-relax machinery pointed
// at a 2D problem (SOR over the 5-point stencil). Fields solve in z-order
// (eval_world_build), so a ramp edge reads already-solved lower-z neighbors
// and the flat base of higher-z ones.

import "core:math"
import "core:math/linalg"

// FIELD_PAD — lattice cells of margin around a shape's AABB, so SDF samples
// just outside the outline (wall blending, normals) still read the field.
FIELD_PAD :: 2

// RAMP_REACH — how far (in lattice steps) from a ramp-tagged edge segment a
// pinned boundary cell takes the neighbor's surface height instead of base.
RAMP_REACH :: 1.6

// Field — a solved scalar field sampled on the lattice cells covered by the
// shape's padded 2D AABB. Sampled at lattice resolution because the SDF
// evaluator (sdf.odin) reads it per surface sample anyway.
Field :: struct {
	origin:  [2]f32, // world-space min corner of the sampled AABB
	step:    f32,    // lattice spacing
	size:    [2]i32,
	samples: []f32,
	fmin:    f32, // sample range after the solve — feeds meshing bounds
	fmax:    f32,
}

// Field_Pin — one rasterized sample of a Hint's crest (§3), assigned per-sample
// to the sector/solid the sample sits over (eval_world_build). A hint's samples
// are contiguous and ordered; `src` (the Hint's component index) groups them
// back into a crest polyline in field_relax AND lets topo warnings name the hint.
//
// The crest carries only a height profile (h) — a fall-line. field_relax screens
// the WHOLE containing field onto that profile: every cell projects onto the
// crest, reads the interpolated height at the foot, and is pulled toward it —
// level PERPENDICULAR to the crest (a contour), ramping ALONG it. There is no
// radius: the tilt fills the whole shape the crest overlaps (nearest crest wins
// per cell). A single-sample hint (point) projects to that point everywhere → a
// flat dish holding one height across the shape.
Field_Pin :: struct {
	pos: [2]f32,
	h:   f32,
	src: i32,
}

// BAND_K — screen strength pulling a cell onto the crest's fold profile, relative
// to the 4-neighbour harmonic pull. Moderate: stiff enough that the whole sheet
// holds the authored profile (level across, tilt along), soft enough that the
// harmonic solve rounds the fold creases at the nodes rather than leaving hard
// kinks. Lower → rounder/softer folds; higher → crisper.
BAND_K :: 16.0

field_destroy :: proc(f: ^Field) {
	delete(f.samples)
	f^ = {}
}

// field_init allocates the lattice over the padded AABB of the shape's
// flattened outline, filled with comp.base — the flat (no-constraint) answer
// and the initial guess for field_relax.
field_init :: proc(comp: ^Component, outline: [][2]f32, step: f32) -> (f: Field) {
	lo, hi := polyline_aabb(outline)
	pad := step * FIELD_PAD
	f.origin = lo - pad
	f.step = step
	span := (hi + pad) - f.origin
	f.size = {i32(span.x / step) + 2, i32(span.y / step) + 2}
	f.samples = make([]f32, int(f.size.x) * int(f.size.y))
	for &s in f.samples {s = comp.base}
	f.fmin = comp.base
	f.fmax = comp.base
	return
}

// over_solid_support — is plan point p inside any active Cliff/Solid outline
// (other than `exclude`)? A bridge deck bears wherever this is true: the compiler
// infers abutments from the hard-rock ledges the blob overlaps, so 2/3/N-way
// spans need no hand-tagging.
//
// TODO(sector-top bearing): only Cliff/Solid supports auto-bear here. A bridge
// resting on a raised Sector floor (a mesa) still needs an explicit `bear` edge,
// because every bridge cell sits over SOME sector — auto-bearing on sectors
// would need a "this surface is a ledge, not the void I'm spanning" test
// (e.g. the sector floor is above the deck's spanned low, or is the topmost
// band under the abutment). Stub it: infer sector abutments the same way once
// that test exists, then drop manual `bear`.
over_solid_support :: proc(w: ^Eval_World, exclude: i32, p: [2]f32) -> bool {
	for idx in w.order {
		if idx == exclude {continue}
		k := w.doc.components[idx].kind
		if k != .Cliff && k != .Solid {continue}
		ec := &w.comps[idx]
		if ec.active && polygon_sdist(ec.poly[:], p) < 0 {return true}
	}
	return false
}

// over_higher_bridge — is 3D point p inside the slab of another active Bridge
// that outranks `idx` (higher `weight`; ties break on later z/index)? A bridge
// yields its slab there so the winning span owns a crisscross (§4). Overpasses
// at different heights don't overlap in y, so this stays false and both survive.
over_higher_bridge :: proc(w: ^Eval_World, idx: i32, p: [3]f32, weight: f32) -> bool {
	plan := [2]f32{p.x, p.z}
	for oidx in w.order {
		if oidx == idx {continue}
		oc := &w.doc.components[oidx]
		if oc.kind != .Bridge {continue}
		if oc.weight < weight || (oc.weight == weight && oidx <= idx) {continue}
		oec := &w.comps[oidx]
		if !oec.active {continue}
		if polygon_sdist(oec.poly[:], plan) >= 0 {continue}
		otop := field_sample(&oec.field, plan)
		if p.y >= otop - oc.thickness && p.y <= otop {return true}
	}
	return false
}

// field_relax runs the harmonic solve for component idx.
//
// Sector/Solid: Dirichlet everywhere outside the outline — base, except
// within RAMP_REACH of a ramp-tagged edge where it is the neighbor's surface
// height. Hint pins are interior Dirichlet cells. Interior relaxes by SOR.
//
// Bridge: mixed boundary — cells near `bear`-tagged segments pin to the
// resolved surface below (the abutments); EVERY other cell, exterior
// included, is free (no-flux), so the solve spans a deck between the pinned
// ends instead of sagging to a pinned rim.
field_relax :: proc(w: ^Eval_World, idx: i32) {
	comp := &w.doc.components[idx]
	ec := &w.comps[idx]
	f := &ec.field
	is_bridge := comp.kind == .Bridge

	// boundary-pinning segments: ramps share constraints, bears bear the deck.
	// bleed segments (Sector/Solid) do the opposite — they FREE the rim so an
	// interior slope runs through the outline instead of snapping to base.
	pin_edges := make([dynamic]i32, context.temp_allocator)
	bleed_edges := make([dynamic]i32, context.temp_allocator)
	if comp.closed {
		want: Edge_Tag_Kind = is_bridge ? .Bear : .Ramp
		for t in comp.edge_tags {
			if int(t.segment) >= len(ec.seg_start) {continue}
			if t.kind == want {append(&pin_edges, t.segment)}
			if t.kind == .Bleed && !is_bridge {append(&bleed_edges, t.segment)}
		}
	}
	// bridges always run: abutments are inferred from support overlaps in the
	// loop below, so an untagged bridge is not necessarily flat.
	if len(ec.pins) == 0 && len(pin_edges) == 0 && !is_bridge {
		return // flat, already the answer
	}

	// hinted: the fall-line FOLDS the whole shape like paper — every cell takes
	// the profile height at its projection onto the crest (level PERPENDICULAR,
	// piecewise tilt ALONG, folds at the nodes). The whole sheet tilts, so the
	// rim is freed too (it rides the fold, not pinned to base).
	hinted := len(ec.pins) > 0

	nx, ny := int(f.size.x), int(f.size.y)
	free := make([]bool, nx * ny, context.temp_allocator)
	for y in 0 ..< ny {
		for x in 0 ..< nx {
			pos := f.origin + [2]f32{f32(x), f32(y)} * f.step
			i := y * nx + x
			if is_bridge {
				// abutment = the deck bears on a support here. INFERRED where the
				// blob OVERLAPS a Cliff/Solid (a ledge to rest on), plus any
				// manually `bear`-tagged edge band. Abutment cells pin to the
				// resolved surface below; the free interior relaxes into a
				// membrane between them — a "bowl" spanning 2, 3 or N supports,
				// cut to the blob outline by the SDF. No support overlap → no
				// abutment → that cell stays free (the span).
				//
				// The overlap test is gated to cells INSIDE the blob: the field
				// solves over the blob's padded AABB, so without this a nearby
				// cliff merely inside that AABB (that the blob never touches)
				// would pin abutments and bend the membrane toward geometry it
				// doesn't connect — worse with crossing bridges + close cliffs.
				inside := polygon_sdist(ec.poly[:], pos) < 0
				abut := inside && over_solid_support(w, idx, pos)
				if !abut {
					for s in pin_edges {
						if edge_segment_dist(ec, int(s), pos) <= RAMP_REACH * f.step {abut = true;break}
					}
				}
				if abut {
					v := comp.base
					if h, ok := surface_height(w, pos, idx); ok {v = h}
					f.samples[i] = v
				}
				free[i] = !abut
				continue
			}
			if polygon_sdist(ec.poly[:], pos) < -0.35 * f.step {
				free[i] = true
				continue
			}
			// pinned boundary/exterior cell: base, or the neighbor's surface
			// height where a ramp edge shares constraints across the outline. A
			// `bleed` edge instead leaves the rim FREE (no-flux), so an interior
			// slope flows through the outline rather than snapping to base — the
			// derived wall then rides the hint-driven rim. Ramp/bear pins win a
			// corner cell shared with a bleed segment (a pin is the stronger BC).
			v := comp.base
			ramped := false
			for s in pin_edges {
				if edge_segment_dist(ec, int(s), pos) <= RAMP_REACH * f.step {
					if h, ok := surface_height(w, pos, idx); ok {v = h}
					ramped = true
					break
				}
			}
			if !ramped && hinted {
				free[i] = true // whole sheet folds: the rim rides the fold
			}
			if !ramped && !hinted {
				for s in bleed_edges {
					if edge_segment_dist(ec, int(s), pos) <= RAMP_REACH * f.step {
						free[i] = true
						break
					}
				}
			}
			if free[i] {continue}
			f.samples[i] = v
		}
	}
	// Hint crests FOLD the whole field onto their height profile (a fall-line). A
	// hint's samples are contiguous in ec.pins and share `src`, so each maximal
	// same-src run is one crest polyline. First pin the exact sample nodes (the
	// crest sits on-profile), then screen EVERY cell toward the profile height at
	// its projection onto the crest — level perpendicular, piecewise tilt along
	// (band_screen). No reach: the whole sheet folds; multiple crests blend by
	// inverse-square distance (Shepard). The harmonic solve rounds the fold creases.
	soft_w: []f32 // per-cell screen weight (0 = untouched)
	soft_h: []f32 // per-cell target: the crest profile height at the projection
	if hinted {
		for pin in ec.pins {
			g := (pin.pos - f.origin) / f.step
			x := clamp(int(g.x + 0.5), 0, nx - 1)
			y := clamp(int(g.y + 0.5), 0, ny - 1)
			f.samples[y * nx + x] = pin.h
			free[y * nx + x] = false
		}
		soft_w = make([]f32, nx * ny, context.temp_allocator)
		soft_h = make([]f32, nx * ny, context.temp_allocator)
		// Shepard blend across crests: each crest contributes its projected height
		// weighted by 1/dist², so a cell over ONE crest gets that crest exactly
		// (single-hint folds are unchanged) and cells between multiple crests blend
		// smoothly — no hard seam where two folds meet. acc_w = Σw, acc_wh = Σ(w·h).
		acc_w := make([]f32, nx * ny, context.temp_allocator)
		acc_wh := make([]f32, nx * ny, context.temp_allocator)
		j := 0
		for j < len(ec.pins) {
			k := j + 1
			for k < len(ec.pins) && ec.pins[k].src == ec.pins[j].src {k += 1}
			band_screen(f, ec.pins[j:k], acc_w, acc_wh)
			j = k
		}
		for i in 0 ..< nx * ny {
			if acc_w[i] > 0 {
				soft_w[i] = f32(BAND_K)
				soft_h[i] = acc_wh[i] / acc_w[i]
			}
		}
	}

	// SOR sweeps. Deterministic: fixed sweep order, fixed epsilon. Free cells
	// average their in-grid neighbors — for Sector/Solid the FIELD_PAD rim is
	// always pinned so every free cell counts 4 (sum/4 is bit-identical to
	// the old *0.25); bridge rim cells are free (no-flux) and count fewer.
	// Cells under a band relax toward the screened blend of the harmonic
	// average and the crest profile (diagonal grows by the weight, so
	// over-relaxation stays stable).
	OMEGA :: 1.85
	for _ in 0 ..< 6000 {
		maxd: f32
		for y in 0 ..< ny {
			for x in 0 ..< nx {
				i := y * nx + x
				if !free[i] {continue}
				sum: f32
				cnt: f32
				if x > 0 {sum += f.samples[i - 1];cnt += 1}
				if x < nx - 1 {sum += f.samples[i + 1];cnt += 1}
				if y > 0 {sum += f.samples[i - nx];cnt += 1}
				if y < ny - 1 {sum += f.samples[i + nx];cnt += 1}
				v: f32
				if soft_w != nil && soft_w[i] > 0 {
					v = (sum + soft_w[i] * soft_h[i]) / (cnt + soft_w[i])
				} else {
					v = sum / cnt
				}
				nv := f.samples[i] + OMEGA * (v - f.samples[i])
				maxd = max(maxd, abs(nv - f.samples[i]))
				f.samples[i] = nv
			}
		}
		if maxd < 1e-4 {break}
	}

	f.fmin = f.samples[0]
	f.fmax = f.samples[0]
	for s in f.samples {
		f.fmin = min(f.fmin, s)
		f.fmax = max(f.fmax, s)
	}
}

// edge_segment_dist — distance from `p` to the flattened sub-polyline of
// source segment `seg` (closed components only; the last segment wraps).
edge_segment_dist :: proc(ec: ^Eval_Comp, seg: int, p: [2]f32) -> f32 {
	start := int(ec.seg_start[seg])
	count: int
	if seg + 1 < len(ec.seg_start) {
		count = int(ec.seg_start[seg + 1]) - start
	} else {
		count = len(ec.poly) - start // wraps through poly[0]
	}
	d2 := max(f32)
	for s in 0 ..< count {
		a := ec.poly[(start + s) % len(ec.poly)]
		b := ec.poly[(start + s + 1) % len(ec.poly)]
		e := b - a
		v := p - a
		t := clamp(linalg.dot(v, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
		r := v - e * t
		d2 = min(d2, linalg.dot(r, r))
	}
	return math.sqrt(d2)
}

// band_screen — accumulate ONE hint crest's (a fall-line's) fold into acc_w/acc_wh
// over the WHOLE field (no reach — the whole sheet folds). For every cell the
// crest's target is the profile height at the cell's projection (crest_height):
// level PERPENDICULAR to the crest, piecewise tilt ALONG it (a fold at each node).
// Weight = 1/(dist² + eps): a cell on the crest is dominated by it (single crest →
// exact projection); comparably-near crests blend by proximity. eps ~ (½ step)²
// keeps the on-crest weight finite.
band_screen :: proc(f: ^Field, crest: []Field_Pin, acc_w, acc_wh: []f32) {
	nx, ny := int(f.size.x), int(f.size.y)
	eps := f.step * f.step * 0.25
	for gy in 0 ..< ny {
		for gx in 0 ..< nx {
			pos := f.origin + [2]f32{f32(gx), f32(gy)} * f.step
			h, d2 := crest_height(crest, pos)
			w := 1.0 / (d2 + eps)
			i := gy * nx + gx
			acc_w[i] += w
			acc_wh[i] += w * h
		}
	}
}

// crest_height — the fall-line profile height at plan point `p`, plus the squared
// perpendicular distance to the crest (the Shepard blend weight). Projects p onto
// the crest polyline: the nearest foot reads the bracketing node heights (level
// across, tilt along). Past an open end the foot HOLDS at the endpoint (no
// extrapolation). A single-sample crest holds its one height across the sheet.
crest_height :: proc(crest: []Field_Pin, p: [2]f32) -> (h, d2: f32) {
	if len(crest) == 1 {
		d := p - crest[0].pos
		return crest[0].h, d.x * d.x + d.y * d.y
	}
	best_d2 := max(f32)
	for s in 0 ..< len(crest) - 1 {
		a := crest[s]
		e := crest[s + 1].pos - a.pos
		t := clamp(linalg.dot(p - a.pos, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
		dd := p - (a.pos + e * t)
		dsq := dd.x * dd.x + dd.y * dd.y
		if dsq < best_d2 {
			best_d2 = dsq
			h = math.lerp(a.h, crest[s + 1].h, t)
		}
	}
	return h, best_d2
}

// node_h — height of source node i, extrapolated linearly past the open ends
// (i<0, i>=n) so the Catmull-Rom below starts/ends at the segment's own slope: a
// 2-node hint stays a straight ramp, while interior nodes get smooth tangents.
// Closed hints wrap.
@(private = "file")
node_h :: proc(pts: []Doc_Point, n, i: int, closed: bool) -> f32 {
	if closed {return pts[((i % n) + n) % n].h}
	if i < 0 {return 2 * pts[0].h - pts[1].h}
	if i >= n {return 2 * pts[n - 1].h - pts[n - 2].h}
	return pts[i].h
}

// catmull_h — Catmull-Rom interpolation of the per-node heights across source
// segment s at parameter t∈[0,1]. Passes through every node height EXACTLY (nodes
// stay accurate) with a C1-smooth curve between them, so a fold profile that would
// stairstep between piecewise-linear segments becomes a smooth ramp — the
// smoothness/accuracy trade the user asked for, resolved by interpolating rather
// than averaging.
@(private = "file")
catmull_h :: proc(pts: []Doc_Point, n, s: int, closed: bool, t: f32) -> f32 {
	h0 := node_h(pts, n, s - 1, closed)
	h1 := node_h(pts, n, s, closed)
	h2 := node_h(pts, n, s + 1, closed)
	h3 := node_h(pts, n, s + 2, closed)
	t2 := t * t
	t3 := t2 * t
	res :=
		0.5 *
		(2 * h1 + (-h0 + h2) * t + (2 * h0 - 5 * h1 + 4 * h2 - h3) * t2 +
				(-h0 + 3 * h1 - 3 * h2 + h3) * t3)
	// clamp to the span's own endpoints so a plateau→ramp junction can't
	// overshoot past an authored height (keeps the nodes' heights honest).
	lo := min(h1, h2)
	hi := max(h1, h2)
	return clamp(res, lo, hi)
}

// hint_samples rasterizes a Hint into an ordered run of crest samples: a point
// Hint is one sample; a polyline Hint is flattened at half-step spacing with h
// interpolated by a Catmull-Rom SPLINE through the node heights (smooth ramp,
// exact at nodes) by arc length within each source segment. Samples stay
// CONTIGUOUS and ordered so field_relax can group them back into a crest
// polyline; `src` is the Hint's component index.
hint_samples :: proc(comp: ^Component, step: f32, out: ^[dynamic]Field_Pin, src: i32) {
	n := len(comp.points)
	if n == 0 {return}
	if n == 1 {
		p := &comp.points[0]
		append(out, Field_Pin{p.pos, p.h, src})
		return
	}
	tmp := make([dynamic][2]f32, context.temp_allocator)
	seg_count := n - 1 if !comp.closed else n
	for s in 0 ..< seg_count {
		a := &comp.points[s]
		b := &comp.points[(s + 1) % n]
		clear(&tmp)
		append(&tmp, a.pos)
		if a.handle_out == {} && b.handle_in == {} {
			append(&tmp, b.pos)
		} else {
			bezier_flatten(a.pos, a.pos + a.handle_out, b.pos + b.handle_in, b.pos, step * 0.25, &tmp)
		}
		total: f32
		for i in 1 ..< len(tmp) {total += linalg.length(tmp[i] - tmp[i - 1])}
		total = max(total, 1e-6)
		acc: f32
		append(out, Field_Pin{a.pos, a.h, src})
		for i in 1 ..< len(tmp) {
			seg := linalg.length(tmp[i] - tmp[i - 1])
			nsub := max(int(seg / (step * 0.5)), 1)
			for k in 1 ..= nsub {
				fk := f32(k) / f32(nsub)
				t := (acc + seg * fk) / total
				append(
					out,
					Field_Pin{
						linalg.lerp(tmp[i - 1], tmp[i], fk),
						catmull_h(comp.points[:], n, s, comp.closed, t),
						src,
					},
				)
			}
			acc += seg
		}
	}
}

// field_sample — bilinear read at a world-space plan position, clamped to the
// sampled AABB (queries just past the outline pad get the edge value).
field_sample :: proc(f: ^Field, pos: [2]f32) -> f32 {
	g := (pos - f.origin) / f.step
	g = linalg.clamp(g, [2]f32{0, 0}, [2]f32{f32(f.size.x - 1), f32(f.size.y - 1)})
	x0 := min(i32(g.x), f.size.x - 2)
	y0 := min(i32(g.y), f.size.y - 2)
	x0 = max(x0, 0)
	y0 = max(y0, 0)
	tx := g.x - f32(x0)
	ty := g.y - f32(y0)
	w := int(f.size.x)
	i := int(y0) * w + int(x0)
	s00 := f.samples[i]
	s10 := f.samples[i + 1]
	s01 := f.samples[i + w]
	s11 := f.samples[i + w + 1]
	return linalg.lerp(linalg.lerp(s00, s10, tx), linalg.lerp(s01, s11, tx), ty)
}
