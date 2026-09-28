import copy
import time
from test_ojo_stage2 import scene
from room_calibration import measure_light
from scene_repair import lighting_plan


class Trial:
    def __init__(self, frames=None, restore_fail=False):
        self.now = time.time()
        self.prior = dict(on=True, brightness=30, hue=345, saturation=3, temperature=0)
        self.frames = iter(frames or [scene(face_luma_mean=145), scene(face_luma_mean=125), scene(face_luma_mean=144)])
        self.writes = []
        self.restore_fail = restore_fail
        self.restores = 0
    def snapshot(self, devices, deadline):
        return {devices[0]: copy.deepcopy(self.prior)}
    def read(self, deadline):
        return dict(brightness=42, absolute_zoom=173, auto_exposure_mode=8)
    def frame(self, after, deadline):
        self.now += .1
        return dict(next(self.frames), measured_at=self.now, actuators_at=self.now)
    def apply(self, change, deadline):
        self.writes.append(change)
        return {"status": "confirmed"}
    def restore(self, baseline, devices, deadline):
        self.restores += 1
        assert baseline[devices[0]] == self.prior
        return {"status": "failed" if self.restore_fail else "confirmed"}


def test_measured_trial_has_real_request_baseline_and_restoration():
    io = Trial()
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)
    assert result["status"] == "measured"
    assert result["restored"] and io.restores == 1
    row = result["response"]
    assert row["request"] == dict(action="adjust", hue=345, saturation=3, brightness=10)
    assert row["face_luma_delta"] == -19.5
    assert row["baseline_device"] == io.prior


def test_lost_face_restores_without_publishing_response():
    io = Trial([scene(), scene(face_count=0)])
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)
    assert result["status"] == "rejected" and result["restored"]
    assert "response" not in result


def test_movement_drift_and_no_effect_are_not_calibration():
    for after in (scene(face_luma_mean=170), scene(face_box=[.6,.3,.3,.4])):
        io = Trial([scene(), scene(face_luma_mean=100), after])
        result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)
        assert result["status"] == "rejected" and result["restored"]
    io = Trial([scene(), scene(), scene()])
    assert measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)["status"] == "rejected"


def test_failed_restore_never_marks_verified():
    io = Trial(restore_fail=True)
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)
    assert result["status"] == "restore_unconfirmed" and not result["restored"]
    assert "response" not in result


def test_off_lamp_never_turns_on_for_calibration():
    io = Trial()
    io.prior["on"] = False
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda: io.now)
    assert result["status"] == "rejected" and not io.writes


def test_small_background_face_cannot_authorize_a_trial():
    io = Trial([scene(face_box=[.1,.5,.05,.085])])
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10, clock=lambda:io.now)
    assert result["status"] == "rejected" and not io.writes
    assert "Sit normally" in result["reason"]
    assert "before" in result["measurements"]


def test_manual_supersession_does_not_restore_over_user():
    io = Trial()
    result = measure_light(io, {"camera_id": "camera:1:2"}, "cafe", 10,
                           current=lambda: not io.writes, clock=lambda: io.now)
    assert result["status"] == "restore_unconfirmed" and not io.restores


def test_planner_repairs_exposure_warning_within_old_numeric_band():
    sample = scene(face_luma_mean=145)
    response = dict(device="cafe", verified=True, camera_id=sample["camera_id"], ambient=85,
                    face_luma_delta=-20, baseline_device={"brightness":30}, baseline_camera={"brightness":42})
    sample.update(room_states={"cafe":{"brightness":30}}, camera_settings={"brightness":42})
    assert lighting_plan(sample,[response],set())["status"] == "planned"
    sample["room_states"]["cafe"]["brightness"] = 20
    assert lighting_plan(sample,[response],set())["changes"] == []
    sample["room_states"]["cafe"]["brightness"] = 30
    sample["camera_settings"]["brightness"] = 20
    assert lighting_plan(sample,[response],set())["changes"] == []
