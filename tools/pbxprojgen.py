#!/usr/bin/env python3
"""Generate a deterministic single-target iOS Xcode project from JSON."""

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

SOURCE_EXTENSIONS = {".c", ".cc", ".cpp", ".cxx", ".m", ".mm", ".swift", ".s", ".S", ".metal"}
PACKAGE_EXTENSIONS = {".xcassets", ".bundle", ".framework", ".xcdatamodeld", ".mlmodelc"}
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$")
VERSION_RE = re.compile(r"^\d+(?:\.\d+){0,2}$")
FRAMEWORK_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.framework)?$")
FILE_TYPES = {
    ".c": "sourcecode.c.c",
    ".cc": "sourcecode.cpp.cpp",
    ".cpp": "sourcecode.cpp.cpp",
    ".cxx": "sourcecode.cpp.cpp",
    ".h": "sourcecode.c.h",
    ".hpp": "sourcecode.cpp.h",
    ".m": "sourcecode.c.objc",
    ".mm": "sourcecode.cpp.objcpp",
    ".swift": "sourcecode.swift",
    ".s": "sourcecode.asm",
    ".S": "sourcecode.asm",
    ".plist": "text.plist.xml",
    ".json": "text.json",
    ".xcassets": "folder.assetcatalog",
    ".xcstrings": "text.json.xcstrings",
    ".storyboard": "file.storyboard",
    ".xib": "file.xib",
    ".strings": "text.plist.strings",
    ".stringsdict": "text.plist.stringsdict",
    ".metal": "sourcecode.metal",
}
BARE_VALUE = re.compile(r"^[A-Za-z0-9_./+\-]+$")


def object_id(kind, key):
    return hashlib.sha1(f"pbxprojgen:{kind}:{key}".encode()).hexdigest()[:24].upper()


def reject_control_characters(value, label):
    if any(ord(character) < 32 for character in str(value)):
        raise ValueError(f"{label} contains control characters")


def quote(value):
    value = str(value)
    reject_control_characters(value, "OpenStep value")
    if BARE_VALUE.fullmatch(value) and value not in {"YES", "NO"}:
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def safe_comment(value):
    return str(value).replace("*/", "* /").replace("\r", " ").replace("\n", " ")


def xml_attribute(value):
    reject_control_characters(value, "XML attribute")
    return xml_escape(str(value), {'"': "&quot;"})


def file_type(path):
    if path.suffix == ".xcassets":
        return FILE_TYPES[".xcassets"]
    if path.suffix == ".bundle":
        return "wrapper.plug-in"
    if path.suffix == ".framework":
        return "wrapper.framework"
    if path.suffix == ".xcdatamodeld":
        return "wrapper.xcdatamodel"
    if path.suffix == ".mlmodelc":
        return "folder.mlmodelc"
    return FILE_TYPES.get(path.suffix, "file")


def reject_symlinks_below(path, root, label="symlinks are not allowed"):
    if path.is_symlink():
        raise ValueError(f"{label}: {path.relative_to(root)}")
    if not path.is_dir():
        return
    for entry in os.scandir(path):
        child = Path(entry.path)
        if entry.is_symlink():
            raise ValueError(f"{label}: {child.relative_to(root)}")
        if entry.is_dir(follow_symlinks=False):
            reject_symlinks_below(child, root, label)


def reject_symlink_components(root, relative, label="symlinks are not allowed"):
    current = root
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"{label}: {current.relative_to(root)}")


def walk_entry(path, root):
    if path.is_symlink():
        raise ValueError(f"symlinks are not allowed: {path.relative_to(root)}")
    if path.suffix == ".xcodeproj":
        return
    if path.suffix in PACKAGE_EXTENSIONS:
        reject_symlinks_below(path, root)
        yield path
        return
    if path.is_file():
        yield path
        return
    for child in sorted(path.iterdir(), key=lambda item: item.name):
        if child.name.startswith("."):
            continue
        yield from walk_entry(child, root)


def validate_relative_path(value, label):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty relative path")
    reject_control_characters(value, label)
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"{label} must stay within the manifest directory: {value}")
    return value


def validate_string_list(value, label, allow_empty=True):
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise ValueError(f"{label} must be an array of strings")
    if not allow_empty and not value:
        raise ValueError(f"{label} must not be empty")
    return value


def validate_version_value(value, label):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise ValueError(f"{label} must be a numeric version string")
    text = str(value)
    if not VERSION_RE.fullmatch(text):
        raise ValueError(f"{label} must be a numeric version string")
    return text


