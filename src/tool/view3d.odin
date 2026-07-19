package tool

// The 3D preview pane (DESIGN.md §6): pure preview, never manipulation. The
// dual-contoured world chunks (editor_reeval → mesh_extract) concatenate into
// one static vertex/index buffer per rebuild; a ground grid on the XZ plane
// (strata world is Y-up) rides a per-frame Dyn_Buffer. Orbit camera:
// right-drag orbits, middle-drag pans the target, wheel zooms.

import "core:fmt"
import "core:math"

import sdl "vendor:sdl3"

import imgui "../../vendor/odin-imgui"

import "../engine"

// Mesh3D_Vertex — upload-side conversion of engine.Mesh_Vertex (its lone u16
// material has no SDL vertex format; ride it as u32).
Mesh3D_Vertex :: struct {
	pos:    [3]f32,
	normal: [3]f32,
	mat:    u32,
}

Mesh3D_Frag_Uniforms :: struct {
	highlight_mat: i32,
	layers:        i32,
	texscale:      f32,
	_pad:          f32,
}

View3D :: struct {
	color:           ^sdl.GPUTexture,
	depth:           ^sdl.GPUTexture,
	w, h:            u32,
	want_w, want_h:  u32,

	mesh_pipeline:   ^sdl.GPUGraphicsPipeline,
	grid_pipeline:   ^sdl.GPUGraphicsPipeline,
	prop_pipeline:   ^sdl.GPUGraphicsPipeline,
	mesh_vbuf:       ^sdl.GPUBuffer,
	mesh_ibuf:       ^sdl.GPUBuffer,
	mesh_nidx:       u32,
	grid_buf:        Dyn_Buffer,
	grid_verts:      [dynamic]Flat_Vertex,
	grid_nverts:     u32,

	// preview assets (palette.odin): material palette array + marker props
	palette_tex:     ^sdl.GPUTexture,
	palette_sampler: ^sdl.GPUSampler,
	palette_layers:  i32,
	palette_key:     string, // heap; material names + assets generation
	texscale:        f32,    // copied from Editor each frame
	props:           [dynamic]Prop_GPU,
	prop_by_name:    map[string]i32,
	prop_draws:      [dynamic]Prop_Draw,

	u:               Uniforms,
	highlight_mat:   i32,
	live:            bool,

	orbiting:        bool,
	panning:         bool,
}

@(private = "file") MESH3D_VERT_SPV :: #load("../../shaders/mesh3d.vert.spv")
@(private = "file") MESH3D_FRAG_SPV :: #load("../../shaders/mesh3d.frag.spv")
@(private = "file") FLAT3D_VERT_SPV :: #load("../../shaders/flat.vert.spv")
@(private = "file") FLAT3D_FRAG_SPV :: #load("../../shaders/flat.frag.spv")
@(private = "file") PROP_VERT_SPV :: #load("../../shaders/prop.vert.spv")
@(private = "file") PROP_FRAG_SPV :: #load("../../shaders/prop.frag.spv")

view3d_init :: proc(v3: ^View3D, device: ^sdl.GPUDevice) -> bool {
	mvs := create_shader(device, MESH3D_VERT_SPV, .VERTEX, 0, 1)
	mfs := create_shader(device, MESH3D_FRAG_SPV, .FRAGMENT, 1, 1)
	if mvs == nil || mfs == nil {return false}
	v3.mesh_pipeline = create_mesh3d_pipeline(device, mvs, mfs)
	sdl.ReleaseGPUShader(device, mvs)
	sdl.ReleaseGPUShader(device, mfs)
	if v3.mesh_pipeline == nil {return false}

	gvs := create_shader(device, FLAT3D_VERT_SPV, .VERTEX, 0, 1)
	gfs := create_shader(device, FLAT3D_FRAG_SPV, .FRAGMENT, 0, 0)
	if gvs == nil || gfs == nil {return false}
	v3.grid_pipeline = create_grid3d_pipeline(device, gvs, gfs)
	sdl.ReleaseGPUShader(device, gvs)
	sdl.ReleaseGPUShader(device, gfs)
	if v3.grid_pipeline == nil {return false}

	pvs := create_shader(device, PROP_VERT_SPV, .VERTEX, 0, 2)
	pfs := create_shader(device, PROP_FRAG_SPV, .FRAGMENT, 0, 0)
	if pvs == nil || pfs == nil {return false}
	v3.prop_pipeline = create_prop_pipeline(device, pvs, pfs)
	sdl.ReleaseGPUShader(device, pvs)
	sdl.ReleaseGPUShader(device, pfs)
	if v3.prop_pipeline == nil {return false}

	v3.palette_sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .REPEAT,
			address_mode_v = .REPEAT,
			address_mode_w = .REPEAT,
			max_lod = PALETTE_LEVELS,
		},
	)

	v3.grid_buf.usage = {.VERTEX}
	v3.highlight_mat = -1
	v3.texscale = 4
	v3.want_w, v3.want_h = 1024, 500
	return true
}

