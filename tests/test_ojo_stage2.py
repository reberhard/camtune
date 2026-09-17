import copy
import importlib.util
import json
from pathlib import Path
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CamTuneApp/Support"))
from scene_contract import assess, bucket, call_activity, ProfileStore, room_readback
from scene_repair import fix_framing, framing_plan, lighting_plan, prepare_scene, cancel_operation, run_physical_framing
from camera_control import execute, validate_setting
from lib.ojo_controls import IntentStore


def scene(**changes):
    now = time.time()
    result = dict(camera_id="camera:1:2", camera_validated=True, measured_at=now, face_count=1,
                  face_box=[.35, .3, .3, .4], face_luma_mean=120,
                  face_luma_p05=50, face_luma_p95=200, highlight_clip_pct=0,
                  shadow_clip_pct=0, rgb_balance=[1, 1, 1], background_luma_mean=85,
                  profile_status="compatible", actuator_status="confirmed", actuators_at=now)
    result.update(changes)
    return result


@pytest.mark.parametrize("key", ["camera_id", "camera_validated", "measured_at", "face_count", "face_box", "face_luma_mean", "face_luma_p05", "face_luma_p95", "highlight_clip_pct", "shadow_clip_pct", "rgb_balance", "background_luma_mean", "profile_status", "actuator_status", "actuators_at"])
def test_each_required_measurement_cannot_be_omitted(key):
    sample = scene()
    del sample[key]
    assert assess(sample)["state"] != "green"


def test_clean_and_stale_and_no_face_and_color():
    assert assess(scene())["state"] == "green"
    assert assess(scene(measured_at=time.time()-3))["state"] == "unknown"
    assert assess(scene(measured_at=time.time()+30))["state"] == "unknown"
    assert assess(scene(face_count=0, face_box=None))["state"] == "red"
    assert assess(scene(face_count=0, face_box=None, trigger="auto"))["state"] == "idle"
    assert assess(scene(face_count=2))["state"] == "red"
    assert assess(scene(rgb_balance=[1.5, .7, .8]))["state"] == "red"
    assert assess(scene(face_luma_mean=float("nan")))["state"] != "green"


def test_cli_and_shared_classifier_are_identical():
    spec = importlib.util.spec_from_file_location("stage2_ojo", ROOT / "ojo.py")
    ojo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ojo)
    sample = scene()
    left, right = ojo.classify_scene(sample), assess(sample)
    left.pop("assessed_at"); right.pop("assessed_at")
    assert left == right


def test_profile_atomic_save_preserves_legacy_and_refuses_bad_scene(tmp_path, monkeypatch):
    legacy = tmp_path / "profile.json"
    legacy.write_text('{"brightness":42}')
    store = ProfileStore(tmp_path)
    sample = scene(profile_status="missing")
    assert store.select(sample)["status"] == "missing"
    store.save(sample, {"brightness": 42})
    assert legacy.read_text() == '{"brightness":42}'
    assert store.select(sample)["status"] == "compatible"
    assert store.select(scene(camera_id="other"))["status"] == "missing"
    assert store.select(scene(background_luma_mean=200))["status"] == "incompatible"
    old = store.path.read_bytes()
    with pytest.raises(ValueError):
        store.save(scene(face_count=0), {"brightness": 80})
    monkeypatch.setattr("scene_contract.os.replace", lambda *_: (_ for _ in ()).throw(OSError("disk")))
    with pytest.raises(OSError):
        store.save(sample, {"brightness": 80})
    assert store.path.read_bytes() == old
    assert not list(tmp_path.glob(".profiles-*"))


@pytest.mark.parametrize("hour,expected", [(4,"evening"),(5,"morning"),(10,"morning"),(11,"midday"),(14,"midday"),(15,"afternoon"),(18,"afternoon"),(19,"evening")])
def test_one_explicit_mexico_city_bucket(hour, expected):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    now = datetime(2026, 9, 12, hour, tzinfo=ZoneInfo("America/Mexico_City")).timestamp()
    assert bucket(now) == expected


