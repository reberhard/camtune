from test_ojo_stage2 import scene
from scene_contract import ProfileStore


def test_automatic_camera_readings_are_not_saved_as_manual_commands(tmp_path):
    settings = dict(brightness=34, absolute_zoom=173, auto_exposure_mode=8,
                    absolute_exposure_time=156, gain=46, auto_white_balance_temperature=1,
                    white_balance_temperature=4700, auto_focus=1, absolute_focus=30)
    store = ProfileStore(tmp_path)
    saved = store.save(scene(profile_status="missing"), settings)["settings"]
    assert saved == dict(brightness=34, absolute_zoom=173, auto_exposure_mode=8,
                         auto_white_balance_temperature=1, auto_focus=1)
    assert settings["gain"] == 46  # caller's readback remains intact


def test_explicit_manual_settings_are_preserved(tmp_path):
    settings = dict(brightness=34, auto_exposure_mode=1, absolute_exposure_time=156,
                    gain=46, auto_white_balance_temperature=0, white_balance_temperature=4700,
                    auto_focus=0, absolute_focus=30)
    assert ProfileStore(tmp_path).save(scene(), settings)["settings"] == settings
