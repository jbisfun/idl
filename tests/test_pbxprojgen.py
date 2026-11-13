import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "pbxprojgen.py"


class PBXProjGeneratorTests(unittest.TestCase):
    def make_project(self, directory: Path):
        (directory / "Sources" / "Support").mkdir(parents=True)
        (directory / "Resources").mkdir()
        (directory / "Sources" / "main.swift").write_text("import UIKit\n", encoding="utf-8")
        (directory / "Sources" / "Support" / "Helper.m").write_text("#import <Foundation/Foundation.h>\n", encoding="utf-8")
        (directory / "Sources" / "Support" / "Helper.h").write_text("void helper(void);\n", encoding="utf-8")
        (directory / "Resources" / "data.json").write_text("{}\n", encoding="utf-8")
        (directory / "Info.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")
        manifest = {
            "name": "GeneratedApp",
            "bundleIdentifier": "com.example.generated",
            "deploymentTarget": "16.0",
            "sources": ["Sources"],
            "resources": ["Resources"],
            "infoPlist": "Info.plist",
            "frameworks": ["UIKit", "Foundation"],
        }
        manifest_path = directory / "project.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        return manifest_path

    def test_generates_deterministic_project_with_sources_resources_and_frameworks(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            output = directory / "GeneratedApp.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            first = (output / "project.pbxproj").read_text(encoding="utf-8")
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            second = (output / "project.pbxproj").read_text(encoding="utf-8")

            self.assertEqual(first, second)
            self.assertIn("isa = PBXProject;", first)
            self.assertIn("productType = \"com.apple.product-type.application\";", first)
            self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.example.generated;", first)
            self.assertIn("IPHONEOS_DEPLOYMENT_TARGET = 16.0;", first)
            self.assertIn("main.swift in Sources", first)
            self.assertIn("Helper.m in Sources", first)
            self.assertNotIn("Helper.h in Sources", first)
            self.assertIn("data.json in Resources", first)
            self.assertIn("UIKit.framework in Frameworks", first)
            self.assertIn("Foundation.framework in Frameworks", first)
            self.assertNotIn("ASSETCATALOG_COMPILER_APPICON_NAME", first)
            self.assertIn('"$(inherited)",', first)
            self.assertIn('PRODUCT_NAME = "$(TARGET_NAME)";', first)

    def test_custom_output_uses_paths_relative_to_output_and_matching_scheme_container(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "app"
            directory.mkdir()
            manifest = self.make_project(directory)
            output = Path(temporary) / "generated" / "DifferentName.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            project = (output / "project.pbxproj").read_text(encoding="utf-8")
            scheme = (output / "xcshareddata" / "xcschemes" / "GeneratedApp.xcscheme").read_text(encoding="utf-8")
            self.assertIn("../app/Sources/main.swift", project)
            self.assertIn("INFOPLIST_FILE = ../app/Info.plist;", project)
            self.assertIn('ReferencedContainer="container:DifferentName.xcodeproj"', scheme)

    def test_normalizes_framework_names_before_deduplicating(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["frameworks"] = ["UIKit", "UIKit.framework"]
            manifest.write_text(json.dumps(data), encoding="utf-8")
            output = directory / "GeneratedApp.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            text = (output / "project.pbxproj").read_text(encoding="utf-8")
            self.assertEqual(text.count("UIKit.framework in Frameworks */ ="), 1)
            self.assertEqual(text.count("/* UIKit.framework */ = {isa = PBXFileReference"), 1)

    def test_writes_shared_scheme(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            output = directory / "GeneratedApp.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            scheme = output / "xcshareddata" / "xcschemes" / "GeneratedApp.xcscheme"
            text = scheme.read_text(encoding="utf-8")
            self.assertIn('BlueprintName="GeneratedApp"', text)
            self.assertIn('BuildableName="GeneratedApp.app"', text)

    def test_treats_asset_catalog_as_one_resource(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "Sources").mkdir()
            (directory / "Sources" / "main.swift").write_text("import UIKit\n", encoding="utf-8")
            catalog = directory / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
            catalog.mkdir(parents=True)
            (catalog / "Contents.json").write_text("{}\n", encoding="utf-8")
            (directory / "Info.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")
            manifest = directory / "project.json"
            manifest.write_text(json.dumps({
                "name": "AssetsApp",
                "bundleIdentifier": "com.example.assets",
                "sources": ["Sources"],
                "resources": ["Resources"],
                "infoPlist": "Info.plist",
            }), encoding="utf-8")
            output = directory / "AssetsApp.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            text = (output / "project.pbxproj").read_text(encoding="utf-8")
            self.assertIn("Assets.xcassets in Resources", text)
            self.assertNotIn("Contents.json in Resources", text)

    def test_rejects_invalid_manifest_shapes_and_unsafe_names(self):
        cases = [
            (["not", "an", "object"], "manifest must be a JSON object"),
            ({"name": "../Escape", "bundleIdentifier": "com.example.escape", "sources": ["Sources"], "infoPlist": "Info.plist"}, "invalid project name"),
            ({"name": "Bad", "bundleIdentifier": "not a bundle id!", "sources": ["Sources"], "infoPlist": "Info.plist"}, "invalid bundleIdentifier"),
            ({"name": "Bad", "bundleIdentifier": "com.example.bad", "sources": "Sources", "infoPlist": "Info.plist"}, "sources must be an array of strings"),
            ({"name": "Bad", "bundleIdentifier": "com.example.bad", "sources": ["Sources"], "infoPlist": "Info.plist", "frameworks": "UIKit"}, "frameworks must be an array of strings"),
        ]
        for data, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / "Sources").mkdir()
                (directory / "Info.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")
                manifest = directory / "project.json"
                manifest.write_text(json.dumps(data), encoding="utf-8")
                result = subprocess.run(["python3", str(TOOL), str(manifest)], text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_rejects_symlinks_in_scanned_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            (directory / "Sources" / "linked.swift").symlink_to(directory / "Sources" / "main.swift")
            result = subprocess.run(["python3", str(TOOL), str(manifest)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinks are not allowed", result.stderr)

    def test_rejects_symlinked_ancestors_and_package_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            outside = directory / "outside"
            outside.mkdir()
            (outside / "main.swift").write_text("import UIKit\n", encoding="utf-8")
            (directory / "Alias").symlink_to(outside, target_is_directory=True)
            (directory / "Info.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")
            manifest = directory / "project.json"
            manifest.write_text(json.dumps({
                "name": "AliasApp", "bundleIdentifier": "com.example.alias",
                "sources": ["Alias"], "infoPlist": "Info.plist",
            }), encoding="utf-8")
            result = subprocess.run(["python3", str(TOOL), str(manifest)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinks are not allowed", result.stderr)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            catalog = directory / "Resources" / "Assets.xcassets"
            catalog.mkdir()
            (catalog / "linked.json").symlink_to(directory / "Resources" / "data.json")
            result = subprocess.run(["python3", str(TOOL), str(manifest)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinks are not allowed", result.stderr)

    def test_rejects_symlinked_output_files_and_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            output = directory / "GeneratedApp.xcodeproj"
            output.mkdir()
            external = directory / "external.pbxproj"
            external.write_text("unchanged", encoding="utf-8")
            (output / "project.pbxproj").symlink_to(external)
            result = subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("output contains a symlink", result.stderr)
            self.assertEqual(external.read_text(encoding="utf-8"), "unchanged")

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            output = directory / "GeneratedApp.xcodeproj"
            external = directory / "external-schemes"
            external.mkdir()
            (external / "Keep.xcscheme").write_text("unchanged", encoding="utf-8")
            (output / "xcshareddata").mkdir(parents=True)
            (output / "xcshareddata" / "xcschemes").symlink_to(external, target_is_directory=True)
            result = subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("output contains a symlink", result.stderr)
            self.assertTrue((external / "Keep.xcscheme").exists())

    def test_atomic_publisher_does_not_follow_symlink_swapped_in_before_publish(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest_path = self.make_project(directory)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            output = directory / "GeneratedApp.xcodeproj"
            external = directory / "external"
            external.mkdir()
            marker = external / "marker"
            marker.write_text("unchanged", encoding="utf-8")

            spec = importlib.util.spec_from_file_location("pbxprojgen", TOOL)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            generator = module.ProjectGenerator(manifest_path.resolve(), manifest, output.resolve())

            def swap_output():
                output.symlink_to(external, target_is_directory=True)

            module.publish_project(generator, output.resolve(), before_publish=swap_output)
            self.assertEqual(marker.read_text(encoding="utf-8"), "unchanged")
            self.assertFalse(output.is_symlink())
            self.assertTrue((output / "project.pbxproj").is_file())

    def test_classifies_assembly_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            (directory / "Sources" / "lower.s").write_text("// assembly\n", encoding="utf-8")
            (directory / "Sources" / "upper.S").write_text("// assembly\n", encoding="utf-8")
            output = directory / "GeneratedApp.xcodeproj"
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            text = (output / "project.pbxproj").read_text(encoding="utf-8")
            self.assertIn("lastKnownFileType = sourcecode.asm; path = Sources/lower.s", text)
            self.assertIn("lastKnownFileType = sourcecode.asm; path = Sources/upper.S", text)
            self.assertIn("lower.s in Sources", text)
            self.assertIn("upper.S in Sources", text)

    def test_compiles_metal_and_skips_generated_xcodeproj_on_rescan(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "main.metal").write_text("kernel void k() {}\n", encoding="utf-8")
            (directory / "Info.plist").write_text("<plist version=\"1.0\"><dict/></plist>\n", encoding="utf-8")
            manifest = directory / "project.json"
            manifest.write_text(json.dumps({
                "name": "RecursiveApp",
                "bundleIdentifier": "com.example.recursive",
                "sources": ["."],
                "infoPlist": "Info.plist",
            }), encoding="utf-8")
            subprocess.run(["python3", str(TOOL), str(manifest)], check=True)
            project = directory / "RecursiveApp.xcodeproj" / "project.pbxproj"
            first = project.read_text(encoding="utf-8")
            subprocess.run(["python3", str(TOOL), str(manifest)], check=True)
            second = project.read_text(encoding="utf-8")
            self.assertEqual(first, second)
            self.assertIn("main.metal in Sources", first)
            self.assertNotIn("project.pbxproj in Sources", first)

    def test_escapes_special_output_name_and_removes_stale_schemes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = self.make_project(directory)
            output = directory / "Generated&Debug.xcodeproj"
            stale = output / "xcshareddata" / "xcschemes" / "Old.xcscheme"
            stale.parent.mkdir(parents=True)
            stale.write_text("stale", encoding="utf-8")
            subprocess.run(["python3", str(TOOL), str(manifest), "--output", str(output)], check=True)
            self.assertFalse(stale.exists())
            scheme = output / "xcshareddata" / "xcschemes" / "GeneratedApp.xcscheme"
            text = scheme.read_text(encoding="utf-8")
            self.assertIn("container:Generated&amp;Debug.xcodeproj", text)
            import xml.etree.ElementTree as ET
            ET.parse(scheme)

    def test_rejects_missing_source_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            manifest = directory / "project.json"
            manifest.write_text(json.dumps({
                "name": "Broken",
                "bundleIdentifier": "com.example.broken",
                "sources": ["Missing"],
                "infoPlist": "Info.plist",
            }), encoding="utf-8")
            result = subprocess.run(
                ["python3", str(TOOL), str(manifest)],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("source path does not exist", result.stderr)


if __name__ == "__main__":
    unittest.main()
