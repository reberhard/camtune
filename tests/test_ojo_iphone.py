"""iPhone (Continuity Camera) as Ojo's primary camera, 2026-11-02 (specs/ojo.md Camera Policy)."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "CamTuneApp/Support"))
from scene_contract import assess

spec = importlib.util.spec_from_file_location("ojo_main", ROOT / "ojo.py")
ojo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ojo)

IPHONE = "Ryan’s iPhone 16 (2025) Camera"


def iphone_scene(**changes):
    now = time.time()
    result = dict(camera_id="iphone:continuity", camera_kind="iphone", camera_validated=False,
                  measured_at=now, face_count=1, face_box=[.35, .3, .3, .4], face_luma_mean=120,
                  face_luma_p05=50, face_luma_p95=200, highlight_clip_pct=0, shadow_clip_pct=0,
                  rgb_balance=[1, 1, 1], background_luma_mean=85, profile_status="missing",
                  actuator_status="confirmed", actuators_at=now)
    result.update(changes)
    return result


def test_iphone_scene_can_be_green_without_calibration_receipt_or_profile():
    result = assess(iphone_scene())
    assert result["state"] == "green"
    assert result["checks"]["camera"]["reason"] == "fresh iPhone camera frame"
    assert result["checks"]["profile"]["state"] == "not_applicable"
    assert "iPhone sets its own exposure and color" not in result["quality"]["issues"]


def test_brio_still_requires_receipt_and_profile():
    brio = iphone_scene(camera_kind=None, camera_id="camera:1:2")
    result = assess(brio)
    assert result["checks"]["camera"]["state"] == "unknown"
    assert result["checks"]["profile"]["state"] == "yellow"


def test_iphone_framing_is_yellow_with_phone_hint_never_red():
    result = assess(iphone_scene(face_box=[.05, .3, .2, .3]))
    assert result["checks"]["framing"]["state"] == "yellow"
    assert result["checks"]["framing"]["reason"].endswith("(adjust the phone)")
    assert result["state"] == "yellow"


def test_iphone_stale_frame_and_no_face_still_fail():
    assert assess(iphone_scene(measured_at=time.time() - 10))["state"] == "unknown"
    assert assess(iphone_scene(face_count=0, face_box=None))["state"] == "red"


def test_detect_camera_prefers_iphone(monkeypatch):
    monkeypatch.setattr(ojo, "detect_imagesnap_cameras", lambda: [IPHONE, "Brio 505"])
    monkeypatch.setattr(ojo, "uvcc", lambda *a: '[{"name":"Brio 505","vendor":1133,"product":2329}]')
    assert ojo.detect_camera() == (IPHONE, None, None)


def test_detect_camera_falls_back_to_brio_and_honours_explicit_choice(monkeypatch):
    monkeypatch.setattr(ojo, "uvcc", lambda *a: '[{"name":"Brio 505","vendor":1133,"product":2329}]')
    monkeypatch.setattr(ojo, "detect_imagesnap_cameras", lambda: ["Brio 505"])
    assert ojo.detect_camera() == ("Brio 505", 1133, 2329)
    monkeypatch.setattr(ojo, "detect_imagesnap_cameras", lambda: [IPHONE, "Brio 505"])
    assert ojo.detect_camera(preferred="Brio") == ("Brio 505", 1133, 2329)


def test_iphone_capture_gets_longer_timeout(monkeypatch, tmp_path):
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["timeout"] = kwargs["timeout"]
        Path(cmd[-1]).write_bytes(b"png")
        return subprocess.CompletedProcess(cmd, 0, "", "")

    monkeypatch.setattr(ojo.subprocess, "run", fake_run)
    assert ojo.capture_frame(IPHONE, str(tmp_path / "f.png"), source="camera", warmup_secs=3)
    assert seen["timeout"] == 20
    assert ojo.capture_frame("Brio 505", str(tmp_path / "g.png"), source="camera", warmup_secs=1)
    assert seen["timeout"] == 8
