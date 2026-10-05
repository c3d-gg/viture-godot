#include "viture_xr_interface.h"

#include "viture_glasses.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/xr_pose.hpp>
#include <godot_cpp/classes/xr_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/projection.hpp>

using namespace godot;

bool VitureXRInterface::_initialize() {
	if (initialized) {
		return true;
	}
	XRServer *xr_server = XRServer::get_singleton();
	if (head.is_null()) {
		head.instantiate();
		head->set_tracker_type(XRServer::TRACKER_HEAD);
		head->set_tracker_name("head");
		head->set_tracker_desc("VITURE glasses");
	}
	xr_server->add_tracker(head);
	if (xr_server->get_primary_interface().is_null()) {
		xr_server->set_primary_interface(this);
	}
	initialized = true;
	return true;
}

void VitureXRInterface::_uninitialize() {
	if (!initialized) {
		return;
	}
	XRServer *xr_server = XRServer::get_singleton();
	xr_server->remove_tracker(head);
	if (xr_server->get_primary_interface() == Ref<XRInterface>(this)) {
		xr_server->set_primary_interface(Ref<XRInterface>());
	}
	initialized = false;
}

XRInterface::TrackingStatus VitureXRInterface::_get_tracking_status() const {
	return tracking ? XRInterface::XR_NORMAL_TRACKING : XRInterface::XR_NOT_TRACKING;
}

void VitureXRInterface::set_glasses(VitureGlasses *p_glasses) {
	glasses_id = p_glasses ? ObjectID(p_glasses->get_instance_id()) : ObjectID();
}

Vector2 VitureXRInterface::_get_render_target_size() {
	// Each eye gets half of the (fullscreen, side-by-side) window.
	Vector2i size = DisplayServer::get_singleton()->window_get_size();
	return Vector2(size.x / 2, size.y);
}

void VitureXRInterface::_process() {
	// XRServer processes before the scene tree, so poll here rather than
	// waiting for VitureGlasses::_process to avoid a frame of latency.
	VitureGlasses *glasses = Object::cast_to<VitureGlasses>(ObjectDB::get_instance(glasses_id));
	tracking = glasses && glasses->is_running();
	if (tracking) {
		glasses->update_pose();
		head_transform = glasses->get_pose();
	}

	Transform3D scaled = head_transform;
	scaled.origin *= XRServer::get_singleton()->get_world_scale();
	head->set_pose("default", scaled, Vector3(), Vector3(),
			tracking ? XRPose::XR_TRACKING_CONFIDENCE_HIGH : XRPose::XR_TRACKING_CONFIDENCE_NONE);
}

Transform3D VitureXRInterface::_get_camera_transform() {
	XRServer *xr_server = XRServer::get_singleton();
	Transform3D scaled = head_transform;
	scaled.origin *= xr_server->get_world_scale();
	return xr_server->get_reference_frame() * scaled;
}

Transform3D VitureXRInterface::_get_transform_for_view(uint32_t p_view, const Transform3D &p_cam_transform) {
	Transform3D eye;
	eye.origin.x = (p_view == 0 ? -0.5 : 0.5) * eye_separation * XRServer::get_singleton()->get_world_scale();
	return p_cam_transform * _get_camera_transform() * eye;
}

PackedFloat64Array VitureXRInterface::_get_projection_for_view(uint32_t p_view, double p_aspect, double p_z_near, double p_z_far) {
	double tan_diagonal = Math::tan(Math::deg_to_rad(fov) * 0.5);
	double tan_v = tan_diagonal / Math::sqrt(p_aspect * p_aspect + 1.0);
	double tan_h = tan_v * p_aspect;

	// The optics place both eyes' screens on one virtual screen at the
	// convergence distance, so skew each frustum toward the centre line to
	// give zero disparity there.
	double shift = convergence_distance > 0.0 ? (eye_separation * 0.5) / convergence_distance : 0.0;
	// Compensates vertical misalignment between the eyes, split evenly.
	// Raising a frustum lowers its image: positive raises the left eye's
	// frustum and lowers the right's, so the right image ends up higher.
	double vshift = Math::tan(Math::deg_to_rad(vertical_offset)) * 0.5;
	if (p_view == 1) {
		shift = -shift;
		vshift = -vshift;
	}

	Projection projection;
	projection.set_frustum((-tan_h + shift) * p_z_near, (tan_h + shift) * p_z_near,
			(-tan_v + vshift) * p_z_near, (tan_v + vshift) * p_z_near, p_z_near, p_z_far);

	PackedFloat64Array result;
	result.resize(16);
	for (int i = 0; i < 16; i++) {
		result.set(i, projection.columns[i / 4][i % 4]);
	}
	return result;
}

void VitureXRInterface::_post_draw_viewport(const RID &p_render_target, const Rect2 &p_screen_rect) {
	Rect2i left(Vector2i(p_screen_rect.position), Vector2i(p_screen_rect.size.x / 2, p_screen_rect.size.y));
	Rect2i right = left;
	right.position.x += left.size.x;

	Rect2 full(0, 0, 1, 1);
	add_blit(p_render_target, full, left, true, 0, false, Vector2(), 0.0, 0.0, 1.0, 1.0);
	add_blit(p_render_target, full, right, true, 1, false, Vector2(), 0.0, 0.0, 1.0, 1.0);
}

void VitureXRInterface::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_eye_separation", "metres"), &VitureXRInterface::set_eye_separation);
	ClassDB::bind_method(D_METHOD("get_eye_separation"), &VitureXRInterface::get_eye_separation);
	ClassDB::bind_method(D_METHOD("set_fov", "degrees"), &VitureXRInterface::set_fov);
	ClassDB::bind_method(D_METHOD("get_fov"), &VitureXRInterface::get_fov);
	ClassDB::bind_method(D_METHOD("set_convergence_distance", "metres"), &VitureXRInterface::set_convergence_distance);
	ClassDB::bind_method(D_METHOD("get_convergence_distance"), &VitureXRInterface::get_convergence_distance);

	ClassDB::bind_method(D_METHOD("set_vertical_offset", "degrees"), &VitureXRInterface::set_vertical_offset);
	ClassDB::bind_method(D_METHOD("get_vertical_offset"), &VitureXRInterface::get_vertical_offset);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "eye_separation", PROPERTY_HINT_RANGE, "0.05,0.08,0.001,suffix:m"), "set_eye_separation", "get_eye_separation");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "fov", PROPERTY_HINT_RANGE, "20,90,0.1,degrees"), "set_fov", "get_fov");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "convergence_distance", PROPERTY_HINT_RANGE, "0,20,0.01,suffix:m"), "set_convergence_distance", "get_convergence_distance");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "vertical_offset", PROPERTY_HINT_RANGE, "-2,2,0.01,degrees"), "set_vertical_offset", "get_vertical_offset");
}
