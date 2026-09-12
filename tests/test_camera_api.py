import importlib.util
import pathlib
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("camera_api", ROOT / "scripts" / "camera_api.py")
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)


class CameraApiTests(unittest.TestCase):
    def test_camera_name_grammar_rejects_url_injection(self):
        self.assertIsNone(MOD.NAME_RE.fullmatch("living_room?src=xiaomi://evil"))
        self.assertIsNone(MOD.NAME_RE.fullmatch("../camera"))
        self.assertIsNotNone(MOD.NAME_RE.fullmatch("living_room_2"))

    def test_snapshot_rejects_unknown_name_before_fetch(self):
        with mock.patch.object(MOD, "list_cameras", return_value=["living_room"]), \
             mock.patch.object(MOD, "request") as request:
            with self.assertRaisesRegex(ValueError, "unknown camera"):
                MOD.snapshot("living_room?src=xiaomi://evil")
            request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
