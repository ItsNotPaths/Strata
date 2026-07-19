package tool

// The 2D vector canvas' render half (DESIGN.md §6): a first-class SDL3_GPU
// pane with an orthographic camera — NOT an ImGui widget; ImGui only
// composites the offscreen target and draws text labels on top. Everything
// visible is CPU-tessellated per frame into one triangle list in WORLD space
// (fills from the per-component earcut cache, strokes as AA quad strips with
// zoom-derived widths) and uploaded through a Dyn_Buffer; pan/zoom ride the
// ortho matrix.
//
// Document coordinates are SVG-style x-right / y-down; the pane maps them
// straight to screen (y down), so px↔world is a scale+offset with no flip.

import "core:math"

import sdl "vendor:sdl3"

CANVAS_COLOR_FORMAT :: sdl.GPUTextureFormat.R8G8B8A8_UNORM

// Vertex uniform block shared by every pane shader (std140: mat4 + vec4).
Uniforms :: struct {
	mvp: matrix[4, 4]f32,
	cam: [4]f32,
}

Flat_Vertex :: struct {
	pos:   [3]f32,
	color: [4]u8, // straight alpha, UBYTE4_NORM
}

#assert(size_of(Flat_Vertex) == 16)

Cam2D :: struct {
	center: [2]f32, // world point at the pane center
	zoom:   f32,    // pixels per world unit
}

Drag_Kind :: enum {
	None,
	Pan,
	Move,      // translate selected components
	Rubber,    // band select
	Node,      // move selected nodes
	Handle_In, // drag a Bézier handle of drag_node
	Handle_Out,
}

Canvas2D :: struct {
	// offscreen target (color only — painter's order, no depth)
	color:          ^sdl.GPUTexture,
	w, h:           u32,
	want_w, want_h: u32,

	pipeline:       ^sdl.GPUGraphicsPipeline,
	vbuf:           Dyn_Buffer,
	verts:          [dynamic]Flat_Vertex,
	nverts:         u32, // count captured at pane-build time for the draw
	u:              Uniforms,
	live:           bool,

	cam:            Cam2D,
	fit_pending:    bool,

	// interaction state (owned here, driven by canvas_edit.odin)
	drag:           Drag_Kind,
	drag_moved:     bool,     // passed the undo/snap threshold
	drag_start:     [2]f32,   // world at press
	drag_ref:       [2]f32,   // grabbed anchor (snapping reference), world
	drag_node:      i32,      // node index for Node/Handle drags
	orig_pts:       [dynamic]Orig_Points, // pre-drag point snapshots
	rubber_a:       [2]f32,   // rubber band corners, world
	rubber_b:       [2]f32,
	pending_click:  bool,     // press that hasn't turned into a drag yet
	press_hit:      i32,      // component hit at press (-1 none)
	press_shift:    bool,
}

// Orig_Points — one component's point positions captured at drag start; drags
// re-apply orig + total-delta each frame so snapping never accumulates error.
Orig_Points :: struct {
	comp: i32,
	pts:  [dynamic]Doc_Point_Pos,
}

Doc_Point_Pos :: struct {
	pos:        [2]f32,
	handle_in:  [2]f32,
	handle_out: [2]f32,
}

@(private = "file") FLAT_VERT_SPV :: #load("../../shaders/flat.vert.spv")
@(private = "file") FLAT_FRAG_SPV :: #load("../../shaders/flat.frag.spv")

canvas2d_init :: proc(cv: ^Canvas2D, device: ^sdl.GPUDevice) -> bool {
	vs := create_shader(device, FLAT_VERT_SPV, .VERTEX, 0, 1)
	fs := create_shader(device, FLAT_FRAG_SPV, .FRAGMENT, 0, 0)
	if vs == nil || fs == nil {return false}
	defer sdl.ReleaseGPUShader(device, vs)
	defer sdl.ReleaseGPUShader(device, fs)

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
		vertex_shader = vs,
		fragment_shader = fs,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 2,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		target_info = {
			color_target_descriptions = &color_desc[0],
			num_color_targets = 1,
		},
	}
	cv.pipeline = sdl.CreateGPUGraphicsPipeline(device, info)
	if cv.pipeline == nil {return false}

	cv.vbuf.usage = {.VERTEX}
	cv.cam = {center = {0, 0}, zoom = 6}
	cv.want_w, cv.want_h = 1024, 600
	cv.drag_node = -1
	cv.press_hit = -1
	return true
}

