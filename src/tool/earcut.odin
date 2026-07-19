package tool

// Ear-clipping triangulation for the 2D canvas fills (DESIGN.md §6: "earcut
// triangulation of the flattened outline — tiny vendor, or a port"). This is
// the port: single closed polygon, no holes, either winding, O(n²·n) worst
// case — fine because fills are cached per component and only re-triangulated
// on a geometry edit. Degenerate/self-intersecting input falls back to a fan
// instead of looping forever.

earcut :: proc(pts: [][2]f32, out: ^[dynamic]u32) {
	n := len(pts)
	if n < 3 {return}

	// index ring, oriented so the convexity test below reads cross > 0
	idx := make([dynamic]i32, 0, n, context.temp_allocator)
	area := f32(0)
	for i in 0 ..< n {
		j := (i + 1) % n
		area += pts[i].x * pts[j].y - pts[j].x * pts[i].y
	}
	if area >= 0 {
		for i in 0 ..< n {append(&idx, i32(i))}
	} else {
		for i in 0 ..< n {append(&idx, i32(n - 1 - i))}
	}

	for len(idx) > 3 {
		m := len(idx)
		found := false
		for i in 0 ..< m {
			ia := idx[(i + m - 1) % m]
			ib := idx[i]
			ic := idx[(i + 1) % m]
			pa, pb, pc := pts[ia], pts[ib], pts[ic]
			cross := (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
			if cross <= 1e-12 {continue} // reflex or collinear — not an ear
			ear := true
			for k in 0 ..< m {
				iq := idx[k]
				if iq == ia || iq == ib || iq == ic {continue}
				if point_in_tri(pts[iq], pa, pb, pc) {
					ear = false
					break
				}
			}
			if ear {
				append(out, u32(ia), u32(ib), u32(ic))
				ordered_remove(&idx, i)
				found = true
				break
			}
		}
		if !found {
			// degenerate input: fan the remainder rather than spin
			for i in 1 ..< len(idx) - 1 {
				append(out, u32(idx[0]), u32(idx[i]), u32(idx[i + 1]))
			}
			return
		}
	}
	append(out, u32(idx[0]), u32(idx[1]), u32(idx[2]))
}

@(private = "file")
point_in_tri :: proc(p, a, b, c: [2]f32) -> bool {
	s0 := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	s1 := (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
	s2 := (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
	eps := f32(1e-9)
	return s0 >= -eps && s1 >= -eps && s2 >= -eps
}
