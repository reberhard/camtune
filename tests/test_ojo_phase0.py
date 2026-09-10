import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ojo", ROOT / "ojo.py")
ojo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ojo)


def base_scene(**overrides):
    scene = {
        "face_detected": True,
        "face_count": 1,
        "face_bbox": [0.25, 0.25, 0.5, 0.5],
        "face_luma_mean": 125.0,
        "face_luma_p05": 55.0,
        "face_luma_p95": 210.0,
        "face_tonal_range": 155.0,
        "background_luma_mean": 95.0,
        "background_separation": 30.0,
        "highlight_clip_pct": 0.0,
        "shadow_clip_pct": 0.0,
        "rgb_balance": [1.0, 1.0, 1.0],
        "framing_state": "green",
        "framing_reason": "framing looks balanced",
        "profile_age_minutes": 20,
        "profile_exists": True,
        "lights_reachable": True,
        "lights_degraded": False,
        "light_status": {},
    }
    scene.update(overrides)
    return scene


def test_classifier_green_for_clean_scene():
    result = ojo.classify_scene(base_scene())

    assert result["state"] == "green"
    assert result["checks"]["face"]["state"] == "green"


def test_classifier_red_for_no_face():
    result = ojo.classify_scene(base_scene(face_detected=False, face_count=0, face_bbox=None))

    assert result["state"] == "red"
    assert result["checks"]["face"]["reason"] == "no face detected"


def test_classifier_yellow_for_stale_profile():
    result = ojo.classify_scene(base_scene(profile_age_minutes=9 * 60))

    assert result["state"] == "yellow"
    assert result["checks"]["profile"]["state"] == "yellow"


def test_classifier_yellow_when_lights_unreachable_but_scene_ok():
    result = ojo.classify_scene(base_scene(lights_reachable=False))

    assert result["state"] == "yellow"
    assert result["checks"]["lights"]["reason"] == "lights unreachable but scene metrics are acceptable"


def test_framing_uses_estimated_crown_not_vision_face_top():
    # Vision's box starts at the face, below the crown. A face whose raw top
    # is 30% from the image top has approximately 13.5% actual headroom when
    # its height is 30% of the frame.
    result = ojo.framing_metrics([0.35, 0.40, 0.30, 0.30])

    assert result["headroom_pct"] == 0.135
    assert result["framing_state"] == "green"


def test_framing_still_flags_genuinely_excessive_headroom():
    # A low face remains a framing problem after the crown correction.
    result = ojo.framing_metrics([0.35, 0.05, 0.30, 0.30])

    assert result["headroom_pct"] == 0.485
    assert "too much headroom" in result["framing_reason"]


def test_classifier_red_when_lights_unreachable_and_scene_needs_light():
    result = ojo.classify_scene(base_scene(
        lights_reachable=False,
        face_luma_mean=55,
        shadow_clip_pct=8,
    ))

    assert result["state"] == "red"
    assert result["checks"]["lights"]["reason"] == "lights unreachable and scene needs lighting help"


def test_profile_map_selects_current_bucket(monkeypatch, tmp_path):
    path = tmp_path / "lighting-profiles.json"
    path.write_text(json.dumps({
        "schema_version": 1,
        "profiles": {"afternoon": {"camera": {"settings": {}}}},
    }))

    class FakeTime:
        tm_hour = 16

    monkeypatch.setattr(ojo.time, "localtime", lambda: FakeTime())
    status = ojo.select_profile_status(base_scene(), ojo.load_profile_map(str(path)))

    assert status["bucket"] == "afternoon"
    assert status["profile_available"] is True


def test_score_look_great_for_dimensional_scene():
    quality = ojo.score_look(base_scene())

    assert quality["label"] == "great"
    assert quality["score"] >= 88


def test_background_separation_affects_status():
    result = ojo.classify_scene(base_scene(background_separation=2))

    assert result["state"] == "yellow"
    assert result["checks"]["background"]["reason"] == "weak face/background separation"


def test_classifier_flags_pale_flat_face_before_clipping():
    result = ojo.classify_scene(base_scene(
        face_luma_mean=140,
        face_luma_p95=198,
        face_tonal_range=118,
        background_separation=62,
        highlight_clip_pct=0.0,
    ))

    assert result["state"] == "yellow"
    assert result["checks"]["exposure"]["reason"] == "face reads too white or flat for the saved preference"
    assert "too white or flat" in result["quality"]["issues"][0]


def test_update_profile_map_writes_current_bucket(monkeypatch, tmp_path):
    path = tmp_path / "lighting-profiles.json"

    class FakeTime:
        tm_hour = 8

    monkeypatch.setattr(ojo.time, "localtime", lambda: FakeTime())
    profile = ojo.update_profile_map(
        {"brightness": 90},
        base_scene(look_score=94),
        profile_map_path=str(path),
    )

    saved = json.loads(path.read_text())
    assert profile["time_bucket"] == "morning"
    assert saved["profiles"]["morning"]["camera"]["settings"]["brightness"] == 90
    assert saved["profiles"]["morning"]["quality"]["look_score"] == 94


def test_feedback_jsonl_append(tmp_path):
    path = tmp_path / "feedback.jsonl"
    event = ojo.build_feedback_event("bad", "too bright", call_session_id="call-1")

    ojo._append_jsonl(str(path), event)

    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert len(rows) == 1
    assert rows[0]["kind"] == "bad"
    assert rows[0]["note"] == "too bright"
    assert rows[0]["call_session_id"] == "call-1"


def test_ai_repair_skips_framing_only_issue():
    result = ojo.classify_scene(base_scene(
        framing_state="yellow",
        framing_reason="too much headroom",
    ))

    assert ojo.ai_repair_needed(result) is False
    assert "Framing Fix" in ojo.calibration_recommendation(result)


def test_ai_repair_runs_for_severe_exposure_failure():
    result = ojo.classify_scene(base_scene(
        highlight_clip_pct=18,
        face_luma_mean=245,
    ))

    assert result["checks"]["exposure"]["state"] == "red"
    assert ojo.ai_repair_needed(result) is True


def test_check_cache_round_trip(tmp_path):
    path = tmp_path / "check-cache.json"
    result = {"state": "green", "reason": "all checks passed"}

    ojo.write_check_cache(result, cache_path=str(path))
    cached = ojo.load_recent_check_cache(60, cache_path=str(path))

    assert cached["state"] == "green"
    assert cached["cached"] is True