def discover(root, entries, label):
    found = []
    for entry in entries:
        validate_relative_path(entry, f"{label} path")
        reject_symlink_components(root, entry)
        path = root / entry
        if not path.exists():
            raise ValueError(f"{label} path does not exist: {entry}")
        found.extend(walk_entry(path, root))
    return sorted(set(found), key=lambda item: item.relative_to(root).as_posix())


def setting_lines(settings, indent="\t\t\t\t"):
    lines = ["{"]
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f"{indent}{key} = (")
            lines.extend(f"{indent}\t{quote(item)}," for item in value)
            lines.append(f"{indent});")
        else:
            lines.append(f"{indent}{key} = {quote(value)};")
    lines.append(indent[:-1] + "}")
    return "\n".join(lines)


class ProjectGenerator:
    def __init__(self, manifest_path, manifest, output):
        self.manifest_path = manifest_path
        self.root = manifest_path.parent.resolve()
        self.output = output.parent.resolve() / output.name
        self.project_base = self.output.parent
        self.manifest = manifest
        self.name = self.required("name")
        if not NAME_RE.fullmatch(self.name) or self.name in {".", ".."}:
            raise ValueError("invalid project name; use letters, numbers, dot, underscore, or hyphen")
        self.bundle_id = self.required("bundleIdentifier")
        if not BUNDLE_ID_RE.fullmatch(self.bundle_id):
            raise ValueError("invalid bundleIdentifier")
        self.deployment_target = validate_version_value(manifest.get("deploymentTarget", "16.0"), "deploymentTarget")
        self.marketing_version = validate_version_value(manifest.get("version", "1.0"), "version")
        self.build_number = validate_version_value(manifest.get("buildNumber", "1"), "buildNumber")
        self.swift_version = validate_version_value(manifest.get("swiftVersion", "5.0"), "swiftVersion")
        self.device_family = manifest.get("deviceFamily", "1,2")
        if not isinstance(self.device_family, str) or not re.fullmatch(r"\d+(?:,\d+)*", self.device_family):
            raise ValueError("deviceFamily must be a comma-separated list of integers")
        self.app_icon = manifest.get("appIcon", "AppIcon")
        if not isinstance(self.app_icon, str) or not NAME_RE.fullmatch(self.app_icon):
            raise ValueError("appIcon must be a simple asset name")
        self.info_plist = validate_relative_path(manifest.get("infoPlist", "Info.plist"), "infoPlist")
        self.entitlements = manifest.get("entitlements")
        if self.entitlements is not None:
            self.entitlements = validate_relative_path(self.entitlements, "entitlements")
        self.frameworks = validate_string_list(manifest.get("frameworks", ["UIKit", "Foundation"]), "frameworks")
        if not all(FRAMEWORK_RE.fullmatch(item) for item in self.frameworks):
            raise ValueError("framework names must be simple SDK framework names")
        source_entries = validate_string_list(manifest.get("sources", ["Sources"]), "sources", allow_empty=False)
        resource_entries = validate_string_list(manifest.get("resources", []), "resources")
        self.sources = discover(self.root, source_entries, "source")
        self.resources = discover(self.root, resource_entries, "resource")
        if self.output.suffix != ".xcodeproj":
            raise ValueError("output must end in .xcodeproj")
        reject_symlink_components(self.root, self.info_plist)
        info_path = self.root / self.info_plist
        if info_path.is_symlink():
            raise ValueError(f"symlinks are not allowed: {self.info_plist}")
        if not info_path.is_file():
            raise ValueError(f"Info.plist does not exist: {self.info_plist}")
        if self.entitlements:
            reject_symlink_components(self.root, self.entitlements)
            entitlements_path = self.root / self.entitlements
            if entitlements_path.is_symlink():
                raise ValueError(f"symlinks are not allowed: {self.entitlements}")
            if not entitlements_path.is_file():
                raise ValueError(f"entitlements file does not exist: {self.entitlements}")
        self.objects = {}
        self.comments = {}
        self.target_id = object_id("target", self.name)
        self.project_id = object_id("project", self.name)

    def required(self, key):
        value = self.manifest.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"manifest requires non-empty string: {key}")
        reject_control_characters(value, key)
        return value

    def add(self, section, key, comment, body):
        oid = object_id(section, key)
        comment = safe_comment(comment)
        self.objects.setdefault(section, []).append((oid, comment, body))
        self.comments[oid] = comment
        return oid

    def ref(self, oid):
        comment = self.comments.get(oid)
        return f"{oid} /* {comment} */" if comment else oid

    def project_relative(self, path):
        return Path(os.path.relpath(path, self.project_base)).as_posix()

    def make_file_reference(self, path, group_name):
        relative = self.project_relative(path)
        comment = path.name
        body = (
            "{isa = PBXFileReference; "
            f"lastKnownFileType = {file_type(path)}; path = {quote(relative)}; sourceTree = \"<group>\"; }}"
        )
        return self.add("PBXFileReference", f"{group_name}:{relative}", comment, body)

    def make_build_file(self, file_id, phase):
        filename = self.comments[file_id]
        comment = f"{filename} in {phase}"
        body = f"{{isa = PBXBuildFile; fileRef = {self.ref(file_id)}; }}"
        return self.add("PBXBuildFile", f"{phase}:{file_id}", comment, body)

    def generate(self):
        source_refs = []
        source_builds = []
        for path in self.sources:
            ref = self.make_file_reference(path, "Sources")
            source_refs.append(ref)
            if path.suffix in SOURCE_EXTENSIONS:
                source_builds.append(self.make_build_file(ref, "Sources"))

        resource_refs = []
        resource_builds = []
        for path in self.resources:
            ref = self.make_file_reference(path, "Resources")
            resource_refs.append(ref)
            resource_builds.append(self.make_build_file(ref, "Resources"))

        info_ref = self.make_file_reference(self.root / self.info_plist, "Project")
        extra_refs = [info_ref]
        if self.entitlements:
            extra_refs.append(self.make_file_reference(self.root / self.entitlements, "Project"))

        framework_refs = []
        framework_builds = []
        normalized_frameworks = {
            framework if framework.endswith(".framework") else framework + ".framework"
            for framework in self.frameworks
        }
        for name in sorted(normalized_frameworks):
            body = (
                "{isa = PBXFileReference; lastKnownFileType = wrapper.framework; "
                f"name = {quote(name)}; path = {quote('System/Library/Frameworks/' + name)}; sourceTree = SDKROOT; }}"
            )
            ref = self.add("PBXFileReference", f"framework:{name}", name, body)
            framework_refs.append(ref)
            framework_builds.append(self.make_build_file(ref, "Frameworks"))

        product_ref = self.add(
            "PBXFileReference",
            f"product:{self.name}",
            f"{self.name}.app",
            "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
            f"path = {quote(self.name + '.app')}; sourceTree = BUILT_PRODUCTS_DIR; }}",
        )

        source_group = self.group("Sources", source_refs)
        resource_group = self.group("Resources", resource_refs) if resource_refs else None
        framework_group = self.group("Frameworks", framework_refs)
        products_group = self.group("Products", [product_ref])
        main_children = [source_group]
        if resource_group:
            main_children.append(resource_group)
        main_children.extend(extra_refs)
        main_children.extend([framework_group, products_group])
        main_group = self.group(self.name, main_children, key="main")

        sources_phase = self.phase("PBXSourcesBuildPhase", "Sources", source_builds)
        resources_phase = self.phase("PBXResourcesBuildPhase", "Resources", resource_builds)
        frameworks_phase = self.phase("PBXFrameworksBuildPhase", "Frameworks", framework_builds)

        project_configs = self.configuration_list("project", self.project_build_settings())
        target_configs = self.configuration_list("target", self.target_build_settings())

        target_body = "\n".join([
            "{",
            "\t\t\tisa = PBXNativeTarget;",
            f"\t\t\tbuildConfigurationList = {self.ref(target_configs)};",
            "\t\t\tbuildPhases = (",
            f"\t\t\t\t{self.ref(sources_phase)},",
            f"\t\t\t\t{self.ref(frameworks_phase)},",
            f"\t\t\t\t{self.ref(resources_phase)},",
            "\t\t\t);",
            "\t\t\tbuildRules = ();",
            "\t\t\tdependencies = ();",
            f"\t\t\tname = {quote(self.name)};",
            f"\t\t\tproductName = {quote(self.name)};",
            f"\t\t\tproductReference = {self.ref(product_ref)};",
            "\t\t\tproductType = \"com.apple.product-type.application\";",
            "\t\t}",
        ])
        self.objects.setdefault("PBXNativeTarget", []).append((self.target_id, self.name, target_body))
        self.comments[self.target_id] = self.name

        project_body = "\n".join([
            "{",
            "\t\t\tisa = PBXProject;",
            "\t\t\tattributes = {",
            "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
            "\t\t\t\tLastSwiftUpdateCheck = 1600;",
            "\t\t\t\tLastUpgradeCheck = 1600;",
            "\t\t\t};",
            f"\t\t\tbuildConfigurationList = {self.ref(project_configs)};",
            "\t\t\tcompatibilityVersion = \"Xcode 14.0\";",
            "\t\t\tdevelopmentRegion = en;",
            "\t\t\thasScannedForEncodings = 0;",
            "\t\t\tknownRegions = (en, Base);",
            f"\t\t\tmainGroup = {self.ref(main_group)};",
            f"\t\t\tproductRefGroup = {self.ref(products_group)};",
            "\t\t\tprojectDirPath = \"\";",
            "\t\t\tprojectRoot = \"\";",
            "\t\t\ttargets = (",
            f"\t\t\t\t{self.target_id} /* {self.name} */ ,",
            "\t\t\t);",
            "\t\t}",
        ])
        self.objects.setdefault("PBXProject", []).append((self.project_id, "Project object", project_body))
        self.comments[self.project_id] = "Project object"
        return self.render()

    def group(self, name, children, key=None):
        lines = ["{", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
        lines.extend(f"\t\t\t\t{self.ref(child)}," for child in children)
        lines.extend(["\t\t\t);", f"\t\t\tname = {quote(name)};", "\t\t\tsourceTree = \"<group>\";", "\t\t}"])
        return self.add("PBXGroup", key or name, name, "\n".join(lines))

    def phase(self, section, name, files):
        lines = ["{", f"\t\t\tisa = {section};", "\t\t\tbuildActionMask = 2147483647;", "\t\t\tfiles = ("]
        lines.extend(f"\t\t\t\t{self.ref(build_file)}," for build_file in files)
        lines.extend(["\t\t\t);", "\t\t\trunOnlyForDeploymentPostprocessing = 0;", "\t\t}"])
        return self.add(section, name, name, "\n".join(lines))

    def project_build_settings(self):
        common = {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": self.deployment_target,
            "SDKROOT": "iphoneos",
        }
        return {
            "Debug": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "ONLY_ACTIVE_ARCH": "YES"},
            "Release": {**common, "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"},
        }

    def target_build_settings(self):
        common = {
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": self.build_number,
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": self.project_relative(self.root / self.info_plist),
            "IPHONEOS_DEPLOYMENT_TARGET": self.deployment_target,
            "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
            "MARKETING_VERSION": self.marketing_version,
            "PRODUCT_BUNDLE_IDENTIFIER": self.bundle_id,
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
            "SUPPORTS_MACCATALYST": "NO",
            "SWIFT_VERSION": self.swift_version,
            "TARGETED_DEVICE_FAMILY": self.device_family,
        }
        if any(path.suffix == ".xcassets" for path in self.resources):
            common["ASSETCATALOG_COMPILER_APPICON_NAME"] = self.app_icon
        if self.entitlements:
            common["CODE_SIGN_ENTITLEMENTS"] = self.project_relative(self.root / self.entitlements)
        return {
            "Debug": {**common, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"},
            "Release": {**common, "SWIFT_OPTIMIZATION_LEVEL": "-O"},
        }

    def configuration_list(self, owner, configurations):
        config_ids = []
        for name, settings in configurations.items():
            body = "\n".join([
                "{",
                "\t\t\tisa = XCBuildConfiguration;",
                "\t\t\tbuildSettings = " + setting_lines(settings) + ";",
                f"\t\t\tname = {name};",
                "\t\t}",
            ])
            config_ids.append(self.add("XCBuildConfiguration", f"{owner}:{name}", name, body))
        comment = f"Build configuration list for {owner} \"{self.name}\""
        lines = ["{", "\t\t\tisa = XCConfigurationList;", "\t\t\tbuildConfigurations = ("]
        lines.extend(f"\t\t\t\t{self.ref(config_id)}," for config_id in config_ids)
        lines.extend(["\t\t\t);", "\t\t\tdefaultConfigurationIsVisible = 0;", "\t\t\tdefaultConfigurationName = Release;", "\t\t}"])
        return self.add("XCConfigurationList", owner, comment, "\n".join(lines))

    def render(self):
        order = [
            "PBXBuildFile", "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup",
            "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase",
            "XCBuildConfiguration", "XCConfigurationList",
        ]
        lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {};", "\tobjectVersion = 56;", "\tobjects = {", ""]
        for section in order:
            objects = self.objects.get(section, [])
            if not objects:
                continue
            lines.append(f"/* Begin {section} section */")
            for oid, comment, body in sorted(objects, key=lambda item: (item[1], item[0])):
                lines.append(f"\t\t{oid} /* {comment} */ = {body};")
            lines.extend([f"/* End {section} section */", ""])
        lines.extend(["\t};", f"\trootObject = {self.project_id} /* Project object */;", "}", ""])
        return "\n".join(lines)

    def scheme(self):
        name = xml_attribute(self.name)
        app_name = xml_attribute(self.name + ".app")
        container = xml_attribute(self.output.name)
        return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{self.target_id}" BuildableName="{app_name}" BlueprintName="{name}" ReferencedContainer="container:{container}"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{self.target_id}" BuildableName="{app_name}" BlueprintName="{name}" ReferencedContainer="container:{container}"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{self.target_id}" BuildableName="{app_name}" BlueprintName="{name}" ReferencedContainer="container:{container}"/>
    </BuildableProductRunnable>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_or_create_directory(path):
    if not path.is_absolute():
        raise ValueError("output parent must be absolute")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in path.parts[1:]:
            try:
                os.mkdir(part, mode=0o755, dir_fd=descriptor)
            except FileExistsError:
                pass
            next_descriptor = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def remove_entry_at(parent_descriptor, name):
    try:
        entry_stat = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(entry_stat.st_mode):
        os.unlink(name, dir_fd=parent_descriptor)
        return
    child_descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_descriptor)
    try:
        for child in os.listdir(child_descriptor):
            remove_entry_at(child_descriptor, child)
    finally:
        os.close(child_descriptor)
    os.rmdir(name, dir_fd=parent_descriptor)


def make_directory_at(parent_descriptor, name):
    os.mkdir(name, mode=0o755, dir_fd=parent_descriptor)
    return os.open(name, DIRECTORY_FLAGS, dir_fd=parent_descriptor)


def write_text_at(parent_descriptor, name, content):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(name, flags, 0o644, dir_fd=parent_descriptor)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(content)


def publish_project(generator, output, before_publish=None):
    output = output.parent.resolve() / output.name
    parent_descriptor = open_or_create_directory(output.parent)
    temporary_name = f".{output.name}.tmp-{secrets.token_hex(12)}"
    temporary_descriptor = None
    published = False
    try:
        os.mkdir(temporary_name, mode=0o700, dir_fd=parent_descriptor)
        temporary_descriptor = os.open(temporary_name, DIRECTORY_FLAGS, dir_fd=parent_descriptor)
        write_text_at(temporary_descriptor, "project.pbxproj", generator.generate())
        shared_descriptor = make_directory_at(temporary_descriptor, "xcshareddata")
        try:
            schemes_descriptor = make_directory_at(shared_descriptor, "xcschemes")
            try:
                write_text_at(schemes_descriptor, f"{generator.name}.xcscheme", generator.scheme())
            finally:
                os.close(schemes_descriptor)
        finally:
            os.close(shared_descriptor)
        os.close(temporary_descriptor)
        temporary_descriptor = None
        if before_publish:
            before_publish()
        remove_entry_at(parent_descriptor, output.name)
        os.rename(temporary_name, output.name, src_dir_fd=parent_descriptor, dst_dir_fd=parent_descriptor)
        published = True
    finally:
        if temporary_descriptor is not None:
            os.close(temporary_descriptor)
        if not published:
            remove_entry_at(parent_descriptor, temporary_name)
        os.close(parent_descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        with args.manifest.open(encoding="utf-8") as stream:
            manifest = json.load(stream)
        if not isinstance(manifest, dict):
            raise ValueError("manifest must be a JSON object")
        name = manifest.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError("manifest requires non-empty string: name")
        requested_output = args.output or (args.manifest.parent / f"{name}.xcodeproj")
        if requested_output.is_symlink():
            raise ValueError(f"output may not be a symlink: {requested_output}")
        reject_control_characters(requested_output.name, "output filename")
        output = requested_output.parent.resolve() / requested_output.name
        if output.exists():
            if not output.is_dir():
                raise ValueError(f"output exists and is not a directory: {output}")
            reject_symlinks_below(output, output, "output contains a symlink")
        generator = ProjectGenerator(args.manifest.resolve(), manifest, output)
        publish_project(generator, output)
        print(output)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
