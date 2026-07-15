from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GoogleContactsTests(TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contacts = load_module("google_contacts_api", "scripts/google-contacts-api.py")
        cls.oauth = load_module("google_contacts_oauth", "scripts/google-contacts-oauth.py")

    def namespace(self, **overrides):
        values = {
            "given_name": None,
            "family_name": None,
            "email": None,
            "phone": None,
            "company": None,
            "job_title": None,
            "notes": None,
            "birthday": None,
            "url": None,
            "clear_emails": False,
            "clear_phones": False,
            "clear_organization": False,
            "clear_notes": False,
            "clear_birthday": False,
            "clear_urls": False,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_contacts_oauth_uses_read_write_scope_and_separate_token(self):
        self.assertEqual(
            self.oauth.SCOPE,
            "https://www.googleapis.com/auth/contacts",
        )
        self.assertEqual(self.oauth.TOKEN_PATH.name, "google_contacts_token.json")
        self.assertEqual(self.contacts.TOKEN_PATH.name, "google_contacts_token.json")

    def test_create_fields_support_common_contact_data(self):
        fields, changed = self.contacts.build_contact_fields(
            self.namespace(
                given_name="Ada",
                family_name="Lovelace",
                email=["ada@example.com"],
                phone=["+65 6123 4567"],
                company="Example Ltd",
                job_title="Engineer",
                notes="Introduced at conference",
                birthday="1815-12-10",
                url=["https://example.com/ada"],
            ),
            for_update=False,
        )
        self.assertIn("names", changed)
        self.assertEqual(fields["names"][0]["givenName"], "Ada")
        self.assertEqual(fields["emailAddresses"][0]["value"], "ada@example.com")
        self.assertEqual(fields["organizations"][0]["title"], "Engineer")
        self.assertEqual(fields["birthdays"][0]["date"]["month"], 12)

    def test_update_fetches_latest_metadata_and_etag(self):
        current = {
            "resourceName": "people/123",
            "etag": "%EgQBAg==",
            "metadata": {"sources": [{"type": "CONTACT", "etag": "%EgQBAg=="}]},
            "names": [{"givenName": "Ada"}],
        }
        response = dict(current)
        response["emailAddresses"] = [{"value": "new@example.com"}]

        with patch.object(self.contacts, "get_person_raw", return_value=current), patch.object(
            self.contacts, "api_request", return_value=response
        ) as request, patch.object(self.contacts, "output"):
            args = self.namespace(email=["new@example.com"])
            args.resource_name = "people/123"
            self.contacts.contacts_update(args)

        body = request.call_args.kwargs["body"]
        query = request.call_args.kwargs["query"]
        self.assertEqual(body["metadata"], current["metadata"])
        self.assertEqual(body["etag"], current["etag"])
        self.assertEqual(query["updatePersonFields"], "emailAddresses")

    def test_delete_normalizes_raw_contact_id(self):
        with patch.object(self.contacts, "api_request") as request, patch.object(
            self.contacts, "output"
        ):
            self.contacts.contacts_delete(argparse.Namespace(resource_name="123"))
        self.assertEqual(request.call_args.args[1], "people/123:deleteContact")

    def test_parser_exposes_contact_mutations(self):
        parser = self.contacts.parser()
        args = parser.parse_args(
            [
                "create",
                "--given-name",
                "Ada",
                "--email",
                "ada@example.com",
            ]
        )
        self.assertEqual(args.given_name, "Ada")
        self.assertEqual(args.email, ["ada@example.com"])
