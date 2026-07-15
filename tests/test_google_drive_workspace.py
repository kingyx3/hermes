from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_script(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DriveWorkspaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.drive = load_script("google_drive_workspace", "scripts/google-drive-workspace.py")

    def folder(self):
        return {
            "id": "folder-id",
            "name": "hermes",
            "mimeType": self.drive.FOLDER_MIME,
            "trashed": False,
            "appProperties": {self.drive.MANAGED_KEY: self.drive.MANAGED_VALUE},
        }

    def test_validate_folder_requires_name_and_marker(self) -> None:
        self.assertEqual(self.drive.validate_folder(self.folder())["id"], "folder-id")
        renamed = self.folder() | {"name": "other"}
        with self.assertRaises(SystemExit):
            self.drive.validate_folder(renamed)
        unmarked = self.folder() | {"appProperties": {}}
        with self.assertRaises(SystemExit):
            self.drive.validate_folder(unmarked)

    def test_managed_file_accepts_only_direct_children(self) -> None:
        inside = {
            "id": "inside",
            "name": "Doc",
            "mimeType": self.drive.DOC_MIME,
            "parents": ["folder-id"],
            "trashed": False,
        }
        outside = inside | {"id": "outside", "parents": ["another-folder"]}
        with mock.patch.object(self.drive, "ensure_workspace", return_value=self.folder()), mock.patch.object(
            self.drive, "drive_file", side_effect=[inside, outside]
        ):
            self.assertEqual(
                self.drive.managed_file("inside", expected_mime=self.drive.DOC_MIME)["id"],
                "inside",
            )
            with self.assertRaises(SystemExit):
                self.drive.managed_file("outside", expected_mime=self.drive.DOC_MIME)

    def test_create_file_sets_folder_parent_and_marker(self) -> None:
        created = {
            "id": "new-doc",
            "name": "Notes",
            "mimeType": self.drive.DOC_MIME,
            "parents": ["folder-id"],
            "appProperties": {self.drive.MANAGED_KEY: self.drive.MANAGED_VALUE},
        }
        with mock.patch.object(self.drive, "ensure_workspace", return_value=self.folder()), mock.patch.object(
            self.drive, "api_request", return_value=created
        ) as request, mock.patch.object(self.drive, "managed_file", return_value=created):
            result = self.drive.create_managed_file("Notes", self.drive.DOC_MIME)
        self.assertEqual(result["id"], "new-doc")
        body = request.call_args.kwargs["body"]
        self.assertEqual(body["parents"], ["folder-id"])
        self.assertEqual(
            body["appProperties"],
            {self.drive.MANAGED_KEY: self.drive.MANAGED_VALUE},
        )

    def test_values_json_must_be_rows(self) -> None:
        self.assertEqual(self.drive.parse_values('[["a",1],["b",2]]'), [["a", 1], ["b", 2]])
        with self.assertRaises(SystemExit):
            self.drive.parse_values('{"a":1}')
        with self.assertRaises(SystemExit):
            self.drive.parse_values('[1,2]')


class DriveOAuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.oauth = load_script("google_drive_oauth", "scripts/google-drive-oauth.py")

    def test_auth_url_requests_only_drive_file(self) -> None:
        client = {
            "client_id": "client-id",
            "client_secret": "secret",
            "auth_uri": self.oauth.AUTH_URI,
            "token_uri": self.oauth.TOKEN_URI,
        }
        stream = io.StringIO()
        with mock.patch.object(self.oauth, "client", return_value=client), mock.patch.object(
            self.oauth, "write_private_json"
        ), contextlib.redirect_stdout(stream):
            self.oauth.auth_url()
        url = stream.getvalue().strip()
        query = dict(__import__("urllib.parse").parse.parse_qsl(__import__("urllib.parse").parse.urlparse(url).query))
        self.assertEqual(query["scope"], self.oauth.SCOPE)
        self.assertNotIn("include_granted_scopes", query)
        self.assertEqual(query["code_challenge_method"], "S256")


if __name__ == "__main__":
    unittest.main()
