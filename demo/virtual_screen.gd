extends Node3D

## Pins a capture of a Windows monitor in the room as a virtual screen.
## Run fullscreen on the glasses (2D mode); look around to see any part of it.
##
## Global hotkeys (work from any app): see HOTKEYS. The settings window opens on
## the desktop, so it shows up inside the virtual screen and works with the
## mouse. There is also a tray icon: left-click for settings, right-click for a menu.
##
## Keys while this app or its settings window has focus: Space = pin where you
## are looking, W/S = raise/lower, Up/Down = closer/further, Left/Right = size,
## [ / ] = field of view, B = display edges, H = next display mode, M = next monitor.
##
## Settings, including where the screen is pinned, are saved to user://virtual_screen.cfg.

const CONFIG := "user://virtual_screen.cfg"
# VITURE_DISPLAY_MODE_*: 1920x1080 @ 60/120 Hz, 1920x1200 @ 60/120 Hz.
const DISPLAY_MODES := {0x31: "1080p 60Hz", 0x34: "1080p 120Hz", 0x41: "1200p 60Hz", 0x44: "1200p 120Hz"}
const STATE_DISPLAY_MODE := 2 # VITURE_CALLBACK_ID_DISPLAY_MODE
const HOTKEYS := [
	# [action, combo, repeats while held]
	["repin", "Ctrl+Alt+Shift+Space", false],
	["settings", "Ctrl+Alt+Shift+S", false],
	["raise", "Ctrl+Alt+Shift+PageUp", true],
	["lower", "Ctrl+Alt+Shift+PageDown", true],
]
const PITCH_STEP := 1.5 # Degrees per raise/lower.
const PITCH_LIMIT := 60.0

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
var hotkeys := GlobalHotkeys.new()
var failed_hotkeys: PackedStringArray = []

# Where the screen is pinned, relative to the tracking origin (which recenters
# on the direction you face at startup).
var pin_yaw := 0.0
var pin_pitch := 0.0
var pin_origin := Vector3.ZERO

var settings: Window
var tray: StatusIndicator
var tray_menu: PopupMenu
var _syncing := false
var _ui := {}


func _ready() -> void:
	# Black is see-through on the glasses' OLED optics.
	RenderingServer.set_default_clear_color(Color.BLACK)
	material.shader = preload("res://desktop_screen.gdshader")
	screen.material_override = material
	add_child(edges)
	_load_config()
	_apply_pin()
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

	add_child(hotkeys)
	hotkeys.hotkey_pressed.connect(_do)
	for h in HOTKEYS:
		if not hotkeys.register_hotkey(h[0], h[1], h[2]):
			failed_hotkeys.append(h[1])

	_build_settings_window()
	_build_tray()


func _process(_delta: float) -> void:
	if capture.update():
		# The texture is replaced when the monitor's resolution changes.
		material.set_shader_parameter("screen", capture.get_texture())
	status.text = _status_text()
	if settings.visible:
		_ui.status.text = _status_text()


func _status_text() -> String:
	var state := "capturing" if capture.is_capturing() else "NOT capturing: " + capture.get_last_error()
	return "%s  ·  tracking %s  ·  glasses %s  ·  window %s" % [
		state, "ok" if glasses.is_tracking_stable() else "unstable",
		DISPLAY_MODES.get(display_mode, "mode 0x%x" % display_mode), get_window().size]


func _unhandled_input(event: InputEvent) -> void:
	_handle_key(event)


## Performs a named action; used by hotkeys, keys, the tray menu and the settings window.
func _do(action: String) -> void:
	match action:
		"repin":
			pin_in_front()
		"raise":
			_set_pitch(pin_pitch + deg_to_rad(PITCH_STEP))
		"lower":
			_set_pitch(pin_pitch - deg_to_rad(PITCH_STEP))
		"settings":
			_toggle_settings()
		"edges":
			edges.visible = not edges.visible
		"next_mode":
			if glasses.is_running():
				var modes := DISPLAY_MODES.keys()
				_set_display_mode(modes[(modes.find(display_mode) + 1) % modes.size()])
		"next_monitor":
			var monitors := DesktopCapture.get_monitor_names()
			_set_monitor(monitors[(_monitor_index(monitors) + 1) % maxi(1, monitors.size())])
		"quit":
			get_tree().quit()
	_sync_settings()


func _handle_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var once: bool = not event.echo
	match event.keycode:
		KEY_SPACE when once: _do("repin")
		KEY_W: _do("raise")
		KEY_S: _do("lower")
		KEY_B when once: _do("edges")
		KEY_H when once: _do("next_mode")
		KEY_M when once: _do("next_monitor")
		KEY_UP: _set_distance(distance - 0.1)
		KEY_DOWN: _set_distance(distance + 0.1)
		KEY_LEFT: _set_width(width - 0.1)
		KEY_RIGHT: _set_width(width + 0.1)
		KEY_BRACKETLEFT: _set_fov(fov - 0.5)
		KEY_BRACKETRIGHT: _set_fov(fov + 0.5)
		KEY_TAB when once:
			get_window().current_screen = (get_window().current_screen + 1) % DisplayServer.get_screen_count()
		_: return
	_sync_settings()