def test_presence_is_not_call_activity():
    assert call_activity({"app": "Zoom", "observed_at": time.time()})["state"] == "unknown"
    assert call_activity({"app":"Zoom", "source":"accessibility", "leave_call_control":True, "media_control":True, "observed_at":time.time()})["state"] == "active"
    assert call_activity({"app":"Zoom", "source":"accessibility", "leave_call_control":True, "observed_at":0})["state"] == "unknown"


CALIBRATION = dict(camera_id="camera:1:2", call_preview_parity=True, face_x_per_pan=.00003,
                   face_y_per_tilt=.00003, face_height_per_zoom=.005,
                   ranges={"absolute_zoom": [100,400,1]},
                   pan_tilt_by_zoom={"150": [[-72000,72000,1],[-72000,72000,1]]})


class Camera:
    def __init__(self, frames, bad_restore=False, cancel=False):
        self.settings = {"absolute_pan_tilt":[0,0], "absolute_zoom":150}
        self.frames = iter(frames)
        self.writes = []
        self.bad_restore = bad_restore
        self.cancel = cancel
        self.now = time.time()

    def read(self, deadline):
        return copy.deepcopy(self.settings)

    def frame(self, after, deadline):
        self.now += .1
        result = next(self.frames)
        result.update(measured_at=self.now, actuators_at=self.now)
        return result

    def write(self, changes, deadline):
        self.writes.append(copy.deepcopy(changes))
        if self.bad_restore and len(self.writes) > 1:
            raise OSError("restore failed")
        self.settings.update(changes)
        return copy.deepcopy(self.settings)


def test_framing_numeric_improvement_and_all_settings_saved():
    camera = Camera([scene(face_box=[.05,.3,.3,.4]), scene()])
    result = fix_framing(camera, CALIBRATION, clock=lambda: camera.now)
    assert result["status"] == "improved"
    assert result["baseline"] == {"absolute_pan_tilt":[0,0], "absolute_zoom":150}


def test_late_good_frame_cannot_escape_correction_deadline():
    class SlowCamera(Camera):
        def frame(self, after, deadline):
            result = super().frame(after,deadline)
            if self.writes:
                self.now += 16
                result["measured_at"] = self.now
            return result
    camera = SlowCamera([scene(face_box=[.05,.3,.3,.4]),scene()])
    result = fix_framing(camera,CALIBRATION,clock=lambda:camera.now)
    assert result["status"] == "worse_or_unverified_restored"
    assert "budget" in result["reason"]


@pytest.mark.parametrize("after", [scene(face_box=[.05,.3,.3,.4]), scene(face_count=0,face_box=None), scene(camera_id="wrong"), scene(highlight_clip_pct=10)])
def test_no_gain_lost_face_wrong_camera_and_clipping_restore(after):
    camera = Camera([scene(face_box=[.05,.3,.3,.4]), after])
    assert fix_framing(camera, CALIBRATION, clock=lambda:camera.now)["status"] == "worse_or_unverified_restored"
    assert camera.writes[-1] == {"absolute_pan_tilt":[0,0], "absolute_zoom":150}


def test_rollback_failure_and_manual_supersession_are_explicit():
    start = scene(face_box=[.05,.3,.3,.4])
    camera = Camera([start,start], bad_restore=True)
    assert fix_framing(camera,CALIBRATION,clock=lambda:camera.now)["status"] == "rollback_failed"
    camera = Camera([start,scene()])
    result = fix_framing(camera,CALIBRATION,current=lambda:not camera.writes,clock=lambda:camera.now)
    assert result["status"] == "cancelled"
    assert len(camera.writes) == 1


def test_unvalidated_direction_never_writes():
    camera = Camera([scene(face_box=[.05,.3,.3,.4])])
    assert fix_framing(camera,dict(CALIBRATION,call_preview_parity=False),clock=lambda:camera.now)["status"] == "could_not_verify"
    assert not camera.writes


def test_lighting_requires_measured_effects_and_preserves_off():
    sample = scene(face_luma_mean=60)
    response = dict(device="overhead-left",verified=True,camera_id=sample["camera_id"],ambient=85,face_luma_delta=50)
    assert lighting_plan(sample,[],set())["changes"] == []
    assert lighting_plan(sample,[response],{"overhead-left"})["changes"] == []
    assert lighting_plan(sample,[response],set())["status"] == "planned"
    curtain = dict(response,device="curtain-left")
    assert lighting_plan(sample,[curtain],set())["changes"] == []


