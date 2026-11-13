#!/usr/bin/env python3
"""Perform structural checks on a simple iOS IPA."""
import argparse
import os
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

MACHO_MAGICS = {0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE}


def fail(message):
    raise SystemExit("error: " + message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    parser.add_argument("--bundle-id")
    parser.add_argument("--allow-unsigned", action="store_true")
    args = parser.parse_args()
    with zipfile.ZipFile(args.ipa) as archive:
        bad = archive.testzip()
        if bad:
            fail("ZIP CRC failure: " + bad)
        plists = [name for name in archive.namelist() if name.count("/") == 2 and name.startswith("Payload/") and name.endswith(".app/Info.plist")]
        if len(plists) != 1:
            fail(f"expected one top-level app Info.plist, found {len(plists)}")
        plist_name = plists[0]
        info = plistlib.loads(archive.read(plist_name))
        required = ["CFBundleExecutable", "CFBundleIdentifier", "CFBundlePackageType", "MinimumOSVersion"]
        missing = [key for key in required if not info.get(key)]
        if missing:
            fail("missing plist keys: " + ", ".join(missing))
        if args.bundle_id and info["CFBundleIdentifier"] != args.bundle_id:
            fail(f"bundle ID is {info['CFBundleIdentifier']}, expected {args.bundle_id}")
        executable_name = plist_name.rsplit("/", 1)[0] + "/" + info["CFBundleExecutable"]
        try:
            executable_info = archive.getinfo(executable_name)
            executable = archive.read(executable_name)
        except KeyError:
            fail("missing executable: " + executable_name)
        if len(executable) < 4 or struct.unpack(">I", executable[:4])[0] not in MACHO_MAGICS:
            fail("executable is not a thin Mach-O")
        mode = executable_info.external_attr >> 16
        if not mode & 0o111:
            fail("executable is not marked executable in ZIP")
        objdump = shutil.which("llvm-objdump")
        if objdump:
            with tempfile.TemporaryDirectory() as directory:
                path = os.path.join(directory, info["CFBundleExecutable"])
                with open(path, "wb") as stream:
                    stream.write(executable)
                output = subprocess.check_output([objdump, "--macho", "--private-headers", path], text=True)
                if "LC_MAIN" not in output:
                    fail("Mach-O has no LC_MAIN")
                signed = "LC_CODE_SIGNATURE" in output
                if not signed and not args.allow_unsigned:
                    fail("Mach-O has no LC_CODE_SIGNATURE")
        else:
            signed = None
        print(f"OK: {args.ipa}")
        print(f"  bundle: {info['CFBundleIdentifier']}")
        print(f"  executable: {info['CFBundleExecutable']} ({len(executable)} bytes)")
        print(f"  minimum iOS: {info['MinimumOSVersion']}")
        if signed is not None:
            print("  load commands: LC_MAIN" + (", LC_CODE_SIGNATURE" if signed else " (unsigned)"))


if __name__ == "__main__":
    main()
