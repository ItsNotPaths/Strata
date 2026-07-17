package engine

// Narrow-band dual contouring (DESIGN.md §4): the sampling lattice ("node
// grid") is a pure sampling structure — chunked, evaluated only near the
// surface, no stored voxels, no cubic memory. Chunks whose padded bounds the
// composed SDF puts far from the surface are rejected on one center sample
// (safe because CSG composes a conservative lower bound on distance, within
// the world's reject_pad of smooth-blend + noise slack).
//
// M1 vertex placement is the edge-crossing mass point (surface-nets style);
// the QEF solve that makes hard-min masonry edges knife-sharp is the next
// step on this file. Quads are emitted per sign-changing lattice edge and
// deduplicated across chunks by edge ownership (a chunk owns edges whose min
// corner lies in its cell range; a one-cell apron supplies neighbor vertices).
//
// Chunks carry provenance (contributing component ids) so the 3D preview can
// answer "why is this lump here" with a click (§5). The same tri-soup (or a
// coarser-lattice remesh) feeds box3d collision.

import "core:math"
import "core:math/linalg"

// CHUNK_CELLS — lattice cells per chunk axis. 16³ cells keeps the editor's
// incremental re-mesh unit (§6) small enough to stay under the edit budget.
CHUNK_CELLS :: 16

Mesh_Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
	mat:    u16, // sorted-recipe-name material id (texgen contract)
}

Mesh_Chunk :: struct {
	cell:       [3]i32, // chunk coordinate on the lattice
	verts:      [dynamic]Mesh_Vertex,
	indices:    [dynamic]u32,
	provenance: [dynamic]i32, // component indices that shaped this chunk
}

mesh_chunk_destroy :: proc(c: ^Mesh_Chunk) {
	delete(c.verts)
	delete(c.indices)
	delete(c.provenance)
	c^ = {}
}

// mesh_extract — dual-contour every lattice chunk whose narrow band the world
// surface crosses, bounded by the evaluated world's padded AABB. The chunk
// lattice is anchored at the WORLD origin (cell = floor(pos / chunk_span)),
// not at bounds_min, so chunk cells — and every sample position — are stable
// while the document's bounds move, which is what lets the editor's
// incremental path (mesh_extract_incr) reuse chunks across evals.
mesh_extract :: proc(w: ^Eval_World) -> (chunks: [dynamic]Mesh_Chunk) {
	return mesh_extract_core(w, nil, {}, {}, {}, {}, nil)
}

// mesh_extract_incr — incremental re-mesh (§6): chunks whose padded sampling
// region misses the dirty plan AABB are STOLEN from `old` (moved, not
// copied); dirty chunks and chunks outside the old bounds' cell range (never
// evaluated before) extract fresh. Consumes `old` — stolen or destroyed,
// then cleared. Produces exactly what a full mesh_extract would (reused
// inputs are deterministic), in the same cell order. `reused` (optional)
// reports how many chunks were stolen.
mesh_extract_incr :: proc(
	w: ^Eval_World,
	old: ^[dynamic]Mesh_Chunk,
	dirty_lo, dirty_hi: [2]f32,
	old_bounds_min, old_bounds_max: [3]f32,
	reused: ^int = nil,
) -> (chunks: [dynamic]Mesh_Chunk) {
	return mesh_extract_core(w, old, dirty_lo, dirty_hi, old_bounds_min, old_bounds_max, reused)
}

// chunk_cell_range — inclusive chunk-cell range covering an AABB on the
// origin-anchored chunk lattice.
@(private = "file")
chunk_cell_range :: proc(bmin, bmax: [3]f32, chunk_span: f32) -> (lo, hi: [3]i32) {
	for a in 0 ..< 3 {
		lo[a] = i32(math.floor(bmin[a] / chunk_span))
		hi[a] = i32(math.floor(bmax[a] / chunk_span))
	}
	return
}

