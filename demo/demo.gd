extends Node3D
## Orbit camera for looking around the BlockMap demo island.

const FOV := 50.0

@onready var cam: Camera3D = $Camera3D
@onready var map: BlockMap = $BlockMap
@onready var info: Label = $UI/Info

var target := Vector3(0, 5.5, 0.5)
var yaw := deg_to_rad(-30.0)
var pitch := deg_to_rad(-42.0)
var distance := 25.0


func _ready() -> void:
	cam.fov = FOV
	# The scene's lighting is tuned for Mobile/Forward+ (linear tonemap). Compatibility
	# lights in sRGB space, so it needs much less light.
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		var env: Environment = $WorldEnvironment.environment
		env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
		env.ambient_light_energy = 0.3
		env.background_energy_multiplier = 1.0
		$Sun.light_energy = 0.5


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT):
		yaw -= event.relative.x * 0.006
		pitch = clampf(pitch - event.relative.y * 0.006, -PI * 0.49, PI * 0.49)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(4.0, distance * 0.9)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(200.0, distance * 1.1)


func _process(delta: float) -> void:
	var input := Vector3(
		Input.get_axis(&"ui_left", &"ui_right") + float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q)),
		Input.get_axis(&"ui_up", &"ui_down") + float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	target += (Basis(Vector3.UP, yaw) * input) * distance * 0.6 * delta

	var cam_basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	cam.transform = Transform3D(cam_basis, target + cam_basis.z * distance)

	var s := map.stats
	info.text = "\n".join([
		"drag: orbit   wheel: zoom   WASD / arrows: pan   Q / E: down / up",
		"blocks %d   triangles %d   %d fps" % [s.get("blocks", 0), s.get("triangles", 0), Engine.get_frames_per_second()],
	])
