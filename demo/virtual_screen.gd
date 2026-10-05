extends Node3D

## Pins a capture of a Windows monitor in the room as a virtual screen.
## Run fullscreen on the glasses (2D mode); look around to see any part of it.
##
## Keys (while this window has focus): Space = pin screen where you are looking,
## W/S = raise/lower, Up/Down = closer/further, Left/Right = smaller/larger, M = next monitor,
## H = next glasses display mode, B = show display edges, [ / ] = field of view,
## Tab = move window to next screen. Settings, including where the screen is
## pinned, are saved to user://virtual_screen.cfg.

const CONFIG := "user://virtual_screen.cfg"
# VITURE_DISPLAY_MODE_*: 1920x1080 @ 60/120 Hz, 1920x1200 @ 60/120 Hz.
const DISPLAY_MODES := {0x31: "1080p 60Hz", 0x34: "1080p 120Hz", 0x41: "1200p 60Hz", 0x44: "1200p 120Hz"}
const STATE_DISPLAY_MODE := 2 # VITURE_CALLBACK_ID_DISPLAY_MODE

@export var distance := 2.0 ## Metres from the viewer.
@export var width := 1.6 ## Metres.
@export var fov := 52.0 ## Diagonal field of view of the glasses, degrees.
@export var preferred_display_mode := 0x44 ## 1200p 120Hz: full panel, smoothest head tracking.

@onready var glasses: VitureGlasses = $Glasses
@onready var head: XRCamera3D = $XROrigin3D/Head
@onready var anchor: Node3D = $Anchor
@onready var screen: MeshInstance3D = $Anchor/Screen
@onready var status: Label3D = $Anchor/Status

var capture := DesktopCapture.new()
# Tracked by Windows device name: indices and handles change when the display
# layout does (e.g. after a glasses mode switch).
var monitor_device := ""
var material := ShaderMaterial.new()
var edges := _make_edge_overlay()
var display_mode := -1 # Cached: reading it is a USB round trip to the glasses.


func _ready() -> void:
	# Black is see-through on the glasses' OLED optics.
	RenderingServer.set_default_clear_color(Color.BLACK)
	material.shader = preload("res://desktop_screen.gdshader")
	screen.material_override = material
	add_child(edges)
	_load_config()
	get_window().size_changed.connect(_update_camera_fov)
	glasses.state_changed.connect(_on_glasses_state)
	var monitors := DesktopCapture.get_monitor_names()
	print("Monitors: ", monitors)
	monitor_device = _device_name(monitors[maxi(0, _find_primary(monitors))])
	_start_capture()
	_layout()
	_go_fullscreen_on_glasses.call_deferred()

	if glasses.is_running():
		display_mode = glasses.get_display_mode()
		if display_mode != preferred_display_mode:
			print("Switching glasses to %s" % DISPLAY_MODES.get(preferred_display_mode, "0x%x" % preferred_display_mode))
			glasses.set_display_mode(preferred_display_mode)


func _process(_delta: float) -> void:
	if capture.update():
		# The texture is replaced when the monitor's resolution changes.
		material.set_shader_parameter("screen", capture.get_texture())

	var state := "capturing" if capture.is_capturing() else "NOT capturing: " + capture.get_last_error()
	var mode := display_mode
	status.text = "%s  ·  %.1f m wide at %.1f m  ·  tracking %s\nglasses %s  ·  window %s  ·  fov %.1f deg" % [
		state, width, distance, "ok" if glasses.is_tracking_stable() else "unstable",
		DISPLAY_MODES.get(mode, "mode 0x%x" % mode), get_window().size, fov]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	match event.keycode:
		KEY_SPACE:
			pin_in_front()
		KEY_W:
			# Swing along an arc around the viewer so the screen keeps facing them.
			anchor.rotate_object_local(Vector3.RIGHT, deg_to_rad(1.5))
			_save_config()
		KEY_S:
			anchor.rotate_object_local(Vector3.RIGHT, deg_to_rad(-1.5))
			_save_config()
		KEY_UP:
			distance = maxf(0.5, distance - 0.1)
			_layout()
		KEY_DOWN:
			distance = minf(10.0, distance + 0.1)
			_layout()
		KEY_LEFT:
			width = maxf(0.3, width - 0.1)
			_layout()
		KEY_RIGHT:
			width = minf(8.0, width + 0.1)
			_layout()
		KEY_BRACKETLEFT:
			fov = maxf(20.0, fov - 0.5)
			_update_camera_fov()
		KEY_BRACKETRIGHT:
			fov = minf(90.0, fov + 0.5)
			_update_camera_fov()
		KEY_B:
			if not event.echo:
				edges.visible = not edges.visible
		KEY_H:
			if not event.echo and glasses.is_running():
				var modes := DISPLAY_MODES.keys()
				var next: int = modes[(modes.find(display_mode) + 1) % modes.size()]
				print("Switching glasses to %s" % DISPLAY_MODES[next])
				glasses.set_display_mode(next)
		KEY_M:
			if not event.echo:
				var monitors := DesktopCapture.get_monitor_names()
				var next := (_monitor_index(monitors) + 1) % maxi(1, monitors.size())
				monitor_device = _device_name(monitors[next])
				_start_capture()
				_layout()
		KEY_TAB:
			if not event.echo:
				get_window().current_screen = (get_window().current_screen + 1) % DisplayServer.get_screen_count()