@(private = "file")
mesh_extract_core :: proc(
	w: ^Eval_World,
	old: ^[dynamic]Mesh_Chunk,
	dirty_lo, dirty_hi: [2]f32,
	old_bounds_min, old_bounds_max: [3]f32,
	reused: ^int,
) -> (chunks: [dynamic]Mesh_Chunk) {
	if len(w.comps) == 0 {
		if old != nil {
			for &c in old^ {mesh_chunk_destroy(&c)}
			clear(old)
		}
		return
	}
	step := w.step
	chunk_span := step * CHUNK_CELLS
	c_lo, c_hi := chunk_cell_range(w.bounds_min, w.bounds_max, chunk_span)

	// old chunk lookup; cells outside the old bounds' range were never
	// evaluated, so "absent from old" only means "empty" INSIDE that range.
	old_map: map[[3]i32]int
	stolen: []bool
	o_lo, o_hi: [3]i32
	if old != nil {
		old_map = make(map[[3]i32]int, context.temp_allocator)
		stolen = make([]bool, len(old^), context.temp_allocator)
		for &c, i in old^ {old_map[c.cell] = i}
		o_lo, o_hi = chunk_cell_range(old_bounds_min, old_bounds_max, chunk_span)
	}
	// dirty test margin: one cell of sampling apron + the normal probes
	// (0.35 step); component-side reach is in the dirty AABB's own pads.
	margin := step * 2

	// reusable per-chunk scratch: corner samples over [-1 .. N] per axis and
	// the cell → vertex-index map over cells [-1 .. N-1].
	NS :: CHUNK_CELLS + 2
	NV :: CHUNK_CELLS + 1
	dist: [NS * NS * NS]f32
	owner: [NS * NS * NS]i32
	cell_vert: [NV * NV * NV]i32

	for cz in c_lo.z ..= c_hi.z {
		for cy in c_lo.y ..= c_hi.y {
			for cx in c_lo.x ..= c_hi.x {
				cell := [3]i32{cx, cy, cz}
				chunk_min := [3]f32{f32(cx), f32(cy), f32(cz)} * chunk_span

				if old != nil {
					in_old_range :=
						cx >= o_lo.x && cx <= o_hi.x &&
						cy >= o_lo.y && cy <= o_hi.y &&
						cz >= o_lo.z && cz <= o_hi.z
					clean :=
						chunk_min.x + chunk_span + margin < dirty_lo.x ||
						chunk_min.x - margin > dirty_hi.x ||
						chunk_min.z + chunk_span + margin < dirty_lo.y ||
						chunk_min.z - margin > dirty_hi.y
					if clean && in_old_range {
						if oi, ok := old_map[cell]; ok {
							append(&chunks, old^[oi])
							stolen[oi] = true
							if reused != nil {reused^ += 1}
						}
						continue // absent = was empty, still empty
					}
				}

				// narrow-band rejection: one sample at the padded chunk center
				// (samples ride the half-step lattice offset; the +step in the
				// radius already covers it)
				lo := chunk_min - step
				hi := chunk_min + chunk_span
				center := (lo + hi) * 0.5 + step * 0.5
				radius := linalg.length(hi - lo) * 0.5 + step + w.reject_pad
				if abs(sdf_sample(w, center).dist) > radius {continue}

				chunk := mesh_chunk_extract(w, cell, chunk_min, dist[:], owner[:], cell_vert[:])
				if len(chunk.indices) > 0 {
					append(&chunks, chunk)
				} else {
					mesh_chunk_destroy(&chunk)
				}
			}
		}
	}
	if old != nil {
		for &c, i in old^ {
			if !stolen[i] {mesh_chunk_destroy(&c)}
		}
		clear(old)
	}
	return
}

