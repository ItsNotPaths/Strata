package tool

// GPU residency for preview assets (assets.odin) in the 3D pane:
//
//   palette    R8G8B8A8 texture ARRAY, one layer per Eval_World.materials
//              entry (the engine's sorted-name id contract — mesh vertex mat
//              IS the layer index). A recipe with a texture in the assets
//              dir gets it resampled in; one without gets its old hash tint
//              baked into the layer, so mesh3d.frag samples unconditionally.
//              CPU-built mips (deterministic, no COLOR_TARGET usage needed).
//   props      vertex/index buffers per marker model preview (.glb), cached
//              by name; index 0 is the generated fallback pin. Rebuilt when
//              the assets dir rescans (Assets.gen rides the cache keys).
//
// All of it is throwaway derived state — dropped and rebuilt whenever the
// material table or the assets generation drifts, never saved anywhere.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"

import sdl "vendor:sdl3"

import "../engine"

PALETTE_DIM :: 256
PALETTE_LEVELS :: 9 // 256 → 1

// mat_hash_tint — the id-debug tint formula the fragment shader used before
// texturing (same constants), so untextured recipes keep their familiar color.
mat_hash_tint :: proc(m: int) -> [3]f32 {
	h :: proc(fm, k: f32) -> f32 {
		v := math.sin(fm * k) * 43758.5453
		return v - math.floor(v)
	}
	fm := f32(m)
	return 0.35 + 0.6 * [3]f32{h(fm, 12.9898), h(fm, 78.2330), h(fm, 37.7190)}
}

// palette_ensure — (re)build the palette array when the material table or the
// assets generation changed. Call with a valid world (materials resolved).
palette_ensure :: proc(ed: ^Editor) {
	v3 := &ed.v3
	nmat := max(len(ed.world.materials), 1)

	kb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&kb, "%d#", ed.assets.gen)
	for &m in ed.world.materials {fmt.sbprintf(&kb, "%s\x00", engine.name32_str(&m))}
	key := strings.to_string(kb)
	if v3.palette_tex != nil && key == v3.palette_key {return}

	if v3.palette_tex != nil {sdl.ReleaseGPUTexture(ed.device, v3.palette_tex)}
	delete(v3.palette_key)
	v3.palette_key = strings.clone(key)

	bytes_per_layer := 0
	for l in 0 ..< PALETTE_LEVELS {
		d := PALETTE_DIM >> uint(l)
		bytes_per_layer += d * d * 4
	}

	v3.palette_tex = sdl.CreateGPUTexture(
		ed.device,
		{
			type = .D2_ARRAY,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = PALETTE_DIM,
			height = PALETTE_DIM,
			layer_count_or_depth = u32(nmat),
			num_levels = PALETTE_LEVELS,
			sample_count = ._1,
		},
	)
	v3.palette_layers = i32(nmat)

	tb := sdl.CreateGPUTransferBuffer(
		ed.device, {usage = .UPLOAD, size = u32(bytes_per_layer * nmat)},
	)
	Level_Off :: struct {
		offset: int,
		dim:    int,
	}
	ptr := ([^]u8)(sdl.MapGPUTransferBuffer(ed.device, tb, false))
	off := 0
	level_offs := make([][PALETTE_LEVELS]Level_Off, nmat, context.temp_allocator)

	for mi in 0 ..< nmat {
		img := palette_layer_pixels(ed, mi) // level 0; each mip replaces it
		for l in 0 ..< PALETTE_LEVELS {
			mem.copy(ptr[off:], raw_data(img.pix), len(img.pix))
			level_offs[mi][l] = {offset = off, dim = img.w}
			off += len(img.pix)
			if l + 1 < PALETTE_LEVELS {
				next := rgba8_mip(&img)
				rgba8_destroy(&img)
				img = next
			}
		}
		rgba8_destroy(&img)
	}
	sdl.UnmapGPUTransferBuffer(ed.device, tb)

	cmd := sdl.AcquireGPUCommandBuffer(ed.device)
	cp := sdl.BeginGPUCopyPass(cmd)
	for mi in 0 ..< nmat {
		for l in 0 ..< PALETTE_LEVELS {
			lo := level_offs[mi][l]
			sdl.UploadToGPUTexture(
				cp,
				{transfer_buffer = tb, offset = u32(lo.offset), pixels_per_row = 0, rows_per_layer = 0},
				{
					texture = v3.palette_tex,
					mip_level = u32(l),
					layer = u32(mi),
					w = u32(lo.dim),
					h = u32(lo.dim),
					d = 1,
				},
				false,
			)
		}
	}
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(ed.device, tb)
}

