package engine

// Narrow-band dual contouring (DESIGN.md §4): the sampling lattice ("node
// grid") is a pure sampling structure — chunked, evaluated only near the
// surface, no stored voxels, no cubic memory. Chunks whose padded bounds the
// composed SDF puts far from the surface are rejected on one center sample
// (safe because CSG composes a conservative lower bound on distance, within
// the world's reject_pad of smooth-blend + noise slack).
//
// Vertex placement is a regularized QEF solve (dual contouring proper): each
// sign-changing lattice edge contributes its crossing point + the SDF normal
// there as a plane constraint; the cell vertex minimizes Σ(nᵢ·(x−pᵢ))²,
// Tikhonov-pulled toward the crossing mass point and clamped to the cell.
// Planar cells reproduce the plane exactly (slopes stop stairstepping at
// coarse step), crease cells land ON the crease (hard-min cliff edges stay
// knife-sharp). Quads are emitted per sign-changing lattice edge and
// deduplicated across chunks by edge ownership (a chunk owns edges whose min
// corner lies in its cell range; a one-cell apron supplies neighbor vertices).
//
// Chunks carry provenance (contributing component ids) so the 3D preview can
// answer "why is this lump here" with a click (§5). The same tri-soup (or a
// coarser-lattice remesh) feeds box3d collision.

