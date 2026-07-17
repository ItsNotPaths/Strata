package engine

// Extended-SVG document reader (DESIGN.md §2a). The source of truth is valid
// SVG carrying a `strata:` attribute namespace: <path> elements are spline
// components (cubic segments in the `d` string ARE the Bézier handles),
// <circle> elements are Markers, and document/group order is z-order.
//
// Strict subset on read — we parse only what we write (paths, circles, <g>
// groups) plus what survives an Inkscape round-trip; unknown elements and
// attributes are skipped with a warning at most. `transform` is NOT honored
// (flatten transforms before handing a sketch to strata).

import "core:encoding/xml"
import "core:fmt"
import "core:strconv"
import "core:strings"

// document_load_svg parses `path` into a Document. On any structural error it
// eprintfln's and returns ok=false; per-element oddities warn and skip so a
// half-sketched Inkscape file still loads what it can.
document_load_svg :: proc(path: string) -> (doc: Document, ok: bool) {
	xdoc, err := xml.load_from_file(path, {flags = {.Ignore_Unsupported, .Decode_SGML_Entities}})
	if err != .None {
		fmt.eprintfln("svg: %q: parse error %v", path, err)
		return {}, false
	}
	defer xml.destroy(xdoc)

	if xdoc.element_count == 0 || xdoc.elements[0].ident != "svg" {
		fmt.eprintfln("svg: %q: root element is not <svg>", path)
		return {}, false
	}

	doc.name = name32(stem_from_path(path))
	load_children(&doc, xdoc, 0, path)
	return doc, true
}

@(private = "file")
load_children :: proc(doc: ^Document, xdoc: ^xml.Document, parent: xml.Element_ID, path: string) {
	for value in xdoc.elements[parent].value {
		id, is_elem := value.(xml.Element_ID)
		if !is_elem {continue}
		el := &xdoc.elements[id]
		if el.kind != .Element {continue}
		switch el.ident {
		case "g":
			load_children(doc, xdoc, id, path) // group order = z-order, flattened
		case "path":
			load_path(doc, el, path)
		case "circle":
			load_circle(doc, el, path)
		case "strata:meta":
			load_meta(doc, xdoc, id)
		case "defs", "metadata", "title", "desc", "style", "namedview", "sodipodi:namedview":
		// editor/browser furniture, ignored silently
		case:
			fmt.eprintfln("svg: %q: skipping unsupported element <%s>", path, el.ident)
		}
	}
}

// load_meta — the <strata:meta> element's text content: opaque level-metadata
// lines (§2a), one per line, stored verbatim (trimmed). Game-agnostic: the
// tool never interprets them, only round-trips and re-emits on export.
@(private = "file")
load_meta :: proc(doc: ^Document, xdoc: ^xml.Document, id: xml.Element_ID) {
	for value in xdoc.elements[id].value {
		text, is_text := value.(string)
		if !is_text {continue}
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(line)
			if t != "" {append(&doc.meta, strings.clone(t))}
		}
	}
}

@(private = "file")
attr :: proc(el: ^xml.Element, key: string) -> (string, bool) {
	for a in el.attribs {
		if a.key == key {return a.val, true}
	}
	return "", false
}

@(private = "file")
attr_f32 :: proc(el: ^xml.Element, key: string, def: f32) -> f32 {
	if s, found := attr(el, key); found {
		if v, pok := strconv.parse_f32(strings.trim_space(s)); pok {return v}
		fmt.eprintfln("svg: attribute %s=%q is not a number, using %v", key, s, def)
	}
	return def
}

// shared strata: attrs (DESIGN.md §2) — everything but kind and geometry.
// attr_u32 — integer parse (base 10), NOT a route through f32: seeds above
// 2²⁴ would lose bits and drift noise/hue vs. the file as written.
@(private = "file")
attr_u32 :: proc(el: ^xml.Element, key: string, def: u32) -> u32 {
	if s, found := attr(el, key); found {
		if v, pok := strconv.parse_uint(strings.trim_space(s), 10); pok {return u32(v)}
		fmt.eprintfln("svg: attribute %s=%q is not an unsigned integer, using %v", key, s, def)
	}
	return def
}