## Re-pins the screen centred on where you are looking, facing you, with its
## horizon kept level.
func pin_in_front() -> void:
	var forward := -head.global_transform.basis.z
	if absf(forward.normalized().y) > 0.95:
		return # Looking straight up or down: no sensible "level".
	anchor.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), head.global_position)
	_save_config()


func _layout() -> void:
	var size := Vector2(capture.get_size())
	var aspect := size.x / size.y if size.y > 0 else 16.0 / 9.0
	var quad := QuadMesh.new()
	quad.size = Vector2(width, width / aspect)
	screen.mesh = quad
	screen.position = Vector3(0, 0, -distance)
	status.position = Vector3(0, -width / aspect * 0.5 - 0.08, -distance)
	_save_config()


## Matches the camera to the optics for the current window shape, so pinned
## content keeps its real size and doesn't slide as you turn your head.
func _update_camera_fov() -> void:
	var size := Vector2(get_window().size)
	var aspect := size.x / size.y if size.y > 0 else 16.0 / 9.0
	var tan_half_diagonal := tan(deg_to_rad(fov) * 0.5)
	head.keep_aspect = Camera3D.KEEP_HEIGHT
	head.fov = rad_to_deg(2.0 * atan(tan_half_diagonal / sqrt(aspect * aspect + 1.0)))
	_save_config()


func _on_glasses_state(id: int, value: int) -> void:
	if id == STATE_DISPLAY_MODE:
		display_mode = value
		print("Glasses display mode now %s" % DISPLAY_MODES.get(value, "0x%x" % value))
		# Windows re-enumerates the glasses after a mode switch; refit once it settles.
		get_tree().create_timer(1.5).timeout.connect(_refit_after_mode_change)


func _refit_after_mode_change() -> void:
	if DisplayServer.get_screen_count() < 2:
		# Windows treats each mode as a new monitor and falls back to mirroring.
		print("Glasses dropped off the desktop; extending.")
		VitureGlasses.extend_desktop()
		await get_tree().create_timer(2.0).timeout
	_go_fullscreen_on_glasses()
	# Monitor handles change with the layout; re-resolve the captured monitor.
	_start_capture()
	_layout()


# White outline at the window edges plus a centre cross, to see exactly where
# the glasses' display ends.
func _make_edge_overlay() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.visible = false
	var outline := ReferenceRect.new()
	outline.editor_only = false
	outline.border_color = Color.WHITE
	outline.border_width = 6.0
	outline.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(outline)
	for horizontal in [true, false]:
		var line := ColorRect.new()
		line.color = Color.WHITE
		var half := Vector2(40, 2) if horizontal else Vector2(2, 40)
		line.anchor_left = 0.5
		line.anchor_right = 0.5
		line.anchor_top = 0.5
		line.anchor_bottom = 0.5
		line.offset_left = -half.x
		line.offset_right = half.x
		line.offset_top = -half.y
		line.offset_bottom = half.y
		outline.add_child(line)
	return layer


func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG) == OK:
		distance = cfg.get_value("screen", "distance", distance)
		width = cfg.get_value("screen", "width", width)
		fov = cfg.get_value("glasses", "fov", fov)
		# Relative to the tracking origin, which is recentered on the direction
		# you face at startup.
		anchor.transform = cfg.get_value("screen", "anchor", Transform3D.IDENTITY)


func _save_config() -> void:
	if not is_node_ready():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("screen", "distance", distance)
	cfg.set_value("screen", "width", width)
	cfg.set_value("screen", "anchor", anchor.transform)
	cfg.set_value("glasses", "fov", fov)
	cfg.save(CONFIG)


func _start_capture() -> void:
	var monitors := DesktopCapture.get_monitor_names()
	var index := _monitor_index(monitors)
	if index < 0:
		push_warning("Monitor %s is gone; not capturing." % monitor_device)
		capture.stop()
		return
	if capture.start(index):
		material.set_shader_parameter("screen", capture.get_texture())
		print("Capturing ", monitors[index])


func _monitor_index(monitors: PackedStringArray) -> int:
	for i in monitors.size():
		if _device_name(monitors[i]) == monitor_device:
			return i
	return -1


# "\\.\DISPLAY1 1920x1080 at (0, 0)" -> "\\.\DISPLAY1"
func _device_name(monitor_name: String) -> String:
	return monitor_name.get_slice(" ", 0)


func _find_primary(monitors: PackedStringArray) -> int:
	for i in monitors.size():
		if monitors[i].ends_with("at (0, 0)"):
			return i
	return -1


func _go_fullscreen_on_glasses() -> void:
	# The glasses are whichever screen isn't the primary one.
	for i in DisplayServer.get_screen_count():
		if i != DisplayServer.get_primary_screen():
			get_window().mode = Window.MODE_WINDOWED
			get_window().current_screen = i
			get_window().mode = Window.MODE_FULLSCREEN
			_update_camera_fov()
			return
	push_warning("Only one screen found: set Windows to Extend (Win+P) so the glasses are their own display.")
