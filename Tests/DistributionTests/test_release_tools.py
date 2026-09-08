"""Run with: python3 -m unittest discover -s Tests/DistributionTests -v"""
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kiosk-release-test-")
        self.root = Path(self.temporary.name)
        (self.root / "Assets").mkdir()
        (self.root / "scripts").mkdir()
        self.plist = self.root / "Assets/Info.plist"
        shutil.copy(ROOT / "Assets/Info.plist", self.plist)
        shutil.copy(ROOT / "scripts/version.sh", self.root / "scripts/version.sh")

    def tearDown(self):
        self.temporary.cleanup()

    def version(self, *args):
        return subprocess.run(["bash", str(self.root / "scripts/version.sh"), *args],
                              capture_output=True, text=True)

    def test_current_version_and_candidates_validate_without_editing_assets(self):
        original = self.plist.read_bytes()
        version = plistlib.loads(original)["CFBundleShortVersionString"]
        for suffix in ["", "-alpha.1", "-beta.2", "-rc.10"]:
            result = self.version("--check-tag", "v" + version + suffix)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plist.read_bytes(), original)

    def test_mismatches_and_malformed_tags_fail(self):
        for tag in ["v9999.0.0", "1.0.0", "v1x0x0", "v1.0.0-rc.0", "v1.0.0-rc.01", "v1.0.0-extra", "v1.0.0/path"]:
            self.assertNotEqual(self.version("--check-tag", tag).returncode, 0, tag)

    def test_version_edit_changes_only_the_two_version_fields(self):
        before = plistlib.loads(self.plist.read_bytes())
        result = self.version("2.3.4", "42")
        self.assertEqual(result.returncode, 0, result.stderr)
        before.update(CFBundleShortVersionString="2.3.4", CFBundleVersion="42")
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), before)
        self.assertEqual(self.version("--check-tag", "v2.3.4").returncode, 0)

    def test_invalid_version_edit_does_not_touch_the_asset(self):
        original = self.plist.read_bytes()
        for version, build in [("1.2", "2"), ("01.2.3", "2"), ("1.2.3-rc.1", "2"), ("1.2.3", "0"), ("1.2.3", "-1")]:
            self.assertNotEqual(self.version(version, build).returncode, 0)
            self.assertEqual(self.plist.read_bytes(), original)

    def test_ignores_generated_files_and_credentials_but_keeps_source_assets(self):
        shutil.copy(ROOT / ".gitignore", self.root / ".gitignore")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        ignored = [".build/release/Kiosk", "dist/Kiosk.app/Contents/Info.plist", ".DS_Store",
                   "Assets/.DS_Store", "certificates/developer.p12", "AuthKey_example.p8",
                   "temporary.keychain-db", ".env", ".env.local", "Tests/__pycache__/test.pyc"]
        tracked = ["Assets/Info.plist", "Assets/AppIcon.icns", "Assets/AppIcon.png", "Assets/AppIcon.svg",
                   "Model/Defaults.plist", "Package.resolved", ".env.example", ".github/workflows/release.yml"]
        for path in ignored + tracked:
            result = subprocess.run(["git", "-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index", path],
                                    cwd=self.root, capture_output=True)
            self.assertEqual(result.returncode, 0 if path in ignored else 1, path)

    def test_refresh_release_notes_preserves_user_notes(self):
        existing = self.root / "release.json"
        generated = self.root / "generated.md"
        output = self.root / "output.md"
        existing.write_text(json.dumps({"body": "<!-- kiosk-build:begin -->\nOld signing status\n<!-- kiosk-build:end -->\n\nMy edited change notes."}))
        generated.write_text("<!-- kiosk-build:begin -->\nNew signing status\n<!-- kiosk-build:end -->\n")
        subprocess.run(["python3", str(ROOT / "scripts/refresh-release-notes.py"), str(existing), str(generated), str(output)], check=True)
        self.assertIn("New signing status", output.read_text())
        self.assertIn("My edited change notes.", output.read_text())
        self.assertNotIn("Old signing status", output.read_text())


if __name__ == "__main__":
    unittest.main()
