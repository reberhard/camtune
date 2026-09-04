import importlib.util
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ojo", ROOT / "ojo.py")
ojo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ojo)


def scene(face_detected=True):
    return {"face_detected": face_detected}


# --- Idle gating (Phase 1 task 1) ---


def test_face_detected_is_never_idle_and_updates_presence(tmp_path):
    path = tmp_path / "face-presence-state.json"
    is_idle = ojo.gate_idle_check(scene(True), trigger="auto", now=1000.0, presence_path=path)
    assert is_idle is False
    assert ojo._load_last_face_seen(path=path) == 1000.0


def test_manual_trigger_with_no_face_is_never_idle(tmp_path):
    path = tmp_path / "face-presence-state.json"
    is_idle = ojo.gate_idle_check(scene(False), trigger="manual", now=1000.0, presence_path=path)
    assert is_idle is False


def test_calendar_trigger_with_no_face_is_never_idle(tmp_path):
    path = tmp_path / "face-presence-state.json"
    is_idle = ojo.gate_idle_check(scene(False), trigger="calendar", now=1000.0, presence_path=path)
    assert is_idle is False


def test_auto_trigger_no_face_no_prior_sighting_is_idle(tmp_path):
    path = tmp_path / "face-presence-state.json"
    is_idle = ojo.gate_idle_check(scene(False), trigger="auto", now=1000.0, presence_path=path)
    assert is_idle is True


def test_auto_trigger_no_face_recent_sighting_is_real(tmp_path):
    path = tmp_path / "face-presence-state.json"
    ojo._save_last_face_seen(1000.0, path=path)
    is_idle = ojo.gate_idle_check(
        scene(False), trigger="auto", now=1000.0 + 60, presence_path=path,
        grace_seconds=ojo.IDLE_GRACE_SECONDS,
    )
    assert is_idle is False


def test_auto_trigger_no_face_stale_sighting_is_idle(tmp_path):
    path = tmp_path / "face-presence-state.json"
    ojo._save_last_face_seen(1000.0, path=path)
    is_idle = ojo.gate_idle_check(
        scene(False), trigger="auto", now=1000.0 + ojo.IDLE_GRACE_SECONDS + 1,
        presence_path=path,
    )
    assert is_idle is True


# --- position control type (Phase 1 task 4, blinds) ---

BLINDS_CONTROL = {
    "controls": [{
        "name": "office_blinds",
        "set_command": "/opt/homebrew/bin/python3 /fake/office-blinds.py set {position} both",
        "type": "position",
        "ranges": {"position": [0, 100]},
    }]
}


def test_apply_env_changes_position_type_dry_run_formats_position_not_hsv():
    applied = ojo.apply_env_changes({"office_blinds": {"position": 40}}, BLINDS_CONTROL, dry_run=True)
    assert len(applied) == 1
    assert "Position:40%" in applied[0]
    assert "H:" not in applied[0]


def test_apply_env_changes_position_type_dry_run_defaults_missing_position_to_zero():
    applied = ojo.apply_env_changes({"office_blinds": {}}, BLINDS_CONTROL, dry_run=True)
    assert "Position:0%" in applied[0]


def test_probe_env_reachability_detects_non_office_lights_script(monkeypatch):
    calls = []

    def fake_run(args, capture_output, text, timeout):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, stdout="Reachable: 2/2\n", stderr="")

    monkeypatch.setattr(ojo.subprocess, "run", fake_run)
    status = ojo.probe_env_reachability(BLINDS_CONTROL)
    assert status == {"office_blinds": "online"}
    assert calls[0][2:] == ["status", "both"]


def test_probe_env_reachability_reports_offline_on_zero_reachable(monkeypatch):
    def fake_run(args, capture_output, text, timeout):
        return subprocess.CompletedProcess(args, 2, stdout="Reachable: 0/2\n", stderr="")

    monkeypatch.setattr(ojo.subprocess, "run", fake_run)
    status = ojo.probe_env_reachability(BLINDS_CONTROL)
    assert status == {"office_blinds": "offline"}


def test_probe_env_reachability_reports_degraded_on_partial(monkeypatch):
    def fake_run(args, capture_output, text, timeout):
        return subprocess.CompletedProcess(args, 2, stdout="Reachable: 1/2\n", stderr="")

    monkeypatch.setattr(ojo.subprocess, "run", fake_run)
    status = ojo.probe_env_reachability(BLINDS_CONTROL)
    assert status == {"office_blinds": "degraded"}