// palette_layer_pixels — the 256² base level for material index mi: assets
// texture (resampled) or hash-tint fill.
@(private = "file")
palette_layer_pixels :: proc(ed: ^Editor, mi: int) -> Rgba8_Image {
	if mi < len(ed.world.materials) {
		name := engine.name32_str(&ed.world.materials[mi])
		if path, found := asset_find(ed.assets.textures[:], name); found {
			if src, ok := image_load_rgba8(path); ok {
				defer rgba8_destroy(&src)
				if src.w == PALETTE_DIM && src.h == PALETTE_DIM {
					out := Rgba8_Image{w = src.w, h = src.h, pix = make([]u8, len(src.pix))}
					copy(out.pix, src.pix)
					return out
				}
				return rgba8_resample(&src, PALETTE_DIM, PALETTE_DIM)
			}
		}
	}
	tint := mat_hash_tint(mi)
	out := Rgba8_Image{w = PALETTE_DIM, h = PALETTE_DIM, pix = make([]u8, PALETTE_DIM * PALETTE_DIM * 4)}
	r := u8(clamp(tint.r * 255, 0, 255))
	g := u8(clamp(tint.g * 255, 0, 255))
	b := u8(clamp(tint.b * 255, 0, 255))
	for p := 0; p < len(out.pix); p += 4 {
		out.pix[p], out.pix[p + 1], out.pix[p + 2], out.pix[p + 3] = r, g, b, 255
	}
	return out
}

// --- marker props ---------------------------------------------------------------

Prop_GPU :: struct {
	vbuf: ^sdl.GPUBuffer,
	ibuf: ^sdl.GPUBuffer,
	nidx: u32,
	ok:   bool, // false = load failed; draw the pin instead
}

Prop_Draw :: struct {
	model: matrix[4, 4]f32,
	color: [4]f32, // rgb tint, a = unlit blend (prop.vert)
	prop:  i32,    // index into View3D.props
}

Prop_Uniforms :: struct {
	model: matrix[4, 4]f32,
	color: [4]f32,
}

PROP_PIN :: i32(0)

// prop_store_reset — drop every cached prop EXCEPT the built-in pin (index 0
// survives, it owes nothing to the assets dir). Called on assets rescan.
prop_store_reset :: proc(ed: ^Editor) {
	v3 := &ed.v3
	for i := 1; i < len(v3.props); i += 1 {
		p := &v3.props[i]
		if p.vbuf != nil {sdl.ReleaseGPUBuffer(ed.device, p.vbuf)}
		if p.ibuf != nil {sdl.ReleaseGPUBuffer(ed.device, p.ibuf)}
	}
	resize(&v3.props, min(len(v3.props), 1))
	for k in v3.prop_by_name {delete(k)}
	clear(&v3.prop_by_name)
	// prop_draws may hold indices into the entries just dropped, and it only
	// rebuilds once the eval is current again (build_prop_draws) — clear it
	// now so a stale frame can't index past the shrunken store
	clear(&v3.prop_draws)
}

prop_store_free :: proc(device: ^sdl.GPUDevice, v3: ^View3D) {
	for &p in v3.props {
		if p.vbuf != nil {sdl.ReleaseGPUBuffer(device, p.vbuf)}
		if p.ibuf != nil {sdl.ReleaseGPUBuffer(device, p.ibuf)}
	}
	delete(v3.props)
	for k in v3.prop_by_name {delete(k)}
	delete(v3.prop_by_name)
	delete(v3.prop_draws)
	if v3.palette_tex != nil {sdl.ReleaseGPUTexture(device, v3.palette_tex)}
	if v3.palette_sampler != nil {sdl.ReleaseGPUSampler(device, v3.palette_sampler)}
	delete(v3.palette_key)
}

@(private = "file")
prop_upload :: proc(ed: ^Editor, mesh: ^Prop_Mesh) -> (p: Prop_GPU) {
	if len(mesh.indices) == 0 {return}
	p.vbuf = upload_buffer(ed.device, {.VERTEX}, slice_bytes(mesh.verts[:]))
	p.ibuf = upload_buffer(ed.device, {.INDEX}, slice_bytes(mesh.indices[:]))
	p.nidx = u32(len(mesh.indices))
	p.ok = true
	return
}

