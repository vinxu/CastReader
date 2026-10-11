#!/usr/bin/env python3
"""Audit every current localized store field after a metadata rejection.

Historical reports are intentionally excluded; pass the actual candidate copy
and the pending ASC snapshots so a clean What's New cannot hide a description.
"""
import argparse
import json
from pathlib import Path
import re
import sys

CATALOG = json.loads((Path(__file__).resolve().parent.parent / "docs/aso/search-localizations.json").read_text())
DESCRIPTIONS = json.loads((Path(__file__).resolve().parent.parent / "docs/aso/ios-description-localizations.json").read_text())
LOCALES = set(CATALOG["localizations"])
FIELDS = ("name", "subtitle", "promotionalText", "keywords", "description", "whatsNew")
LIMITS = dict(name=30, subtitle=30, promotionalText=170, description=4000, whatsNew=4000)
REJECTED = re.compile(r"google[\s\-]*play|play[\s\-]*books|play\.google\.com|谷歌\s*(?:图书|圖書|商店)", re.I)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--whats-new", type=Path)
    parser.add_argument("--version-localizations", type=Path)
    parser.add_argument("--app-info-localizations", type=Path)
    parser.add_argument("--review-notes", type=Path)
    parser.add_argument("--platform", choices=("IOS", "MAC_OS"), default="IOS")
    parser.add_argument("--allow-empty-whats-new", action="store_true", help="Metadata draft audit only; never use for submission preflight")
    args = parser.parse_args()
    if not any((args.metadata, args.whats_new, args.version_localizations, args.app_info_localizations, args.review_notes)):
        parser.error("Provide current candidate copy or pending ASC snapshots")
    errors, checked = [], []

    def check(source, locale, field, value):
        if value is None and field in ("promotionalText", "subtitle"):
            value = ""
        if value is None and field == "whatsNew" and args.allow_empty_whats_new:
            value = ""
        if not isinstance(value, str):
            errors.append(f"{source}: {locale}/{field}: missing or non-string")
            return
        if REJECTED.search(value):
            errors.append(f"{source}: {locale}/{field}: rejected platform reference")
        if field in LIMITS and len(value) > LIMITS[field]:
            errors.append(f"{source}: {locale}/{field}: exceeds character limit")
        if field == "keywords" and len(value.encode("utf-8")) > 100:
            errors.append(f"{source}: {locale}/{field}: exceeds 100 UTF-8 bytes")
        if locale in LOCALES and field in ("name", "subtitle", "keywords"):
            if value != CATALOG["localizations"][locale][field]:
                errors.append(f"{source}: {locale}/{field}: differs from current ASO catalog")
        if locale in LOCALES and field == "description" and args.platform == "IOS":
            if value != DESCRIPTIONS["localizations"][locale]["description"]:
                errors.append(f"{source}: {locale}/description: differs from reviewed iOS description")
        checked.append(f"{source}:{locale}/{field}")

    def locales(source, values):
        if len(values) != len(LOCALES) or set(values) != LOCALES:
            errors.append(f"{source}: expected exactly {len(LOCALES)} supported locales; missing={sorted(LOCALES-set(values))}, unexpected={sorted(set(values)-LOCALES)}")

    if args.metadata:
        sections = re.findall(r"^## .*?— `([^`]+)`\n(.*?)(?=^## |\Z)", args.metadata.read_text(), re.M | re.S)
        locales("metadata", [locale for locale, _ in sections])
        for locale, section in sections:
            blocks = re.findall(r"```text\n(.*?)\n```", section, re.S)
            if len(blocks) != 6:
                errors.append(f"metadata: {locale}: expected 6 fields")
                continue
            for field, value in zip(FIELDS, blocks):
                check("metadata", locale, field, value.strip())
    if args.whats_new:
        values = json.loads(args.whats_new.read_text())
        locales("whats-new", list(values))
        for locale, value in values.items():
            check("whats-new", locale, "whatsNew", value)
    for source, path, fields in (
        ("ASC-version", args.version_localizations, FIELDS[2:]),
        ("ASC-app-info", args.app_info_localizations, FIELDS[:2]),
    ):
        if path:
            items = json.loads(path.read_text())
            locales(source, [x["attributes"]["locale"] for x in items])
            for item in items:
                for field in fields:
                    check(source, item["attributes"]["locale"], field, item["attributes"].get(field))
    if args.review_notes:
        notes = json.loads(args.review_notes.read_text())
        check("review-notes", "shared", "notes", notes["notes"])
    print(json.dumps({"passed": not errors, "checkedFields": len(checked), "draftOnly": args.allow_empty_whats_new, "errors": errors}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
