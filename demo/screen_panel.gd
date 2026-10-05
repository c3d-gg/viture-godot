extends Node3D

## One virtual screen: a live capture of a Windows monitor on a quad, pinned
## in the room on an arc around `pin_origin` (yaw, then pitch, then distance).

const SHADER := preload("res://desktop_screen.gdshader")
const PITCH_LIMIT := deg_to_rad(60.0)

## Windows device name of the captured monitor, e.g. "\\.\DISPLAY1". Tracked by
## name because indices and handles change when the display layout does.
var monitor_device := ""
## SudoVDA slot of the virtual monitor this panel owns, or -1 for a real monitor.
var virtual_slot := -1
var virtual_size := Vector2i(1920, 1080)
var distance := 2.0
var width := 1.6
var pin_yaw := 0.0
var pin_pitch := 0.0
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
	_label.text = monitor_device if capture.is_capturing() else "%s: not capturing (%s)" % [monitor_device, capture.get_last_error()]


## (Re)starts capturing `monitor_device`. Returns false if it isn't attached.
func start_capture() -> bool:
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


func layout() -> void:
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
	pin_pitch = clampf(pin_pitch, -PITCH_LIMIT, PITCH_LIMIT)
	# Yaw then pitch: the panel swings along an arc around the viewer, facing them.
	transform = Transform3D(Basis.from_euler(Vector3(pin_pitch, pin_yaw, 0.0)), pin_origin)


## Points the panel along `forward` (a gaze direction) from `origin`, kept level.
func aim(forward: Vector3, origin: Vector3) -> void:
	forward = forward.normalized()
	if absf(forward.y) > 0.95:
		return # Looking straight up or down: no sensible "level".
	pin_yaw = atan2(-forward.x, -forward.z)
	pin_pitch = asin(forward.y)
	pin_origin = origin
	apply_pin()


## Angle in radians between `forward` from `origin` and this panel's centre.
func angle_from(origin: Vector3, forward: Vector3) -> float:
	var centre := _quad.global_position
	return forward.normalized().angle_to(centre - origin)


func to_dict() -> Dictionary:
	return {
		"monitor": monitor_device, "distance": distance, "width": width,
		"yaw": pin_yaw, "pitch": pin_pitch, "origin": pin_origin,
		"virtual_slot": virtual_slot, "virtual_size": virtual_size,
	}


func from_dict(d: Dictionary) -> void:
	monitor_device = d.get("monitor", monitor_device)
	distance = d.get("distance", distance)
	width = d.get("width", width)
	pin_yaw = d.get("yaw", pin_yaw)
	pin_pitch = d.get("pitch", pin_pitch)
	pin_origin = d.get("origin", pin_origin)
	virtual_slot = d.get("virtual_slot", virtual_slot)
	virtual_size = d.get("virtual_size", virtual_size)


# "\\.\DISPLAY1 1920x1080 at (0, 0)" -> "\\.\DISPLAY1"
static func device_name(monitor_name: String) -> String:
	return monitor_name.get_slice(" ", 0)