import "base:intrinsics"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strconv"
import "core:sys/info"
import "core:thread"

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

	// phase 1 (serial): steal clean chunks, queue the rest as jobs. `seq`
	// records the original cell-scan order so the merged output is
	// bit-identical to the old serial loop.
	Seq :: struct {
		old_i: int, // stolen chunk index in `old`, or -1
		job:   int, // job index, or -1
	}
	jobs := make([dynamic]Extract_Job, context.temp_allocator)
	seq := make([dynamic]Seq, context.temp_allocator)

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
							append(&seq, Seq{old_i = oi, job = -1})
							stolen[oi] = true
							if reused != nil {reused^ += 1}
						}
						continue // absent = was empty, still empty
					}
				}
				append(&jobs, Extract_Job{cell = cell, chunk_min = chunk_min})
				append(&seq, Seq{old_i = -1, job = len(jobs) - 1})
			}
		}
	}

	// phase 2 (parallel): extract jobs. Chunks are independent (sdf_sample is
	// a pure read of the world), each worker owns its scratch, and results
	// land by job index — thread count cannot affect the output.
	results := make([]Mesh_Chunk, len(jobs), context.temp_allocator)
	ctx := Extract_Ctx {
		w       = w,
		jobs    = jobs[:],
		results = results,
	}
	nt := min(mesh_threads(), len(jobs))
	if nt <= 1 {
		extract_worker(&ctx)
	} else {
		workers := make([]^thread.Thread, nt, context.temp_allocator)
		for i in 0 ..< nt {
			workers[i] = thread.create_and_start_with_poly_data(&ctx, extract_worker)
		}
		for t in workers {
			thread.join(t)
			thread.destroy(t)
		}
	}

	// phase 3 (serial): merge in original cell order
	for e in seq {
		if e.old_i >= 0 {
			append(&chunks, old^[e.old_i])
			continue
		}
		c := results[e.job]
		if len(c.indices) > 0 {
			append(&chunks, c)
		} else {
			mesh_chunk_destroy(&c)
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

// mesh_threads — worker count: STRATA_THREADS override, else logical cores.
// Purely a throughput knob; extraction output is thread-count-independent.
@(private = "file")
mesh_threads :: proc() -> int {
	if s := os.get_env("STRATA_THREADS", context.temp_allocator); s != "" {
		if v, ok := strconv.parse_int(s); ok && v >= 1 {return v}
	}
	_, logical, ok := info.cpu_core_count()
	if !ok || logical < 1 {return 1}
	return logical
}

@(private = "file")
Extract_Job :: struct {
	cell:      [3]i32,
	chunk_min: [3]f32,
}

@(private = "file")
Extract_Ctx :: struct {
	w:       ^Eval_World,
	jobs:    []Extract_Job,
	results: []Mesh_Chunk,
	next:    int, // atomic job cursor
}

@(private = "file")
extract_worker :: proc(ctx: ^Extract_Ctx) {
	NS :: CHUNK_CELLS + 2
	NV :: CHUNK_CELLS + 1
	dist: [NS * NS * NS]f32
	owner: [NS * NS * NS]i32
	cell_vert: [NV * NV * NV]i32
	// per-edge crossing scratch is too big for the stack (~560 KB) — heap,
	// once per worker (the default heap allocator is thread-safe)
	edge_p := make([][3]f32, 3 * NS * NS * NS)
	edge_n := make([][3]f32, 3 * NS * NS * NS)
	scope := make([dynamic]i32)
	defer {
		delete(edge_p)
		delete(edge_n)
		delete(scope)
	}
	for {
		i := intrinsics.atomic_add(&ctx.next, 1)
		if i >= len(ctx.jobs) {break}
		ctx.results[i] = extract_job_run(
			ctx.w, ctx.jobs[i], dist[:], owner[:], cell_vert[:], edge_p, edge_n, &scope,
		)
	}
}

@(private = "file")
extract_job_run :: proc(
	w: ^Eval_World,
	job: Extract_Job,
	dist: []f32,
	owner: []i32,
	cell_vert: []i32,
	edge_p: [][3]f32,
	edge_n: [][3]f32,
	scope: ^[dynamic]i32,
) -> Mesh_Chunk {
	step := w.step
	chunk_span := step * CHUNK_CELLS

	// influence scope (sdf_sample_scoped): components whose padded plan
	// footprint reaches this chunk's sampling rect. One step of rect margin
	// covers the half-step corner offset and the normal probes.
	clear(scope)
	rect_lo := [2]f32{job.chunk_min.x - step, job.chunk_min.z - step}
	rect_hi := [2]f32{job.chunk_min.x + chunk_span + step, job.chunk_min.z + chunk_span + step}
	for idx in w.order {
		ec := &w.comps[idx]
		if !ec.active || len(ec.poly) < 2 {continue}
		if ec.dirty_min.x > rect_hi.x || ec.dirty_max.x < rect_lo.x ||
		   ec.dirty_min.y > rect_hi.y || ec.dirty_max.y < rect_lo.y {continue}
		append(scope, idx)
	}
	if len(scope) == 0 {return {}} // pure rock: nothing can surface here

	// narrow-band rejection: one sample at the padded chunk center
	// (samples ride the half-step lattice offset; the +step in the
	// radius already covers it)
	lo := job.chunk_min - step
	hi := job.chunk_min + chunk_span
	center := (lo + hi) * 0.5 + step * 0.5
	radius := linalg.length(hi - lo) * 0.5 + step + w.reject_pad
	if abs(sdf_sample_scoped(w, center, scope[:]).dist) > radius {return {}}

	return mesh_chunk_extract(w, job.cell, job.chunk_min, scope[:], dist, owner, cell_vert, edge_p, edge_n)
}

// QEF_REG — Tikhonov regularization per plane constraint: unconstrained
// directions (the tangent plane of a flat cell, the crease line of a 2-plane
// cell) pull toward the crossing mass point with this weight instead of
// blowing up. Small enough not to blunt creases, big enough to damp noise.
QEF_REG :: f32(0.05)

@(private = "file")
mesh_chunk_extract :: proc(
	w: ^Eval_World,
	cell: [3]i32,
	chunk_min: [3]f32,
	scope: []i32,
	dist: []f32,
	owner: []i32,
	cell_vert: []i32,
	edge_p: [][3]f32,
	edge_n: [][3]f32,
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

	NS3 :: NS * NS * NS

	for k in -1 ..= N {
		for j in -1 ..= N {
			for i in -1 ..= N {
				s := sdf_sample_scoped(w, corner_pos(chunk_min, step, i, j, k), scope)
				dist[corner_at(i, j, k)] = s.dist
				owner[corner_at(i, j, k)] = s.owner
			}
		}
	}

	// per-edge crossings, computed ONCE per lattice edge (each edge borders 4
	// cells): interpolated crossing point + the SDF normal there. The normals
	// are the QEF's plane constraints, so they're sampled at the crossing, not
	// at the cell vertex.
	axis_d := [3][3]int{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	eps := step * 0.35
	for k in -1 ..= N {
		for j in -1 ..= N {
			for i in -1 ..= N {
				ci := corner_at(i, j, k)
				da := dist[ci]
				for a in 0 ..< 3 {
					d := axis_d[a]
					ii, jj, kk := i + d[0], j + d[1], k + d[2]
					if ii > N || jj > N || kk > N {continue}
					db := dist[corner_at(ii, jj, kk)]
					if (da < 0) == (db < 0) {continue}
					t := da / (da - db)
					pa := corner_pos(chunk_min, step, i, j, k)
					pb := corner_pos(chunk_min, step, ii, jj, kk)
					q := linalg.lerp(pa, pb, t)
					idx := a * NS3 + ci
					edge_p[idx] = q
					edge_n[idx] = linalg.normalize0(
						[3]f32 {
							sdf_sample_scoped(w, q + {eps, 0, 0}, scope).dist - sdf_sample_scoped(w, q - {eps, 0, 0}, scope).dist,
							sdf_sample_scoped(w, q + {0, eps, 0}, scope).dist - sdf_sample_scoped(w, q - {0, eps, 0}, scope).dist,
							sdf_sample_scoped(w, q + {0, 0, eps}, scope).dist - sdf_sample_scoped(w, q - {0, 0, eps}, scope).dist,
						},
					)
				}
			}
		}
	}

	// one vertex per cell straddling the surface: regularized QEF over the
	// cell's edge-crossing plane constraints (header comment), clamped to the
	// cell; normal = mean crossing normal; material from the owning component
	// via the angle splitter.
	CELL_EDGES :: [12][2][3]int {
		{{0, 0, 0}, {1, 0, 0}}, {{0, 1, 0}, {1, 1, 0}}, {{0, 0, 1}, {1, 0, 1}}, {{0, 1, 1}, {1, 1, 1}},
		{{0, 0, 0}, {0, 1, 0}}, {{1, 0, 0}, {1, 1, 0}}, {{0, 0, 1}, {0, 1, 1}}, {{1, 0, 1}, {1, 1, 1}},
		{{0, 0, 0}, {0, 0, 1}}, {{1, 0, 0}, {1, 0, 1}}, {{0, 1, 0}, {0, 1, 1}}, {{1, 1, 0}, {1, 1, 1}},
	}
	// axis of CELL_EDGES[e]: e/4 (0-3 span x, 4-7 span y, 8-11 span z)
	for k in -1 ..< N {
		for j in -1 ..< N {
			for i in -1 ..< N {
				cell_vert[cell_at(i, j, k)] = -1
				ata: matrix[3, 3]f32
				atb: [3]f32
				sum_p: [3]f32
				sum_n: [3]f32
				crossings := 0
				for e, ei in CELL_EDGES {
					a, b := e[0], e[1]
					da := dist[corner_at(i + a[0], j + a[1], k + a[2])]
					db := dist[corner_at(i + b[0], j + b[1], k + b[2])]
					if (da < 0) == (db < 0) {continue}
					idx := (ei / 4) * NS3 + corner_at(i + a[0], j + a[1], k + a[2])
					q, n := edge_p[idx], edge_n[idx]
					ata += linalg.outer_product(n, n)
					atb += n * linalg.dot(n, q)
					sum_p += q
					sum_n += n
					crossings += 1
				}
				if crossings == 0 {continue}
				mass := sum_p / f32(crossings)

				// solve for the offset from the mass point; Tikhonov pulls the
				// null space (plane tangents / crease line) to the mass point
				atb -= ata * mass
				reg := QEF_REG * f32(crossings)
				ata[0, 0] += reg
				ata[1, 1] += reg
				ata[2, 2] += reg
				p := mass
				det := linalg.determinant(ata)
				if abs(det) > 1e-10 {
					p = mass + linalg.inverse(ata) * atb
					// clamp to the cell: a bad constraint set must not spike
					cmin := corner_pos(chunk_min, step, i, j, k)
					p = linalg.clamp(p, cmin, cmin + step)
				}

				n := linalg.normalize0(sum_n)

				own := sdf_sample_scoped(w, p, scope).owner
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

// mesh_checksum — FNV-1a over quantized vertex data and triangle counts: the
// golden-test / STRATA_VERIFY_INCR primitive (DESIGN.md §5). Catches geometry
// drift without storing meshes; part of the compiler's determinism contract,
// which is why it lives here and not with any exporter.
mesh_checksum :: proc(chunks: []Mesh_Chunk) -> u32 {
	h := u32(0x811c9dc5)
	mix :: #force_inline proc(h: ^u32, v: u32) {
		x := v
		for _ in 0 ..< 4 {
			h^ = (h^ ~ (x & 0xff)) * 16777619
			x >>= 8
		}
	}
	for &c in chunks {
		for a in 0 ..< 3 {mix(&h, transmute(u32)c.cell[a])}
		for v in c.verts {
			for a in 0 ..< 3 {mix(&h, transmute(u32)i32(math.round(v.pos[a] * 1024)))}
			mix(&h, u32(v.mat))
		}
		mix(&h, u32(len(c.indices)))
	}
	return h
}
