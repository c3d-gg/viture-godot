extends Node3D

## Pins live captures of Windows monitors in the room as virtual screens.
## Run fullscreen on the glasses (2D mode); look around to see any of them.
##
## Global hotkeys (work from any app): see HOTKEYS. Grab picks up the screen
## you are looking at; it follows your gaze until you grab again to drop it.
## The settings window opens on the desktop, so it shows up inside a virtual
## screen and works with the mouse. Tray icon: left-click for settings,
## right-click for a menu.
##
## Keys while this app or its settings window has focus act on the screen you
## are looking at (else the one selected in settings): Space = grab/drop,
## W/S = raise/lower, Up/Down = closer/further, Left/Right = size,
## [ / ] = field of view, B = display edges, H = next display mode.
##
## Everything is saved to user://virtual_screen.cfg.

const CONFIG := "user://virtual_screen.cfg"
# VITURE_DISPLAY_MODE_*: 1920x1080 @ 60/120 Hz, 1920x1200 @ 60/120 Hz.
const DISPLAY_MODES := {0x31: "1080p 60Hz", 0x34: "1080p 120Hz", 0x41: "1200p 60Hz", 0x44: "1200p 120Hz"}
const STATE_DISPLAY_MODE := 2 # VITURE_CALLBACK_ID_DISPLAY_MODE
const HOTKEYS := [
	# [action, combo, repeats while held]
	["grab", "Ctrl+Alt+Shift+Space", false],
	["settings", "Ctrl+Alt+Shift+S", false],
	["raise", "Ctrl+Alt+Shift+PageUp", true],
	["lower", "Ctrl+Alt+Shift+PageDown", true],
]
const VIRTUAL_SIZES: Array[Vector2i] = [
	Vector2i(1920, 1080), Vector2i(1920, 1200), Vector2i(2560, 1440), Vector2i(2560, 1080), Vector2i(3840, 2160),
]
const PITCH_STEP := deg_to_rad(1.5)
const LOOK_AT_ANGLE := deg_to_rad(30.0) # How close to a screen's centre counts as looking at it.
const ScreenPanel := preload("res://screen_panel.gd")

@export var fov := 52.0 ## Diagonal field of view of the glasses, degrees.
@export var preferred_display_mode := 0x44 ## 1200p 120Hz: full panel, smoothest head tracking.

@onready var glasses: VitureGlasses = $Glasses
@onready var head: XRCamera3D = $XROrigin3D/Head
@onready var status: Label3D = $XROrigin3D/Head/Status

var panels: Array[ScreenPanel] = []
var selected: ScreenPanel # Edited by the settings window.
var grabbed: ScreenPanel # Following your gaze until dropped.
var looked_at: ScreenPanel

var edges := _make_edge_overlay()
var display_mode := -1 # Cached: reading it is a USB round trip to the glasses.
var hotkeys := GlobalHotkeys.new()
# Virtual monitors exist only while the app runs; they're removed on exit.
var virtual_displays := VirtualDisplays.new()
var failed_hotkeys: PackedStringArray = []

var settings: Window
var tray: StatusIndicator
var tray_menu: PopupMenu
var _syncing := false
var _ui := {}


func _ready() -> void:
	# Black is see-through on the glasses' OLED optics.
	RenderingServer.set_default_clear_color(Color.BLACK)
	add_child(edges)
	add_child(virtual_displays)
	get_window().size_changed.connect(_update_camera_fov)
	glasses.state_changed.connect(_on_glasses_state)
	print("Monitors: ", DesktopCapture.get_monitor_names())

	_load_config()
	if panels.is_empty():
		_add_panel(_device_of(DesktopCapture.get_monitor_names()[maxi(0, _find_primary())]))
	selected = panels[0]
	_go_fullscreen_on_glasses.call_deferred()

	if glasses.is_running():
		display_mode = glasses.get_display_mode()
		if display_mode != preferred_display_mode:
			_set_display_mode(preferred_display_mode)

	add_child(hotkeys)
	hotkeys.hotkey_pressed.connect(_do)
	for h in HOTKEYS:
		if not hotkeys.register_hotkey(h[0], h[1], h[2]):
			failed_hotkeys.append(h[1])

	_build_settings_window()
	_build_tray()


