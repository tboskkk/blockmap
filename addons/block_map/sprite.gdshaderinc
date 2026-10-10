// Shared by sprite.gdshader and billboard.gdshader.
// CUSTOM0: x = frames, y = fps, z = UV stride between frames, w = mode
//   (0 = static geometry, 1 = upright billboard, 2 = camera-facing billboard).
// Billboard quads have all four vertices on their anchor; UV2 holds each
// corner's offset in tiles.

uniform sampler2D atlas : source_color, filter_nearest;
uniform float alpha_cut = 0.5;
// Upright billboards face the camera fully too (top-down views, where upright is edge-on).
uniform bool force_face_camera = false;
// With force_face_camera, how far sprites are pulled toward the camera. In an orthographic
// top-down view that changes only depth, not screen position: flat sprites draw over the
// ground and over other grids' tiles at the same height instead of fighting them.
uniform float flat_lift = 2.0;

void vertex() {
	if (CUSTOM0.x > 1.0) {
		UV.x += floor(mod(TIME * CUSTOM0.y, CUSTOM0.x)) * CUSTOM0.z;
	}
	if (CUSTOM0.w > 0.5) {
		vec3 right = INV_VIEW_MATRIX[0].xyz;
		vec3 up = INV_VIEW_MATRIX[1].xyz;
		if (CUSTOM0.w < 1.5 && !force_face_camera) {
			right = vec3(right.x, 0.0, right.z);
			right = length(right) > 0.0001 ? normalize(right) : vec3(1.0, 0.0, 0.0);
			up = vec3(0.0, 1.0, 0.0);
		}
		mat3 to_model = inverse(mat3(MODEL_MATRIX));
		VERTEX += to_model * (right * UV2.x + up * UV2.y);
		if (force_face_camera) {
			VERTEX += to_model * INV_VIEW_MATRIX[2].xyz * flat_lift;
		}
		// Lit like the ground so sprites don't go dark when the sun is behind them.
		NORMAL = normalize(to_model * vec3(0.0, 1.0, 0.0));
	}
}

void fragment() {
	vec4 tex = texture(atlas, UV);
	if (tex.a < alpha_cut) {
		discard;
	}
	ALBEDO = tex.rgb;
	ROUGHNESS = 1.0;
}
