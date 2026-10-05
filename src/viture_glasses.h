#pragma once

#include "viture_sdk.h"
#include "viture_xr_interface.h"

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/node_path.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <mutex>

namespace godot {

// Connects to a pair of VITURE glasses through the VITURE Glasses SDK and
// exposes head pose plus display controls. Optionally drives a Node3D
// (typically a Camera3D) with the tracked pose every frame.
//
// The SDK's C callbacks carry no user pointer, so only one instance may be
// running at a time.
class VitureGlasses : public Node {
	GDCLASS(VitureGlasses, Node)

public:
	enum DeviceType {
		DEVICE_TYPE_NONE = -1,
		DEVICE_TYPE_GEN1 = XR_DEVICE_TYPE_VITURE_GEN1,
		DEVICE_TYPE_GEN2 = XR_DEVICE_TYPE_VITURE_GEN2,
		DEVICE_TYPE_CARINA = XR_DEVICE_TYPE_VITURE_CARINA,
	};

	VitureGlasses();
	~VitureGlasses();

	void _ready() override;
	void _process(double p_delta) override;
	void _exit_tree() override;

	bool start();
	void stop();
	bool is_running() const { return running; }
	String get_last_error() const { return last_error; }

	int get_device_type() const { return device_type; }
	int get_connected_product_id() const { return connected_product_id; }
	String get_market_name() const;
	String get_sdk_version() const;

	void update_pose();
	Transform3D get_pose() const { return pose; }
	bool is_tracking_stable() const { return tracking_stable; }
	void recenter();
	void reset_tracking();

	int set_display_3d(bool p_enabled);
	int get_display_mode() const;
	int set_display_mode(int p_mode);
	int get_brightness() const;
	int set_brightness(int p_level);
	static bool extend_desktop();
	static String get_glasses_display();

	void set_library_path(const String &p_path) { library_path = p_path; }
	String get_library_path() const { return library_path; }
	void set_product_id(int p_id) { product_id = p_id; }
	int get_product_id() const { return product_id; }
	void set_auto_start(bool p_enabled) { auto_start = p_enabled; }
	bool get_auto_start() const { return auto_start; }
	void set_enable_6dof(bool p_enabled) { enable_6dof = p_enabled; }
	bool get_enable_6dof() const { return enable_6dof; }
	void set_prediction_ms(double p_ms) { prediction_ms = p_ms; }
	double get_prediction_ms() const { return prediction_ms; }
	void set_target(const NodePath &p_target) { target = p_target; }
	NodePath get_target() const { return target; }
	void set_stereo(bool p_enabled);
	bool get_stereo() const { return stereo; }
	Ref<VitureXRInterface> get_xr_interface() const { return xr_interface; }

protected:
	static void _bind_methods();

private:
	static viture::Api api;
	static VitureGlasses *active_instance;

	static void on_state_changed(int p_state_id, int p_value);
	static void on_imu_pose(float *p_data, uint64_t p_timestamp);

	String library_path = "res://bin/viture/glasses.dll";
	int product_id = 0; // 0 = auto-detect.
	bool auto_start = true;
	bool enable_6dof = true; // Carina only; applied at start().
	double prediction_ms = 0.0;
	NodePath target;
	bool stereo = false;

	Ref<VitureXRInterface> xr_interface;
	bool stereo_active = false;

	viture::Handle handle = nullptr;
	bool running = false;
	int device_type = DEVICE_TYPE_NONE;
	int connected_product_id = 0;
	String last_error;

	bool tracking_stable = false;
	bool has_pose = false;
	Transform3D raw_pose;
	Transform3D reference; // Recenter origin; the reported pose is relative to it.
	Transform3D pose;

	// Gen1/Gen2 euler angles in degrees (roll, pitch, yaw), written from the SDK's IMU thread.
	std::mutex imu_mutex;
	Vector3 imu_euler;
	bool imu_fresh = false;

	String resolve_library_path() const;
	int detect_product_id();
	bool fail(const String &p_message);
	bool poll_raw_pose();
	void apply_stereo(bool p_enabled);
};

} // namespace godot

VARIANT_ENUM_CAST(VitureGlasses::DeviceType);