# --- Placement -----------------------------------------------------------------

## Re-pins the screen centred on where you are looking, facing you, with its
## horizon kept level.
func pin_in_front() -> void:
	var forward := -head.global_transform.basis.z.normalized()
	if absf(forward.y) > 0.95:
		return # Looking straight up or down: no sensible "level".
	pin_yaw = atan2(-forward.x, -forward.z)
	pin_pitch = clampf(asin(forward.y), -deg_to_rad(PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))
	pin_origin = head.global_position
	_apply_pin()
	_save_config()


func _set_pitch(radians: float) -> void:
	pin_pitch = clampf(radians, -deg_to_rad(PITCH_LIMIT), deg_to_rad(PITCH_LIMIT))
	_apply_pin()
	_save_config()


func _apply_pin() -> void:
	# Yaw then pitch: the screen swings along an arc around the viewer, facing them.
	anchor.transform = Transform3D(Basis.from_euler(Vector3(pin_pitch, pin_yaw, 0.0)), pin_origin)


func _set_distance(value: float) -> void:
	distance = clampf(value, 0.5, 10.0)
	_layout()


func _set_width(value: float) -> void:
	width = clampf(value, 0.3, 8.0)
	_layout()


func _layout() -> void:
	var size := Vector2(capture.get_size())
	var aspect := size.x / size.y if size.y > 0 else 16.0 / 9.0
	var quad := QuadMesh.new()
	quad.size = Vector2(width, width / aspect)
	screen.mesh = quad
	screen.position = Vector3(0, 0, -distance)
	status.position = Vector3(0, -width / aspect * 0.5 - 0.08, -distance)
	_save_config()


# --- Glasses display ---------------------------------------------------------------

func _set_fov(value: float) -> void:
	fov = clampf(value, 20.0, 90.0)
	_update_camera_fov()


## Matches the camera to the optics for the current window shape, so pinned
## content keeps its real size and doesn't slide as you turn your head.
func _update_camera_fov() -> void:
	var size := Vector2(get_window().size)
	var aspect := size.x / size.y if size.y > 0 else 16.0 / 9.0
	var tan_half_diagonal := tan(deg_to_rad(fov) * 0.5)
	head.keep_aspect = Camera3D.KEEP_HEIGHT
	head.fov = rad_to_deg(2.0 * atan(tan_half_diagonal / sqrt(aspect * aspect + 1.0)))
	_save_config()


func _set_display_mode(mode: int) -> void:
	if glasses.is_running() and mode != display_mode:
		print("Switching glasses to %s" % DISPLAY_MODES.get(mode, "0x%x" % mode))
		glasses.set_display_mode(mode)


func _on_glasses_state(id: int, value: int) -> void:
	if id == STATE_DISPLAY_MODE:
		display_mode = value
		print("Glasses display mode now %s" % DISPLAY_MODES.get(value, "0x%x" % value))
		_sync_settings()
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


# --- Capture -----------------------------------------------------------------------

func _set_monitor(monitor_name: String) -> void:
	monitor_device = _device_name(monitor_name)
	_start_capture()
	_layout()


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


# --- Settings window -------------------------------------------------------------

func _build_settings_window() -> void:
	settings = Window.new()
	settings.title = "VITURE virtual screen"
	settings.size = Vector2i(460, 600)
	settings.always_on_top = true
	settings.visible = false
	settings.close_requested.connect(func(): settings.hide())
	# Keys pressed while it has focus go to its own viewport, not ours.
	settings.window_input.connect(_handle_key)
	add_child(settings)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_ui.status = Label.new()
	_ui.status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ui.status.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_ui.status)

	_ui.distance = _slider_row(box, "Distance", "%.2f m", 0.5, 6.0, 0.05, _set_distance)
	_ui.width = _slider_row(box, "Width", "%.2f m", 0.3, 6.0, 0.05, _set_width)
	_ui.height = _slider_row(box, "Height", "%+.1f°", -PITCH_LIMIT, PITCH_LIMIT, 0.5,
			func(v): _set_pitch(deg_to_rad(v)))
	_ui.fov = _slider_row(box, "Field of view", "%.1f°", 40.0, 65.0, 0.1, _set_fov)

	_ui.mode = OptionButton.new()
	for mode in DISPLAY_MODES:
		_ui.mode.add_item(DISPLAY_MODES[mode], mode)
	_ui.mode.item_selected.connect(func(i): _set_display_mode(_ui.mode.get_item_id(i)))
	_labelled(box, "Glasses mode", _ui.mode)

	_ui.monitor = OptionButton.new()
	_ui.monitor.item_selected.connect(func(i): _set_monitor(_ui.monitor.get_item_text(i)))
	_labelled(box, "Show monitor", _ui.monitor)

	_ui.edges = CheckButton.new()
	_ui.edges.text = "Show display edges"
	_ui.edges.toggled.connect(func(on): edges.visible = on)
	box.add_child(_ui.edges)

	var buttons := HBoxContainer.new()
	for b in [["Pin where I'm looking", "repin"], ["Reset height", "reset_height"]]:
		var button := Button.new()
		button.text = b[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func():
			if b[1] == "reset_height":
				_set_pitch(0.0)
				_sync_settings()
			else:
				_do(b[1]))
		buttons.add_child(button)
	box.add_child(buttons)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.7)
	var lines := PackedStringArray(["Hotkeys (from any app):"])
	for h in HOTKEYS:
		lines.append("  %s  —  %s%s" % [h[1], h[0], "  (IN USE by another app)" if h[1] in failed_hotkeys else ""])
	help.text = "\n".join(lines)
	box.add_child(help)


