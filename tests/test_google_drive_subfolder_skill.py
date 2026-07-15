from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SKILL = (ROOT / "skills/google-workspace/SKILL.md").read_text(encoding="utf-8")
DOC = (ROOT / "docs/google-drive-workspace.md").read_text(encoding="utf-8")


class DriveSubfolderSkillTests(unittest.TestCase):
    def test_nested_folder_commands_are_documented(self) -> None:
        self.assertIn("Do not claim nested folders are unsupported", SKILL)
        self.assertIn("drive mkdir", SKILL)
        self.assertIn("drive move", SKILL)
        self.assertIn("--parent-id", SKILL)

    def test_recursive_boundary_is_documented(self) -> None:
        self.assertIn("managed-descendants-only", SKILL)
        self.assertIn("managed-descendants-only", DOC)
        self.assertIn("complete parent chain", SKILL)

    def test_cycle_and_root_guards_are_documented(self) -> None:
        self.assertIn("cannot be moved into itself or one of its descendants", SKILL)
        self.assertIn("root cannot be renamed, moved, or trashed", DOC)


if __name__ == "__main__":
    unittest.main()
