#!/usr/bin/env python3
"""Generate the second-source reference for the XHTML converter tests.

Run from the repo root:

    python3 -I scripts/gen_chapter_reference.py [--output PATH]

By default the result is written over the committed Fixtures/chapter-reference.json.
`ChapterReferenceTests.referenceIsUpToDate` runs this with --output to a temporary file and
fails if the bytes differ from the committed file.

For every XHTML/HTML document in the OPF spine of each EPUB fixture (and the loose XHTML
fixtures), this records what an independent implementation (Python's html.parser plus the
CREngine-style path algorithm that was validated against real KOReader-protocol devices)
finds: the <p> paragraphs with their element paths and text, the tables (path, caption, rows
with their paths, cells with their text and header flag), the element ids and the document
title. A <p> inside a table is cell content, not a paragraph. The Swift tests compare the
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
XHTML = ["table-chapter.xhtml", "table-shapes.xhtml"]
SAMPLE_STRIDE = 37

CONTAINER_NS = "{urn:oasis:names:tc:opendocument:xmlns:container}"
OPF_NS = "{http://www.idpf.org/2007/opf}"
DOCUMENT_TYPES = {"application/xhtml+xml", "text/html"}

VOID = {"br", "img", "hr", "meta", "link", "input", "area", "base", "col", "embed", "source",
        "track", "wbr", "param"}


def collapse(parts):
    return re.sub(r"\s+", " ", " ".join(parts)).strip()


# A cell's text: its text nodes joined as written (the converter adds no space between inline
# elements), a space where a block, a line break or a nested table's row or cell begins or ends.
CELL_BREAKS = {"p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl", "dt", "dd",
               "blockquote", "pre", "table", "tr", "td", "th", "br", "section", "figure", "figcaption"}
CELL_CHARACTER_LIMIT = 600
CELL_BLOCK_CONTENT = {"h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "blockquote", "pre"}


def cell_text(parts):
    return re.sub(r"\s+", " ", "".join(parts)).strip()


def span(attrs):
    try:
        value = int((dict(attrs).get("colspan") or "1").strip())
    except ValueError:
        value = 1
    return max(1, min(value, 64))


class TableShape:
    """Whether one table is laid out as a table or flattened into plain blocks, the converter's
    rule (TableShape.swift): flattened when a cell holds a heading, list, blockquote or pre, two or
    more paragraphs (<p>, or <div> with text), more than 600 characters other than whitespace,
    or when the table has a single column (counting colspan)."""

    def __init__(self):
        self.depth = 1
        self.in_cell = False
        self.row_columns = 0
        self.columns = 0
        self.open_blocks = []
        self.text_blocks = 0
        self.characters = 0
        self.result = None

    def finish(self):
        if self.result is None:
            self.result = "flatten" if max(self.columns, self.row_columns) <= 1 else "table"

    def start(self, tag, attrs):
        if self.result is not None:
            return
        if tag == "table":
            self.depth += 1
            return
        if self.depth == 1:
            if tag == "tr":
                self.columns = max(self.columns, self.row_columns)
                self.row_columns = 0
                self.in_cell = False
            elif tag in ("td", "th"):
                self.row_columns += span(attrs)
                self.in_cell = True
                self.open_blocks = []
                self.text_blocks = 0
                self.characters = 0
                return
            elif tag == "caption":
                self.in_cell = False
        if not self.in_cell:
            return
        if tag in CELL_BLOCK_CONTENT:
            self.result = "flatten"
        elif tag in ("p", "div"):
            self.open_blocks.append([tag, False])

    def end(self, tag):
        if self.result is not None:
            return
        if tag == "table":
            self.depth -= 1
            if self.depth <= 0:
                self.finish()
            return
        if self.depth == 1 and tag in ("td", "th"):
            self.in_cell = False
            return
        if not self.in_cell or tag not in ("p", "div"):
            return
        indices = [i for i, (name, _) in enumerate(self.open_blocks) if name == tag]
        if not indices:
            return
        closed = self.open_blocks[indices[-1]:]
        if any(has_text for _, has_text in closed):
            self.text_blocks += 1
            if self.text_blocks >= 2:
                self.result = "flatten"
        del self.open_blocks[indices[-1]:]

    def data(self, text):
        if self.result is not None or not self.in_cell:
            return
        count = sum(1 for ch in text if ch not in " \t\n\r\f")
        if count == 0:
            return
        self.characters += count
        if self.characters > CELL_CHARACTER_LIMIT:
            self.result = "flatten"
        elif self.open_blocks:
            self.open_blocks[-1][1] = True


class TableDecider(HTMLParser):
    """First pass: the TableShape decision of every <table> in <body>, in document order."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_body = False
        self.decisions = []
        self._active = []

    def _settle(self):
        for index, shape in list(self._active):
            if shape.result is not None:
                self.decisions[index] = shape.result
        self._active = [(i, shape) for i, shape in self._active if shape.result is None]

    def _finish_all(self):
        for _, shape in self._active:
            shape.finish()
        self._settle()

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self._finish_all()
            self.in_body = True
            return
        if not self.in_body:
            return
        for _, shape in self._active:
            shape.start(tag, attrs)
        if tag == "table":
            self.decisions.append(None)
            self._active.append((len(self.decisions) - 1, TableShape()))
        self._settle()

    def handle_endtag(self, tag):
        if tag == "body":
            self._finish_all()
            self.in_body = False
            return
        if not self.in_body:
            return
        for _, shape in self._active:
            shape.end(tag)
        self._settle()

    def handle_data(self, data):
        if self.in_body:
            for _, shape in self._active:
                shape.data(data)
            self._settle()

    def close(self):
        super().close()
        self._finish_all()


