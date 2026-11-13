import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "plisttool.py"


class PlistToolTests(unittest.TestCase):
    def test_expands_variables_and_keeps_version_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.plist"
            output = Path(directory) / "output.plist"
            with source.open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"}, stream)
            subprocess.run([
                "python3", str(TOOL), "plist", "-i", str(source), "-o", str(output),
                "--var", "PRODUCT_BUNDLE_IDENTIFIER=com.example.test",
                "--set", "CFBundleVersion=123", "--set", "Enabled=true",
            ], check=True)
            with output.open("rb") as stream:
                result = plistlib.load(stream)
            self.assertEqual(result["CFBundleIdentifier"], "com.example.test")
            self.assertEqual(result["CFBundleVersion"], "123")
            self.assertIs(result["Enabled"], True)


if __name__ == "__main__":
    unittest.main()
