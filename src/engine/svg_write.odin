package engine

// Extended-SVG document writer (DESIGN.md §2a) — the editor's save path.
// Emits exactly the subset svg.odin reads back: <path> per spline component
// (cubic control points in `d` ARE the Bézier handles), <circle> per Marker /
// point Hint, document order = z-order. Presentation attrs (fill/stroke, from
// the same seeded golden-ratio hue walk the canvas uses) make the file render
// as a colored plan in any browser; the loader ignores them.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"

document_save_svg :: proc(doc: ^Document, path: string) -> bool {
	b := strings.builder_make(context.temp_allocator)

	// bounds (points + handles) for width/height/viewBox, padded
	lo := [2]f32{max(f32), max(f32)}
	hi := [2]f32{-max(f32), -max(f32)}
	any_pt := false
	for &c in doc.components {
		for &p in c.points {
			for q in ([3][2]f32{p.pos, p.pos + p.handle_in, p.pos + p.handle_out}) {
				lo.x = min(lo.x, q.x); lo.y = min(lo.y, q.y)
				hi.x = max(hi.x, q.x); hi.y = max(hi.y, q.y)
			}
			any_pt = true
		}
	}
	if !any_pt {
		lo, hi = {0, 0}, {64, 48}
	}
	pad := f32(4)
	lo -= pad
	hi += pad

	fmt.sbprintln(&b, `<?xml version="1.0" encoding="UTF-8"?>`)
	fmt.sbprint(&b, `<svg xmlns="http://www.w3.org/2000/svg"`)
	fmt.sbprint(&b, "\n     xmlns:strata=\"https://strata.tool/ns\"\n     ")
	fmt.sbprintf(&b, `width="%s" height="%s" viewBox="%s %s %s %s">`,
		f(hi.x - lo.x), f(hi.y - lo.y), f(lo.x), f(lo.y), f(hi.x - lo.x), f(hi.y - lo.y))
	fmt.sbprintln(&b)

	// opaque level-metadata lines (§2a) — game-agnostic, never interpreted
	if len(doc.meta) > 0 {
		fmt.sbprintln(&b, "  <strata:meta>")
		for line in doc.meta {fmt.sbprintfln(&b, "    %s", xesc(line))}
		fmt.sbprintln(&b, "  </strata:meta>")
	}

	// stable z-order walk (the loader re-derives z_order from element order)
	order := make([]int, len(doc.components), context.temp_allocator)
	for i in 0 ..< len(order) {order[i] = i}
	for i in 1 ..< len(order) {
		j := i
		for j > 0 && doc.components[order[j - 1]].z_order > doc.components[order[j]].z_order {
			order[j - 1], order[j] = order[j], order[j - 1]
			j -= 1
		}
	}

	for oi in order {
		c := &doc.components[oi]
		if len(c.points) == 0 {continue}
		if c.kind == .Marker || (c.kind == .Hint && len(c.points) == 1) {
			write_circle(&b, c)
		} else {
			write_path(&b, c)
		}
	}

	fmt.sbprintln(&b, "</svg>")

	if werr := os.write_entire_file(path, b.buf[:]); werr != nil {
		diagf(.Error, "svg: cannot write %q: %v", path, werr)
		return false
	}
	return true
}

// xesc — XML escaping for free-form strings (names, material/class names,
// args, meta lines). The loader decodes entities (.Decode_SGML_Entities);
// this is the other half of the round-trip — without it a single `&` typed
// into a name field makes the saved file refuse to parse.
//
// Quirk shield: core:xml's entity decoder swallows literal whitespace that
// directly follows a decoded entity ("a &amp; b" loads as "a &b"), so any
// space right after an entity is written as &#32; — which decodes cleanly.
@(private = "file")
xesc :: proc(s: string) -> string {
	if strings.index_any(s, `&<>"`) < 0 {return s}
	b := strings.builder_make(context.temp_allocator)
	after_entity := false
	for ch in s {
		emitted_entity := true
		switch ch {
		case '&':
			strings.write_string(&b, "&amp;")
		case '<':
			strings.write_string(&b, "&lt;")
		case '>':
			strings.write_string(&b, "&gt;")
		case '"':
			strings.write_string(&b, "&quot;")
		case ' ':
			if after_entity {
				strings.write_string(&b, "&#32;")
			} else {
				strings.write_byte(&b, ' ')
				emitted_entity = false
			}
		case:
			strings.write_rune(&b, ch)
			emitted_entity = false
		}
		after_entity = emitted_entity
	}
	return strings.to_string(b)
}

// f — shortest round-trip float formatting (temp-allocated string).
@(private = "file")
f :: proc(v: f32) -> string {
	buf := make([]byte, 32, context.temp_allocator)
	s := strconv.write_float(buf, f64(v), 'g', -1, 32)
	// strconv prefixes positives with '+'
	if len(s) > 0 && s[0] == '+' {s = s[1:]}
	return s
}