def test_camera_ack_without_readback_is_failure(tmp_path):
    commands = []
    def backend(args, deadline):
        commands.append(args)
        return json.dumps([{"vendor":1,"product":2}]) if args[0] == "devices" else json.dumps({"brightness":{"min":0,"max":100,"res":1}}) if args[0] == "ranges" else json.dumps({"brightness":20}) if args[0] == "export" else ""
    result = execute(1,2,{"brightness":30},store=IntentStore(tmp_path),backend=backend)
    assert result["status"] == "failed"
    assert any(c[0]=="set" for c in commands)


@pytest.mark.parametrize("control,value", [("brightness",101),("brightness",3),("gain",20),("unknown",20)])
def test_camera_ranges_resolution_auto_ownership(control,value):
    with pytest.raises(ValueError):
        validate_setting(control,value,{"brightness":{"min":0,"max":100,"res":2},"gain":{"min":0,"max":100}}, {"brightness":20,"gain":10,"auto_exposure_mode":8})


@pytest.mark.parametrize("box,axis,sign", [([.05,.3,.3,.4],0,1),([.65,.3,.3,.4],0,-1),([.35,.05,.3,.4],1,1),([.35,.55,.3,.4],1,-1)])
def test_each_numeric_framing_direction(box,axis,sign):
    changes = framing_plan(scene(face_box=box),{"absolute_pan_tilt":[0,0],"absolute_zoom":150},CALIBRATION)
    assert changes["absolute_pan_tilt"][axis] * sign > 0


@pytest.mark.parametrize("height,sign",[(.15,1),(.65,-1)])
def test_numeric_face_size_drives_zoom(height,sign):
    changes = framing_plan(scene(face_box=[.35,.5-height/2,.3,height]),{"absolute_pan_tilt":[0,0],"absolute_zoom":150},CALIBRATION)
    assert (changes["absolute_zoom"]-150)*sign > 0


def test_unknown_zoom_limits_never_guess():
    with pytest.raises(ValueError,match="limits"):
        framing_plan(scene(face_box=[.05,.3,.3,.4]),{"absolute_pan_tilt":[0,0],"absolute_zoom":200},CALIBRATION)


def test_corrupt_profile_and_legacy_are_not_accepted(tmp_path):
    store = ProfileStore(tmp_path)
    (tmp_path/"profile.json").write_text('{"brightness":42}')
    assert store.migrate_legacy()[0]["accepted"] is False
    assert store.select(scene())["status"] == "missing"
    store.path.write_text("broken")
    with pytest.raises(ValueError):
        store.select(scene())


def test_room_readback_cannot_accept_reachability_text_or_partial_receipts():
    from types import SimpleNamespace
    assert room_readback(lambda _:SimpleNamespace(returncode=0,stdout="Reachable: 4/4"))["actuator_status"] == "unknown"
    assert room_readback(lambda _:SimpleNamespace(returncode=0,stdout='{"schema_version":1,"devices":[]}'))["actuator_status"] == "unknown"


class Room:
    def __init__(self, after, fail=False):
        self.now = time.time()
        self.after = after
        self.frames = 0
        self.applied = []
        self.restored = False
        self.fail = fail
    def frame(self, after, deadline):
        self.now += .1
        result = scene(face_luma_mean=60) if not self.frames else self.after
        self.frames += 1
        return dict(result,measured_at=self.now,actuators_at=self.now)
    def snapshot(self, devices, deadline):
        return {d:{"on":True,"brightness":20} for d in devices}
    def apply(self, change, deadline):
        self.applied.append(change)
        return {"status":"failed" if self.fail else "confirmed"}
    def restore(self, baseline, devices, deadline):
        self.restored = True
        return {"status":"confirmed"}


ROOM_CALIBRATION = dict(camera_id="camera:1:2",room_effects_verified=True,
                        responses=[dict(device="overhead-left",verified=True,camera_id="camera:1:2",ambient=85,face_luma_delta=60)])


