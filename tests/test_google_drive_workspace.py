from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
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

    def root(self):
        return {
            "id": "root-id",
            "name": "hermes",
            "mimeType": self.drive.FOLDER_MIME,
            "parents": ["my-drive"],
            "trashed": False,
            "appProperties": {self.drive.MANAGED_KEY: self.drive.MANAGED_VALUE},
        }

    def folder(self, folder_id: str, parent_id: str, name: str = "Folder"):
        return {
            "id": folder_id,
            "name": name,
            "mimeType": self.drive.FOLDER_MIME,
            "parents": [parent_id],
            "trashed": False,
            "appProperties": {self.drive.MANAGED_KEY: self.drive.MANAGED_VALUE},
        }

    def document(self, file_id: str, parent_id: str):
        return {
            "id": file_id,
            "name": "Doc",
            "mimeType": self.drive.DOC_MIME,
            "parents": [parent_id],
            "trashed": False,
        }

    def test_validate_folder_requires_name_and_marker(self) -> None:
        self.assertEqual(self.drive.validate_folder(self.root())["id"], "root-id")
        with self.assertRaises(SystemExit):
            self.drive.validate_folder(self.root() | {"name": "other"})
        with self.assertRaises(SystemExit):
            self.drive.validate_folder(self.root() | {"appProperties": {}})

    def test_managed_file_accepts_nested_descendant(self) -> None:
        items = {
            "doc-id": self.document("doc-id", "trip-folder"),
            "trip-folder": self.folder("trip-folder", "year-folder", "Japan"),
            "year-folder": self.folder("year-folder", "root-id", "2026"),
        }
        with mock.patch.object(
            self.drive, "ensure_workspace", return_value=self.root()
        ), mock.patch.object(
            self.drive, "drive_file", side_effect=lambda file_id, **_: items[file_id]
        ):
            result = self.drive.managed_file(
                "doc-id", expected_mime=self.drive.DOC_MIME
            )
        self.assertEqual(result["id"], "doc-id")

    def test_managed_file_rejects_item_without_root_ancestry(self) -> None:
        items = {
            "doc-id": self.document("doc-id", "outside-folder"),
            "outside-folder": self.folder("outside-folder", "outside-root"),
            "outside-root": self.folder("outside-root", "another-parent"),
            "another-parent": self.folder("another-parent", "yet-another-parent"),
            "yet-another-parent": self.folder("yet-another-parent", "outside-root"),
        }
        with mock.patch.object(
            self.drive, "ensure_workspace", return_value=self.root()
        ), mock.patch.object(
            self.drive, "drive_file", side_effect=lambda file_id, **_: items[file_id]
        ):
            with self.assertRaises(SystemExit):
                self.drive.managed_file("doc-id")

    def test_create_file_uses_validated_nested_parent(self) -> None:
        parent = self.folder("trip-folder", "root-id", "Japan")
        created = self.document("new-doc", "trip-folder")
        with mock.patch.object(
            self.drive, "managed_folder", return_value=parent
        ), mock.patch.object(
            self.drive, "api_request", return_value=created
        ) as request, mock.patch.object(
            self.drive, "managed_file", return_value=created
        ):
            result = self.drive.create_managed_file(
                "Notes", self.drive.DOC_MIME, parent_id="trip-folder"
            )
        self.assertEqual(result["id"], "new-doc")
        self.assertEqual(request.call_args.kwargs["body"]["parents"], ["trip-folder"])

    def test_mkdir_creates_folder_in_nested_parent(self) -> None:
        args = argparse.Namespace(name="Japan", parent_id="trips")
        created = self.folder("japan", "trips", "Japan")
        with mock.patch.object(
            self.drive, "create_managed_file", return_value=created
        ) as create, mock.patch.object(self.drive, "output"):
            self.drive.drive_mkdir(args)
        create.assert_called_once_with(
            "Japan", self.drive.FOLDER_MIME, parent_id="trips"
        )

    def test_move_rejects_folder_into_own_descendant(self) -> None:
        source = self.folder("source", "root-id", "Source")
        target = self.folder("target", "source", "Target")
        args = argparse.Namespace(file_id="source", parent_id="target")
        with mock.patch.object(
            self.drive, "managed_file", return_value=source
        ), mock.patch.object(
            self.drive, "managed_folder", return_value=target
        ), mock.patch.object(
            self.drive,
            "managed_lineage",
            return_value=[target, source, self.root()],
        ):
            with self.assertRaises(SystemExit):
                self.drive.drive_move(args)

    def test_parser_exposes_nested_folder_operations(self) -> None:
        args = self.drive.parser().parse_args(
            ["docs", "create", "--title", "Plan", "--parent-id", "trip-folder"]
        )
        self.assertEqual(args.parent_id, "trip-folder")
        args = self.drive.parser().parse_args(
            ["drive", "move", "doc-id", "--parent-id", "archive-folder"]
        )
        self.assertEqual(args.parent_id, "archive-folder")
        args = self.drive.parser().parse_args(["drive", "tree", "--max", "250"])
        self.assertEqual(args.max_results, 250)

    def test_values_json_must_be_rows(self) -> None:
        self.assertEqual(
            self.drive.parse_values('[["a",1],["b",2]]'), [["a", 1], ["b", 2]]
        )
        with self.assertRaises(SystemExit):
            self.drive.parse_values('{"a":1}')
        with self.assertRaises(SystemExit):
            self.drive.parse_values("[1,2]")


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
        with mock.patch.object(
            self.oauth, "client", return_value=client
        ), mock.patch.object(
            self.oauth, "write_private_json"
        ), contextlib.redirect_stdout(stream):
            self.oauth.auth_url()
        url = stream.getvalue().strip()
        query = dict(
            __import__("urllib.parse").parse.parse_qsl(
                __import__("urllib.parse").parse.urlparse(url).query
            )
        )
        self.assertEqual(query["scope"], self.oauth.SCOPE)
        self.assertNotIn("include_granted_scopes", query)
        self.assertEqual(query["code_challenge_method"], "S256")


if __name__ == "__main__":
    unittest.main()