func _process(_delta: float) -> void:
	var origin := head.global_position
	var forward := -head.global_transform.basis.z
	if grabbed:
		grabbed.aim(forward, origin)

	looked_at = null
	var best := LOOK_AT_ANGLE
	for panel in panels:
		var angle := panel.angle_from(origin, forward)
		if angle < best:
			best = angle
			looked_at = panel
	for panel in panels:
		panel.highlighted = panel == grabbed or (settings.visible and panel == selected)

	status.text = _status_text() if edges.visible or settings.visible else ""
	if settings.visible:
		_ui.status.text = _status_text()


func _status_text() -> String:
	return "tracking %s  ·  glasses %s  ·  window %s  ·  %d screen(s)%s" % [
		"ok" if glasses.is_tracking_stable() else "unstable",
		DISPLAY_MODES.get(display_mode, "mode 0x%x" % display_mode), get_window().size,
		panels.size(), "  ·  GRABBED: look where you want it, grab again to drop" if grabbed else ""]


func _unhandled_input(event: InputEvent) -> void:
	_handle_key(event)


## The screen keyboard/hotkey adjustments apply to.
func _target() -> ScreenPanel:
	if grabbed:
		return grabbed
	return looked_at if looked_at else selected


## Performs a named action; used by hotkeys, keys, the tray menu and the settings window.
func _do(action: String) -> void:
	var target := _target()
	match action:
		"grab":
			if grabbed:
				grabbed = null
				_save_config()
			else:
				grabbed = target
				selected = target
		"raise":
			target.pin_pitch += PITCH_STEP
			target.apply_pin()
			_save_config()
		"lower":
			target.pin_pitch -= PITCH_STEP
			target.apply_pin()
			_save_config()
		"settings":
			_toggle_settings()
		"edges":
			edges.visible = not edges.visible
		"next_mode":
			if glasses.is_running():
				var modes := DISPLAY_MODES.keys()
				_set_display_mode(modes[(modes.find(display_mode) + 1) % modes.size()])
		"add":
			_add_panel(_unused_monitor())
		"add_virtual":
			_add_virtual_panel()
		"remove":
			_remove_panel(selected)
		"quit":
			get_tree().quit()
	_sync_settings()


func _handle_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var once: bool = not event.echo
	var target := _target()
	match event.keycode:
		KEY_SPACE when once: _do("grab")
		KEY_W: _do("raise")
		KEY_S: _do("lower")
		KEY_B when once: _do("edges")
		KEY_H when once: _do("next_mode")
		KEY_UP: _set_distance(target, target.distance - 0.1)
		KEY_DOWN: _set_distance(target, target.distance + 0.1)
		KEY_LEFT: _set_width(target, target.width - 0.1)
		KEY_RIGHT: _set_width(target, target.width + 0.1)
		KEY_BRACKETLEFT: _set_fov(fov - 0.5)
		KEY_BRACKETRIGHT: _set_fov(fov + 0.5)
		KEY_TAB when once:
			get_window().current_screen = (get_window().current_screen + 1) % DisplayServer.get_screen_count()
		_: return
	_sync_settings()


# --- Panels --------------------------------------------------------------------------

func _add_panel(monitor_device: String, data := {}) -> ScreenPanel:
	var panel := ScreenPanel.new()
	panel.monitor_device = monitor_device
	if data.is_empty() and not panels.is_empty():
		# Place it to the right of the selected screen, same distance and height.
		var beside := selected if selected else panels[-1]
		panel.distance = beside.distance
		panel.width = beside.width
		panel.pin_pitch = beside.pin_pitch
		panel.pin_origin = beside.pin_origin
		panel.pin_yaw = beside.pin_yaw - 2.0 * atan((beside.width * 0.5 + 0.05) / beside.distance)
	else:
		panel.from_dict(data)
	add_child(panel)
	panels.append(panel)
	if not panel.start_capture():
		push_warning("Monitor %s is not attached; its screen stays blank until it is." % monitor_device)
	panel.layout()
	selected = panel
	_save_config()
	return panel