canvas2d_free :: proc(device: ^sdl.GPUDevice, cv: ^Canvas2D) {
	if cv.color != nil {sdl.ReleaseGPUTexture(device, cv.color)}
	if cv.pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(device, cv.pipeline)}
	dyn_buffer_free(device, &cv.vbuf)
	delete(cv.verts)
	for &o in cv.orig_pts {delete(o.pts)}
	delete(cv.orig_pts)
	cv^ = {}
}

canvas2d_ensure_target :: proc(cv: ^Canvas2D, device: ^sdl.GPUDevice) {
	w := max(cv.want_w, 1)
	h := max(cv.want_h, 1)
	if cv.color != nil && w == cv.w && h == cv.h {return}
	if cv.color != nil {sdl.ReleaseGPUTexture(device, cv.color)}
	cv.color = sdl.CreateGPUTexture(
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
	cv.w, cv.h = w, h
}

// canvas2d_draw uploads this frame's vertices and records the offscreen pass.
// Runs before the swapchain UI pass that samples cv.color.
canvas2d_draw :: proc(cv: ^Canvas2D, device: ^sdl.GPUDevice, cmd: ^sdl.GPUCommandBuffer) {
	if cv.color == nil || !cv.live {return}
	cv.live = false

	has_verts := dyn_buffer_upload(device, cmd, &cv.vbuf, slice_bytes(cv.verts[:cv.nverts]))

	sdl.PushGPUVertexUniformData(cmd, 0, &cv.u, size_of(Uniforms))
	ct := sdl.GPUColorTargetInfo {
		texture     = cv.color,
		clear_color = {0.094, 0.094, 0.11, 1.0},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	rp := sdl.BeginGPURenderPass(cmd, &ct, 1, nil)
	if has_verts {
		sdl.BindGPUGraphicsPipeline(rp, cv.pipeline)
		bind := sdl.GPUBufferBinding{buffer = cv.vbuf.buf, offset = 0}
		sdl.BindGPUVertexBuffers(rp, 0, &bind, 1)
		sdl.DrawGPUPrimitives(rp, cv.nverts, 1, 0, 0)
	}
	sdl.EndGPURenderPass(rp)
}

// canvas2d_matrix — world → SDL_gpu NDC (+y up) for the current pane size.
canvas2d_matrix :: proc(cam: Cam2D, size: [2]f32) -> matrix[4, 4]f32 {
	sx := 2 * cam.zoom / max(size.x, 1)
	sy := -2 * cam.zoom / max(size.y, 1)
	return matrix[4, 4]f32{
		sx,  0, 0, -cam.center.x * sx,
		 0, sy, 0, -cam.center.y * sy,
		 0,  0, 0,                  0,
		 0,  0, 0,                  1,
	}
}

world_to_px :: proc(cam: Cam2D, w: [2]f32, origin, size: [2]f32) -> [2]f32 {
	return origin + size * 0.5 + (w - cam.center) * cam.zoom
}

px_to_world :: proc(cam: Cam2D, px: [2]f32, origin, size: [2]f32) -> [2]f32 {
	return cam.center + (px - origin - size * 0.5) / cam.zoom
}

// --- tessellation -----------------------------------------------------------

rgba :: proc(r, g, b, a: u8) -> [4]u8 {return {r, g, b, a}}

// hsv_rgba — h in [0,1) wraps, s/v in [0,1].
hsv_rgba :: proc(h, s, v: f32, a: u8) -> [4]u8 {
	hh := math.mod(h, 1)
	if hh < 0 {hh += 1}
	i := int(hh * 6)
	f := hh * 6 - f32(i)
	p := v * (1 - s)
	q := v * (1 - s * f)
	t := v * (1 - s * (1 - f))
	r, g, b: f32
	switch i % 6 {
	case 0: r, g, b = v, t, p
	case 1: r, g, b = q, v, p
	case 2: r, g, b = p, v, t
	case 3: r, g, b = p, q, v
	case 4: r, g, b = t, p, v
	case 5: r, g, b = v, p, q
	}
	return {u8(r * 255), u8(g * 255), u8(b * 255), a}
}

cv_tri :: proc(cv: ^Canvas2D, a, b, c: [2]f32, col: [4]u8) {
	append(&cv.verts, Flat_Vertex{{a.x, a.y, 0}, col}, Flat_Vertex{{b.x, b.y, 0}, col}, Flat_Vertex{{c.x, c.y, 0}, col})
}

cv_quad :: proc(cv: ^Canvas2D, a, b, c, d: [2]f32, col: [4]u8) {
	cv_tri(cv, a, b, c, col)
	cv_tri(cv, a, c, d, col)
}

// cv_line — a world-space segment as a quad `width` wide, plus 1px AA feather
// wings fading to zero alpha. `width`/feather are world units (caller divides
// pixels by zoom).
cv_line :: proc(cv: ^Canvas2D, a, b: [2]f32, width: f32, col: [4]u8, feather: f32 = 0) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 1e-9 {return}
	n := [2]f32{-d.y / l, d.x / l}
	hw := width * 0.5
	p0 := a + n * hw
	p1 := b + n * hw
	p2 := b - n * hw
	p3 := a - n * hw
	cv_quad(cv, p0, p1, p2, p3, col)
	if feather > 0 {
		edge := col
		edge[3] = 0
		f0 := a + n * (hw + feather)
		f1 := b + n * (hw + feather)
		g0 := a - n * (hw + feather)
		g1 := b - n * (hw + feather)
		// wings: solid inner edge → transparent outer edge
		fv :: proc(cv: ^Canvas2D, p: [2]f32, c: [4]u8) {
			append(&cv.verts, Flat_Vertex{{p.x, p.y, 0}, c})
		}
		fv(cv, p0, col); fv(cv, f0, edge); fv(cv, f1, edge)
		fv(cv, p0, col); fv(cv, f1, edge); fv(cv, p1, col)
		fv(cv, p3, col); fv(cv, g1, edge); fv(cv, g0, edge)
		fv(cv, p3, col); fv(cv, p2, col); fv(cv, g1, edge)
	}
}

// cv_polyline strokes consecutive points; `closed` adds the wrap segment.
cv_polyline :: proc(cv: ^Canvas2D, pts: [][2]f32, closed: bool, width: f32, col: [4]u8, feather: f32 = 0) {
	if len(pts) < 2 {return}
	for i in 0 ..< len(pts) - 1 {
		cv_line(cv, pts[i], pts[i + 1], width, col, feather)
	}
	if closed {
		cv_line(cv, pts[len(pts) - 1], pts[0], width, col, feather)
	}
}

cv_circle_fill :: proc(cv: ^Canvas2D, c: [2]f32, r: f32, col: [4]u8, segs := 20) {
	prev := c + [2]f32{r, 0}
	for i in 1 ..= segs {
		ang := f32(i) / f32(segs) * math.TAU
		cur := c + [2]f32{math.cos(ang) * r, math.sin(ang) * r}
		cv_tri(cv, c, prev, cur, col)
		prev = cur
	}
}

cv_ring :: proc(cv: ^Canvas2D, c: [2]f32, r: f32, width: f32, col: [4]u8, segs := 28) {
	prev := c + [2]f32{r, 0}
	for i in 1 ..= segs {
		ang := f32(i) / f32(segs) * math.TAU
		cur := c + [2]f32{math.cos(ang) * r, math.sin(ang) * r}
		cv_line(cv, prev, cur, width, col)
		prev = cur
	}
}

cv_diamond :: proc(cv: ^Canvas2D, c: [2]f32, r: f32, col: [4]u8) {
	cv_quad(cv, c + {0, -r}, c + {r, 0}, c + {0, r}, c + {-r, 0}, col)
}

cv_square :: proc(cv: ^Canvas2D, c: [2]f32, r: f32, col: [4]u8) {
	cv_quad(cv, c + {-r, -r}, c + {r, -r}, c + {r, r}, c + {-r, r}, col)
}

cv_rect_fill :: proc(cv: ^Canvas2D, lo, hi: [2]f32, col: [4]u8) {
	cv_quad(cv, lo, {hi.x, lo.y}, hi, {lo.x, hi.y}, col)
}

// --- component palette --------------------------------------------------------
// (the hue walk itself is engine.comp_hue — one implementation for the file's
// browser-render fills and the canvas, so they can't drift)
