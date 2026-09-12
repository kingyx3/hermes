import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("camera_proxy", ROOT / "scripts" / "camera_proxy.py")
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)


class CameraProxyTests(unittest.TestCase):
    def test_inventory_filters_non_private_and_bad_names(self):
        payload = {
            "cameras": [
                {"name": "living_room", "display_name": "Living Room", "ip": "192.168.0.201", "model": "x"},
                {"name": "bad?src=x", "ip": "192.168.0.202"},
                {"name": "public", "ip": "8.8.8.8"},
            ]
        }
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "cameras.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with mock.patch.object(MOD, "INVENTORY", path):
                cameras = MOD.load_inventory()
        self.assertEqual(set(cameras), {"living_room"})

    def test_unknown_camera_never_fetches_go2rtc(self):
        with mock.patch.object(MOD, "load_inventory", return_value={"living_room": {}}), \
             mock.patch.object(MOD, "fetch_mp4") as fetch:
            with self.assertRaisesRegex(ValueError, "unknown camera"):
                MOD.snapshot("bedroom")
            fetch.assert_not_called()

    def test_runtime_error_is_not_reflected_to_untrusted_client(self):
        self.assertEqual(MOD._safe_error(RuntimeError("xiaomi://123:sg@192.168.0.2?secret=oops")), "camera request failed")


if __name__ == "__main__":
    unittest.main()