func _remove_panel(panel: ScreenPanel) -> void:
	if panels.size() <= 1 or panel == null:
		return
	panels.erase(panel)
	if grabbed == panel:
		grabbed = null
	if panel.virtual_slot >= 0:
		virtual_displays.remove_display(panel.virtual_slot)
		_refit_soon()
	panel.queue_free()
	selected = panels[0]
	_save_config()


## Adds a screen backed by a new virtual monitor (needs the SudoVDA driver).
func _add_virtual_panel() -> void:
	var used := panels.map(func(p): return p.virtual_slot)
	var slot := 0
	while slot in used:
		slot += 1
	var size := Vector2i(1920, 1080)
	var device := virtual_displays.add_display(slot, size.x, size.y, 60)
	if device.is_empty():
		_notice("Couldn't add a virtual monitor: " + virtual_displays.get_last_error())
		return
	print("Virtual monitor %d is %s" % [slot, device])
	var panel := _add_panel(device)
	panel.virtual_slot = slot
	panel.virtual_size = size
	_save_config()
	_refit_soon()


## Changes a virtual monitor's resolution by recreating it.
func _set_virtual_size(panel: ScreenPanel, size: Vector2i) -> void:
	if panel.virtual_slot < 0 or size == panel.virtual_size:
		return
	virtual_displays.remove_display(panel.virtual_slot)
	var device := virtual_displays.add_display(panel.virtual_slot, size.x, size.y, 60)
	if device.is_empty():
		_notice("Couldn't resize the virtual monitor: " + virtual_displays.get_last_error())
		return
	panel.virtual_size = size
	panel.monitor_device = device
	_save_config()
	_refit_soon()


# Adding or removing a monitor rearranges the desktop: give Windows a moment,
# then refit the window and restart every capture.
func _refit_soon() -> void:
	get_tree().create_timer(1.0).timeout.connect(_refit_after_display_change)


func _notice(message: String) -> void:
	push_warning(message)
	if settings:
		_ui.notice.text = message


func _set_distance(panel: ScreenPanel, value: float) -> void:
	panel.distance = clampf(value, 0.5, 10.0)
	panel.layout()
	_save_config()


func _set_width(panel: ScreenPanel, value: float) -> void:
	panel.width = clampf(value, 0.3, 8.0)
	panel.layout()
	_save_config()


func _set_monitor(panel: ScreenPanel, monitor_device: String) -> void:
	panel.monitor_device = monitor_device
	panel.start_capture()
	_save_config()


## A monitor that isn't the glasses and isn't shown yet, else the primary one.
func _unused_monitor() -> String:
	var used := panels.map(func(p): return p.monitor_device)
	var glasses_device := _glasses_device()
	for m in DesktopCapture.get_monitor_names():
		var device := _device_of(m)
		if device != glasses_device and device not in used:
			return device
	return _device_of(DesktopCapture.get_monitor_names()[maxi(0, _find_primary())])


## The glasses' Windows display, found by its VITURE monitor ID.
func _glasses_device() -> String:
	return VitureGlasses.get_glasses_display()


## Godot screen index of the glasses, or -1 if they aren't on the desktop.
func _glasses_screen() -> int:
	var device := _glasses_device()
	for m in DesktopCapture.get_monitor_names():
		if _device_of(m) != device:
			continue
		# "... at (x, y)": match Godot's screen by its desktop position.
		var at := m.get_slice("at (", 1).trim_suffix(")").split(", ")
		var pos := Vector2i(at[0].to_int(), at[1].to_int())
		for i in DisplayServer.get_screen_count():
			if DisplayServer.screen_get_position(i) == pos:
				return i
	return -1


func _device_of(monitor_name: String) -> String:
	return ScreenPanel.device_name(monitor_name)


func _find_primary() -> int:
	var monitors := DesktopCapture.get_monitor_names()
	for i in monitors.size():
		if monitors[i].ends_with("at (0, 0)"):
			return i
	return -1


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
		get_tree().create_timer(1.5).timeout.connect(_refit_after_display_change)


