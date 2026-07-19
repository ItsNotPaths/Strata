package tool

// Orbit camera for the 3D preview pane — dymeta-tool's camera.odin converted
// to strata's Y-UP world (plan (x,y) → world (x,z), height on +y; sdf.odin):
// yaw spins about world Y, pitch rises above the XZ horizon. The 3D pane is
// pure preview (DESIGN.md §6), so only orbit/pan/zoom survive the port — no
// node picking, no drawlist projection.
//
//   right-drag        orbit (yaw/pitch around the target)
//   middle-drag       pan the target along the world XZ plane
//   scroll            zoom (dolly the orbit distance)

import "core:math"
import "core:math/linalg"

CAM_FOV_DEG :: f32(60)
CAM_PITCH_MIN :: f32(4) // degrees above horizon
CAM_PITCH_MAX :: f32(88)
CAM_DIST_MIN :: f32(3)
CAM_DIST_MAX :: f32(1200)

Orbit_Cam :: struct {
	target: [3]f32, // focus point the camera orbits + pans
	yaw:    f32,    // radians about world Y (0 = eye at +X of target)
	pitch:  f32,    // radians above the XZ horizon
	dist:   f32,
}

orbit_cam_default :: proc(target: [3]f32) -> Orbit_Cam {
	return {
		target = target,
		yaw    = math.to_radians(f32(-120)),
		pitch  = math.to_radians(f32(38)),
		dist   = 90,
	}
}

orbit_cam_orbit :: proc(cam: ^Orbit_Cam, ddx_px, ddy_px: f32) {
	// Y-up flips yaw handedness vs dymeta's Z-up frame: +yaw moves the eye
	// LEFT here, so grab-the-scene (drag right → camera left) is yaw +=.
	cam.yaw += ddx_px * 0.008
	cam.pitch = clamp(
		cam.pitch + ddy_px * 0.008,
		math.to_radians(CAM_PITCH_MIN),
		math.to_radians(CAM_PITCH_MAX),
	)
}

orbit_cam_zoom :: proc(cam: ^Orbit_Cam, wheel: f32) {
	cam.dist = clamp(cam.dist * math.pow(0.88, wheel), CAM_DIST_MIN, CAM_DIST_MAX)
}

// orbit_cam_eye — target → eye offset resolved from yaw/pitch (Y-up).
orbit_cam_eye :: proc(cam: Orbit_Cam) -> [3]f32 {
	cp, sp := math.cos(cam.pitch), math.sin(cam.pitch)
	cy, sy := math.cos(cam.yaw), math.sin(cam.yaw)
	return cam.target + [3]f32{cp * cy, sp, cp * sy} * cam.dist
}

// orbit_cam_pan translates the target on the XZ plane by a screen-pixel drag,
// grab-the-ground: the point under the cursor follows the cursor, so the
// TARGET moves opposite the drag in view space (screen right = camera right
// s = {sy,0,-cy}; screen up ≈ camera-forward flattened to XZ).
orbit_cam_pan :: proc(cam: ^Orbit_Cam, ddx_px, ddy_px: f32, view_h: f32) {
	cy, sy := math.cos(cam.yaw), math.sin(cam.yaw)
	fwd_xz := [3]f32{-cy, 0, -sy} // toward target, flattened
	neg_s := [3]f32{-sy, 0, cy}   // -(camera right)
	// world units per pixel at the target distance
	wpp := 2 * cam.dist * math.tan(math.to_radians(CAM_FOV_DEG) * 0.5) / max(view_h, 1)
	cam.target += neg_s * (ddx_px * wpp) + fwd_xz * (ddy_px * wpp)
}

// cam_view_proj builds the GPU pane's combined matrix: right-handed Y-up view,
// perspective with depth in [0,1], matching SDL_gpu's normalized device space
// (matrix conventions from dymeta/alchaspec).
CAM_GPU_NEAR :: f32(0.5)
CAM_GPU_FAR :: f32(4096)

cam_view_proj :: proc(cam: Orbit_Cam, aspect: f32) -> matrix[4, 4]f32 {
	eye := orbit_cam_eye(cam)

	// look_at (right-handed; literal written row-major, Odin stores
	// column-major in memory, which is what GLSL mat4 expects on upload)
	f := linalg.normalize(cam.target - eye)
	s := linalg.normalize(linalg.cross(f, [3]f32{0, 1, 0})) // pitch clamp keeps f off vertical
	u := linalg.cross(s, f)
	view := matrix[4, 4]f32{
		 s.x,  s.y,  s.z, -linalg.dot(s, eye),
		 u.x,  u.y,  u.z, -linalg.dot(u, eye),
		-f.x, -f.y, -f.z,  linalg.dot(f, eye),
		   0,    0,    0,                   1,
	}
	// perspective, depth range [0,1] (Vulkan/D3D)
	near, far := CAM_GPU_NEAR, CAM_GPU_FAR
	t := 1.0 / math.tan(math.to_radians(CAM_FOV_DEG) * 0.5)
	proj := matrix[4, 4]f32{
		t / aspect, 0,                  0,                           0,
		         0, t,                  0,                           0,
		         0, 0, far / (near - far), (near * far) / (near - far),
		         0, 0,                 -1,                           0,
	}
	return proj * view
}
