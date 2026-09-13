#!/usr/bin/env python3
"""Audit production offline copy, including interpolation and compiled catalogs."""
import argparse
from collections import Counter
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ["zh-Hans", "en", "ja", "es", "fr", "de", "pt-BR", "it", "hi"]
SOURCES = [
    "Views/Kindle/KindleOfflineDownloadView.swift",
    "Views/Kindle/KindleOfflineLibraryScreen.swift",
    "Views/Kindle/KindleOfflineLibraryView.swift",
    "Views/Kindle/KindleOfflineReaderView.swift",
    "Views/Kindle/KindleOfflinePlaybackCenter.swift",
    "Views/Kindle/OfflineDownloadsEntryCard.swift",
    "Views/Kindle/KindleLibraryView.swift",
    "Views/Reader/ReaderMoreButton.swift",
    "Services/KindleOfflineDownloadCoordinator.swift",
    "Services/KindleOfflineOCRService.swift",
    "Services/SystemSpeechPlaybackService.swift",
]
FORMAT = re.compile(r"%(?:\d+\$)?(?:\.\d+)?(lld|ld|d|@|f)")
HAN = re.compile(r"[\u4e00-\u9fff]")


def production(source):
    """Drop DEBUG-only UI and line comments before examining Swift literals."""
    active, stack, lines = True, [], []
    for line in source.splitlines():
        token = line.strip()
        if token == "#if DEBUG":
            stack.append(active)
            active = False
        elif token == "#else" and stack:
            active = stack[-1] and not active
        elif token == "#endif" and stack:
            active = stack.pop()
        elif active and not token.startswith("//"):
            lines.append(line)
    return "\n".join(lines)


def literals(source):
    """Read Swift strings; treat a balanced interpolation as one placeholder."""
    i = 0
    while i < len(source):
        if source[i] != '"':
            i += 1
            continue
        start, value = i, ""
        i += 1
        while i < len(source):
            if source[i:i+2] == "\\(":
                i += 2
                depth = 1
                while i < len(source) and depth:
                    if source[i] == "(": depth += 1
                    elif source[i] == ")": depth -= 1
                    i += 1
                value += "{value}"
            elif source[i] == "\\" and i + 1 < len(source):
                value += {"n": "\n", '"': '"', "\\": "\\"}.get(source[i+1], source[i+1])
                i += 2
            elif source[i] == '"':
                i += 1
                break
            else:
                value += source[i]
                i += 1
        if HAN.search(value):
            yield value, source.count("\n", 0, start) + 1


def units(value):
    if isinstance(value, dict):
        if "stringUnit" in value:
            yield value["stringUnit"]
        for key, child in value.items():
            if key != "stringUnit": yield from units(child)


def audit(app=None):
    catalog = json.loads((ROOT / "CastReader/Localizable.xcstrings").read_text())["strings"]
    normalized = {}
    for key in catalog:
        normalized.setdefault(FORMAT.sub("{value}", key), []).append(key)
    used = {"离线保存整本书"}
    errors = []
    for relative in SOURCES:
        for literal, line in literals(production((ROOT / "CastReader" / relative).read_text())):
            matches = normalized.get(FORMAT.sub("{value}", literal), [])
            if not matches: errors.append(f"Missing key in {relative}:{line}: {literal}")
            used.update(matches)
    for key in sorted(used):
        entry = catalog[key]
        expected = Counter(FORMAT.findall(key))
        for language in LANGUAGES:
            values = list(units(entry.get("localizations", {}).get(language, {})))
            if not values: errors.append(f"Missing translation: {language}: {key}")
            for unit in values:
                text = unit.get("value", "")
                if not text or unit.get("state") != "translated":
                    errors.append(f"Unfinished translation: {language}: {key}")
                if Counter(FORMAT.findall(text)) != expected:
                    errors.append(f"Placeholder mismatch: {language}: {key}")
                if language not in ("zh-Hans", "ja") and HAN.search(text):
                    errors.append(f"Chinese fallback: {language}: {key}")
    if app:
        for language in LANGUAGES:
            path = app / (language + ".lproj") / "Localizable.strings"
            if not path.exists():
                errors.append(f"Missing compiled catalog: {language}")
                continue
            compiled = plistlib.loads(path.read_bytes())
            for key in used:
                if key not in compiled:
                    errors.append(f"Missing compiled key: {language}: {key}")
    return {"languages": LANGUAGES, "sourceFiles": SOURCES, "keysChecked": len(used),
            "keys": sorted(used), "compiledApp": str(app) if app else None,
            "errors": errors, "passed": not errors}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = audit(args.app)
    if args.output: args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("keys", "sourceFiles")}, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result["passed"] else 1)