func _refit_after_display_change() -> void:
	if _glasses_screen() < 0:
		# Windows treats each mode as a new monitor and falls back to mirroring.
		print("Glasses dropped off the desktop; extending.")
		VitureGlasses.extend_desktop()
		await get_tree().create_timer(2.0).timeout
	_go_fullscreen_on_glasses()
	# Monitor handles change with the layout; re-resolve every capture.
	for panel in panels:
		panel.start_capture()


func _go_fullscreen_on_glasses() -> void:
	var screen := _glasses_screen()
	if screen < 0:
		push_warning("The glasses aren't on the desktop: set Windows to Extend (Win+P) so they are their own display.")
		return
	get_window().mode = Window.MODE_WINDOWED
	get_window().current_screen = screen
	get_window().mode = Window.MODE_FULLSCREEN
	_update_camera_fov()


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


# --- Settings window -------------------------------------------------------------

func _build_settings_window() -> void:
	settings = Window.new()
	settings.title = "VITURE virtual screens"
	settings.size = Vector2i(480, 700)
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

	# Screens
	box.add_child(_heading("Screens"))
	_ui.screens = OptionButton.new()
	_ui.screens.item_selected.connect(func(i):
		selected = panels[i]
		_sync_settings())
	_labelled(box, "Editing", _ui.screens)
	box.add_child(_button_row([["Add virtual monitor", "add_virtual"], ["Add existing monitor", "add"]]))
	box.add_child(_button_row([["Remove screen", "remove"], ["Grab / drop", "grab"]]))
	_ui.notice = Label.new()
	_ui.notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ui.notice.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	box.add_child(_ui.notice)

	_ui.monitor = OptionButton.new()
	_ui.monitor.item_selected.connect(func(i): _set_monitor(selected, _device_of(_ui.monitor.get_item_text(i))))
	_labelled(box, "Shows", _ui.monitor)
	_ui.resolution = OptionButton.new()
	for size in VIRTUAL_SIZES:
		_ui.resolution.add_item("%d × %d" % [size.x, size.y])
	_ui.resolution.item_selected.connect(func(i): _set_virtual_size(selected, VIRTUAL_SIZES[i]))
	_ui.resolution_row = _labelled(box, "Resolution", _ui.resolution)
	_ui.distance = _slider_row(box, "Distance", "%.2f m", 0.5, 6.0, 0.05, func(v): _set_distance(selected, v))
	_ui.width = _slider_row(box, "Width", "%.2f m", 0.3, 6.0, 0.05, func(v): _set_width(selected, v))
	_ui.height = _slider_row(box, "Height", "%+.1f°", -60.0, 60.0, 0.5, func(v):
		selected.pin_pitch = deg_to_rad(v)
		selected.apply_pin()
		_save_config())

	# Glasses
	box.add_child(_heading("Glasses"))
	_ui.fov = _slider_row(box, "Field of view", "%.1f°", 40.0, 65.0, 0.1, _set_fov)
	_ui.mode = OptionButton.new()
	for mode in DISPLAY_MODES:
		_ui.mode.add_item(DISPLAY_MODES[mode], mode)
	_ui.mode.item_selected.connect(func(i): _set_display_mode(_ui.mode.get_item_id(i)))
	_labelled(box, "Display mode", _ui.mode)
	_ui.edges = CheckButton.new()
	_ui.edges.text = "Show display edges"
	_ui.edges.toggled.connect(func(on): edges.visible = on)
	box.add_child(_ui.edges)

	var help := Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.7)
	var lines := PackedStringArray(["Hotkeys (from any app):"])
	for h in HOTKEYS:
		lines.append("  %s  —  %s%s" % [h[1], h[0], "  (IN USE by another app)" if h[1] in failed_hotkeys else ""])
	help.text = "\n".join(lines)
	box.add_child(help)


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	return label


