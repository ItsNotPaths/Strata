package tool

// Small SDL3-GPU helpers (ported from dymeta-tool): shader creation, static
// buffer upload, depth target, plus Dyn_Buffer — a growable vertex buffer with
// a persistent transfer buffer re-uploaded inside the frame's command buffer,
// for the 2D canvas geometry that changes while navigating/editing.

import "core:mem"

import sdl "vendor:sdl3"

// slice_bytes reinterprets a typed slice as a raw byte slice for GPU upload.
slice_bytes :: proc(s: []$T) -> []byte {
	return (cast([^]byte)raw_data(s))[:len(s) * size_of(T)]
}

// create_shader compiles a SPIR-V blob into a GPU shader. The sampler/uniform
// counts must match the shader's declared descriptor usage (SDL_gpu validates).
create_shader :: proc(
	device: ^sdl.GPUDevice,
	code: []u8,
	stage: sdl.GPUShaderStage,
	num_samplers, num_uniform_buffers: u32,
) -> ^sdl.GPUShader {
	info := sdl.GPUShaderCreateInfo {
		code_size           = uint(len(code)),
		code                = raw_data(code),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = stage,
		num_samplers        = num_samplers,
		num_uniform_buffers = num_uniform_buffers,
	}
	return sdl.CreateGPUShader(device, info)
}

// upload_buffer creates a GPU buffer of the given usage and fills it via a
// staging transfer buffer + copy pass on its own command buffer. For data that
// changes rarely (the 3D mesh chunks); per-frame data goes through Dyn_Buffer.
upload_buffer :: proc(
	device: ^sdl.GPUDevice,
	usage: sdl.GPUBufferUsageFlags,
	data: []byte,
) -> ^sdl.GPUBuffer {
	size := u32(len(data))
	buf := sdl.CreateGPUBuffer(device, {usage = usage, size = size})

	tb := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	ptr := sdl.MapGPUTransferBuffer(device, tb, false)
	mem.copy(ptr, raw_data(data), int(size))
	sdl.UnmapGPUTransferBuffer(device, tb)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		cp,
		{transfer_buffer = tb, offset = 0},
		{buffer = buf, offset = 0, size = size},
		false,
	)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(device, tb)
	return buf
}

create_depth_texture :: proc(device: ^sdl.GPUDevice, w, h: u32) -> ^sdl.GPUTexture {
	return sdl.CreateGPUTexture(
		device,
		{
			type = .D2,
			format = .D32_FLOAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
}

// Dyn_Buffer — persistent GPU buffer + transfer buffer pair, grown by doubling
// (never shrunk). dyn_buffer_upload records the copy into the CURRENT frame's
// command buffer, so call it before any render pass that binds the buffer;
// cycling keeps the previous frame's in-flight reads valid.
Dyn_Buffer :: struct {
	buf:   ^sdl.GPUBuffer,
	tb:    ^sdl.GPUTransferBuffer,
	cap:   u32,
	usage: sdl.GPUBufferUsageFlags,
}

dyn_buffer_free :: proc(device: ^sdl.GPUDevice, db: ^Dyn_Buffer) {
	if db.buf != nil {sdl.ReleaseGPUBuffer(device, db.buf)}
	if db.tb != nil {sdl.ReleaseGPUTransferBuffer(device, db.tb)}
	db^ = {}
}

dyn_buffer_upload :: proc(
	device: ^sdl.GPUDevice,
	cmd: ^sdl.GPUCommandBuffer,
	db: ^Dyn_Buffer,
	data: []byte,
) -> bool {
	if len(data) == 0 {return false}
	size := u32(len(data))
	if db.buf == nil || size > db.cap {
		grown := max(db.cap, 16384)
		for grown < size {grown *= 2}
		if db.buf != nil {sdl.ReleaseGPUBuffer(device, db.buf)}
		if db.tb != nil {sdl.ReleaseGPUTransferBuffer(device, db.tb)}
		db.buf = sdl.CreateGPUBuffer(device, {usage = db.usage, size = grown})
		db.tb = sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = grown})
		db.cap = grown
	}
	ptr := sdl.MapGPUTransferBuffer(device, db.tb, true)
	mem.copy(ptr, raw_data(data), int(size))
	sdl.UnmapGPUTransferBuffer(device, db.tb)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		cp,
		{transfer_buffer = db.tb, offset = 0},
		{buffer = db.buf, offset = 0, size = size},
		true,
	)
	sdl.EndGPUCopyPass(cp)
	return true
}
