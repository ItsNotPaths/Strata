package tool

// Preview assets (DESIGN.md §6a): the OPTIONAL asset directory the editor
// pulls texture/model previews from. Pure convention, zero manifest:
//
//   <dir>/textures/<recipe>.<any ext>   albedo for a material recipe name
//   <dir>/models/<name>.<any ext>       preview mesh for marker model <name>
//
// Files are matched by STEM and identified by CONTENT — image formats are
// sniffed by magic bytes via core:image's generic loader (png/jpeg/tga/bmp/
// qoi/netpbm all register below), models by the glTF-binary magic
// (gltf.odin). Extensions never matter.
//
// This is deliberately NOT a game contract. The game's real texgen recipes
// and model format stay in the game; a fork that vendors this frontend swaps
// image_load_rgba8 / glb_load for its own pipeline (§7) and everything else
// — the palette array, the prop pass, the sidebar picker — keeps working.
// Resolution order: -assets=DIR flag > STRATA_ASSETS env > an `assets` dir
// beside the opened document.

import "core:fmt"
import "core:image"
import "core:os"
import "core:slice"
import "core:strings"

// register content-sniffing decoders with core:image's generic loader
import _ "core:image/bmp"
import _ "core:image/jpeg"
import _ "core:image/netpbm"
import _ "core:image/png"
import _ "core:image/qoi"
import _ "core:image/tga"

import "../engine"

// Rgba8_Image — the one pixel format everything downstream (palette upload)
// consumes: 8-bit RGBA, y-down, len(pix) == w*h*4.
Rgba8_Image :: struct {
	w, h: int,
	pix:  []u8,
}

rgba8_destroy :: proc(img: ^Rgba8_Image) {
	delete(img.pix)
	img^ = {}
}

// Asset_Entry — one scanned file: name stem -> full path.
Asset_Entry :: struct {
	stem: string, // heap
	path: string, // heap
}

Assets :: struct {
	dir:      string, // heap; "" = no asset directory
	explicit: bool,   // true when dir came from flag/env (survives doc opens)
	textures: [dynamic]Asset_Entry,
	models:   [dynamic]Asset_Entry,
	gen:      u64, // bumped on every (re)scan — cache invalidation key
}

assets_destroy :: proc(a: ^Assets) {
	gen := a.gen
	explicit := a.explicit
	assets_clear(a)
	delete(a.dir)
	a^ = {}
	a.gen = gen
	a.explicit = explicit
}

@(private = "file")
assets_clear :: proc(a: ^Assets) {
	for &e in a.textures {delete(e.stem);delete(e.path)}
	for &e in a.models {delete(e.stem);delete(e.path)}
	clear(&a.textures)
	clear(&a.models)
}

// assets_scan points the store at `dir` and lists textures/ + models/.
// A missing subdirectory is fine (empty list); a missing/unreadable `dir`
// itself warns. Listing only — files are read lazily on first use.
assets_scan :: proc(a: ^Assets, dir: string) -> bool {
	assets_clear(a)
	if dir != a.dir {
		delete(a.dir)
		a.dir = strings.clone(dir)
	}
	a.gen += 1
	if dir == "" {return false}
	if !os.is_directory(dir) {
		engine.diagf(.Warn, "assets: %q is not a directory", dir)
		return false
	}
	scan_sub(a, &a.textures, dir, "textures")
	scan_sub(a, &a.models, dir, "models")
	sort_entries(a.textures[:])
	sort_entries(a.models[:])
	return true
}

@(private = "file")
sort_entries :: proc(entries: []Asset_Entry) {
	slice.sort_by(entries, proc(x, y: Asset_Entry) -> bool {return x.stem < y.stem})
}

@(private = "file")
scan_sub :: proc(a: ^Assets, out: ^[dynamic]Asset_Entry, dir, sub: string) {
	path := fmt.tprintf("%s/%s", dir, sub)
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {return} // absent subdir is not an error
	for &fi in infos {
		if fi.type == .Directory {continue}
		stem := fi.name
		if i := strings.last_index_byte(stem, '.'); i > 0 {stem = stem[:i]}
		if stem == "" {continue}
		for &e in out {
			if e.stem == stem {
				engine.diagf(.Warn, "assets: duplicate stem %q (%s), keeping %s", stem, sub, e.path)
				stem = ""
				break
			}
		}
		if stem == "" {continue}
		append(out, Asset_Entry{stem = strings.clone(stem), path = strings.clone(fi.fullpath)})
	}
}