def test_preparation_reports_only_measured_improvement():
    room = Room(scene())
    assert prepare_scene(room,ROOM_CALIBRATION,set(),clock=lambda:room.now)["status"] == "improved"
    assert not room.restored


@pytest.mark.parametrize("after,fail",[(scene(face_luma_mean=60),False),(scene(highlight_clip_pct=20),False),(scene(),True)])
def test_preparation_no_gain_worsening_and_device_failure_restore(after,fail):
    room = Room(after,fail)
    assert prepare_scene(room,ROOM_CALIBRATION,set(),clock=lambda:room.now)["status"] == "worse_or_unverified_restored"
    assert room.restored


def test_preparation_preserves_new_manual_intent():
    room = Room(scene())
    result = prepare_scene(room,ROOM_CALIBRATION,set(),current=lambda:not room.applied,clock=lambda:room.now)
    assert result["status"] == "cancelled"
    assert not room.restored


def test_camera_old_intent_never_reaches_backend(tmp_path):
    store = IntentStore(tmp_path)
    store.register(["camera:1:2"],"new",20)
    calls=[]
    result=execute(1,2,{"brightness":40},operation="old",issued=10,store=store,backend=lambda *args:calls.append(args))
    assert result["status"] == "superseded"
    assert not calls


def test_cancel_only_invalidates_its_own_devices(tmp_path):
    store=IntentStore(tmp_path)
    store.register(["camera:1:2","overhead-left"],"scene",1)
    store.register(["overhead-left"],"manual-off",2)
    assert cancel_operation(store,"scene","camera:1:2") == 1
    assert not store.current("camera:1:2","scene")
    assert store.current("overhead-left","manual-off")


def test_real_adapter_gate_and_preparation_dispatch_without_hardware(tmp_path):
    payload=dict(vendor=1,product=2,camera_name="Test",operation_id="scene",issued=1,allow_room_changes=True)
    missing=tmp_path/"validation.json"
    assert run_physical_framing(payload,"prepare",validation_path=missing)["status"] == "could_not_verify"
    calibration=dict(CALIBRATION,**{k:v for k,v in ROOM_CALIBRATION.items() if k!="camera_id"},
                     stage1_accepted=True,validation_receipt="test-fixture-only")
    missing.write_text(json.dumps(calibration))
    room=Room(scene())
    # Runtime clock used by dispatcher must see fresh fixture frames.
    def frame(after,deadline):
        result=scene(face_luma_mean=60) if not room.frames else scene()
        room.frames+=1
        result["measured_at"]=time.time()
        return result
    room.frame=frame
    result=run_physical_framing(payload,"prepare",validation_path=missing,intent_store=IntentStore(tmp_path/"intents"),io_factory=lambda:room)
    assert result["status"] == "improved", result
    assert len(room.applied)==1


def test_profile_participates_in_preparation_rollback():
    class ProfileRoom(Room):
        def __init__(self):
            super().__init__(scene(face_luma_mean=60))
            self.settings={"brightness":20}
        def select_profile(self,scene):
            return {"status":"compatible","profile":{"settings":{"brightness":40}}}
        def read(self,deadline):
            return dict(self.settings)
        def write(self,changes,deadline):
            self.settings.update(changes)
            return dict(self.settings)
        def restore(self,baseline,devices,deadline):
            self.settings=baseline["camera:1:2"]
            self.restored=True
            return {"status":"confirmed"}
    room=ProfileRoom()
    assert prepare_scene(room,ROOM_CALIBRATION,set(),clock=lambda:room.now)["status"] == "worse_or_unverified_restored"
    assert room.settings == {"brightness":20}


def test_call_rollup_retry_is_idempotent_and_corruption_is_visible(tmp_path):
    spec=importlib.util.spec_from_file_location("call_ojo",ROOT/"ojo.py")
    ojo=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ojo)
    path=str(tmp_path/"calls.jsonl")
    row={"call_session_id":"fixture","boundary_source":"verified-call-observation"}
    assert ojo.append_call_once(row,path)
    assert not ojo.append_call_once(row,path)
    assert len(Path(path).read_text().splitlines()) == 1
    Path(path).write_text("corrupt\n")
    with pytest.raises(ValueError,match="Corrupt"):
        ojo.append_call_once(row,path)


