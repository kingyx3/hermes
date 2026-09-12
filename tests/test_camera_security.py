import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CameraSecurityPolicyTests(unittest.TestCase):
    def test_production_go2rtc_is_unix_socket_only(self):
        text = (ROOT / "scripts" / "install-camera-runtime.sh").read_text(encoding="utf-8")
        self.assertIn('unix_listen: "/run/go2rtc/api.sock"', text)
        self.assertIn('api:\n  listen: ""', text)
        self.assertIn('RestrictAddressFamilies=AF_UNIX', text)
        self.assertIn('ExecStartPost=/bin/chmod 0660 /run/go2rtc/api.sock', text)
        self.assertIn('MemoryMax=192M', text)
        self.assertIn('MemoryMax=256M', text)

    def test_hermes_client_has_no_network_or_go2rtc_api_code(self):
        text = (ROOT / "scripts" / "camera_api.py").read_text(encoding="utf-8")
        self.assertNotIn("urllib", text)
        self.assertNotIn("http.client", text)
        self.assertNotIn("go2rtc", text.lower())
        self.assertIn("AF_UNIX", text)

    def test_auth_window_is_time_limited_local_auth_and_ui_only(self):
        install = (ROOT / "scripts" / "install-camera-runtime.sh").read_text(encoding="utf-8")
        auth = (ROOT / "scripts" / "hermes-camera-auth.sh").read_text(encoding="utf-8")
        self.assertIn("OnActiveSec=15min", install)
        self.assertIn('listen: "127.0.0.1:1984"', auth)
        self.assertIn("local_auth: true", auth)
        self.assertIn("token_urlsafe(32)", auth)
        self.assertIn("    - /\n    - /api/xiaomi", auth)
        self.assertNotIn("/api/streams", auth)
        self.assertNotIn("/api/frame.mp4", auth)

    def test_repo_does_not_contain_wireguard_or_xiaomi_secret_material(self):
        private_key = re.compile(r"PrivateKey\s*=\s*[A-Za-z0-9+/]{40,}={0,2}")
        xiaomi_token = re.compile(r"V1:[A-Za-z0-9+/=_-]{20,}")
        roots = ["scripts", "skills", "docs", ".github"]
        offenders = []
        for root_name in roots:
            root = ROOT / root_name
            if not root.exists():
                continue
            for path in root.rglob("*"):
                if not path.is_file():
                    continue
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    continue
                if private_key.search(text) or xiaomi_token.search(text):
                    offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
