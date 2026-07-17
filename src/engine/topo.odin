package engine

// Topo oracle (DESIGN.md §5): the final evaluator pass and the golden-test
// workhorse. Runs on the SOLVED floor fields in plan space — far cheaper than
// interrogating the mesh, and it is the surface the movement contract
// actually reads (displacement noise deliberately stays small on floors,
// sdf.odin). Checks: walkable connectivity (flood fill under the step-up
// rule), player clearance, field slope limits (pinned to the Hint that caused
// them), gamestart reachability, portal-tag sanity.
//
// The oracle is split data/format so the editor's 2D debug overlays (§5) can
// render the same truth the report prints: topo_data_build produces the
// per-cell grid + structured WARN pins, topo_report formats the text.
//
// Constants derive from folly's movement contract (§0): no jump, one-tile
// auto step-up — height deltas are load-bearing.

import "core:fmt"
import "core:math"
import "core:strings"

STEP_UP :: 1.0 // max height delta auto-stepped between adjacent cells
CLEARANCE :: 2.0 // player headroom: floor-to-ceiling minimum
MAX_SLOPE :: 1.0 // max walkable rise/run within one component's field
TOPO_WARN_MAX :: 6 // detailed WARN lines per check; counts always report
TOPO_PIN_MAX :: 512 // structured pins kept per kind for the editor overlay

Topo_Pin_Kind :: enum u8 {
	Slope,     // same-owner cell pair exceeds MAX_SLOPE (val = rise/run)
	Clearance, // open cell with floor-to-ceiling under CLEARANCE
	Region,    // seed of a walkable region when regions are unreachable
	Start,     // gamestart marker not on walkable ground
}

Topo_Pin :: struct {
	pos:  [2]f32,
	kind: Topo_Pin_Kind,
	comp: i32, // offending component index, -1 = none
	val:  f32, // Slope: rise/run. Region: cell count.
	id:   i32, // Region: region index
}

Topo_Region :: struct {
	cells: int,
	seed:  [2]f32,
	floor: f32,
}

// Topo_Data — one oracle run: the sampled column grid, walkable regions, and
// every finding as a plan-space pin. Columns carry up to TWO layers (multi-
// band columns under Bridges: deck above, passage below): the per-cell
// arrays hold nx*nz entries per layer, layer L at [L*nx*nz + cell]. Layer 0
// is the TOPMOST band — single-band documents populate only layer 0, and the
// editor overlays read just that first slice. Values are valid where `open`.
TOPO_LAYERS :: 2

Topo_Data :: struct {
	origin:     [2]f32, // center of cell (0, 0)
	step:       f32,
	nx, nz:     int,
	floor_v:    []f32,
	ceil_v:     []f32,
	own:        []i32,
	open:       []bool,
	walk:       []bool,
	region:     []i32, // walkable region id, -1 elsewhere
	regions:    [dynamic]Topo_Region,
	pins:       [dynamic]Topo_Pin,
	open_cells: int,
	walk_cells: int,
	clear_viol: int,
	slope_viol: int,
	hmin, hmax: f32, // layer-0 floor range over open cells (heatmap)
}

topo_data_destroy :: proc(td: ^Topo_Data) {
	delete(td.floor_v)
	delete(td.ceil_v)
	delete(td.own)
	delete(td.open)
	delete(td.walk)
	delete(td.region)
	delete(td.regions)
	delete(td.pins)
	td^ = {}
}

@(private = "file")
topo_cell_pos :: #force_inline proc(td: ^Topo_Data, i: int) -> [2]f32 {
	return td.origin + [2]f32{f32(i % td.nx), f32(i / td.nx)} * td.step
}