func _slider_row(parent: Control, label: String, fmt: String, lo: float, hi: float, step: float, on_change: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 70
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	slider.value_changed.connect(func(v):
		value_label.text = fmt % v
		if not _syncing:
			on_change.call(v))
	var row := _labelled(parent, label, slider)
	row.add_child(value_label)
	return slider


func _labelled(parent: Control, label: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = label
	name_label.custom_minimum_size.x = 110
	row.add_child(name_label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	parent.add_child(row)
	return row


func _toggle_settings() -> void:
	if settings.visible:
		settings.hide()
		return
	# Open on the primary (captured) desktop so it appears in the virtual screen.
	var primary := DisplayServer.get_primary_screen()
	var area := DisplayServer.screen_get_usable_rect(primary)
	settings.position = area.position + (area.size - settings.size) / 2
	_sync_settings()
	settings.show()
	settings.grab_focus()


## Pushes current values into the settings controls without re-triggering them.
func _sync_settings() -> void:
	if settings == null or not settings.visible:
		return
	_syncing = true
	_ui.distance.value = distance
	_ui.width.value = width
	_ui.height.value = rad_to_deg(pin_pitch)
	_ui.fov.value = fov
	_ui.edges.button_pressed = edges.visible
	for i in _ui.mode.item_count:
		if _ui.mode.get_item_id(i) == display_mode:
			_ui.mode.select(i)
	_ui.monitor.clear()
	for m in DesktopCapture.get_monitor_names():
		_ui.monitor.add_item(m)
		if _device_name(m) == monitor_device:
			_ui.monitor.select(_ui.monitor.item_count - 1)
	_syncing = false


# --- Tray icon -----------------------------------------------------------------------

func _build_tray() -> void:
	tray_menu = PopupMenu.new()
	for item in [["Pin where I'm looking", "repin"], ["Settings", "settings"], ["Show display edges", "edges"], ["Quit", "quit"]]:
		tray_menu.add_item(item[0])
		tray_menu.set_item_metadata(tray_menu.item_count - 1, item[1])
	tray_menu.index_pressed.connect(func(i): _do(tray_menu.get_item_metadata(i)))
	add_child(tray_menu)

	tray = StatusIndicator.new()
	tray.tooltip = "VITURE virtual screen"
	tray.icon = _make_tray_icon()
	tray.pressed.connect(func(button: int, position: Vector2i):
		if button == MOUSE_BUTTON_LEFT:
			_do("settings")
		elif button == MOUSE_BUTTON_RIGHT:
			tray_menu.popup(Rect2i(position - Vector2i(0, tray_menu.get_contents_minimum_size().y as int), Vector2i.ZERO)))
	add_child(tray)


func _make_tray_icon() -> Texture2D:
	# A simple pair-of-lenses glyph, so no icon file is needed.
	var image := Image.create_empty(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			for cx in [10, 22]:
				var d := Vector2(x - cx, y - 16).length()
				if d < 7.5 and d > 4.5:
					image.set_pixel(x, y, Color(0.55, 0.8, 1.0))
	for x in range(14, 19):
		image.set_pixel(x, 15, Color(0.55, 0.8, 1.0))
	return ImageTexture.create_from_image(image)


# --- Persistence ---------------------------------------------------------------------

func _load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG) != OK:
		return
	distance = cfg.get_value("screen", "distance", distance)
	width = cfg.get_value("screen", "width", width)
	fov = cfg.get_value("glasses", "fov", fov)
	if cfg.has_section_key("screen", "pin_yaw"):
		pin_yaw = cfg.get_value("screen", "pin_yaw")
		pin_pitch = cfg.get_value("screen", "pin_pitch", 0.0)
		pin_origin = cfg.get_value("screen", "pin_origin", Vector3.ZERO)
	elif cfg.has_section_key("screen", "anchor"):
		# Older saves stored the anchor transform directly.
		var t: Transform3D = cfg.get_value("screen", "anchor")
		var euler := t.basis.get_euler() # YXZ: x = pitch, y = yaw.
		pin_pitch = euler.x
		pin_yaw = euler.y
		pin_origin = t.origin


func _save_config() -> void:
	if not is_node_ready():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("screen", "distance", distance)
	cfg.set_value("screen", "width", width)
	cfg.set_value("screen", "pin_yaw", pin_yaw)
	cfg.set_value("screen", "pin_pitch", pin_pitch)
	cfg.set_value("screen", "pin_origin", pin_origin)
	cfg.set_value("glasses", "fov", fov)
	cfg.save(CONFIG)