view3d_free :: proc(device: ^sdl.GPUDevice, v3: ^View3D) {
	if v3.color != nil {sdl.ReleaseGPUTexture(device, v3.color)}
	if v3.depth != nil {sdl.ReleaseGPUTexture(device, v3.depth)}
	if v3.mesh_vbuf != nil {sdl.ReleaseGPUBuffer(device, v3.mesh_vbuf)}
	if v3.mesh_ibuf != nil {sdl.ReleaseGPUBuffer(device, v3.mesh_ibuf)}
	if v3.mesh_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(device, v3.mesh_pipeline)}
	if v3.grid_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(device, v3.grid_pipeline)}
	if v3.prop_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(device, v3.prop_pipeline)}
	prop_store_free(device, v3) // props + palette + sampler + key
	dyn_buffer_free(device, &v3.grid_buf)
	delete(v3.grid_verts)
	v3^ = {}
}

view3d_ensure_target :: proc(v3: ^View3D, device: ^sdl.GPUDevice) {
	w := max(v3.want_w, 1)
	h := max(v3.want_h, 1)
	if v3.color != nil && w == v3.w && h == v3.h {return}
	if v3.color != nil {sdl.ReleaseGPUTexture(device, v3.color)}
	if v3.depth != nil {sdl.ReleaseGPUTexture(device, v3.depth)}
	v3.color = sdl.CreateGPUTexture(
		device,
		{
			type = .D2,
			format = CANVAS_COLOR_FORMAT,
			usage = {.COLOR_TARGET, .SAMPLER},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	v3.depth = create_depth_texture(device, w, h)
	v3.w, v3.h = w, h
}

// view3d_set_chunks rebuilds the static mesh buffers from the evaluated
// chunks (indices rebased into one stream). nil/empty clears the scene.
view3d_set_chunks :: proc(v3: ^View3D, device: ^sdl.GPUDevice, chunks: []engine.Mesh_Chunk) {
	verts := make([dynamic]Mesh3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	for &c in chunks {
		base := u32(len(verts))
		for &v in c.verts {
			append(&verts, Mesh3D_Vertex{pos = v.pos, normal = v.normal, mat = u32(v.mat)})
		}
		for i in c.indices {append(&indices, base + i)}
	}
	if v3.mesh_vbuf != nil {sdl.ReleaseGPUBuffer(device, v3.mesh_vbuf); v3.mesh_vbuf = nil}
	if v3.mesh_ibuf != nil {sdl.ReleaseGPUBuffer(device, v3.mesh_ibuf); v3.mesh_ibuf = nil}
	v3.mesh_nidx = u32(len(indices))
	if v3.mesh_nidx > 0 {
		v3.mesh_vbuf = upload_buffer(device, {.VERTEX}, slice_bytes(verts[:]))
		v3.mesh_ibuf = upload_buffer(device, {.INDEX}, slice_bytes(indices[:]))
	}
}

// view3d_pane — imgui side: camera input, uniforms, composite.
view3d_pane :: proc(ed: ^Editor) {
	v3 := &ed.v3
	origin := imgui.GetCursorScreenPos()
	size := imgui.GetContentRegionAvail()
	if size.x < 16 || size.y < 16 {return}

	imgui.Dummy(size)
	io := imgui.GetIO()
	hovered := imgui.IsWindowHovered()
	if hovered {ed.hover_pane = .P3D}

	if hovered {
		if imgui.IsMouseClicked(.Right) {v3.orbiting = true}
		if imgui.IsMouseClicked(.Middle) || (io.KeyAlt && imgui.IsMouseClicked(.Left)) {v3.panning = true}
		if io.MouseWheel != 0 {orbit_cam_zoom(&ed.cam3, io.MouseWheel)}
	}
	if !imgui.IsMouseDown(.Right) {v3.orbiting = false}
	if !(imgui.IsMouseDown(.Middle) || (io.KeyAlt && imgui.IsMouseDown(.Left))) {v3.panning = false}
	if v3.orbiting {orbit_cam_orbit(&ed.cam3, io.MouseDelta.x, io.MouseDelta.y)}
	if v3.panning {orbit_cam_pan(&ed.cam3, io.MouseDelta.x, io.MouseDelta.y, size.y)}

	eye := orbit_cam_eye(ed.cam3)
	v3.u = Uniforms {
		mvp = cam_view_proj(ed.cam3, size.x / size.y),
		cam = {eye.x, eye.y, eye.z, 0},
	}
	build_grid3d(v3, ed.cam3.target)
	v3.texscale = ed.texscale
	if ed.world_ok {palette_ensure(ed)}
	prop_store_init(ed)
	build_prop_draws(ed)
	v3.want_w, v3.want_h = u32(size.x), u32(size.y)
	v3.live = true

	dl := imgui.GetWindowDrawList()
	if v3.color != nil {
		imgui.DrawList_AddImage(dl, tex_ref(v3.color), origin, origin + size)
	}
	if ed.mesh_tris > 0 {
		imgui.DrawList_AddText(
			dl, {origin.x + 10, origin.y + 8}, 0xffb8c8d8,
			fmt.ctprintf("%d tris  ·  eval %.0f ms  ·  step %.2g%s",
				ed.mesh_tris, ed.eval_ms, ed.eval_step,
				ed.doc_rev != ed.eval_rev ? " (stale)" : ""),
		)
	} else {
		imgui.DrawList_AddText(
			dl, {origin.x + 10, origin.y + 8}, 0xff8898a8,
			cstring("no world — draw a Sector in the 2D pane above"),
		)
	}
}

// build_grid3d — XZ ground lines at y = 0, 8 wu spacing around the target,
// world axes emphasized.
@(private = "file")
build_grid3d :: proc(v3: ^View3D, target: [3]f32) {
	GRID_R :: 10
	SPACING :: f32(8)
	clear(&v3.grid_verts)
	tx := math.floor(target.x / SPACING)
	tz := math.floor(target.z / SPACING)
	minor := rgba(255, 255, 255, 16)
	axis := rgba(255, 255, 255, 55)
	x0 := (tx - GRID_R) * SPACING
	x1 := (tx + GRID_R) * SPACING
	z0 := (tz - GRID_R) * SPACING
	z1 := (tz + GRID_R) * SPACING
	gv :: proc(v3: ^View3D, p: [3]f32, c: [4]u8) {
		append(&v3.grid_verts, Flat_Vertex{p, c})
	}
	for i in -GRID_R ..= GRID_R {
		gx := (tx + f32(i)) * SPACING
		gz := (tz + f32(i)) * SPACING
		cx := gx == 0 ? axis : minor
		cz := gz == 0 ? axis : minor
		gv(v3, {gx, 0, z0}, cx); gv(v3, {gx, 0, z1}, cx)
		gv(v3, {x0, 0, gz}, cz); gv(v3, {x1, 0, gz}, cz)
	}
	v3.grid_nverts = u32(len(v3.grid_verts))
}

// view3d_draw records the offscreen scene pass; runs before the UI pass.
view3d_draw :: proc(v3: ^View3D, cmd: ^sdl.GPUCommandBuffer) {
	if v3.color == nil || !v3.live {return}
	v3.live = false

	has_grid := v3.grid_nverts > 0 && v3.grid_buf.buf != nil

	sdl.PushGPUVertexUniformData(cmd, 0, &v3.u, size_of(Uniforms))
	ct := sdl.GPUColorTargetInfo {
		texture     = v3.color,
		clear_color = {0.075, 0.08, 0.10, 1.0},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	dt := sdl.GPUDepthStencilTargetInfo {
		texture          = v3.depth,
		clear_depth      = 1.0,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}
	rp := sdl.BeginGPURenderPass(cmd, &ct, 1, &dt)

	if v3.mesh_nidx > 0 && v3.palette_tex != nil {
		sdl.BindGPUGraphicsPipeline(rp, v3.mesh_pipeline)
		fu := Mesh3D_Frag_Uniforms {
			highlight_mat = v3.highlight_mat,
			layers        = max(v3.palette_layers, 1),
			texscale      = v3.texscale,
		}
		sdl.PushGPUFragmentUniformData(cmd, 0, &fu, size_of(Mesh3D_Frag_Uniforms))
		sbind := sdl.GPUTextureSamplerBinding{texture = v3.palette_tex, sampler = v3.palette_sampler}
		sdl.BindGPUFragmentSamplers(rp, 0, &sbind, 1)
		bind := sdl.GPUBufferBinding{buffer = v3.mesh_vbuf, offset = 0}
		sdl.BindGPUVertexBuffers(rp, 0, &bind, 1)
		ibind := sdl.GPUBufferBinding{buffer = v3.mesh_ibuf, offset = 0}
		sdl.BindGPUIndexBuffer(rp, ibind, ._32BIT)
		sdl.DrawGPUIndexedPrimitives(rp, v3.mesh_nidx, 1, 0, 0, 0)
	}

	if len(v3.prop_draws) > 0 && v3.prop_pipeline != nil {
		sdl.BindGPUGraphicsPipeline(rp, v3.prop_pipeline)
		for &d in v3.prop_draws {
			p := &v3.props[d.prop]
			if !p.ok {continue}
			pu := Prop_Uniforms{model = d.model, color = d.color}
			sdl.PushGPUVertexUniformData(cmd, 1, &pu, size_of(Prop_Uniforms))
			bind := sdl.GPUBufferBinding{buffer = p.vbuf, offset = 0}
			sdl.BindGPUVertexBuffers(rp, 0, &bind, 1)
			ibind := sdl.GPUBufferBinding{buffer = p.ibuf, offset = 0}
			sdl.BindGPUIndexBuffer(rp, ibind, ._32BIT)
			sdl.DrawGPUIndexedPrimitives(rp, p.nidx, 1, 0, 0, 0)
		}
	}

	if has_grid {
		sdl.BindGPUGraphicsPipeline(rp, v3.grid_pipeline)
		gbind := sdl.GPUBufferBinding{buffer = v3.grid_buf.buf, offset = 0}
		sdl.BindGPUVertexBuffers(rp, 0, &gbind, 1)
		sdl.DrawGPUPrimitives(rp, v3.grid_nverts, 1, 0, 0)
	}

	sdl.EndGPURenderPass(rp)
}

// view3d_upload_grid — the grid's per-frame upload; must run BEFORE
// view3d_draw's render pass, within the same command buffer.
view3d_upload_grid :: proc(v3: ^View3D, device: ^sdl.GPUDevice, cmd: ^sdl.GPUCommandBuffer) {
	if v3.grid_nverts > 0 {
		_ = dyn_buffer_upload(device, cmd, &v3.grid_buf, slice_bytes(v3.grid_verts[:]))
	}
}

@(private = "file")
create_mesh3d_pipeline :: proc(
	device: ^sdl.GPUDevice,
	vshader, fshader: ^sdl.GPUShader,
) -> ^sdl.GPUGraphicsPipeline {
	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of(Mesh3D_Vertex), input_rate = .VERTEX, instance_step_rate = 0},
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh3D_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh3D_Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .UINT, offset = u32(offset_of(Mesh3D_Vertex, mat))},
	}
	color_desc := [1]sdl.GPUColorTargetDescription{{format = CANVAS_COLOR_FORMAT}}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 3,
		},
		// two-sided: DC sliver tris can flip until the QEF solve lands
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_desc[0],
			num_color_targets = 1,
			depth_stencil_format = .D32_FLOAT,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(device, info)
}

