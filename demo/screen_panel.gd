extends Node3D

## One virtual screen: a live capture of a Windows monitor or a single app
## window on a quad, pinned in the room. The panel's node sits at the viewer (`pin_origin`) with
## orientation `pin_basis`, and the quad is `distance` along its -Z, facing
## back at the viewer.

const SHADER := preload("res://desktop_screen.gdshader")
const PITCH_LIMIT := deg_to_rad(60.0)
const EDGE_GAP := deg_to_rad(1.0) # Between neighbouring screens.

## Windows device name of the captured monitor, e.g. "\\.\DISPLAY1". Tracked by
## name because indices and handles change when the display layout does.
var monitor_device := ""
## "monitor" or "window". A window is remembered by its app and title, since
## its handle changes every time the app is restarted.
var source := "monitor"
var window_handle := 0
var window_process := ""
var window_title := ""
## SudoVDA slot of the virtual monitor this panel owns, or -1 for a real monitor.
var virtual_slot := -1
var virtual_size := Vector2i(1920, 1080)
var distance := 2.0
var width := 1.6
## Full orientation, so a row of tilted screens can share a tilted axis (and
## so a screen can lean like its neighbours) rather than only yaw + pitch.
var pin_basis := Basis.IDENTITY
var pin_origin := Vector3.ZERO
var highlighted := false:
	set(value):
		highlighted = value
		_frame.visible = value

var capture := DesktopCapture.new()
var _material := ShaderMaterial.new()
var _quad := MeshInstance3D.new()
var _frame := MeshInstance3D.new()
var _label := Label3D.new()
var _laid_out_size := Vector2i.ZERO


func _init() -> void:
	_material.shader = SHADER
	_quad.material_override = _material
	add_child(_quad)

	# A slightly larger quad behind the screen, shown when highlighted.
	var frame_material := StandardMaterial3D.new()
	frame_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	frame_material.albedo_color = Color(0.35, 0.7, 1.0)
	_frame.material_override = frame_material
	_frame.visible = false
	add_child(_frame)

	_label.pixel_size = 0.001
	_label.font_size = 24
	_label.outline_size = 6
	add_child(_label)


func _process(_delta: float) -> void:
	if capture.update():
		# The texture is replaced when the monitor's resolution changes.
		_material.set_shader_parameter("screen", capture.get_texture())
		if capture.get_size() != _laid_out_size:
			layout() # Windows resize freely; keep the panel's shape matching.
	_label.text = display_name() if capture.is_capturing() else "%s: not capturing (%s)" % [display_name(), capture.get_last_error()]


func display_name() -> String:
	if source == "window":
		return "%s (%s)" % [window_title, window_process]
	return monitor_device


func set_sharpness(value: float) -> void:
	_material.set_shader_parameter("sharpness", value)


## (Re)starts capturing the monitor or window. Returns false if it's gone.
func start_capture() -> bool:
	if source == "window":
		if DesktopCapture.get_window_info(window_handle).is_empty():
			window_handle = _find_window()
		if window_handle == 0:
			capture.stop()
			return false
		var info := DesktopCapture.get_window_info(window_handle)
		window_title = info.get("title", window_title)
		window_process = info.get("process", window_process)
		if capture.start_window(window_handle):
			_material.set_shader_parameter("screen", capture.get_texture())
			layout()
			return true
		return false

	var monitors := DesktopCapture.get_monitor_names()
	for i in monitors.size():
		if device_name(monitors[i]) == monitor_device:
			if capture.start(i):
				_material.set_shader_parameter("screen", capture.get_texture())
				layout()
				return true
			return false
	capture.stop()
	return false


## Points this panel at a window (from DesktopCapture.get_windows()).
func set_window(info: Dictionary) -> void:
	source = "window"
	window_handle = info.get("handle", 0)
	window_title = info.get("title", "")
	window_process = info.get("process", "")


# Re-finds the remembered window: same app and title, else the same app.
func _find_window() -> int:
	var same_app := 0
	for w: Dictionary in DesktopCapture.get_windows():
		if w.process == window_process:
			if w.title == window_title:
				return w.handle
			if same_app == 0:
				same_app = w.handle
	return same_app