// topo_data_build samples column_resolve over the world's plan bounds and runs
// every check, recording findings as pins. Deterministic: fixed scan order.
topo_data_build :: proc(w: ^Eval_World, allocator := context.allocator) -> (td: Topo_Data) {
	context.allocator = allocator
	step := w.step
	td.step = step
	td.origin = [2]f32{w.bounds_min.x, w.bounds_min.z} + step * 0.5
	td.nx = max(int((w.bounds_max.x - w.bounds_min.x) / step), 1)
	td.nz = max(int((w.bounds_max.z - w.bounds_min.z) / step), 1)
	nx, nz := td.nx, td.nz
	n := nx * nz

	n2 := TOPO_LAYERS * n
	td.floor_v = make([]f32, n2)
	td.ceil_v = make([]f32, n2)
	td.own = make([]i32, n2)
	td.open = make([]bool, n2)
	td.walk = make([]bool, n2)
	td.region = make([]i32, n2)
	td.regions = make([dynamic]Topo_Region)
	td.pins = make([dynamic]Topo_Pin)

	td.hmin, td.hmax = max(f32), min(f32)
	clear_pins := 0
	bands: [COL_BANDS]Col_Band
	for i in 0 ..< n {
		pos := topo_cell_pos(&td, i)
		nb := column_resolve_bands(w, pos, &bands)
		for l in 0 ..< TOPO_LAYERS {
			bi := nb - 1 - l // layer 0 = topmost band
			if bi < 0 {continue}
			node := l * n + i
			b := bands[bi]
			td.floor_v[node] = b.floor
			td.ceil_v[node] = b.ceil
			td.own[node] = b.owner
			td.open[node] = true
			td.open_cells += 1
			if l == 0 {
				td.hmin = min(td.hmin, b.floor)
				td.hmax = max(td.hmax, b.floor)
			}
			if b.ceil - b.floor >= CLEARANCE {
				td.walk[node] = true
				td.walk_cells += 1
			} else {
				td.clear_viol += 1
				if clear_pins < TOPO_PIN_MAX {
					clear_pins += 1
					append(&td.pins, Topo_Pin{pos = pos, kind = .Clearance, comp = b.owner})
				}
			}
		}
	}
	if td.open_cells == 0 {td.hmin, td.hmax = 0, 0}

	// connectivity: flood fill walkable column-layers, 4-neighborhood,
	// step-up rule. Layers connect across CELL boundaries (deck onto bank,
	// underpass into open canyon), never vertically within one cell.
	for i in 0 ..< n2 {td.region[i] = -1}
	queue := make([dynamic]int, context.temp_allocator)
	for start in 0 ..< n2 {
		if !td.walk[start] || td.region[start] >= 0 {continue}
		id := i32(len(td.regions))
		append(&td.regions, Topo_Region{seed = topo_cell_pos(&td, start % n), floor = td.floor_v[start]})
		clear(&queue)
		append(&queue, start)
		td.region[start] = id
		for len(queue) > 0 {
			i := pop(&queue)
			td.regions[id].cells += 1
			cell := i % n
			x, z := cell % nx, cell / nx
			nbors := [4]int{cell - 1, cell + 1, cell - nx, cell + nx}
			ok := [4]bool{x > 0, x < nx - 1, z > 0, z < nz - 1}
			for j in 0 ..< 4 {
				if !ok[j] {continue}
				for l in 0 ..< TOPO_LAYERS {
					nb := l * n + nbors[j]
					if !td.walk[nb] || td.region[nb] >= 0 {continue}
					if abs(td.floor_v[nb] - td.floor_v[i]) > STEP_UP {continue}
					td.region[nb] = id
					append(&queue, nb)
				}
			}
		}
	}
	if len(td.regions) > 1 {
		for r, i in td.regions {
			append(&td.pins, Topo_Pin{
				pos = r.seed, kind = .Region, comp = -1,
				val = f32(r.cells), id = i32(i),
			})
		}
	}

	// slope: adjacent open cells of the SAME owner (different owners meeting
	// at a delta is a derived wall, which is legitimate geometry) — a too-
	// steep field is an authoring error, pinned to the nearest Hint (§3).
	// The neighbor's matching layer is found by owner (a bridge shadow can
	// shift one surface between layer indices across a cell boundary).
	slope_pins := 0
	for node in 0 ..< n2 {
		if !td.open[node] {continue}
		cell := node % n
		x, z := cell % nx, cell / nx
		for dir in 0 ..< 2 {
			nbcell := cell + 1 if dir == 0 else cell + nx
			if dir == 0 && x >= nx - 1 {continue}
			if dir == 1 && z >= nz - 1 {continue}
			nb := -1
			for l in 0 ..< TOPO_LAYERS {
				cand := l * n + nbcell
				if td.open[cand] && td.own[cand] == td.own[node] {nb = cand;break}
			}
			if nb < 0 {continue}
			rise := abs(td.floor_v[nb] - td.floor_v[node])
			if rise <= MAX_SLOPE * step {continue}
			td.slope_viol += 1
			if slope_pins < TOPO_PIN_MAX {
				slope_pins += 1
				append(&td.pins, Topo_Pin{
					pos = topo_cell_pos(&td, cell), kind = .Slope,
					comp = td.own[node], val = rise / step,
				})
			}
		}
	}

	// gamestart markers off walkable ground on EVERY layer (the ok/WARN lines
	// both format from the grid; only the violation earns an overlay pin)
	for &comp, ci in w.doc.components {
		if comp.kind != .Marker {continue}
		if name32_str(&comp.class) != "gamestart" || len(comp.points) == 0 {continue}
		pos := comp.points[0].pos
		if _, on_walk := topo_start_cell(&td, pos); !on_walk {
			append(&td.pins, Topo_Pin{pos = pos, kind = .Start, comp = i32(ci)})
		}
	}
	return
}

// topo_start_cell — map a marker to its grid cell and test walkability on both
// layers; the returned cell indexes the walkable layer when ok. floor() before
// int(): plain int() truncates toward zero, so positions just past the negative
// bounds would alias into cell 0 and read the wrong verdict.
topo_start_cell :: proc(td: ^Topo_Data, pos: [2]f32) -> (cell: int, ok: bool) {
	gx := int(math.floor((pos.x - td.origin.x) / td.step + 0.5))
	gz := int(math.floor((pos.y - td.origin.y) / td.step + 0.5))
	if gx < 0 || gx >= td.nx || gz < 0 || gz >= td.nz {return 0, false}
	cell = gz * td.nx + gx
	if td.walk[cell] {return cell, true}
	n := td.nx * td.nz
	if td.walk[n + cell] {return n + cell, true}
	return cell, false
}