@(private = "file")
mesh_chunk_extract :: proc(
	w: ^Eval_World,
	cell: [3]i32,
	chunk_min: [3]f32,
	dist: []f32,
	owner: []i32,
	cell_vert: []i32,
) -> (chunk: Mesh_Chunk) {
	chunk.cell = cell
	step := w.step
	N :: CHUNK_CELLS
	NS :: CHUNK_CELLS + 2 // corners [-1 .. N]
	NV :: CHUNK_CELLS + 1 // cells   [-1 .. N-1]

	corner_at :: #force_inline proc(i, j, k: int) -> int { // corner indices offset by +1
		return ((k + 1) * NS + (j + 1)) * NS + (i + 1)
	}
	cell_at :: #force_inline proc(i, j, k: int) -> int {
		return ((k + 1) * NV + (j + 1)) * NV + (i + 1)
	}
	corner_pos :: #force_inline proc(chunk_min: [3]f32, step: f32, i, j, k: int) -> [3]f32 {
		// half-step lattice offset: authored heights land on round numbers
		// (integer floors, integer-thickness Bridge slabs), and a sample
		// sitting EXACTLY on a surface (d == 0) counts as outside — a thin
		// slab aligned to the lattice would produce no sign change at all.
		// Sampling between round values keeps thin features watertight.
		return chunk_min + ([3]f32{f32(i), f32(j), f32(k)} + 0.5) * step
	}

	for k in -1 ..= N {
		for j in -1 ..= N {
			for i in -1 ..= N {
				s := sdf_sample(w, corner_pos(chunk_min, step, i, j, k))
				dist[corner_at(i, j, k)] = s.dist
				owner[corner_at(i, j, k)] = s.owner
			}
		}
	}

	// one vertex per cell straddling the surface: mass point of edge
	// crossings, normal from central differences, material from the owning
	// component via the angle splitter. TODO: QEF placement for sharp edges.
	CELL_EDGES :: [12][2][3]int {
		{{0, 0, 0}, {1, 0, 0}}, {{0, 1, 0}, {1, 1, 0}}, {{0, 0, 1}, {1, 0, 1}}, {{0, 1, 1}, {1, 1, 1}},
		{{0, 0, 0}, {0, 1, 0}}, {{1, 0, 0}, {1, 1, 0}}, {{0, 0, 1}, {0, 1, 1}}, {{1, 0, 1}, {1, 1, 1}},
		{{0, 0, 0}, {0, 0, 1}}, {{1, 0, 0}, {1, 0, 1}}, {{0, 1, 0}, {0, 1, 1}}, {{1, 1, 0}, {1, 1, 1}},
	}
	for k in -1 ..< N {
		for j in -1 ..< N {
			for i in -1 ..< N {
				cell_vert[cell_at(i, j, k)] = -1
				sum: [3]f32
				crossings := 0
				for e in CELL_EDGES {
					a, b := e[0], e[1]
					da := dist[corner_at(i + a[0], j + a[1], k + a[2])]
					db := dist[corner_at(i + b[0], j + b[1], k + b[2])]
					if (da < 0) == (db < 0) {continue}
					t := da / (da - db)
					pa := corner_pos(chunk_min, step, i + a[0], j + a[1], k + a[2])
					pb := corner_pos(chunk_min, step, i + b[0], j + b[1], k + b[2])
					sum += linalg.lerp(pa, pb, t)
					crossings += 1
				}
				if crossings == 0 {continue}
				p := sum / f32(crossings)

				eps := step * 0.35
				n := linalg.normalize0(
					[3]f32 {
						sdf_sample(w, p + {eps, 0, 0}).dist - sdf_sample(w, p - {eps, 0, 0}).dist,
						sdf_sample(w, p + {0, eps, 0}).dist - sdf_sample(w, p - {0, eps, 0}).dist,
						sdf_sample(w, p + {0, 0, eps}).dist - sdf_sample(w, p - {0, 0, eps}).dist,
					},
				)

				own := sdf_sample(w, p).owner
				mat := u16(0)
				if own >= 0 {
					// angle splitter: slot by surface normal (§4)
					slot := 1 // wall
					if n.y > 0.55 {slot = 0} else if n.y < -0.55 {slot = 2}
					mat = w.comps[own].mat[slot]
					provenance_add(&chunk.provenance, own)
				}

				cell_vert[cell_at(i, j, k)] = i32(len(chunk.verts))
				append(&chunk.verts, Mesh_Vertex{pos = p, normal = n, mat = mat})
			}
		}
	}

	// quads: one per owned sign-changing lattice edge (min corner in
	// [0..N-1]³), connecting the 4 adjacent cell vertices around the edge.
	for k in 0 ..< N {
		for j in 0 ..< N {
			for i in 0 ..< N {
				c := [3]int{i, j, k}
				d0 := dist[corner_at(i, j, k)]
				for a in 0 ..< 3 {
					c1 := c
					c1[a] += 1
					d1 := dist[corner_at(c1[0], c1[1], c1[2])]
					if (d0 < 0) == (d1 < 0) {continue}
					u := (a + 1) % 3
					v := (a + 2) % 3
					quad: [4]i32
					offs := [4][2]int{{-1, -1}, {0, -1}, {0, 0}, {-1, 0}}
					valid := true
					for o, qi in offs {
						cc := c
						cc[u] += o[0]
						cc[v] += o[1]
						quad[qi] = cell_vert[cell_at(cc[0], cc[1], cc[2])]
						if quad[qi] < 0 {valid = false}
					}
					if !valid {continue} // shouldn't happen; guards degenerate SDFs
					if d0 < 0 {
						// inside → outside along +axis: wind CCW seen from +axis
						append(&chunk.indices, u32(quad[0]), u32(quad[1]), u32(quad[2]))
						append(&chunk.indices, u32(quad[0]), u32(quad[2]), u32(quad[3]))
					} else {
						append(&chunk.indices, u32(quad[0]), u32(quad[2]), u32(quad[1]))
						append(&chunk.indices, u32(quad[0]), u32(quad[3]), u32(quad[2]))
					}
				}
			}
		}
	}
	return
}

@(private = "file")
provenance_add :: proc(prov: ^[dynamic]i32, comp: i32) {
	for have in prov {if have == comp {return}}
	append(prov, comp)
}
