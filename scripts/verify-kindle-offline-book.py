#!/usr/bin/env python3
"""Independently verify a device-exported Kindle offline book, without printing text.

Pass the .book manifest path with its sibling resource directory intact.
By default require a complete book and restored online position; --partial only
verifies resources and continuous coverage of the saved portion.
"""
import argparse
import hashlib
import json
from pathlib import Path


def verify(manifest_path, partial=False):
    manifest = json.loads(manifest_path.read_bytes())
    pages = manifest["pages"]
    assert manifest["version"] == 1 and pages, "Missing pages or unsupported manifest"
    directory = manifest_path.parent / manifest["id"] / manifest["generation"] / manifest["id"]
    index = json.loads((directory / "index.json").read_bytes())
    indexed = {page["id"]: page for page in index["pages"]}
    first = pages[0]["position"]
    previous = None
    byte_count = text_characters = image_only_pages = 0
    unique_images = set()
    for ordinal, page in enumerate(pages):
        assert page["ordinal"] == ordinal, "Non-contiguous page ordinal"
        position = page["position"]
        for key in ("layoutID", "minimum", "maximum"):
            assert position[key] == first[key], "Source layout/bounds changed"
        assert first["minimum"] <= position["start"] <= position["end"] <= first["maximum"]
        if previous:
            assert previous["start"] < position["start"] <= previous["end"] + 1, "Source position gap"
            assert position["start"] >= previous["end"], "Source pages overlap beyond a shared boundary"
            assert previous["end"] < position["end"], "Page does not advance"
        previous = position
        resource = page["resource"]
        page_key = f'{manifest["generation"]}:{ordinal}:{position["start"]}:{position["end"]}'
        key_hash = hashlib.sha256(page_key.encode()).hexdigest()
        assert resource["pageKeyHash"] == key_hash, "Resource belongs to a different source page"
        resource_key = f'{key_hash}:{resource["imageHash"]}:{resource["snapshotHash"]}'
        assert resource["id"] == hashlib.sha256(resource_key.encode()).hexdigest(), "Resource identity mismatch"
        assert indexed.get(resource["id"]) == resource, "Resource missing from page index"
        sizes = []
        for key, suffix in (("imageHash", ".image"), ("snapshotHash", ".page")):
            digest = resource[key]
            assert len(digest) == 64 and all(c in "0123456789abcdef" for c in digest)
            data = (directory / (digest + suffix)).read_bytes()
            assert hashlib.sha256(data).hexdigest() == digest, "Resource SHA-256 mismatch"
            sizes.append(len(data))
            if suffix == ".page":
                snapshot = json.loads(data)
                assert snapshot["version"] == 1
                characters = sum(len(p["text"]) for p in snapshot["paragraphs"])
                text_characters += characters
                image_only_pages += characters == 0
        assert sum(sizes) == resource["byteCount"], "Resource size mismatch"
        byte_count += sum(sizes)
        unique_images.add(resource["imageHash"])
    assert first["start"] == first["minimum"], "Book start missing"
    whole = previous["end"] == first["maximum"]
    if not partial:
        assert whole and manifest["status"] == "complete", "Book is not complete"
        assert manifest["originalPositionRestored"], "Original online position not restored"
    return {
        "pages": len(pages), "logicalResourceBytes": byte_count,
        "uniqueImages": len(unique_images), "textCharacters": text_characters,
        "imageOnlyPages": image_only_pages, "sourceMinimum": first["minimum"],
        "sourceMaximum": first["maximum"], "savedStart": first["start"],
        "savedEnd": previous["end"], "continuous": True,
        "allResourceHashesVerified": True, "coversWholeBook": whole,
        "status": manifest["status"], "originalPositionRestored": manifest["originalPositionRestored"],
        "readingPosition": manifest["readingPosition"],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--partial", action="store_true")
    args = parser.parse_args()
    print(json.dumps(verify(args.manifest, args.partial), indent=2, ensure_ascii=False))