def test_cached_green_is_reassessed_with_original_capture_time(monkeypatch):
    from types import SimpleNamespace
    spec=importlib.util.spec_from_file_location("cached_ojo",ROOT/"ojo.py")
    ojo=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ojo)
    stale=scene(measured_at=time.time()-10)
    monkeypatch.setattr(ojo,"load_recent_check_cache",lambda _: {"state":"green","scene":stale})
    result=ojo.cmd_check(SimpleNamespace(max_age_seconds=45,json=True),"Test")
    assert result["state"] == "unknown"
    assert result["scene"]["measured_at"] == stale["measured_at"]


def test_invalid_camera_payload_cannot_reach_hardware(tmp_path):
    for changes in ({"brightness":True},{"unknown":None},{"absolute_pan_tilt":[]}):
        with pytest.raises(ValueError,match="Typed"):
            execute(1,2,changes,store=IntentStore(tmp_path),backend=lambda *_:pytest.fail("No hardware calls"))


def test_calibration_cannot_extend_device_limits_and_zoom_precedes_pan():
    from camera_control import calibrated_ranges, write_order
    raw = {"absolute_pan_tilt":{"min":[-100,-100],"max":[100,100]}}
    valid = {"pan_tilt_by_zoom":{"120":[[-50,50,10],[-40,40,10]]}}
    assert calibrated_ranges(raw,valid,120)["absolute_pan_tilt"]["min"] == [-50,-40]
    assert raw["absolute_pan_tilt"]["min"] == [-100,-100]
    invalid = {"pan_tilt_by_zoom":{"120":[[-150,50,10],[-40,40,10]]}}
    with pytest.raises(ValueError,match="bounds"):
        calibrated_ranges(raw,invalid,120)
    assert sorted(["absolute_pan_tilt","absolute_zoom","auto_focus"],key=write_order) == ["auto_focus","absolute_zoom","absolute_pan_tilt"]


# 2026-09-14 regression: camera pointed at the ceiling, Vision box hanging below the frame.
CEILING_BOX = [.406, .9564, .1763, .3134]


def test_clipped_face_rectangle_is_a_framing_warning_not_unknown():
    from scene_contract import clamp_box
    checks = assess(scene(face_box=CEILING_BOX))["checks"]
    assert checks["framing"]["state"] == "yellow"
    assert "cut off at bottom" in checks["framing"]["reason"] and "face too low" in checks["framing"]["reason"]
    assert "too small" not in checks["framing"]["reason"]
    assert clamp_box([.4, -.5, .2, .4]) == (None, False)
    assert clamp_box([.35, .3, .3, .4]) == ([.35, .3, .3, .4], False)


def test_camera_check_names_the_missing_item():
    checks = assess(scene(camera_validated=False))["checks"]
    assert checks["camera"]["reason"] == "camera calibration receipt missing or mismatched"
    checks = assess(scene(measured_at=0))["checks"]
    assert checks["camera"]["reason"] == "camera frame stale"


def test_framing_plan_uses_measured_step_default_zoom_row_and_clipped_box():
    from scene_repair import framing_plan
    calibration = dict(CALIBRATION, pan_tilt_by_zoom={"default": [[-72000, 72000, 3600], [-72000, 72000, 3600]]},
                       max_pan_tilt_step=36000, response_reference_zoom=150,
                       face_y_per_tilt=5e-6, face_x_per_pan=-5e-6)
    settings = {"absolute_pan_tilt": [0, 0], "absolute_zoom": 150}
    changes = framing_plan(scene(face_box=CEILING_BOX), settings, calibration)
    assert changes["absolute_pan_tilt"] == [0, -36000]   # low face -> negative tilt, bounded by the measured step
    assert "absolute_zoom" not in changes                 # size unknown while the face is clipped
    with pytest.raises(ValueError, match="unverified"):
        framing_plan(scene(face_box=CEILING_BOX), dict(settings, absolute_zoom=100), calibration)
    # Without a measured step the old one-degree bound still applies.
    conservative = framing_plan(scene(face_box=CEILING_BOX), settings, dict(calibration, max_pan_tilt_step=3600))
    assert conservative["absolute_pan_tilt"] == [0, -3600]


