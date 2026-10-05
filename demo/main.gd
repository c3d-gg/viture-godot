extends Node3D

## Head-tracking test scene: a ring of cubes around the viewer.
## 3 = toggle stereo, R = recenter, T = reset tracking,
## Tab = move window to next screen, F11 = toggle fullscreen.
## Stereo tuning (saved to user://stereo.cfg): Left/Right = convergence,
## Up/Down = right-eye vertical offset, [ / ] = eye separation, Backspace = reset.

const STEREO_CONFIG := "user://stereo.cfg"
const DEFAULT_CONVERGENCE := 3.0
const DEFAULT_EYE_SEPARATION := 0.063

@onready var glasses: VitureGlasses = $Glasses
@onready var hud: Label3D = $XROrigin3D/Head/HUD
@onready var xr: VitureXRInterface = glasses.get_xr_interface()

# After switching to stereo the glasses re-enumerate as a 3840-wide display;
# wait for it to appear, then go fullscreen on it.
var _waiting_for_stereo_screen := 0.0


func _ready() -> void:
	_build_world()
	_load_stereo_config()
	# VitureGlasses auto-starts in its own _ready, which runs before ours.
	glasses.started.connect(_print_device)
	if glasses.is_running():
		_print_device()
	glasses.state_changed.connect(func(id, value): print("VITURE state %d = %d" % [id, value]))


func _print_device() -> void:
	print("VITURE: %s (%s), SDK %s" % [glasses.get_market_name(), _device_name(), glasses.get_sdk_version()])


func _process(delta: float) -> void:
	if _waiting_for_stereo_screen > 0.0:
		_waiting_for_stereo_screen -= delta
		var screen := _find_stereo_screen()
		if screen >= 0:
			_waiting_for_stereo_screen = 0.0
			get_window().current_screen = screen
			get_window().mode = Window.MODE_FULLSCREEN
			print("Stereo: fullscreen on screen %d %s" % [screen, DisplayServer.screen_get_size(screen)])
		elif _waiting_for_stereo_screen <= 0.0:
			push_warning("Stereo: no 3840-wide screen appeared. Is Windows set to Extend (Win+P)?")

	if not glasses.is_running():
		hud.text = "Glasses not running: %s\nR: retry" % glasses.get_last_error()
		return
	var pose: Transform3D = glasses.get_pose()
	var euler := pose.basis.get_euler() * (180.0 / PI)
	hud.text = "%s  [%s]  %s  tracking %s\nyaw %.1f  pitch %.1f  roll %.1f   pos %.2f, %.2f, %.2f\nconvergence %.2f m · vertical %+.2f deg · eyes %.1f mm\n3 stereo · R recenter · T reset · Tab screen · F11 fullscreen\nLeft/Right convergence · Up/Down vertical · [ ] eyes · Backspace defaults" % [
		glasses.get_market_name(), _device_name(),
		"STEREO" if glasses.stereo else "mono",
		"stable" if glasses.is_tracking_stable() else "UNSTABLE",
		euler.y, euler.x, euler.z,
		pose.origin.x, pose.origin.y, pose.origin.z,
		xr.convergence_distance, xr.vertical_offset, xr.eye_separation * 1000.0]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if _handle_tuning_key(event.keycode):
		_save_stereo_config()
		return
	if event.echo:
		return
	match event.keycode:
		KEY_3, KEY_KP_3:
			glasses.stereo = not glasses.stereo
			if glasses.stereo:
				_waiting_for_stereo_screen = 10.0  # The glasses take ~4 s to switch modes.
			else:
				get_window().mode = Window.MODE_WINDOWED
		KEY_R:
			if glasses.is_running():
				glasses.recenter()
			else:
				glasses.start()
		KEY_T:
			glasses.reset_tracking()
		KEY_TAB:
			var next := (get_window().current_screen + 1) % DisplayServer.get_screen_count()
			get_window().current_screen = next
		KEY_F11:
			var w := get_window()
			w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN


# Tuning keys auto-repeat when held. Returns true if the key was one of them.
func _handle_tuning_key(keycode: Key) -> bool:
	match keycode:
		KEY_LEFT, KEY_RIGHT:
			# Step in dioptres (1 / distance) so each press moves the images by
			# the same amount; Left pushes the convergence point further away.
			var dioptres := 1.0 / xr.convergence_distance if xr.convergence_distance > 0.0 else 0.0
			dioptres = clampf(dioptres + (0.02 if keycode == KEY_RIGHT else -0.02), 0.0, 5.0)
			xr.convergence_distance = 1.0 / dioptres if dioptres > 0.001 else 0.0
		KEY_UP:
			xr.vertical_offset += 0.02
		KEY_DOWN:
			xr.vertical_offset -= 0.02
		KEY_BRACKETRIGHT:
			xr.eye_separation += 0.001
		KEY_BRACKETLEFT:
			xr.eye_separation -= 0.001
		KEY_BACKSPACE:
			xr.convergence_distance = DEFAULT_CONVERGENCE
			xr.vertical_offset = 0.0
			xr.eye_separation = DEFAULT_EYE_SEPARATION
		_:
			return false
	return true


func _load_stereo_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STEREO_CONFIG) != OK:
		return
	xr.convergence_distance = cfg.get_value("stereo", "convergence_distance", DEFAULT_CONVERGENCE)
	xr.vertical_offset = cfg.get_value("stereo", "vertical_offset", 0.0)
	xr.eye_separation = cfg.get_value("stereo", "eye_separation", DEFAULT_EYE_SEPARATION)


func _save_stereo_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("stereo", "convergence_distance", xr.convergence_distance)
	cfg.set_value("stereo", "vertical_offset", xr.vertical_offset)
	cfg.set_value("stereo", "eye_separation", xr.eye_separation)
	cfg.save(STEREO_CONFIG)


func _find_stereo_screen() -> int:
	for i in DisplayServer.get_screen_count():
		var size := DisplayServer.screen_get_size(i)
		if size.x >= 3 * size.y:
			return i
	return -1


func _device_name() -> String:
	match glasses.get_device_type():
		VitureGlasses.DEVICE_TYPE_CARINA: return "Carina 6DoF"
		VitureGlasses.DEVICE_TYPE_GEN2: return "Gen2 3DoF"
		VitureGlasses.DEVICE_TYPE_GEN1: return "Gen1 3DoF"
	return "none"


func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.02, 0.02, 0.04)
	env.environment.ambient_light_color = Color(0.3, 0.3, 0.35)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)

	# Ring of cubes 2 m away.
	var count := 16
	for i in count:
		var angle := TAU * i / count
		var cube := _cube(0.25, Color.from_hsv(float(i) / count, 0.7, 1.0))
		cube.position = Vector3(sin(angle), (i % 3 - 1) * 0.4, -cos(angle)) * 2.0
		add_child(cube)

	# Depth ladder straight ahead: 0.5 m to 8 m, to judge stereo depth.
	for d in [0.5, 1.0, 2.0, 4.0, 8.0]:
		var cube := _cube(0.05 * d, Color.WHITE)
		cube.position = Vector3(0.3 * d, -0.15 * d, -d)
		add_child(cube)

	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.position.y = -1.5
	add_child(ground)


func _cube(size: float, color: Color) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var cube := MeshInstance3D.new()
	cube.mesh = box
	cube.material_override = mat
	return cube
