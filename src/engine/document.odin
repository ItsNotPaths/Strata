package engine

// The vector document (DESIGN.md §2): a level is a flat, z-ordered list of 2D
// components. One geometric primitive — the path spline (cubic Bézier point
// chain, open or closed; tangents auto-derived per point until its handles
// are grabbed, Point_Mode) — specialized by kind. Everything 3D derives from
// this at load (field.odin → sdf.odin → mesh.odin); the file stores components,
// never geometry.
//
// Heights are FIELDS, not numbers (§3): base value + Hint constraints, solved
// over the shape interior. A Solid's base snaps to the surface below it — it
// grows from the underlying component's height up to its own top field.
// Walls are never stored anywhere: they are the derived boundary between
// adjacent components whose bands disagree by more than step-up.
//
// Serialization (§2a): the source document is EXTENDED SVG — SVG geometry
// (cubic paths, circles for Markers, group order = z-order) with our data as
// `strata:` namespaced attributes. The compile target is OBJ + a game-agnostic
// level sidecar (export.odin); the SVG is never derived data.

import "core:math/linalg"

NAME32 :: 32

// Name32 — NUL-padded small name (recipe/component/asset stem), the fixed POD
// form every name takes in file records. Same contract as dymeta/folly.
Name32 :: [NAME32]u8

name32 :: proc(s: string) -> (n: Name32) {
	copy(n[:NAME32 - 1], s)
	return
}

name32_str :: proc(n: ^Name32) -> string {
	for i in 0 ..< NAME32 {
		if n[i] == 0 {return string(n[:i])}
	}
	return string(n[:])
}

Component_Kind :: enum u8 {
	Sector, // closed: playspace void — floor field + ceiling
	Path,   // open: swept void — per-point width/floor/ceiling (corridors/streams/streets)
	Solid,  // closed: additive island — base snaps to surface below, top is a field
	Hint,   // point/open: pinned height constraint for the containing shape's field
	Marker, // point entity: class (model/enemy/npc/gamestart/…) + yaw/scale + args
	Bridge, // closed: floating rock slab [top − thickness, top] — walkable above,
	        // passable below. Deck top is a field pinned to the resolved surface
	        // under `bear`-tagged boundary segments, free elsewhere (§3).
	Cliff,  // closed: vertical rock column — flat top at `base`, HARD vertical
	        // walls (no blend/noise), extruded straight down to the lowest level.
	        // The "cliff blob": crisp architectural mesa/butte, unlike Solid's
	        // blended organic rock with a field top. No field, no ceiling.
}

// MARKER_ARGS sizes the marker-grammar args line — matches folly's UTIL chunk
// 256-byte args so the grammar ports without truncation.
MARKER_ARGS :: 256
Marker_Args :: [MARKER_ARGS]u8

// SKY as a ceiling sentinel: a Sector whose ceiling is SKY is an open canyon —
// the void simply extends past the meshing bounds' top (no cap geometry).
SKY :: max(f32)

// Point_Mode — Bézier-handle state per node (DESIGN.md §6, Inkscape node
// types). Auto derives tangents from neighbors (Catmull-Rom feel, no handles
// shown until grabbed); Smooth is manual with mirrored in/out handles; Corner
// is manual with independent handles (hard vertex). Dragging an Auto point's
// handle converts it. On disk, handles are the cubic control points of the
// SVG `d` string; modes ride as a chars-per-node attr (§2a).
Point_Mode :: enum u8 {
	Auto,
	Smooth,
	Corner,
}

// Doc_Point — one spline point. Per-point attrs only matter for some kinds
// (width/floor/ceiling on Path; h on Hint polylines); unused fields stay 0.
Doc_Point :: struct {
	pos:        [2]f32,
	mode:       Point_Mode,
	handle_in:  [2]f32, // tangent handle, offset from pos; ignored when Auto
	handle_out: [2]f32,
	width:      f32, // Path: half-width of the swept void. (Hints have no
	                 // width — a fall-line fills the shape it overlaps, §3.)
	floor:      f32, // Path: floor height at this point
	ceiling:    f32, // Path: ceiling height at this point (SKY allowed)
	h:          f32, // Hint: crest height at this point (the swept profile, §3)
}

// Edge_Tag — attrs on a closed-spline boundary segment i → i+1 (DESIGN.md §2).
Edge_Tag_Kind :: enum u8 {
	None,
	Ramp,   // traversable transition instead of a derived wall
	Cliff,  // force a wall even where the height delta alone wouldn't
	Portal, // folly marker grammar attaches via `args`
	Bear,   // Bridge bearing edge: deck field boundary pins to the resolved
	        // surface below this segment (abutment); untagged edges span free
	Bleed,  // Sector/Solid: leave this boundary segment FREE (no-flux) instead
	        // of pinning it to base, so an interior slope (a hint) flows through
	        // the outline and the derived wall rides the hint-driven rim (§3)
}

Edge_Tag :: struct {
	segment: i32, // index of the boundary segment this tags
	kind:    Edge_Tag_Kind,
	args:    Name32, // Portal: doorname/connection/clearflag line (marker-grammar)
}