@(private = "file")
create_prop_pipeline :: proc(
	device: ^sdl.GPUDevice,
	vshader, fshader: ^sdl.GPUShader,
) -> ^sdl.GPUGraphicsPipeline {
	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of(Prop_Vertex), input_rate = .VERTEX, instance_step_rate = 0},
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Prop_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Prop_Vertex, normal))},
	}
	color_desc := [1]sdl.GPUColorTargetDescription{{format = CANVAS_COLOR_FORMAT}}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 2,
		},
		// two-sided: glb winding is author-dependent, previews shouldn't vanish
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_desc[0],
			num_color_targets = 1,
			depth_stencil_format = .D32_FLOAT,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(device, info)
}

@(private = "file")
create_grid3d_pipeline :: proc(
	device: ^sdl.GPUDevice,
	vshader, fshader: ^sdl.GPUShader,
) -> ^sdl.GPUGraphicsPipeline {
	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = size_of(Flat_Vertex), input_rate = .VERTEX, instance_step_rate = 0},
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Flat_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(Flat_Vertex, color))},
	}
	color_desc := [1]sdl.GPUColorTargetDescription {
		{
			format = CANVAS_COLOR_FORMAT,
			blend_state = {
				enable_blend = true,
				src_color_blendfactor = .SRC_ALPHA,
				dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
				color_blend_op = .ADD,
				src_alpha_blendfactor = .ONE,
				dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
				alpha_blend_op = .ADD,
			},
		},
	}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .LINELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 2,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = false},
		target_info = {
			color_target_descriptions = &color_desc[0],
			num_color_targets = 1,
			depth_stencil_format = .D32_FLOAT,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(device, info)
}