def test_camera_validated_needs_measured_calibration_not_stage1(tmp_path):
    from scene_contract import camera_validated
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps(dict(CALIBRATION, validation_receipt="fixture")))
    assert camera_validated("camera:1:2", path)
    path.write_text(json.dumps(dict(CALIBRATION, validation_receipt="fixture", face_y_per_tilt=0)))
    assert not camera_validated("camera:1:2", path)
    path.write_text(json.dumps(dict(CALIBRATION, validation_receipt="fixture", stage1_accepted=True, pan_tilt_by_zoom={})))
    assert not camera_validated("camera:1:2", path)


def test_frame_adapter_needs_calibration_only_and_prepare_needs_stage1(tmp_path):
    payload = dict(vendor=1, product=2, camera_name="Test", operation_id="op", issued=1, allow_room_changes=False)
    receipt = tmp_path / "receipt.json"
    receipt.write_text(json.dumps(dict(CALIBRATION, validation_receipt="fixture")))
    assert run_physical_framing(payload, "prepare", validation_path=receipt)["reason"].startswith("Room preparation requires Stage 1")


def test_python_face_crop_is_clipped_to_the_image():
    import importlib.util
    spec = importlib.util.spec_from_file_location("ojo_clip", Path(__file__).resolve().parents[1] / "ojo.py")
    ojo = importlib.util.module_from_spec(spec); spec.loader.exec_module(ojo)
    left, top, right, bottom = ojo._bbox_to_pixels([.406, -.2698, .1763, .3134], 1920, 1080)
    assert 0 <= left < right <= 1920 and 0 <= top < bottom <= 1080
    assert ojo._bbox_to_pixels([.4, .3, .2, .2], 1000, 1000) == (400, 500, 600, 700)


def test_engine_face_detector_failure_is_an_error_not_no_face(monkeypatch, tmp_path):
    import scene_repair
    monkeypatch.setattr(scene_repair, "DETECTOR_INTERPRETERS", ("/nonexistent/python3",))
    with pytest.raises(ValueError, match="Face detector unavailable"):
        scene_repair.detect_faces_strict(tmp_path / "ojo.py", tmp_path / "frame.jpg", time.time() + 5)


def test_confirmed_lights_survive_normal_pipeline_latency():
    # Found live 2026-09-15/16: actuators_at is stamped before camera capture
    # and Vision detection (ojo.py run_pre_call_check), so `now` at assessment
    # time is the end of the whole check, not readback time. A 10s window let
    # a fully current, confirmed readback read "unknown" purely because a
    # normal check (elapsed_ms often 10-13s) took a bit longer than usual.
    now = time.time()
    result = assess(scene(actuator_status="confirmed", actuators_at=now - 12, measured_at=now), now=now)
    assert result["checks"]["lights"] == {"state": "green", "reason": "required actuator readback confirmed"}
    # Genuine staleness (well past any realistic pipeline latency) still blocks.
    stale = assess(scene(actuator_status="confirmed", actuators_at=now - 120, measured_at=now), now=now)
    assert stale["checks"]["lights"]["state"] == "unknown"


def test_failed_light_readback_is_unknown_and_names_the_bulb():
    result = assess(scene(actuator_status="failed", actuator_failed=["overhead-right"]))
    assert result["checks"]["lights"] == {"state": "unknown", "reason": "light readback failed: overhead-right (Refresh to retry)"}
    assert result["state"] == "unknown"
    assert assess(scene(actuator_status="failed"))["checks"]["lights"]["reason"] == "light readback failed (Refresh to retry)"
    dark = assess(scene(actuator_status="failed", actuator_failed=["overhead-right"], face_luma_mean=55))
    assert dark["checks"]["lights"] == {"state": "red", "reason": "light readback failed: overhead-right; face needs light (Refresh to retry)"}
