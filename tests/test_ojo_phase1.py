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
