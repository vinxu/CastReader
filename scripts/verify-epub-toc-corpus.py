#!/usr/bin/env python3
"""Independent lxml oracle for the Swift parser's complete real-book TOC output."""
import json
import pathlib
import re
import urllib.parse
import zipfile
from lxml import etree

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPORT = ROOT / "reports/epub-toc-20260914"


def tag(el):
    return str(el.tag).split("}")[-1].split(":")[-1].lower()


def compact(text):
    return re.sub(r"\s+", "", text)


def content_index(data):
    # HTML recovery is intentional: several real books contain invalid XHTML
    # entities/markup, which the production SwiftSoup HTML parser also repairs.
    encoding = re.search(br'encoding=["\']([^"\']+)', data[:200])
    charset = encoding.group(1).decode("ascii") if encoding else "utf-8"
    root = etree.fromstring(data, etree.HTMLParser(no_network=True, encoding=charset))
    chunks, anchors = [], {}

    def visit(el):
        if not isinstance(el.tag, str):
            return
        name = tag(el)
        sem = el.get("epub:type", "").split()
        classes = set(el.get("class", "").split())
        if name in {"head", "script", "style", "noscript", "iframe"} or el.get("hidden") is not None or el.get("aria-hidden") == "true":
            return
        if "pagebreak" in sem or el.get("role") == "doc-pagebreak" or classes & {"pageno", "x-ebookmaker-pageno", "linenum"}:
            return
        if name == "nav" and (set(sem) & {"toc", "page-list", "landmarks"} or el.get("role") == "doc-toc"):
            return
        for key in (el.get("id"), el.get("xml:id"), el.get("name") if name == "a" else None):
            if key and key not in anchors:
                anchors[key] = len(chunks)
        if name in {"img", "image"} and "dropcap" not in classes:
            chunks.append("\ufffc")
        else:
            if el.text:
                chunks.append(el.text)
            for child in el:
                visit(child)
                if child.tail:
                    chunks.append(child.tail)
    visit(root)
    return chunks, anchors


def main():
    books = json.loads((REPORT / "corpus-parser-results.json").read_text())
    passed, disabled, mismatches = [], [], []
    for book in books:
        if "destinations" not in book:
            continue
        indexes = {}
        with zipfile.ZipFile(book["file"]) as archive:
            for row in book["destinations"]:
                result = {"file": book["file"], **row}
                if row["paragraph"] < 0:
                    disabled.append(result)
                    continue
                path = row["path"]
                if path not in indexes:
                    indexes[path] = content_index(archive.read(path))
                chunks, anchors = indexes[path]
                start = anchors.get(row["fragment"]) if row["fragment"] else 0
                if start is None:
                    result["reason"] = "source fragment absent"
                    mismatches.append(result)
                    continue
                expected = compact("".join(chunks[start:]))
                actual = compact(row["rendered"])
                if row["image"]:
                    valid = expected.startswith("\ufffc")
                else:
                    valid = bool(actual) and expected.startswith(actual[:100])
                if valid:
                    passed.append(result)
                else:
                    result["expectedPrefix"] = expected[:120]
                    mismatches.append(result)
    report = {"verifiedDestinations": len(passed), "disabledDestinations": disabled,
              "mismatches": mismatches, "method": "Independent lxml HTML DOM, source ID/name and next text boundary; compare first 100 non-whitespace characters or image marker."}
    (REPORT / "corpus-independent-oracle.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({"verified": len(passed), "disabled": len(disabled), "mismatches": len(mismatches)}))
    for mismatch in mismatches[:15]:
        print(pathlib.Path(mismatch["file"]).name, mismatch["title"], mismatch["rendered"][:65], "EXPECTED", mismatch.get("expectedPrefix", mismatch.get("reason")))


if __name__ == "__main__":
    main()
