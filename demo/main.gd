extends Node3D

## Head-tracking test scene: a ring of cubes around the viewer.
## R = recenter, T = reset tracking, Tab = move window to next screen, F11 = toggle fullscreen.

@onready var glasses: VitureGlasses = $Glasses
@onready var hud: Label = $HUD


func _ready() -> void:
	_build_world()
	# VitureGlasses auto-starts in its own _ready, which runs before ours.
	glasses.started.connect(_print_device)
	if glasses.is_running():
		_print_device()
	glasses.state_changed.connect(func(id, value): print("VITURE state %d = %d" % [id, value]))


func _print_device() -> void:
	print("VITURE: %s (%s), SDK %s" % [glasses.get_market_name(), _device_name(), glasses.get_sdk_version()])


func _process(_delta: float) -> void:
	if not glasses.is_running():
		hud.text = "Glasses not running: %s\nR: retry" % glasses.get_last_error()
		return
	var pose: Transform3D = glasses.get_pose()
	var euler := pose.basis.get_euler() * (180.0 / PI)
	hud.text = "%s  [%s]  tracking %s\nyaw %.1f  pitch %.1f  roll %.1f\npos %.3f, %.3f, %.3f\nR recenter · T reset tracking · Tab next screen · F11 fullscreen" % [
		glasses.get_market_name(), _device_name(),
		"stable" if glasses.is_tracking_stable() else "UNSTABLE",
		euler.y, euler.x, euler.z,
		pose.origin.x, pose.origin.y, pose.origin.z]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
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

	var count := 16
	for i in count:
		var angle := TAU * i / count
		var box := BoxMesh.new()
		box.size = Vector3.ONE * 0.25
		var cube := MeshInstance3D.new()
		cube.mesh = box
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.from_hsv(float(i) / count, 0.7, 1.0)
		cube.material_override = mat
		cube.position = Vector3(sin(angle), (i % 3 - 1) * 0.4, -cos(angle)) * 2.0
		add_child(cube)

	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.position.y = -1.5
	add_child(ground)
