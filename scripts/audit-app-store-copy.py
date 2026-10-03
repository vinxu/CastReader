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

LOCALES = set("en-US zh-Hans zh-Hant ja es-ES es-MX fr-FR pt-BR it de-DE hi".split())
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
    args = parser.parse_args()
    if not any(vars(args).values()):
        parser.error("Provide current candidate copy or pending ASC snapshots")
    errors, checked = [], []

    def check(source, locale, field, value):
        if value is None and field in ("promotionalText", "subtitle"):
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
        checked.append(f"{source}:{locale}/{field}")

    def locales(source, values):
        if len(values) != 11 or set(values) != LOCALES:
            errors.append(f"{source}: expected exactly the 11 supported locales")

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
    print(json.dumps({"passed": not errors, "checkedFields": len(checked), "errors": errors}, ensure_ascii=False, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