@(private = "file")
load_common_attrs :: proc(c: ^Component, el: ^xml.Element) {
	if s, found := attr(el, "strata:name"); found {c.name = name32(s)}
	c.seed = attr_u32(el, "strata:seed", 0)
	c.base = attr_f32(el, "strata:base", 0)
	if s, found := attr(el, "strata:ceiling"); found && strings.trim_space(s) == "sky" {
		c.ceiling = SKY
	} else {
		c.ceiling = attr_f32(el, "strata:ceiling", 0)
	}
	c.blend_radius = attr_f32(el, "strata:blend", 0)
	c.noise_amp = attr_f32(el, "strata:noise", 0)
	if s, found := attr(el, "strata:dynamic"); found {c.is_dynamic = s == "true" || s == "1"}
	if s, found := attr(el, "strata:mat-floor"); found {c.mat_floor = name32(s)}
	if s, found := attr(el, "strata:mat-wall"); found {c.mat_wall = name32(s)}
	if s, found := attr(el, "strata:mat-ceiling"); found {c.mat_ceiling = name32(s)}
}

@(private = "file")
load_path :: proc(doc: ^Document, el: ^xml.Element, path: string) {
	d, has_d := attr(el, "d")
	if !has_d {
		fmt.eprintfln("svg: %q: <path> without d attribute, skipped", path)
		return
	}
	if _, has_tf := attr(el, "transform"); has_tf {
		fmt.eprintfln("svg: %q: <path> has a transform, which strata ignores — flatten it", path)
	}

	c: Component
	c.z_order = i32(len(doc.components))
	points, closed, pok := parse_path_d(d)
	if !pok {
		fmt.eprintfln("svg: %q: unparseable path d=%q, skipped", path, d)
		delete(points)
		return
	}
	c.points = points
	c.closed = closed

	kind_s, has_kind := attr(el, "strata:kind")
	if k, kok := kind_from_name(kind_s); kok && k != .Marker {
		c.kind = k
	} else if !has_kind && closed {
		// Inkscape sketch without our attrs: closed footprint reads as a void.
		c.kind = .Sector
		c.ceiling = SKY
	} else {
		fmt.eprintfln("svg: %q: path with strata:kind=%q (closed=%v) skipped", path, kind_s, closed)
		delete(c.points)
		return
	}
	load_common_attrs(&c, el)
	if c.kind == .Bridge {
		c.thickness = attr_f32(el, "strata:thickness", 1)
		c.weight = attr_f32(el, "strata:weight", 0)
	}
	if c.kind == .Path {
		// sketch-friendly default: an open stroke reads as an open-air route
		if _, found := attr(el, "strata:ceiling"); !found {c.ceiling = SKY}
	}

	// per-point metadata rides beside the d string as number arrays (§2a).
	// Path per-point floor/ceiling default to the component attrs, so plain
	// strokes (and Inkscape sketches) get a sane band without the arrays.
	if c.kind == .Path {
		for &p in c.points {
			p.width = 2
			p.floor = c.base
			p.ceiling = c.ceiling
		}
	}
	// Hints are fall-lines with no radius (§3); ignore any legacy widths on them.
	if s, found := attr(el, "strata:widths"); found && c.kind != .Hint {
		load_point_array(&c, s, offset_of(Doc_Point, width))
	}
	if s, found := attr(el, "strata:floors"); found {load_point_array(&c, s, offset_of(Doc_Point, floor))}
	if s, found := attr(el, "strata:ceilings"); found {load_point_array(&c, s, offset_of(Doc_Point, ceiling))}
	if s, found := attr(el, "strata:hs"); found {load_point_array(&c, s, offset_of(Doc_Point, h))}
	if s, found := attr(el, "strata:nodes"); found {
		for i in 0 ..< min(len(s), len(c.points)) {
			switch s[i] {
			case 'a':
				c.points[i].mode = .Auto
			case 's':
				c.points[i].mode = .Smooth
			case 'c':
				c.points[i].mode = .Corner
			}
		}
	}
	if s, found := attr(el, "strata:edge-tags"); found {load_edge_tags(&c, s, path)}

	append(&doc.components, c)
}