Component :: struct {
	kind:         Component_Kind,
	name:         Name32,
	z_order:      i32,  // overlap resolution: later wins within intersections (§1)
	seed:         u32,  // per-component determinism for noise/generators
	is_dynamic:   bool, // meshed as own island, toggleable at runtime (§4)
	closed:       bool,

	// heights (fields, §3): base value; Hints inside the shape refine it.
	// Sector/Path: floor is the field. Solid: top is the field, base derived.
	base:         f32,
	ceiling:      f32, // Sector: SKY or a height. Path: per-point default.
	                   // Solid/Cliff/Marker/Hint: unused.

	// look (§4): smooth-min radius (~0 = hard masonry, large = organic rock)
	// + noise displacement amplitude on the SDF.
	blend_radius: f32,
	noise_amp:    f32,

	// Bridge only: deck slab thickness — rock band [top − thickness, top].
	thickness:    f32,
	// Bridge only: layer weight — where two bridge slabs occupy the same space
	// (a crisscross), the higher weight wins and the lower yields (§4). Ties
	// break on z. Overpasses at different heights don't conflict, so weight is
	// irrelevant there.
	weight:       f32,

	// materials by texgen recipe name; the angle splitter assigns by normal.
	mat_floor:    Name32,
	mat_wall:     Name32,
	mat_ceiling:  Name32,

	// Marker only (DESIGN.md §2): Hammer-style point entity. `class` says what
	// it is (tool-known: model/enemy/npc/gamestart; else opaque to the tool,
	// resolved by the game); `model` fills for class=model; `args` is a
	// marker-grammar line (folly docs/marker-grammar.md). Canvas gives
	// pos/yaw/scale handles; everything else tweaks live in the sidebar.
	class:        Name32,
	model:        Name32,
	yaw:          f32,
	scale:        f32,
	cover:        bool, // class=model: authored-cover gameplay tag
	args:         Marker_Args,

	points:       [dynamic]Doc_Point,
	edge_tags:    [dynamic]Edge_Tag,
}

Document :: struct {
	name:       Name32,
	components: [dynamic]Component,
	// meta — opaque level-metadata lines (game-agnostic: the tool stores and
	// round-trips them, never interprets them). On disk they ride a
	// <strata:meta> element; on export they lead the level sidecar txt.
	meta:       [dynamic]string, // heap-owned lines
}

component_clone :: proc(c: ^Component) -> (out: Component) {
	out = c^
	out.points = make([dynamic]Doc_Point, len(c.points))
	copy(out.points[:], c.points[:])
	out.edge_tags = make([dynamic]Edge_Tag, len(c.edge_tags))
	copy(out.edge_tags[:], c.edge_tags[:])
	return
}

document_destroy :: proc(doc: ^Document) {
	for &c in doc.components {
		delete(c.points)
		delete(c.edge_tags)
	}
	delete(doc.components)
	for line in doc.meta {delete(line)}
	delete(doc.meta)
	doc^ = {}
}

// The on-disk name tables — one source for reader (svg.odin), writer
// (svg_write.odin), and any generator, so the mappings can't drift.
KIND_NAMES := [Component_Kind]string {
	.Sector = "sector",
	.Path   = "path",
	.Solid  = "solid",
	.Hint   = "hint",
	.Marker = "marker",
	.Bridge = "bridge",
	.Cliff  = "cliff",
}

kind_from_name :: proc(s: string) -> (k: Component_Kind, ok: bool) {
	for name, kk in KIND_NAMES {
		if name == s {return kk, true}
	}
	return .Sector, false
}

EDGE_TAG_NAMES := [Edge_Tag_Kind]string {
	.None   = "none",
	.Ramp   = "ramp",
	.Cliff  = "cliff",
	.Portal = "portal",
	.Bear   = "bear",
	.Bleed  = "bleed",
}

edge_tag_from_name :: proc(s: string) -> (k: Edge_Tag_Kind, ok: bool) {
	if s == "door" {return .Portal, true} // marker-grammar alias
	for name, kk in EDGE_TAG_NAMES {
		if name == s {return kk, true}
	}
	return .None, false
}

// auto_tangents recomputes a point's handles when its mode is Auto: tangent
// along prev→next (Catmull-Rom feel), scaled by a third of each neighbor
// distance. Open-spline endpoints retract (straight into the curve). Part of
// the document schema, not the editor: Auto nodes rewrite their `d` control
// points whenever a neighbor moves (§2a), so anything that mutates points —
// editor drag or headless generator — must call this before saving.
auto_tangents :: proc(comp: ^Component, i: int) {
	n := len(comp.points)
	if i < 0 || i >= n {return}
	p := &comp.points[i]
	if p.mode != .Auto {return}
	has_prev := comp.closed || i > 0
	has_next := comp.closed || i < n - 1
	if !has_prev || !has_next || n < 3 {
		p.handle_in = {}
		p.handle_out = {}
		return
	}
	prev := comp.points[(i - 1 + n) % n].pos
	next := comp.points[(i + 1) % n].pos
	t := next - prev
	tl := linalg.length(t)
	if tl < 1e-6 {
		p.handle_in = {}
		p.handle_out = {}
		return
	}
	dir := t / tl
	p.handle_out = dir * linalg.length(next - p.pos) / 3
	p.handle_in = -dir * linalg.length(prev - p.pos) / 3
}

auto_tangents_around :: proc(comp: ^Component, i: int) {
	n := len(comp.points)
	if n == 0 {return}
	for off in -1 ..= 1 {
		k := i + off
		if comp.closed {
			k = (k + n) % n
		} else if k < 0 || k >= n {
			continue
		}
		auto_tangents(comp, k)
	}
}
