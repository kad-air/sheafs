#!/usr/bin/env python3
"""Regenerate Tests/SheafsKitTests/Fixtures/sync-reference.json.

The JSON is the independent second source for the Swift tests of the kosync
document key (partial MD5), the kosync auth key (MD5 of the password) and the
facts in the OPDS fixture feed. Everything here is computed with the Python
standard library only, never with SheafsKit code.

Run from the repo root:

    python3 -I scripts/gen_sync_reference.py

The output is deterministic, so regenerating it must produce no diff.
"""

import hashlib
import io
import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages" / "SheafsKit" / "Tests" / "SheafsKitTests" / "Fixtures"
OUTPUT = FIXTURES / "sync-reference.json"

EPUB_FIXTURES = ["alice-epub3.epub", "hub-fixture.epub", "pride-epub2.epub"]
SYNTHETIC_SIZES = [0, 1, 1023, 1024, 1025, 2047, 4096, 5000, 70000, 1_100_000]
PASSWORDS = ["password", "correct horse battery staple", "pässwörd"]

# Known-true external facts. If the implementation below ever disagrees with
# these, the script fails instead of writing a plausible-looking wrong reference.
KNOWN_HUB_FIXTURE_PARTIAL_MD5 = "2d54ce2c70a99dc5b63e58ebfe69bf51"
KNOWN_EMPTY_MD5 = "d41d8cd98f00b204e9800998ecf8427e"
KNOWN_PASSWORD_MD5 = "5f4dcc3b5aa765d61d8327deb882cf99"

ATOM = "{http://www.w3.org/2005/Atom}"


def partial_md5(f):
    """KOReader's util.partialMD5 over a seekable binary file object.

    For i in -1...10 read 1024 bytes at offset 1024 << (2*i); LuaJIT's 32-bit
    shift turns the i = -1 offset into 0. Reading stops at the first offset
    that is at or past EOF (offsets only grow after the first two).
    """
    digest = hashlib.md5()
    for i in range(-1, 11):
        offset = 0 if i < 0 else 1024 << (2 * i)
        f.seek(offset)
        sample = f.read(1024)
        if not sample:
            break
        digest.update(sample)
    return digest.hexdigest()


def synthetic_bytes(size):
    return bytes((i * 7 + 3) % 251 for i in range(size))


def collapse(text):
    """Trim and collapse runs of whitespace, as a title is shown to a reader."""
    return " ".join((text or "").split())


def epoch(text):
    return round(datetime.fromisoformat(text).timestamp(), 6)


def link_with(entry, rel_part, type_=None):
    for link in entry.findall(ATOM + "link"):
        rel = link.get("rel") or ""
        if rel_part in rel and (type_ is None or link.get("type") == type_):
            return link
    return None


def opds_facts():
    root = ET.parse(FIXTURES / "opds-feed.xml").getroot()
    entries = []
    for entry in root.findall(ATOM + "entry"):
        epub = link_with(entry, "opds-spec.org/acquisition", "application/epub+zip")
        thumb = link_with(entry, "opds-spec.org/image/thumbnail")
        entries.append(
            {
                "id": entry.findtext(ATOM + "id"),
                "title": collapse(entry.findtext(ATOM + "title")),
                "updatedEpoch": epoch(entry.findtext(ATOM + "updated")),
                "epubHref": epub.get("href") if epub is not None else None,
                "thumbnailHref": thumb.get("href") if thumb is not None else None,
            }
        )

    def feed_link(rel):
        for link in root.findall(ATOM + "link"):
            if link.get("rel") == rel:
                return link
        return None

    nxt = feed_link("next")
    # Compare with None: an Element without children is falsy, so `or` would skip it.
    prev = feed_link("previous")
    if prev is None:
        prev = feed_link("prev")
    search = feed_link("search")
    start = feed_link("start")
    return {
        "entryCount": len(entries),
        "feedTitle": collapse(root.findtext(ATOM + "title")),
        "feedUpdatedEpoch": epoch(root.findtext(ATOM + "updated")),
        "entries": entries,
        "hasNext": nxt is not None,
        "nextHref": nxt.get("href") if nxt is not None else None,
        "hasPrevious": prev is not None,
        "previousHref": prev.get("href") if prev is not None else None,
        "searchHref": search.get("href") if search is not None else None,
        "searchType": search.get("type") if search is not None else None,
        "startHref": start.get("href") if start is not None else None,
    }


def main():
    fixtures = {}
    for name in EPUB_FIXTURES:
        with open(FIXTURES / name, "rb") as f:
            fixtures[name] = partial_md5(f)
    assert fixtures["hub-fixture.epub"] == KNOWN_HUB_FIXTURE_PARTIAL_MD5, fixtures

    synthetic = {}
    for size in SYNTHETIC_SIZES:
        synthetic[str(size)] = partial_md5(io.BytesIO(synthetic_bytes(size)))
    assert synthetic["0"] == KNOWN_EMPTY_MD5, synthetic["0"]

    md5 = {p: hashlib.md5(p.encode("utf-8")).hexdigest() for p in PASSWORDS}
    assert md5["password"] == KNOWN_PASSWORD_MD5, md5["password"]

    reference = {
        "md5": md5,
        "opds": opds_facts(),
        "partialMd5": {"fixtures": fixtures, "synthetic": synthetic},
    }
    text = json.dumps(reference, sort_keys=True, indent=2, ensure_ascii=True) + "\n"
    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as out:
        out.write(text)
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(text)} bytes)")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        sys.exit(f"reference check failed: {error}")