asset_find :: proc(entries: []Asset_Entry, stem: string) -> (path: string, ok: bool) {
	for &e in entries {
		if e.stem == stem {return e.path, true}
	}
	return "", false
}

// image_load_rgba8 — read + sniff + decode any registered format, normalized
// to RGBA8 (16-bit collapses to its high byte, RGB gains opaque alpha).
image_load_rgba8 :: proc(path: string) -> (out: Rgba8_Image, ok: bool) {
	img, err := image.load_from_file(path, {.alpha_add_if_missing})
	if err != nil {
		engine.diagf(.Warn, "assets: cannot decode %q: %v", path, err)
		return
	}
	defer image.destroy(img)
	if img.width <= 0 || img.height <= 0 {return}

	src := img.pixels.buf[:]
	npix := img.width * img.height
	bytes_per := img.channels * (img.depth / 8)
	if len(src) < npix * bytes_per || (img.channels != 3 && img.channels != 4) {
		engine.diagf(.Warn, "assets: %q: unsupported layout (%d ch, %d bit)",
			path, img.channels, img.depth)
		return
	}

	out.w, out.h = img.width, img.height
	out.pix = make([]u8, npix * 4)
	step := img.depth / 8 // 16-bit samples are big-endian: byte 0 is the high byte
	for p in 0 ..< npix {
		s := p * bytes_per
		d := p * 4
		out.pix[d + 0] = src[s]
		out.pix[d + 1] = src[s + step]
		out.pix[d + 2] = src[s + 2 * step]
		out.pix[d + 3] = img.channels == 4 ? src[s + 3 * step] : 255
	}
	return out, true
}

// rgba8_resample — bilinear resize (wrap-agnostic clamp taps; palette layers
// need one fixed size and preview textures are assumed roughly tileable).
rgba8_resample :: proc(src: ^Rgba8_Image, w, h: int) -> (out: Rgba8_Image) {
	out.w, out.h = w, h
	out.pix = make([]u8, w * h * 4)
	if src.w <= 0 || src.h <= 0 {return}
	for y in 0 ..< h {
		fy := (f32(y) + 0.5) / f32(h) * f32(src.h) - 0.5
		y0 := clamp(int(fy), 0, src.h - 1)
		y1 := min(y0 + 1, src.h - 1)
		ty := clamp(fy - f32(y0), 0, 1)
		for x in 0 ..< w {
			fx := (f32(x) + 0.5) / f32(w) * f32(src.w) - 0.5
			x0 := clamp(int(fx), 0, src.w - 1)
			x1 := min(x0 + 1, src.w - 1)
			tx := clamp(fx - f32(x0), 0, 1)
			d := (y * w + x) * 4
			for c in 0 ..< 4 {
				s00 := f32(src.pix[(y0 * src.w + x0) * 4 + c])
				s10 := f32(src.pix[(y0 * src.w + x1) * 4 + c])
				s01 := f32(src.pix[(y1 * src.w + x0) * 4 + c])
				s11 := f32(src.pix[(y1 * src.w + x1) * 4 + c])
				v := (s00 * (1 - tx) + s10 * tx) * (1 - ty) + (s01 * (1 - tx) + s11 * tx) * ty
				out.pix[d + c] = u8(clamp(v + 0.5, 0, 255))
			}
		}
	}
	return
}

// rgba8_mip — 2x2 box reduction (dim halves, min 1). src dims must be the
// level above's; palette levels are power-of-two so the box never straddles.
rgba8_mip :: proc(src: ^Rgba8_Image) -> (out: Rgba8_Image) {
	out.w, out.h = max(src.w / 2, 1), max(src.h / 2, 1)
	out.pix = make([]u8, out.w * out.h * 4)
	for y in 0 ..< out.h {
		y0 := min(y * 2, src.h - 1)
		y1 := min(y * 2 + 1, src.h - 1)
		for x in 0 ..< out.w {
			x0 := min(x * 2, src.w - 1)
			x1 := min(x * 2 + 1, src.w - 1)
			d := (y * out.w + x) * 4
			for c in 0 ..< 4 {
				s := int(src.pix[(y0 * src.w + x0) * 4 + c]) +
					int(src.pix[(y0 * src.w + x1) * 4 + c]) +
					int(src.pix[(y1 * src.w + x0) * 4 + c]) +
					int(src.pix[(y1 * src.w + x1) * 4 + c])
				out.pix[d + c] = u8((s + 2) / 4)
			}
		}
	}
	return
}
