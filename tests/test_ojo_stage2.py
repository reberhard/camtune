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
from scene_repair import fix_framing, framing_plan, lighting_plan, prepare_scene
from camera_control import execute, validate_setting
from lib.ojo_controls import IntentStore


def scene(**changes):
    now = time.time()
    result = dict(camera_id="camera:1:2", measured_at=now, face_count=1,
                  face_box=[.35, .3, .3, .4], face_luma_mean=120,
                  face_luma_p05=50, face_luma_p95=200, highlight_clip_pct=0,
                  shadow_clip_pct=0, rgb_balance=[1, 1, 1], background_luma_mean=85,
                  profile_status="compatible", actuator_status="confirmed", actuators_at=now)
    result.update(changes)
    return result


@pytest.mark.parametrize("key", ["camera_id", "measured_at", "face_count", "face_box", "face_luma_mean", "face_luma_p05", "face_luma_p95", "highlight_clip_pct", "shadow_clip_pct", "rgb_balance", "background_luma_mean", "profile_status", "actuator_status", "actuators_at"])
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
    assert call_activity({"app":"Zoom", "source":"accessibility", "leave_call_control":True, "observed_at":time.time()})["state"] == "active"
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
