#!/usr/bin/env python3
"""Linux replacements for common Xcode plist and xcstrings build steps."""
import argparse
import json
import os
import plistlib
import re

VAR_RE = re.compile(r"\$[({]([A-Za-z0-9_]+)(?::[a-z0-9]+)?[)}]")
STRING_KEYS = {
    "CFBundleVersion",
    "CFBundleShortVersionString",
    "CFBundleInfoDictionaryVersion",
    "MinimumOSVersion",
}


def expand(value, env):
    if isinstance(value, str):
        return VAR_RE.sub(lambda match: env.get(match.group(1), ""), value)
    if isinstance(value, list):
        return [expand(item, env) for item in value]
    if isinstance(value, dict):
        return {key: expand(item, env) for key, item in value.items()}
    return value


def parse_value(key, raw):
    if key in STRING_KEYS:
        return raw
    if raw[:1] in "[{" or raw in ("true", "false") or re.fullmatch(r"-?\d+", raw):
        return json.loads(raw)
    return raw


def plist_command(args):
    env = dict(os.environ)
    for assignment in args.var or []:
        key, _, value = assignment.partition("=")
        env[key] = value
    data = {}
    if args.input:
        with open(args.input, "rb") as stream:
            data = plistlib.load(stream)
    for assignment in args.default or []:
        key, _, value = assignment.partition("=")
        data.setdefault(key, parse_value(key, value))
    for assignment in args.set or []:
        key, _, value = assignment.partition("=")
        data[key] = parse_value(key, value)
    for key in args.delete or []:
        data.pop(key, None)
    data = expand(data, env)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "wb") as stream:
        plistlib.dump(data, stream, fmt=plistlib.FMT_XML, sort_keys=True)


def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def plural_dict(variations, specifier="lld"):
    result = {
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
        "NSStringFormatValueTypeKey": specifier,
    }
    for category, entry in variations.get("plural", {}).items():
        result[category] = entry["stringUnit"]["value"].replace("%arg", "%" + specifier)
    return result


def xcstrings_command(args):
    with open(args.input, encoding="utf-8") as stream:
        catalog = json.load(stream)
    source_language = catalog.get("sourceLanguage", "en")
    strings = {}
    plurals = {}
    for key, entry in catalog["strings"].items():
        localizations = entry.get("localizations", {})
        if source_language not in localizations and entry.get("shouldTranslate", True):
            strings.setdefault(source_language, {})[key] = key
        for language, localization in localizations.items():
            if "variations" in localization and "plural" in localization["variations"]:
                other = localization["variations"]["plural"].get("other", {}).get("stringUnit", {}).get("value", key)
                match = re.search(r"%(?:\d+\$)?(l{0,2}[dui@fs])", other)
                specifier = match.group(1) if match else "lld"
                plurals.setdefault(language, {})[key] = {
                    "NSStringLocalizedFormatKey": "%#@value@",
                    "value": plural_dict(localization["variations"], specifier),
                }
                strings.setdefault(language, {})[key] = other
            elif "stringUnit" in localization:
                strings.setdefault(language, {})[key] = localization["stringUnit"]["value"]
    for language, table in strings.items():
        directory = os.path.join(args.outdir, language + ".lproj")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "Localizable.strings"), "w", encoding="utf-8") as stream:
            for key in sorted(table):
                stream.write('"%s" = "%s";\n' % (escape(key), escape(table[key])))
    for language, table in plurals.items():
        directory = os.path.join(args.outdir, language + ".lproj")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "Localizable.stringsdict"), "wb") as stream:
            plistlib.dump(table, stream, fmt=plistlib.FMT_XML)


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    plist_parser = subparsers.add_parser("plist")
    plist_parser.add_argument("-i", "--input")
    plist_parser.add_argument("-o", "--output", required=True)
    plist_parser.add_argument("--var", action="append")
    plist_parser.add_argument("--default", action="append")
    plist_parser.add_argument("--set", action="append")
    plist_parser.add_argument("--delete", action="append")
    plist_parser.set_defaults(function=plist_command)
    strings_parser = subparsers.add_parser("xcstrings")
    strings_parser.add_argument("input")
    strings_parser.add_argument("outdir")
    strings_parser.set_defaults(function=xcstrings_command)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