// load_point_array writes a whitespace-separated number list onto one f32
// field of each Doc_Point (width/floor/ceiling/h), by field offset.
@(private = "file")
load_point_array :: proc(c: ^Component, s: string, field_offset: uintptr) {
	rest := s
	i := 0
	for tok in strings.split_iterator(&rest, " ") {
		if tok == "" {continue}
		if i >= len(c.points) {break}
		v: f32
		if tok == "sky" {
			v = SKY
		} else if parsed, pok := strconv.parse_f32(tok); pok {
			v = parsed
		} else {
			continue
		}
		(^f32)(uintptr(&c.points[i]) + field_offset)^ = v
		i += 1
	}
}

// edge tags: whitespace-separated `segment:kind[:args]` tokens, e.g.
// "3:ramp 7:portal:doorname=exit_a" (DESIGN.md §2). Args may contain spaces
// (marker-grammar lines), so a token only STARTS a new tag when it parses as
// `int:…`; anything else continues the previous tag's args.
@(private = "file")
load_edge_tags :: proc(c: ^Component, s: string, path: string) {
	starts_tag :: proc(tok: string) -> bool {
		i := strings.index_byte(tok, ':')
		if i <= 0 {return false}
		_, ok := strconv.parse_int(tok[:i])
		return ok
	}
	parse_one :: proc(c: ^Component, tok: string, path: string) {
		parts := strings.split_n(tok, ":", 3, context.temp_allocator)
		if len(parts) < 2 {
			fmt.eprintfln("svg: %q: bad edge tag %q, skipped", path, tok)
			return
		}
		seg, sok := strconv.parse_int(parts[0])
		if !sok || seg < 0 { // negative would index seg_start[-1] → panic at eval
			fmt.eprintfln("svg: %q: bad edge tag segment in %q, skipped", path, tok)
			return
		}
		kind, kok := edge_tag_from_name(parts[1])
		if !kok || kind == .None {
			fmt.eprintfln("svg: %q: unknown edge tag kind %q, skipped", path, tok)
			return
		}
		tag := Edge_Tag {
			segment = i32(seg),
			kind    = kind,
		}
		if len(parts) == 3 {tag.args = name32(parts[2])}
		append(&c.edge_tags, tag)
	}

	toks := strings.fields(s, context.temp_allocator)
	i := 0
	for i < len(toks) {
		if !starts_tag(toks[i]) {
			fmt.eprintfln("svg: %q: bad edge tag %q, skipped", path, toks[i])
			i += 1
			continue
		}
		full := strings.builder_make(context.temp_allocator)
		strings.write_string(&full, toks[i])
		i += 1
		for i < len(toks) && !starts_tag(toks[i]) {
			strings.write_byte(&full, ' ')
			strings.write_string(&full, toks[i])
			i += 1
		}
		parse_one(c, strings.to_string(full), path)
	}
}

@(private = "file")
load_circle :: proc(doc: ^Document, el: ^xml.Element, path: string) {
	c: Component
	c.kind = .Marker
	c.z_order = i32(len(doc.components))
	c.scale = 1
	pt: Doc_Point
	pt.pos = {attr_f32(el, "cx", 0), attr_f32(el, "cy", 0)}
	append(&c.points, pt)

	kind_s, _ := attr(el, "strata:kind")
	if kind_s == "hint" {
		// point Hint: a single pinned height sample (§3), held across the shape
		// it overlaps (no radius — legacy strata:radius is ignored).
		c.kind = .Hint
		c.points[0].h = attr_f32(el, "strata:h", 0)
		load_common_attrs(&c, el)
		append(&doc.components, c)
		return
	}
	if kind_s != "" && kind_s != "marker" {
		fmt.eprintfln("svg: %q: circle with strata:kind=%q skipped", path, kind_s)
		delete(c.points)
		return
	}
	load_common_attrs(&c, el)
	if s, found := attr(el, "strata:class"); found {c.class = name32(s)}
	if s, found := attr(el, "strata:model"); found {c.model = name32(s)}
	c.yaw = attr_f32(el, "strata:yaw", 0)
	c.scale = attr_f32(el, "strata:scale", 1)
	if s, found := attr(el, "strata:cover"); found {c.cover = s == "true" || s == "1"}
	if s, found := attr(el, "strata:args"); found {
		copy(c.args[:MARKER_ARGS - 1], s)
	}
	append(&doc.components, c)
}

// --- path data ---------------------------------------------------------------

