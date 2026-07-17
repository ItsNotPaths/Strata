package engine

// 2D geometry shared by the evaluator (sdf.odin) and, later, the editor's
// hit-testing/snapping: cubic Bézier flattening, polygon signed distance,
// AABBs. Plan coordinates are document coordinates (SVG x right, y down);
// the world mapping is plan (x,y) → world (x, z) with height on +y.

import "core:math"
import "core:math/linalg"

// bezier_flatten appends the curve p0→p3 (control points p1, p2) to `out` as
// line endpoints, EXCLUDING p0 (the caller has it) and INCLUDING p3. Adaptive
// recursive subdivision: a segment is flat enough when both control points
// sit within `tol` of the chord.
bezier_flatten :: proc(p0, p1, p2, p3: [2]f32, tol: f32, out: ^[dynamic][2]f32, depth := 0) {
	if depth >= 16 || bezier_flat_enough(p0, p1, p2, p3, tol) {
		append(out, p3)
		return
	}
	// de Casteljau split at t = 0.5
	a := (p0 + p1) * 0.5
	b := (p1 + p2) * 0.5
	c := (p2 + p3) * 0.5
	ab := (a + b) * 0.5
	bc := (b + c) * 0.5
	m := (ab + bc) * 0.5
	bezier_flatten(p0, a, ab, m, tol, out, depth + 1)
	bezier_flatten(m, bc, c, p3, tol, out, depth + 1)
}

@(private = "file")
bezier_flat_enough :: proc(p0, p1, p2, p3: [2]f32, tol: f32) -> bool {
	// distance of each control point from the chord, conservative (uses the
	// unclamped line when the chord is degenerate).
	d := p3 - p0
	len2 := linalg.dot(d, d)
	if len2 < 1e-12 {
		return linalg.length(p1 - p0) <= tol && linalg.length(p2 - p0) <= tol
	}
	c1 := abs((p1.x - p0.x) * d.y - (p1.y - p0.y) * d.x)
	c2 := abs((p2.x - p0.x) * d.y - (p2.y - p0.y) * d.x)
	limit := tol * math.sqrt(len2)
	return c1 <= limit && c2 <= limit
}

// component_flatten flattens a spline component's points to a polyline in
// plan space. Closed shapes get the closing segment flattened too but do NOT
// duplicate the first point. Handles are offsets from their point (zero =
// straight toward the neighbor). Caller owns the result.
//
// `seg_start`, when given, receives one entry per SOURCE segment: the index
// into the result where that segment begins — edge tags name source segments,
// this maps them onto the flattened outline (edge_segment_dist).
component_flatten :: proc(comp: ^Component, tol: f32, seg_start: ^[dynamic]i32 = nil) -> [dynamic][2]f32 {
	out := make([dynamic][2]f32)
	n := len(comp.points)
	if n == 0 {return out}
	append(&out, comp.points[0].pos)
	seg_count := n - 1 if !comp.closed else n
	for s in 0 ..< seg_count {
		if seg_start != nil {append(seg_start, i32(len(out) - 1))}
		a := &comp.points[s]
		b := &comp.points[(s + 1) % n]
		if a.handle_out == {} && b.handle_in == {} {
			append(&out, b.pos)
		} else {
			bezier_flatten(a.pos, a.pos + a.handle_out, b.pos + b.handle_in, b.pos, tol, &out)
		}
	}
	if comp.closed && len(out) > 1 && out[len(out) - 1] == out[0] {
		pop(&out)
	}
	return out
}

// polygon_sdist — exact signed distance from `p` to the closed polyline
// `poly` (no duplicated endpoint). Negative inside. Sign by even-odd crossing
// parity, so winding direction doesn't matter. O(n).
polygon_sdist :: proc(poly: [][2]f32, p: [2]f32) -> f32 {
	n := len(poly)
	if n < 3 {return 1e9}
	d2 := max(f32)
	inside := false
	j := n - 1
	for i in 0 ..< n {
		a := poly[j]
		b := poly[i]
		e := b - a
		w := p - a
		t := clamp(linalg.dot(w, e) / max(linalg.dot(e, e), 1e-12), 0, 1)
		v := w - e * t
		d2 = min(d2, linalg.dot(v, v))
		if (a.y > p.y) != (b.y > p.y) {
			if p.x < a.x + e.x * (p.y - a.y) / e.y {
				inside = !inside
			}
		}
		j = i
	}
	return math.sqrt(d2) * (-1 if inside else 1)
}

// polyline_aabb — min/max corners of a point set (zeroed for empty input).
polyline_aabb :: proc(pts: [][2]f32) -> (lo, hi: [2]f32) {
	if len(pts) == 0 {return}
	lo = pts[0]
	hi = pts[0]
	for p in pts[1:] {
		lo = linalg.min(lo, p)
		hi = linalg.max(hi, p)
	}
	return
}