@(private = "file")
write_common_attrs :: proc(b: ^strings.Builder, c: ^Component) {
	if n := name32_str(&c.name); n != "" {
		fmt.sbprintf(b, ` strata:name="%s"`, xesc(n))
	}
	if c.seed != 0 {fmt.sbprintf(b, ` strata:seed="%d"`, c.seed)}
	if c.kind == .Sector || c.kind == .Path || c.kind == .Solid || c.kind == .Bridge || c.kind == .Cliff {
		fmt.sbprintf(b, ` strata:base="%s"`, f(c.base))
	}
	if c.kind == .Bridge {
		fmt.sbprintf(b, ` strata:thickness="%s"`, f(c.thickness))
		if c.weight != 0 {fmt.sbprintf(b, ` strata:weight="%s"`, f(c.weight))}
	}
	if c.kind == .Sector || c.kind == .Path {
		if c.ceiling == SKY {
			fmt.sbprint(b, ` strata:ceiling="sky"`)
		} else {
			fmt.sbprintf(b, ` strata:ceiling="%s"`, f(c.ceiling))
		}
	}
	if c.blend_radius != 0 {fmt.sbprintf(b, ` strata:blend="%s"`, f(c.blend_radius))}
	if c.noise_amp != 0 {fmt.sbprintf(b, ` strata:noise="%s"`, f(c.noise_amp))}
	if c.is_dynamic {fmt.sbprint(b, ` strata:dynamic="true"`)}
	if n := name32_str(&c.mat_floor); n != "" {fmt.sbprintf(b, ` strata:mat-floor="%s"`, xesc(n))}
	if n := name32_str(&c.mat_wall); n != "" {fmt.sbprintf(b, ` strata:mat-wall="%s"`, xesc(n))}
	if n := name32_str(&c.mat_ceiling); n != "" {fmt.sbprintf(b, ` strata:mat-ceiling="%s"`, xesc(n))}
}

// comp_hue — seeded golden-ratio hue walk (§6). ONE implementation: the file's
// presentation fill, the editor canvas, and any future views all call this, so
// document colors and tool colors can't drift.
comp_hue :: proc(kind: Component_Kind, seed: u32, idx: int) -> f32 {
	s := seed != 0 ? seed : u32(idx) * 7 + 3
	t := math.mod(f32(s) * 0.61803398875, 1)
	switch kind {
	case .Sector, .Path:
		return 0.38 + 0.40 * t
	case .Solid:
		return math.mod(0.94 + 0.22 * t, 1)
	case .Hint:
		return 0.79
	case .Marker:
		return 0.12
	case .Bridge:
		return 0.47 + 0.08 * t
	case .Cliff:
		return 0.06 + 0.03 * t // earthy orange-brown, distinct from Solid's magenta
	}
	return 0
}

@(private = "file")
comp_fill_hex :: proc(c: ^Component, idx: int) -> string {
	h := comp_hue(c.kind, c.seed, idx)
	// hsv(h, .55, .85) → hex
	i := int(h * 6) % 6
	fr := h * 6 - f32(int(h * 6))
	v, sat := f32(0.85), f32(0.55)
	p := v * (1 - sat)
	q := v * (1 - sat * fr)
	tt := v * (1 - sat * (1 - fr))
	r, g, bl: f32
	switch i {
	case 0: r, g, bl = v, tt, p
	case 1: r, g, bl = q, v, p
	case 2: r, g, bl = p, v, tt
	case 3: r, g, bl = p, q, v
	case 4: r, g, bl = tt, p, v
	case 5: r, g, bl = v, p, q
	}
	return fmt.tprintf("#%02x%02x%02x", int(r * 255), int(g * 255), int(bl * 255))
}