// prop_store_init — build + upload the fallback pin (props[0]): a stretched
// octahedron standing tip-down on the marker's surface point.
prop_store_init :: proc(ed: ^Editor) {
	if len(ed.v3.props) > 0 {return}
	mesh: Prop_Mesh
	defer prop_mesh_destroy(&mesh)
	R :: f32(0.35)
	MID :: f32(0.8) // widest point height; tip at 0, top at 2*MID
	top := [3]f32{0, 2 * MID, 0}
	tip := [3]f32{0, 0, 0}
	ring := [4][3]f32{{R, MID, 0}, {0, MID, R}, {-R, MID, 0}, {0, MID, -R}}
	face :: proc(mesh: ^Prop_Mesh, a, b, c: [3]f32) {
		n := linalg.normalize(linalg.cross(b - a, c - a))
		v := u32(len(mesh.verts))
		append(&mesh.verts, Prop_Vertex{a, n}, Prop_Vertex{b, n}, Prop_Vertex{c, n})
		append(&mesh.indices, v, v + 1, v + 2)
	}
	for i in 0 ..< 4 {
		a, b := ring[i], ring[(i + 1) % 4]
		face(&mesh, a, b, top)
		face(&mesh, b, a, tip)
	}
	append(&ed.v3.props, prop_upload(ed, &mesh))
}

// prop_get — cached model preview by name; loads + uploads on first request.
// Returns PROP_PIN when the name is empty or the load failed.
prop_get :: proc(ed: ^Editor, name: string) -> i32 {
	if name == "" {return PROP_PIN}
	v3 := &ed.v3
	if idx, hit := v3.prop_by_name[name]; hit {
		return v3.props[idx].ok ? idx : PROP_PIN
	}
	p: Prop_GPU
	if path, found := asset_find(ed.assets.models[:], name); found {
		if mesh, ok := glb_load_file(path); ok {
			p = prop_upload(ed, &mesh)
			prop_mesh_destroy(&mesh)
		}
	}
	idx := i32(len(v3.props))
	append(&v3.props, p)
	v3.prop_by_name[strings.clone(name)] = idx
	return p.ok ? idx : PROP_PIN
}

// build_prop_draws — the frame's marker draw list. Only rebuilt when the
// eval is current: surface_height must not sample a world whose component
// snapshots drifted from the document (editor_after_doc_swap's rule); stale
// frames just keep the previous list.
build_prop_draws :: proc(ed: ^Editor) {
	if ed.doc_rev != ed.eval_rev {return}
	v3 := &ed.v3
	clear(&v3.prop_draws)
	for &c, i in ed.doc.components {
		if c.kind != .Marker || len(c.points) == 0 {continue}
		plan := c.points[0].pos
		y := f32(0)
		if ed.world_ok {
			if h, ok := engine.surface_height(&ed.world, plan); ok {y = h}
		}
		scale := c.scale > 0.01 ? c.scale : 1
		model_name := engine.name32_str(&c.model)
		prop := prop_get(ed, model_name)

		color: [4]f32
		if prop != PROP_PIN {
			color = {0.78, 0.78, 0.82, 0}
		} else {
			// pin: tint by class name so kinds read apart at a glance
			hash := u32(2166136261)
			for b in transmute([]u8)engine.name32_str(&c.class) {
				hash = (hash ~ u32(b)) * 16777619
			}
			t := mat_hash_tint(int(hash % 251))
			color = {t.r, t.g, t.b, 0.25}
		}
		if is_selected(ed, i32(i)) {
			color.rgb = linalg.lerp(color.rgb, [3]f32{1, 0.62, 0.18}, f32(0.5))
			color.a = max(color.a, 0.35)
		}

		yaw := -c.yaw * math.RAD_PER_DEG // positive yaw = clockwise from above (y-up)
		m := linalg.matrix4_translate([3]f32{plan.x, y, plan.y}) *
			linalg.matrix4_rotate(yaw, [3]f32{0, 1, 0}) *
			linalg.matrix4_scale([3]f32{scale, scale, scale})
		append(&v3.prop_draws, Prop_Draw{model = m, color = color, prop = prop})
	}
}