// parse_path_d converts an SVG path `d` string into Doc_Points. Supported:
// M/m L/l H/h V/v C/c Z/z, one subpath. Cubic control points become the
// point's handle_out / next point's handle_in (offsets from their anchor);
// a trailing curve back to the start folds into the closing segment instead
// of duplicating the first point.
@(private = "file")
parse_path_d :: proc(d: string) -> (points: [dynamic]Doc_Point, closed: bool, ok: bool) {
	p := D_Parser {
		s = d,
	}
	cur: [2]f32
	cmd: u8
	for {
		d_skip_ws(&p)
		if p.i >= len(p.s) {break}
		ch := p.s[p.i]
		if (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') {
			cmd = ch
			p.i += 1
		} else if cmd == 0 {
			return points, false, false // numbers before any command
		}
		// implicit repeat: M repeats as L per the SVG spec
		if cmd == 'M' && len(points) > 0 {cmd = 'L'}
		if cmd == 'm' && len(points) > 0 {cmd = 'l'}

		rel := cmd >= 'a'
		switch cmd {
		case 'M', 'm', 'L', 'l':
			v := d_num2(&p) or_return
			if rel {v += cur}
			cur = v
			append(&points, Doc_Point{pos = cur, mode = .Corner})
		case 'H', 'h':
			x := d_num(&p) or_return
			cur.x = cur.x + x if rel else x
			append(&points, Doc_Point{pos = cur, mode = .Corner})
		case 'V', 'v':
			y := d_num(&p) or_return
			cur.y = cur.y + y if rel else y
			append(&points, Doc_Point{pos = cur, mode = .Corner})
		case 'C', 'c':
			if len(points) == 0 {return points, false, false}
			c1 := d_num2(&p) or_return
			c2 := d_num2(&p) or_return
			end := d_num2(&p) or_return
			if rel {
				c1 += cur
				c2 += cur
				end += cur
			}
			points[len(points) - 1].handle_out = c1 - cur
			cur = end
			append(&points, Doc_Point{pos = end, mode = .Corner, handle_in = c2 - end})
		case 'Z', 'z':
			closed = true
			d_skip_ws(&p)
			if p.i < len(p.s) {
				return points, false, false // multiple subpaths unsupported
			}
		case:
			return points, false, false // A/S/Q/T not in our subset
		}
	}
	// A closed path whose final curve lands back on the start duplicates the
	// first point — fold it into the closing segment. Only under Z: an OPEN
	// path whose last node was point-snapped onto its first must keep both.
	if closed && len(points) >= 2 && points[len(points) - 1].pos == points[0].pos {
		points[0].handle_in = points[len(points) - 1].handle_in
		pop(&points)
	}
	return points, closed, len(points) > 0
}

@(private = "file")
D_Parser :: struct {
	s: string,
	i: int,
}

@(private = "file")
d_skip_ws :: proc(p: ^D_Parser) {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r', ',':
			p.i += 1
		case:
			return
		}
	}
}

@(private = "file")
d_num :: proc(p: ^D_Parser) -> (v: f32, ok: bool) {
	d_skip_ws(p)
	start := p.i
	for p.i < len(p.s) {
		ch := p.s[p.i]
		is_sign := (ch == '+' || ch == '-') && p.i == start
		if (ch >= '0' && ch <= '9') || ch == '.' || is_sign || ch == 'e' || ch == 'E' {
			p.i += 1
		} else if (ch == '+' || ch == '-') && (p.s[p.i - 1] == 'e' || p.s[p.i - 1] == 'E') {
			p.i += 1 // exponent sign
		} else {
			break
		}
	}
	if p.i == start {return 0, false}
	return strconv.parse_f32(p.s[start:p.i])
}

@(private = "file")
d_num2 :: proc(p: ^D_Parser) -> (v: [2]f32, ok: bool) {
	v.x = d_num(p) or_return
	v.y = d_num(p) or_return
	return v, true
}

// stem_from_path — "content/samples/canyon.strata.svg" → "canyon".
@(private = "file")
stem_from_path :: proc(path: string) -> string {
	stem := path
	if i := strings.last_index_any(stem, "/\\"); i >= 0 {stem = stem[i + 1:]}
	if i := strings.index_byte(stem, '.'); i >= 0 {stem = stem[:i]}
	return stem
}
