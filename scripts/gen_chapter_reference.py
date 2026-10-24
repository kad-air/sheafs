#!/usr/bin/env python3
"""Generate the second-source reference for the XHTML converter tests.

Run from the repo root:

    python3 -I scripts/gen_chapter_reference.py [--output PATH]

By default the result is written over the committed Fixtures/chapter-reference.json.
`ChapterReferenceTests.referenceIsUpToDate` runs this with --output to a temporary file and
fails if the bytes differ from the committed file.

For every XHTML/HTML document in the OPF spine of each EPUB fixture, this records what an
independent implementation (Python's html.parser plus the CREngine-style path algorithm that
was validated against real KOReader-protocol devices) finds: the <p> paragraphs with their
element paths and text, the element ids and the document title. The Swift tests compare the
converter's output against this file instead of against itself.

Standard library only. The output is deterministic (sorted keys, fixed indent, trailing
newline), so regenerating it must be byte-identical.
"""
import json
import posixpath
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages" / "SheafsKit" / "Tests" / "SheafsKitTests" / "Fixtures"
OUTPUT = FIXTURES / "chapter-reference.json"
EPUBS = ["alice-epub3.epub", "hub-fixture.epub", "pride-epub2.epub"]
SAMPLE_STRIDE = 37

CONTAINER_NS = "{urn:oasis:names:tc:opendocument:xmlns:container}"
OPF_NS = "{http://www.idpf.org/2007/opf}"
DOCUMENT_TYPES = {"application/xhtml+xml", "text/html"}

VOID = {"br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source",
        "track", "wbr", "param"}


class PathBuilder(HTMLParser):
    """CREngine-style element paths: /body/div[1]/p[3], counting same-tag siblings."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.in_body = False
        self.paras = []
        self._open = None

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.in_body = True
            self.stack = [("body", {})]
            return
        if not self.in_body or tag in VOID:
            return
        counts = self.stack[-1][1]
        counts[tag] = counts.get(tag, 0) + 1
        self.stack.append((f"{tag}[{counts[tag]}]", {}))
        if tag == "p" and self._open is None:
            self._open = ("/" + "/".join(seg for seg, _ in self.stack), [], len(self.stack))

    def handle_endtag(self, tag):
        if tag == "body":
            self.in_body = False
            return
        if not self.in_body or tag in VOID:
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i][0].startswith(f"{tag}["):
                del self.stack[i:]
                break
        if self._open and len(self.stack) < self._open[2]:
            path, parts, _ = self._open
            self.paras.append((path, re.sub(r"\s+", " ", " ".join(parts)).strip()))
            self._open = None

    def handle_data(self, data):
        if self._open is not None:
            self._open[1].append(data)


class DocumentScanner(PathBuilder):
    """The path builder, plus the element ids/anchor names in <body> and the <title> text."""

    def __init__(self):
        super().__init__()
        self.ids = set()
        self._in_title = False
        self._title_parts = []
        self._title_done = False

    def handle_starttag(self, tag, attrs):
        super().handle_starttag(tag, attrs)
        if self.in_body:
            for name, value in attrs:
                if value and (name == "id" or (tag == "a" and name == "name")):
                    self.ids.add(value)
        elif tag == "title" and not self._title_done:
            self._in_title = True

    def handle_endtag(self, tag):
        super().handle_endtag(tag)
        if tag == "title" and self._in_title:
            self._in_title = False
            self._title_done = True

    def handle_data(self, data):
        super().handle_data(data)
        if self._in_title:
            self._title_parts.append(data)

    @property
    def title(self):
        text = re.sub(r"\s+", " ", "".join(self._title_parts)).strip()
        return text or None


def spine_documents(archive):
    """(spine index, zip path) for every XHTML/HTML itemref, via container.xml and the OPF."""
    container = ET.fromstring(archive.read("META-INF/container.xml"))
    rootfile = container.find(f".//{CONTAINER_NS}rootfile").get("full-path")
    package = ET.fromstring(archive.read(rootfile))
    manifest = {item.get("id"): (item.get("href"), item.get("media-type"))
                for item in package.iter(f"{OPF_NS}item")}
    base = posixpath.dirname(rootfile)
    documents = []
    for index, itemref in enumerate(package.find(f"{OPF_NS}spine").iter(f"{OPF_NS}itemref")):
        href, media_type = manifest[itemref.get("idref")]
        if media_type in DOCUMENT_TYPES:
            documents.append((index, posixpath.normpath(posixpath.join(base, unquote(href)))))
    return documents


def sample_indices(count):
    """Paragraph indices 0, the last, and every SAMPLE_STRIDE-th."""
    if count == 0:
        return []
    return sorted({0, count - 1} | set(range(0, count, SAMPLE_STRIDE)))


def describe(archive, spine_index, path):
    scanner = DocumentScanner()
    scanner.feed(archive.read(path).decode("utf-8"))
    scanner.close()
    paragraphs = scanner.paras
    return {
        "path": path,
        "spineIndex": spine_index,
        "title": scanner.title,
        "paragraphCount": len(paragraphs),
        "nonEmptyParagraphCount": sum(1 for _, text in paragraphs if text),
        "ids": sorted(scanner.ids),
        "samples": [{"index": i, "path": paragraphs[i][0], "text": paragraphs[i][1]}
                    for i in sample_indices(len(paragraphs))],
    }


def main(argv):
    output = OUTPUT
    if argv[1:2] == ["--output"] and len(argv) == 3:
        output = Path(argv[2])
    elif len(argv) != 1:
        sys.exit("usage: gen_chapter_reference.py [--output PATH]")
    result = {"sampleStride": SAMPLE_STRIDE, "epubs": {}}
    for name in EPUBS:
        with zipfile.ZipFile(FIXTURES / name) as archive:
            result["epubs"][name] = {
                "documents": [describe(archive, index, path)
                              for index, path in spine_documents(archive)],
            }
    with open(output, "w", encoding="utf-8", newline="\n") as out:
        out.write(json.dumps(result, sort_keys=True, indent=2) + "\n")
    total = sum(len(e["documents"]) for e in result["epubs"].values())
    print(f"wrote {output}: {total} documents", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
