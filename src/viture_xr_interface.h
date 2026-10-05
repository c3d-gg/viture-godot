#pragma once

#include <godot_cpp/classes/xr_interface_extension.hpp>
#include <godot_cpp/classes/xr_positional_tracker.hpp>
#include <godot_cpp/core/object_id.hpp>

namespace godot {

class VitureGlasses;

// Side-by-side stereo XR interface for VITURE glasses in 3D mode.
//
// Godot renders both eyes in one multiview pass; each eye is blitted to its
// half of the window, which must be fullscreen on the glasses' 3840-wide
// display. Head pose comes from the owning VitureGlasses node.
class VitureXRInterface : public XRInterfaceExtension {
	GDCLASS(VitureXRInterface, XRInterfaceExtension)

public:
	StringName _get_name() const override { return StringName("VITURE"); }
	uint32_t _get_capabilities() const override { return XRInterface::XR_STEREO; }
	bool _is_initialized() const override { return initialized; }
	bool _initialize() override;
	void _uninitialize() override;
	XRInterface::TrackingStatus _get_tracking_status() const override;

	Vector2 _get_render_target_size() override;
	uint32_t _get_view_count() override { return 2; }
	Transform3D _get_camera_transform() override;
	Transform3D _get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) override;
	PackedFloat64Array _get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) override;

	void _process() override;
	void _post_draw_viewport(const RID &p_render_target, const Rect2 &p_screen_rect) override;

	void set_glasses(VitureGlasses *p_glasses);

	void set_eye_separation(double p_metres) { eye_separation = p_metres; }
	double get_eye_separation() const { return eye_separation; }
	void set_fov(double p_degrees) { fov = p_degrees; }
	double get_fov() const { return fov; }
	void set_convergence_distance(double p_metres) { convergence_distance = p_metres; }
	double get_convergence_distance() const { return convergence_distance; }
	void set_vertical_offset(double p_degrees) { vertical_offset = p_degrees; }
	double get_vertical_offset() const { return vertical_offset; }

protected:
	static void _bind_methods();

private:
	bool initialized = false;
	bool tracking = false;
	ObjectID glasses_id;
	Ref<XRPositionalTracker> head;
	Transform3D head_transform;

	double eye_separation = 0.063; // Metres between the eyes.
	double fov = 52.0; // Diagonal, degrees (Luma Ultra spec).
	double convergence_distance = 3.0; // Metres to the virtual screen; 0 = parallel eyes.
	double vertical_offset = 0.0; // Degrees the right eye's image sits above the left's.
};

} // namespace godot
