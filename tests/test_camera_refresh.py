import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("camera_refresh", ROOT / "scripts" / "camera_refresh.py")
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)


class CameraRefreshTests(unittest.TestCase):
    def test_builds_named_xiaomi_streams(self):
        sources = [{
            "name": "Living Room",
            "url": "xiaomi://12345:sg@192.168.0.201?did=99887766&model=chuangmi.camera.061a03",
        }]
        streams, cameras = MOD.build_streams(sources)
        self.assertEqual(cameras[0]["name"], "living_room")
        self.assertEqual(cameras[0]["ip"], "192.168.0.201")
        self.assertEqual(
            streams["living_room"],
            "xiaomi://12345:sg@192.168.0.201?did=99887766&model=chuangmi.camera.061a03",
        )
        self.assertEqual(set(streams), {"living_room"})

    def test_rejects_non_private_camera_address(self):
        sources = [{
            "name": "Bad",
            "url": "xiaomi://12345:sg@8.8.8.8?did=1&model=chuangmi.camera.061a03",
        }]
        streams, cameras = MOD.build_streams(sources)
        self.assertEqual(streams, {})
        self.assertEqual(cameras, [])

    def test_duplicate_names_are_disambiguated(self):
        sources = [
            {"name": "Camera", "url": "xiaomi://1:sg@192.168.0.2?did=111111&model=chuangmi.camera.061a03"},
            {"name": "Camera", "url": "xiaomi://1:sg@192.168.0.3?did=222222&model=chuangmi.camera.061a03"},
        ]
        _, cameras = MOD.build_streams(sources)
        self.assertEqual(cameras[0]["name"], "camera")
        self.assertEqual(cameras[1]["name"], "camera_222222")


if __name__ == "__main__":
    unittest.main()
