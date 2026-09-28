from test_ojo_stage2 import scene
from scene_contract import ProfileStore
from scene_repair import prepare_scene
from test_ojo_stage2 import Room, ROOM_CALIBRATION


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


def test_profile_rollback_never_replays_unrelated_auto_readings():
    class AutoRoom(Room):
        def __init__(self):
            super().__init__(scene(face_luma_mean=60))
            self.settings = dict(brightness=42, gain=46, auto_exposure_mode=8)
        def select_profile(self, sample):
            return {"status":"compatible", "profile":{"settings":{"brightness":34}}}
        def read(self, deadline):
            return dict(self.settings)
        def write(self, changes, deadline):
            self.settings.update(changes)
            self.settings["gain"] += 1
            return dict(self.settings)
        def restore(self, baseline, devices, deadline):
            assert baseline["camera:1:2"] == {"brightness":42}
            self.settings.update(baseline["camera:1:2"])
            return {"status":"confirmed"}
    io = AutoRoom()
    result = prepare_scene(io, ROOM_CALIBRATION, set(), clock=lambda:io.now)
    assert result["status"] == "worse_or_unverified_restored"
    assert io.settings["brightness"] == 42
