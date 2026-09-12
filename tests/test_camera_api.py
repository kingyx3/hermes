import importlib.util
import pathlib
import tempfile
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

    def test_snapshot_rejects_injection_before_broker(self):
        with mock.patch.object(MOD, "broker_request") as request:
            with self.assertRaisesRegex(ValueError, "invalid camera name"):
                MOD.snapshot("living_room?src=xiaomi://evil")
            request.assert_not_called()

    def test_snapshot_writes_only_broker_returned_jpeg(self):
        image = b"\xff\xd8test\xff\xd9"
        header = {"ok": True, "camera": "living_room", "captured_at_utc": "20260912T000000Z", "length": len(image)}
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(MOD, "broker_request", return_value=(header, image)), \
             mock.patch.dict(MOD.os.environ, {"CAMERA_CACHE_DIR": tmp}):
            result = MOD.snapshot("living_room")
            self.assertEqual(pathlib.Path(result["path"]).read_bytes(), image)
            self.assertEqual(pathlib.Path(result["path"]).stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
