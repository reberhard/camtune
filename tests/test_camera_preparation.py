from test_ojo_stage2 import Camera, CALIBRATION, scene
from scene_repair import fix_exposure, prepare_camera, accept_verified_profile
from scene_contract import ProfileStore


def camera(frames, **kwargs):
    io = Camera(frames, **kwargs)
    io.settings["brightness"] = 42
    return io


def test_exposure_is_corrected_only_after_measured_improvement():
    io = camera([scene(face_luma_mean=145), scene(face_luma_mean=121)])
    result = fix_exposure(io, CALIBRATION, clock=lambda: io.now)
    assert result["status"] == "improved" and result["after_luma"] == 121
    assert io.writes == [{"brightness":34}]


def test_acceptable_exposure_is_successful_noop():
    io = camera([scene()])
    assert fix_exposure(io, CALIBRATION, clock=lambda: io.now)["status"] == "unchanged"
    assert not io.writes


def test_nonimprovement_lost_face_and_new_clipping_restore_brightness():
    for after in (scene(face_luma_mean=145), scene(face_count=0), scene(highlight_clip_pct=10)):
        io = camera([scene(face_luma_mean=145), after])
        result = fix_exposure(io, CALIBRATION, clock=lambda: io.now)
        assert result["status"] == "worse_or_unverified_restored"
        assert io.settings["brightness"] == 42


def test_newer_manual_camera_intent_is_preserved():
    io = camera([scene(face_luma_mean=145), scene()])
    result = fix_exposure(io, CALIBRATION, current=lambda:not io.writes, clock=lambda:io.now)
    assert result["status"] == "cancelled" and len(io.writes) == 1


def test_composite_camera_preparation_runs_both_stages():
    io = camera([scene(face_luma_mean=145), scene(face_luma_mean=145), scene()])
    result = prepare_camera(io, CALIBRATION, clock=lambda:io.now)
    assert result["status"] == "improved"
    assert result["framing"]["status"] == "unchanged"
    assert result["exposure"]["status"] == "improved"


def test_exposure_failure_does_not_claim_complete_camera_preparation():
    io = camera([scene(face_luma_mean=145), scene(face_luma_mean=145), scene(face_luma_mean=145)])
    result = prepare_camera(io, CALIBRATION, clock=lambda:io.now)
    assert result["status"] == "worse_or_unverified_restored"
    assert io.settings["brightness"] == 42


def test_profile_requires_all_measured_checks_green(tmp_path):
    store = ProfileStore(tmp_path)
    io = camera([scene(profile_status="missing")])
    result = accept_verified_profile(io,{"status":"improved"},store,clock=lambda:io.now)
    assert result["profile_saved"] and store.path.exists()
    other = ProfileStore(tmp_path/"bad")
    io = camera([scene(face_luma_mean=145)])
    result = accept_verified_profile(io,{"status":"improved"},other,clock=lambda:io.now)
    assert not result.get("profile_saved") and not other.path.exists()


def test_profile_save_failure_and_supersession_preserve_correction_record(tmp_path):
    class Failed:
        def save(self,*args,**kwargs):
            raise OSError("disk unavailable")
    io = camera([scene()])
    result = accept_verified_profile(io,{"status":"improved"},Failed(),clock=lambda:io.now)
    assert result["status"] == "improved" and "disk unavailable" in result["profile_error"]
    store = ProfileStore(tmp_path)
    io = camera([scene()])
    result = accept_verified_profile(io,{"status":"improved"},store,current=lambda:False,clock=lambda:io.now)
    assert not store.path.exists() and "superseded" in result["profile_error"]


def test_prepare_budget_plus_restore_stays_inside_the_app_helper_timeout():
    """Regression 2026-10-05: a 20 s budget could never finish (two room readbacks,
    a lamp status and the change), but a budget that is too long gets the helper
    killed mid-restore by the app's 45 s limit."""
    import scene_repair
    assert scene_repair.PREPARE_BUDGET_SECONDS >= 30
    assert (scene_repair.PREPARE_BUDGET_SECONDS + scene_repair.RESTORE_BUDGET_SECONDS
            < scene_repair.APP_HELPER_TIMEOUT_SECONDS)


def test_app_helper_timeout_constant_matches_the_swift_source():
    import re, pathlib, scene_repair
    swift = (pathlib.Path(__file__).resolve().parents[1] / "CamTuneApp/Sources/AppState.swift").read_text()
    m = re.search(r'command == "camera-prepare" \? 75 : (\d+)', swift)
    assert m and int(m.group(1)) == scene_repair.APP_HELPER_TIMEOUT_SECONDS