// topo_report — the CLI/golden entry: build the data, format the text.
topo_report :: proc(w: ^Eval_World, b: ^strings.Builder) {
	td := topo_data_build(w, context.temp_allocator)
	topo_report_data(w, &td, b)
}

// topo_report_data appends the oracle's findings to `b`. Deterministic: fixed
// scan order over the lattice, no allocation-order dependence in the output.
topo_report_data :: proc(w: ^Eval_World, td: ^Topo_Data, b: ^strings.Builder) {
	step := td.step

	fmt.sbprintfln(b, "topo       %s (step %.4g, %dx%d cells)",
		name32_str(&w.doc.name), step, td.nx, td.nz)
	fmt.sbprintfln(b, "open       %d cells, %d walkable, %d clearance violations (< %.4g)",
		td.open_cells, td.walk_cells, td.clear_viol, f32(CLEARANCE))
	fmt.sbprintfln(b, "regions    %d", len(td.regions))
	for r, i in td.regions {
		fmt.sbprintfln(b, "  [%d] %d cells, seed (%.4g %.4g) floor %.4g",
			i, r.cells, r.seed.x, r.seed.y, r.floor)
	}
	if len(td.regions) > 1 {
		fmt.sbprintfln(b, "WARN %d walkable regions are mutually unreachable (step-up %.4g)",
			len(td.regions), f32(STEP_UP))
	}

	if td.slope_viol > 0 {
		fmt.sbprintfln(b, "WARN %d cell pairs exceed max walkable slope %.4g",
			td.slope_viol, f32(MAX_SLOPE))
		lines := 0
		for pin in td.pins {
			if pin.kind != .Slope || pin.comp < 0 {continue}
			if lines >= TOPO_WARN_MAX {break}
			lines += 1
			comp := &w.doc.components[pin.comp]
			hint := nearest_pin_hint(w, pin.comp, pin.pos)
			if hint != "" {
				fmt.sbprintfln(b, "  WARN slope %.3g at (%.4g %.4g) on %q (hint %q)",
					pin.val, pin.pos.x, pin.pos.y, name32_str(&comp.name), hint)
			} else {
				fmt.sbprintfln(b, "  WARN slope %.3g at (%.4g %.4g) on %q",
					pin.val, pin.pos.x, pin.pos.y, name32_str(&comp.name))
			}
		}
	} else {
		fmt.sbprintfln(b, "slope      ok (max %.4g)", f32(MAX_SLOPE))
	}

	// gamestart markers: must exist and stand on walkable ground
	starts := 0
	for &comp in w.doc.components {
		if comp.kind != .Marker {continue}
		class := name32_str(&comp.class)
		if class != "gamestart" || len(comp.points) == 0 {continue}
		starts += 1
		pos := comp.points[0].pos
		if cell, on_walk := topo_start_cell(td, pos); on_walk {
			fmt.sbprintfln(b, "start      (%.4g %.4g) floor %.4g region %d",
				pos.x, pos.y, td.floor_v[cell], td.region[cell])
		} else {
			fmt.sbprintfln(b, "WARN gamestart %q at (%.4g %.4g) is not on walkable ground",
				name32_str(&comp.name), pos.x, pos.y)
		}
	}
	if starts == 0 {
		fmt.sbprintfln(b, "WARN no gamestart marker")
	}

	// portal edge tags: named, and no doorname dangling with a single side
	portals, unnamed := 0, 0
	names := make([dynamic]Name32, context.temp_allocator)
	counts := make([dynamic]int, context.temp_allocator)
	for &comp in w.doc.components {
		for t in comp.edge_tags {
			if t.kind != .Portal {continue}
			portals += 1
			if t.args[0] == 0 {
				unnamed += 1
				continue
			}
			found := false
			for nm, j in names {
				if nm == t.args {
					counts[j] += 1
					found = true
					break
				}
			}
			if !found {
				append(&names, t.args)
				append(&counts, 1)
			}
		}
	}
	fmt.sbprintfln(b, "portals    %d tagged", portals)
	if unnamed > 0 {
		fmt.sbprintfln(b, "WARN %d portal edge tags carry no args", unnamed)
	}
	for &nm, j in names {
		if counts[j] == 1 {
			fmt.sbprintfln(b, "WARN portal %q has only one side", name32_str(&nm))
		}
	}
}

// nearest_pin_hint — name of the Hint whose pin sits closest to `pos` within
// component `idx`'s constraints ("" when the field has no pins).
@(private = "file")
nearest_pin_hint :: proc(w: ^Eval_World, idx: i32, pos: [2]f32) -> string {
	best := max(f32)
	src := i32(-1)
	for pin in w.comps[idx].pins {
		dx := pin.pos - pos
		d := dx.x * dx.x + dx.y * dx.y
		if d < best {
			best = d
			src = pin.src
		}
	}
	if src < 0 {return ""}
	return name32_str(&w.doc.components[src].name)
}
