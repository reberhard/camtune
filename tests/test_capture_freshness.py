from pathlib import Path
from types import SimpleNamespace
import subprocess
import pytest
from test_ojo_phase1 import ojo


@pytest.mark.parametrize("code,content", [(1,b"new but failed"),(0,None),(0,b"")])
def test_failed_capture_never_accepts_an_old_file(tmp_path, monkeypatch, code, content):
    target = tmp_path / "capture.png"
    target.write_bytes(b"old frame")
    def capture(args, **kwargs):
        assert kwargs["timeout"] == 8
        assert args[-1] != str(target)
        if content is not None:
            Path(args[-1]).write_bytes(content)
        return SimpleNamespace(returncode=code,stderr="camera unavailable")
    monkeypatch.setattr(ojo.subprocess,"run",capture)
    assert not ojo.capture_frame("fixture",str(target),source="camera")
    assert target.read_bytes() == b"old frame"
    assert list(tmp_path.iterdir()) == [target]


def test_successful_capture_replaces_only_with_fresh_image(tmp_path, monkeypatch):
    target = tmp_path / "capture.png"
    target.write_bytes(b"old")
    def capture(args, **kwargs):
        Path(args[-1]).write_bytes(b"fresh")
        return SimpleNamespace(returncode=0,stderr="")
    monkeypatch.setattr(ojo.subprocess,"run",capture)
    assert ojo.capture_frame("fixture",str(target),source="camera")
    assert target.read_bytes() == b"fresh"


def test_camera_timeout_names_the_capture_and_cleans_temp(tmp_path, monkeypatch):
    def capture(args, **kwargs):
        raise subprocess.TimeoutExpired(args,kwargs["timeout"])
    monkeypatch.setattr(ojo.subprocess,"run",capture)
    with pytest.raises(RuntimeError,match="Camera capture timed out after 8 seconds"):
        ojo.capture_frame("fixture",str(tmp_path/"capture.png"),source="camera")
    assert not list(tmp_path.iterdir())


def test_default_check_image_is_private_per_invocation_and_removed(monkeypatch):
    seen = []
    def check(args,*_):
        path=Path(args.capture_path)
        assert path.parent.exists()
        path.write_bytes(b"private")
        seen.append(path)
        return {"state":"fixture"}
    monkeypatch.setattr(ojo,"_run_pre_call_check",check)
    for _ in range(2):
        assert ojo.run_pre_call_check(SimpleNamespace(),"fixture")["state"] == "fixture"
    assert seen[0] != seen[1]
    assert all(not p.parent.exists() for p in seen)