@(private = "file")
write_path :: proc(b: ^strings.Builder, c: ^Component) {
	n := len(c.points)
	fmt.sbprint(b, `  <path d="`)
	p0 := c.points[0]
	fmt.sbprintf(b, "M %s %s", f(p0.pos.x), f(p0.pos.y))
	seg_count := c.closed ? n : n - 1
	for s in 0 ..< seg_count {
		a := &c.points[s]
		pb := &c.points[(s + 1) % n]
		if a.handle_out == {} && pb.handle_in == {} {
			if s == n - 1 {continue} // straight closing segment: Z suffices
			fmt.sbprintf(b, " L %s %s", f(pb.pos.x), f(pb.pos.y))
		} else {
			c1 := a.pos + a.handle_out
			c2 := pb.pos + pb.handle_in
			fmt.sbprintf(
				b, " C %s %s, %s %s, %s %s",
				f(c1.x), f(c1.y), f(c2.x), f(c2.y), f(pb.pos.x), f(pb.pos.y),
			)
		}
	}
	if c.closed {fmt.sbprint(b, " Z")}
	fmt.sbprint(b, `"`)

	fmt.sbprintf(b, ` strata:kind="%s"`, KIND_NAMES[c.kind])
	write_common_attrs(b, c)

	// per-point metadata arrays (§2a) — skipped only when every value equals
	// the LOADER's default for that point (svg.odin), so an authored value
	// that happens to be 0 still round-trips.
	if c.kind == .Path {
		write_point_array(b, c, "strata:widths", offset_of(Doc_Point, width), 2)
		write_point_array(b, c, "strata:floors", offset_of(Doc_Point, floor), c.base)
		write_point_array(b, c, "strata:ceilings", offset_of(Doc_Point, ceiling), c.ceiling)
	}
	if c.kind == .Hint {
		// a Hint is a fall-line: only the per-node height profile is authored;
		// there is no radius (the tilt fills the shape it overlaps, §3).
		write_point_array(b, c, "strata:hs", offset_of(Doc_Point, h), 0)
	}
	any_mode := false
	for &p in c.points {
		if p.mode != .Corner {any_mode = true;break}
	}
	if any_mode {
		fmt.sbprint(b, ` strata:nodes="`)
		for &p in c.points {
			switch p.mode {
			case .Auto:   fmt.sbprint(b, "a")
			case .Smooth: fmt.sbprint(b, "s")
			case .Corner: fmt.sbprint(b, "c")
			}
		}
		fmt.sbprint(b, `"`)
	}
	if len(c.edge_tags) > 0 {
		fmt.sbprint(b, ` strata:edge-tags="`)
		for &t, k in c.edge_tags {
			if t.kind == .None {continue}
			if k > 0 {fmt.sbprint(b, " ")}
			tag := t
			if args := name32_str(&tag.args); args != "" {
				fmt.sbprintf(b, "%d:%s:%s", t.segment, EDGE_TAG_NAMES[t.kind], xesc(args))
			} else {
				fmt.sbprintf(b, "%d:%s", t.segment, EDGE_TAG_NAMES[t.kind])
			}
		}
		fmt.sbprint(b, `"`)
	}

	// presentation for browsers (ignored by the loader)
	idx := int(c.z_order)
	if c.closed {
		fmt.sbprintf(b, ` fill="%s" fill-opacity="0.35" stroke="#446" stroke-width="0.3"`, comp_fill_hex(c, idx))
	} else {
		fmt.sbprintf(b, ` fill="none" stroke="%s" stroke-width="0.4"`, comp_fill_hex(c, idx))
	}
	fmt.sbprintln(b, "/>")
}

@(private = "file")
write_point_array :: proc(b: ^strings.Builder, c: ^Component, key: string, field_offset: uintptr, def: f32) {
	any_non_default := false
	for &p in c.points {
		if (^f32)(uintptr(&p) + field_offset)^ != def {any_non_default = true;break}
	}
	if !any_non_default {return}
	fmt.sbprintf(b, ` %s="`, key)
	for &p, k in c.points {
		if k > 0 {fmt.sbprint(b, " ")}
		v := (^f32)(uintptr(&p) + field_offset)^
		if v == SKY {
			fmt.sbprint(b, "sky")
		} else {
			fmt.sbprint(b, f(v))
		}
	}
	fmt.sbprint(b, `"`)
}

@(private = "file")
write_circle :: proc(b: ^strings.Builder, c: ^Component) {
	p := c.points[0]
	if c.kind == .Hint {
		// point Hint: a single pinned height, held across the shape it overlaps
		// (no radius). A small nominal r just makes browsers render the marker.
		fmt.sbprintf(
			b, `  <circle cx="%s" cy="%s" r="0.6" strata:kind="hint" strata:h="%s"`,
			f(p.pos.x), f(p.pos.y), f(p.h),
		)
		write_common_attrs(b, c)
		fmt.sbprintf(b, ` fill="%s"`, comp_fill_hex(c, int(c.z_order)))
		fmt.sbprintln(b, "/>")
		return
	}
	fmt.sbprintf(b, `  <circle cx="%s" cy="%s" r="1" strata:kind="marker"`, f(p.pos.x), f(p.pos.y))
	if n := name32_str(&c.class); n != "" {fmt.sbprintf(b, ` strata:class="%s"`, xesc(n))}
	if n := name32_str(&c.model); n != "" {fmt.sbprintf(b, ` strata:model="%s"`, xesc(n))}
	if c.yaw != 0 {fmt.sbprintf(b, ` strata:yaw="%s"`, f(c.yaw))}
	if c.scale != 1 {fmt.sbprintf(b, ` strata:scale="%s"`, f(c.scale))}
	if c.cover {fmt.sbprint(b, ` strata:cover="true"`)}
	args := c.args
	args_s := string(cstring(&args[0]))
	if args_s != "" {fmt.sbprintf(b, ` strata:args="%s"`, xesc(args_s))}
	write_common_attrs(b, c)
	fmt.sbprintf(b, ` fill="%s"`, comp_fill_hex(c, int(c.z_order)))
	fmt.sbprintln(b, "/>")
}