func layout() -> void:
	_laid_out_size = capture.get_size()
	var size := Vector2(capture.get_size())
	var aspect := size.x / size.y if size.y > 0 else 16.0 / 9.0
	var height := width / aspect
	var quad := QuadMesh.new()
	quad.size = Vector2(width, height)
	_quad.mesh = quad
	_quad.position = Vector3(0, 0, -distance)
	var frame := QuadMesh.new()
	frame.size = Vector2(width, height) + Vector2.ONE * 0.04
	_frame.mesh = frame
	_frame.position = Vector3(0, 0, -distance - 0.005)
	_label.position = Vector3(0, -height * 0.5 - 0.06, -distance)
	apply_pin()


func apply_pin() -> void:
	pin_basis = pin_basis.orthonormalized()
	transform = Transform3D(pin_basis, pin_origin)


# --- Orientation helpers -------------------------------------------------------------

func forward() -> Vector3:
	return -pin_basis.z


## Compass direction, radians; larger is further left.
func get_yaw() -> float:
	var f := forward()
	return atan2(-f.x, -f.z)


## Elevation of the screen's centre, radians; negative is below eye level.
func get_pitch() -> float:
	return asin(clampf(forward().y, -1.0, 1.0))


## Sets the elevation, keeping the compass direction and levelling the screen.
func set_pitch(radians: float) -> void:
	pin_basis = Basis.from_euler(Vector3(clampf(radians, -PITCH_LIMIT, PITCH_LIMIT), get_yaw(), 0.0))
	apply_pin()


## Moves the screen up or down along its own arc, keeping any lean it has
## from being lined up with tilted neighbours.
func nudge_pitch(radians: float) -> void:
	var nudged := pin_basis * Basis(Vector3.RIGHT, radians)
	if absf(asin(clampf(-nudged.z.y, -1.0, 1.0))) <= PITCH_LIMIT:
		pin_basis = nudged
		apply_pin()


## Points the panel along `forward` (a gaze direction) from `origin`, kept level.
func aim(direction: Vector3, origin: Vector3) -> void:
	direction = direction.normalized()
	if absf(direction.y) > 0.95:
		return # Looking straight up or down: no sensible "level".
	pin_basis = Basis.looking_at(direction, Vector3.UP)
	pin_origin = origin
	apply_pin()


## Half the angle this panel spans across its own width, seen from the viewer.
func half_extent() -> float:
	return atan2(width * 0.5, distance)


## Orientation that puts this panel edge to edge with `other`, on its left
## (side = -1) or right (side = +1). Rotating about `other`'s own up axis keeps
## a tilted row flush along the full height of every edge.
func slot_beside(other: Node3D, side: int) -> Basis:
	var angle: float = other.half_extent() + half_extent() + EDGE_GAP
	return other.pin_basis * Basis(Vector3.UP, -side * angle)


func place_beside(other: Node3D, side: int) -> void:
	pin_basis = slot_beside(other, side)
	pin_origin = other.pin_origin
	apply_pin()


## Angle in radians between `forward` from `origin` and this panel's centre.
func angle_from(origin: Vector3, direction: Vector3) -> float:
	var centre := _quad.global_position
	return direction.normalized().angle_to(centre - origin)


# --- Persistence ---------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"monitor": monitor_device, "distance": distance, "width": width,
		"source": source, "window_process": window_process, "window_title": window_title,
		"basis": pin_basis, "origin": pin_origin,
		"virtual_slot": virtual_slot, "virtual_size": virtual_size,
	}


func from_dict(d: Dictionary) -> void:
	monitor_device = d.get("monitor", monitor_device)
	source = d.get("source", source)
	window_process = d.get("window_process", window_process)
	window_title = d.get("window_title", window_title)
	distance = d.get("distance", distance)
	width = d.get("width", width)
	if d.has("basis"):
		pin_basis = d.basis
	else:
		# Older saves: yaw then pitch.
		pin_basis = Basis.from_euler(Vector3(d.get("pitch", 0.0), d.get("yaw", 0.0), 0.0))
	pin_origin = d.get("origin", pin_origin)
	virtual_slot = d.get("virtual_slot", virtual_slot)
	virtual_size = d.get("virtual_size", virtual_size)


# "\\.\DISPLAY1 1920x1080 at (0, 0)" -> "\\.\DISPLAY1"
static func device_name(monitor_name: String) -> String:
	return monitor_name.get_slice(" ", 0)