# --- Phase 2: bucket-aware profile freshness (2026-09-03) ---


def test_parse_utc_iso_round_trips_utc_now_format():
    ts = ojo._utc_now()
    parsed = ojo._parse_utc_iso(ts)
    assert parsed is not None
    assert abs(parsed - time.time()) < 5


def test_parse_utc_iso_returns_none_for_garbage():
    assert ojo._parse_utc_iso("not a timestamp") is None
    assert ojo._parse_utc_iso(None) is None


def test_bucket_profile_age_minutes_none_when_no_entry_for_bucket():
    profile_map = {"schema_version": 1, "profiles": {}}
    age = ojo.bucket_profile_age_minutes(profile_map=profile_map, bucket="afternoon", now=1000.0)
    assert age is None


def test_bucket_profile_age_minutes_computes_from_updated_at():
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(1000.0))
    profile_map = {"schema_version": 1, "profiles": {"afternoon": {"updated_at": ts}}}
    now = 1000.0 + 600  # 10 minutes later
    age = ojo.bucket_profile_age_minutes(profile_map=profile_map, bucket="afternoon", now=now)
    assert age == 10


def test_bucket_profile_age_minutes_none_for_unparseable_updated_at():
    profile_map = {"schema_version": 1, "profiles": {"afternoon": {"updated_at": "garbage"}}}
    age = ojo.bucket_profile_age_minutes(profile_map=profile_map, bucket="afternoon", now=1000.0)
    assert age is None


def test_current_time_bucket_boundaries():
    assert ojo.current_time_bucket(time.strptime("2026-01-01 08:00", "%Y-%m-%d %H:%M")) == "morning"
    assert ojo.current_time_bucket(time.strptime("2026-01-01 12:00", "%Y-%m-%d %H:%M")) == "midday"
    assert ojo.current_time_bucket(time.strptime("2026-01-01 17:00", "%Y-%m-%d %H:%M")) == "afternoon"
    assert ojo.current_time_bucket(time.strptime("2026-01-01 21:00", "%Y-%m-%d %H:%M")) == "evening"


# --- Phase 2: call rollups (2026-09-04) ---


def test_build_call_rollup_computes_duration():
    row = ojo.build_call_rollup(
        app="Zoom", session_id="abc", started_at="2026-09-04T14:00:00Z",
        ended_at="2026-09-04T14:05:30Z", checks_run=4, reached_green=True,
        worst_state="yellow", final_state="green", rescue_count=0,
    )
    assert row["event_type"] == "call_rollup"
    assert row["duration_seconds"] == 330
    assert row["reached_green"] is True


def test_build_call_rollup_duration_none_when_timestamps_unparseable():
    row = ojo.build_call_rollup(
        app="Zoom", session_id="abc", started_at="garbage",
        ended_at="also garbage", checks_run=0, reached_green=False,
        worst_state=None, final_state=None, rescue_count=0,
    )
    assert row["duration_seconds"] is None


# --- Phase 2 follow-up: parallel light-reachability probing (2026-09-04) ---


def test_probe_env_reachability_runs_controls_in_parallel(monkeypatch):
    """Three controls each taking ~0.2s should finish in ~0.2s total, not 0.6s,
    if they're actually probed concurrently rather than one at a time."""
    def fake_run(args, capture_output, text, timeout):
        time.sleep(0.2)
        return subprocess.CompletedProcess(args, 0, stdout="Reachable: 1/1\n", stderr="")

    monkeypatch.setattr(ojo.subprocess, "run", fake_run)
    config = {"controls": [
        {"name": f"light_{i}", "set_command": f"/opt/homebrew/bin/python3 /fake/light_{i}.py status all"}
        for i in range(3)
    ]}
    start = time.time()
    status = ojo.probe_env_reachability(config, timeout=5.0)
    elapsed = time.time() - start
    assert status == {"light_0": "online", "light_1": "online", "light_2": "online"}
    assert elapsed < 0.5, f"expected ~0.2s in parallel, took {elapsed:.2f}s (looks sequential)"


def test_probe_env_reachability_default_timeout_is_generous():
    # Regression guard: this was 1.0s, which live testing showed reads a
    # genuinely-reachable-but-slow bulb as offline. It should not silently
    # drop back down.
    import inspect
    default = inspect.signature(ojo.probe_env_reachability).parameters["timeout"].default
    assert default >= 5.0