func _button_row(buttons: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	for b in buttons:
		var button := Button.new()
		button.text = b[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func(): _do(b[1]))
		row.add_child(button)
	return row


func _slider_row(parent: Control, label: String, fmt: String, lo: float, hi: float, step: float, on_change: Callable) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
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
	# Open on the primary (captured) desktop so it appears in a virtual screen.
	var area := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	settings.position = area.position + (area.size - settings.size) / 2
	settings.show()
	_sync_settings()
	settings.grab_focus()


## Pushes current values into the settings controls without re-triggering them.
func _sync_settings() -> void:
	if settings == null or not settings.visible:
		return
	_syncing = true
	_ui.screens.clear()
	for i in panels.size():
		_ui.screens.add_item("Screen %d — %s" % [i + 1, panels[i].monitor_device])
		if panels[i] == selected:
			_ui.screens.select(i)
	var glasses_device := _glasses_device()
	_ui.monitor.clear()
	for m in DesktopCapture.get_monitor_names():
		if _device_of(m) == glasses_device:
			continue # Capturing the glasses' own display just shows a hall of mirrors.
		_ui.monitor.add_item(m)
		if _device_of(m) == selected.monitor_device:
			_ui.monitor.select(_ui.monitor.item_count - 1)
	_ui.distance.value = selected.distance
	_ui.width.value = selected.width
	# Only virtual monitors can change resolution; real ones show what they show.
	_ui.resolution_row.visible = selected.virtual_slot >= 0
	_ui.monitor.get_parent().visible = selected.virtual_slot < 0
	_ui.resolution.select(VIRTUAL_SIZES.find(selected.virtual_size))
	_ui.height.value = rad_to_deg(selected.pin_pitch)
	_ui.fov.value = fov
	_ui.edges.button_pressed = edges.visible
	for i in _ui.mode.item_count:
		if _ui.mode.get_item_id(i) == display_mode:
			_ui.mode.select(i)
	_syncing = false


# --- Tray icon -----------------------------------------------------------------------

func _build_tray() -> void:
	tray_menu = PopupMenu.new()
	for item in [["Grab / drop screen", "grab"], ["Add virtual monitor", "add_virtual"], ["Settings", "settings"],
			["Show display edges", "edges"], ["Quit", "quit"]]:
		tray_menu.add_item(item[0])
		tray_menu.set_item_metadata(tray_menu.item_count - 1, item[1])
	tray_menu.index_pressed.connect(func(i): _do(tray_menu.get_item_metadata(i)))
	add_child(tray_menu)

	tray = StatusIndicator.new()
	tray.tooltip = "VITURE virtual screens"
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
	fov = cfg.get_value("glasses", "fov", fov)
	var list: Array = cfg.get_value("screens", "list", [])
	if list.is_empty() and cfg.has_section("screen"):
		list = [_migrate_single_screen(cfg)]
	var recreated := false
	for data: Dictionary in list:
		var slot: int = data.get("virtual_slot", -1)
		if slot >= 0:
			# Virtual monitors don't outlive the app; bring this one back.
			var size: Vector2i = data.get("virtual_size", Vector2i(1920, 1080))
			var device := virtual_displays.add_display(slot, size.x, size.y, 60)
			if device.is_empty():
				push_warning("Couldn't recreate virtual monitor %d: %s" % [slot, virtual_displays.get_last_error()])
				continue
			data.monitor = device
			recreated = true
		_add_panel(data.get("monitor", ""), data)
	if recreated:
		_refit_soon()


# Saves from before multiple screens: one [screen] section.
func _migrate_single_screen(cfg: ConfigFile) -> Dictionary:
	var data := {
		"monitor": _device_of(DesktopCapture.get_monitor_names()[maxi(0, _find_primary())]),
		"distance": cfg.get_value("screen", "distance", 2.0),
		"width": cfg.get_value("screen", "width", 1.6),
	}
	if cfg.has_section_key("screen", "pin_yaw"):
		data.yaw = cfg.get_value("screen", "pin_yaw")
		data.pitch = cfg.get_value("screen", "pin_pitch", 0.0)
		data.origin = cfg.get_value("screen", "pin_origin", Vector3.ZERO)
	elif cfg.has_section_key("screen", "anchor"):
		var t: Transform3D = cfg.get_value("screen", "anchor")
		var euler := t.basis.get_euler() # YXZ: x = pitch, y = yaw.
		data.pitch = euler.x
		data.yaw = euler.y
		data.origin = t.origin
	return data


func _save_config() -> void:
	if not is_node_ready():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("glasses", "fov", fov)
	cfg.set_value("screens", "list", panels.map(func(p): return p.to_dict()))
	cfg.save(CONFIG)