class PathBuilder(HTMLParser):
    """CREngine-style element paths: /body/div[1]/p[3], counting same-tag siblings.

    Also collects tables: the outermost open <table> that TableDecider keeps as a table is the
    one being built; its <tr> are rows, its <td>/<th> cells (header: a <th>, or any cell in its
    <thead>), its <caption> the caption. Everything inside a cell, nested tables included, is
    that cell's text. Cells outside any <tr> form one row. Rows without cells and tables without
    rows or caption are dropped, as the converter drops them. A flattened table is not a table:
    its <p> are paragraphs like any other.
    """

    def __init__(self, decisions=()):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.in_body = False
        self.paras = []
        self.tables = []
        self.decisions = list(decisions)
        self._table_count = 0
        self._open = None
        self._table = None      # the table being built, with "_depth" (stack length when opened)
        self._nested = []       # stack lengths of tables opened inside it
        self._thead = None      # stack length of its open <thead>
        self._row = None
        self._cell = None
        self._caption = None

    def _path(self):
        return "/" + "/".join(seg for seg, _ in self.stack)

    def _cell_break(self, tag):
        if self._table is not None and tag in CELL_BREAKS:
            target = self._caption if self._caption is not None else self._cell
            if target is not None:
                target["parts"].append(" ")

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.in_body = True
            self.stack = [("body", {})]
            return
        if not self.in_body:
            return
        if tag in VOID:
            if tag == "br":
                self._cell_break(tag)
            return
        counts = self.stack[-1][1]
        counts[tag] = counts.get(tag, 0) + 1
        self.stack.append((f"{tag}[{counts[tag]}]", {}))
        depth = len(self.stack)
        if tag == "table":
            index = self._table_count
            self._table_count += 1
        if self._table is None:
            if tag == "table":
                decision = self.decisions[index] if index < len(self.decisions) else "table"
                if decision == "table":
                    self._table = {"path": self._path(), "rows": [], "caption": None, "_depth": depth}
            elif tag == "p" and self._open is None:
                self._open = (self._path(), [], depth)
            return
        if tag == "table":
            self._cell_break(tag)
            self._nested.append(depth)
        elif not self._nested:
            if tag == "thead":
                self._thead = depth
            elif tag == "tr":
                self._finish_row()
                self._row = {"path": self._path(), "cells": [], "_depth": depth}
            elif tag in ("td", "th"):
                self._start_cell(tag == "th" or self._thead is not None, depth)
            elif tag == "caption":
                self._caption = {"parts": [], "_depth": depth}
            else:
                self._cell_break(tag)
        else:
            self._cell_break(tag)

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
        depth = len(self.stack)
        if self._open and depth < self._open[2]:
            path, parts, _ = self._open
            self.paras.append((path, collapse(parts)))
            self._open = None
        if self._table is None:
            return
        self._cell_break(tag)
        self._nested = [d for d in self._nested if d <= depth]
        if self._cell and depth < self._cell["_depth"]:
            self._finish_cell()
        if self._row and depth < self._row["_depth"]:
            self._finish_row()
        if self._thead is not None and depth < self._thead:
            self._thead = None
        if self._caption and depth < self._caption["_depth"]:
            text = cell_text(self._caption["parts"])
            if self._table["caption"] is None and text:
                self._table["caption"] = text
            self._caption = None
        if depth < self._table["_depth"]:
            self._finish_row()
            table = self._table
            self._table = None
            if table["rows"] or table["caption"] is not None:
                del table["_depth"]
                self.tables.append(table)

    def _start_cell(self, header, depth):
        self._finish_cell()
        if self._row is None:
            # Cells outside any <tr> share one row, which only the next <tr> or the table ends.
            self._row = {"path": self._table["path"], "cells": [], "_depth": self._table["_depth"]}
        self._cell = {"header": header, "parts": [], "_depth": depth}

    def _finish_cell(self):
        if self._cell is not None:
            self._row["cells"].append({"header": self._cell["header"], "text": cell_text(self._cell["parts"])})
            self._cell = None

    def _finish_row(self):
        self._finish_cell()
        if self._row is not None and self._row["cells"]:
            self._table["rows"].append({"path": self._row["path"], "cells": self._row["cells"]})
        self._row = None

    def handle_data(self, data):
        if self._open is not None:
            self._open[1].append(data)
        if self._table is None or not self.in_body:
            return
        if self._caption is not None:
            self._caption["parts"].append(data)
            return
        if self._cell is None:
            if not data.strip():
                return
            self._start_cell(False, len(self.stack) + 1)
        self._cell["parts"].append(data)


class DocumentScanner(PathBuilder):
    """The path builder, plus the element ids/anchor names in <body> and the <title> text."""

    def __init__(self, decisions=()):
        super().__init__(decisions)
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


def describe(text, spine_index, path):
    decider = TableDecider()
    decider.feed(text)
    decider.close()
    scanner = DocumentScanner(decider.decisions)
    scanner.feed(text)
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
        "tables": scanner.tables,
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
                "documents": [describe(archive.read(path).decode("utf-8"), index, path)
                              for index, path in spine_documents(archive)],
            }
    result["xhtml"] = {name: describe((FIXTURES / name).read_text(encoding="utf-8"), 0, name)
                       for name in XHTML}
    with open(output, "w", encoding="utf-8", newline="\n") as out:
        out.write(json.dumps(result, sort_keys=True, indent=2) + "\n")
    total = sum(len(e["documents"]) for e in result["epubs"].values())
    print(f"wrote {output}: {total} documents", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
