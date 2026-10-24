#!/usr/bin/env python3
"""Regenerate Tests/SheafsKitTests/Fixtures/epub-reference.json.

The JSON is the independent second source for the Swift tests of the ZIP reader and
the EPUB parser. For each EPUB fixture it records what Python's zipfile and
ElementTree/html.parser make of the file: the central directory (sizes, CRC-32,
compression method, and the CRC-32 of the first 4096 decompressed bytes of every
entry, which proves the Swift inflater byte for byte against zlib), the package
metadata, manifest/spine, cover, and the flattened table of contents. Everything is
computed with the Python standard library only, never with SheafsKit code.

Run from the repo root:

    python3 -I scripts/gen_epub_reference.py            # rewrite the JSON
    python3 -I scripts/gen_epub_reference.py --check    # exit 1 if the JSON is stale

The output is deterministic, so regenerating it must produce no diff.
"""

import html.parser
import json
import os
import posixpath
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Packages", "SheafsKit", "Tests", "SheafsKitTests", "Fixtures")
OUTPUT = os.path.join(FIXTURES, "epub-reference.json")

EPUB_FIXTURES = ["alice-epub3.epub", "hub-fixture.epub", "pride-epub2.epub"]

NCX_MEDIA_TYPE = "application/x-dtbncx+xml"

# Known-true external facts. If the implementation below ever disagrees with these,
# the script fails instead of writing a plausible-looking wrong reference.
KNOWN_TITLES = {
    "alice-epub3.epub": "Alice's Adventures in Wonderland",
    "pride-epub2.epub": "Pride and Prejudice",
    "hub-fixture.epub": "The Fixture Book",
}
KNOWN_SPINE_COUNTS = {"alice-epub3.epub": 15, "pride-epub2.epub": 17, "hub-fixture.epub": 1}
KNOWN_CRC32_123456789 = 0xCBF43926  # the standard CRC-32 check value


# --------------------------------------------------------------------------- XML helpers


def local(name):
    """Local part of 'prefix:name' or '{namespace}name'."""
    return name.rsplit("}", 1)[-1].rsplit(":", 1)[-1]


def attr(element, wanted):
    """Attribute by local name; an unprefixed attribute wins over a prefixed one."""
    if wanted in element.attrib:
        return element.attrib[wanted]
    for key in sorted(element.attrib):
        if local(key) == wanted:
            return element.attrib[key]
    return None


def children(element, name):
    return [child for child in element if local(child.tag) == name]


def first_child(element, name):
    found = children(element, name)
    return found[0] if found else None


def collapse(text):
    return " ".join(text.split())


def text_of(element):
    return collapse("".join(element.itertext()))


SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:")


def is_external(href):
    return SCHEME.match(href) is not None


def resolve(href, base):
    """Zip path of href relative to the file at zip path `base`; None if external."""
    if is_external(href):
        return None
    path = href.split("#", 1)[0].split("?", 1)[0]
    path = urllib.parse.unquote(path)
    if path.startswith("/"):
        joined = path
    elif path == "":
        joined = base
    else:
        joined = posixpath.join(posixpath.dirname(base), path)
    parts = []
    for component in joined.split("/"):
        if component in ("", "."):
            continue
        if component == "..":
            if parts:
                parts.pop()
            continue
        parts.append(component)
    return "/".join(parts)


# --------------------------------------------------------------------------- package


def read_package(archive):
    container = ET.fromstring(archive.read("META-INF/container.xml"))
    rootfile = next(
        el for el in container.iter() if local(el.tag) == "rootfile" and attr(el, "full-path")
    )
    opf_path = attr(rootfile, "full-path")
    package = ET.fromstring(archive.read(opf_path))
    return opf_path, package


def read_metadata(package):
    """Returns (metadata dict, list of <metadata> child elements)."""
    metadata_el = first_child(package, "metadata")
    nodes = list(metadata_el) if metadata_el is not None else []

    refinements = {}
    for node in nodes:
        if local(node.tag) != "meta":
            continue
        refines, prop = attr(node, "refines"), attr(node, "property")
        if refines and refines.startswith("#") and prop:
            refinements.setdefault(refines[1:], []).append((prop, text_of(node)))

    def refinement(node, prop):
        ident = attr(node, "id")
        for name, value in refinements.get(ident, []) if ident else []:
            if name == prop:
                return value
        return None

    def named(name):
        return [n for n in nodes if local(n.tag) == name and text_of(n)]

    titles = named("title")
    main = next((t for t in titles if refinement(t, "title-type") == "main"), None)
    title = text_of(main if main is not None else titles[0]) if titles else ""

    identifiers = named("identifier")
    unique_id = attr(package, "unique-identifier")
    chosen_id = next((i for i in identifiers if unique_id and attr(i, "id") == unique_id), None)
    if chosen_id is None and identifiers:
        chosen_id = identifiers[0]

    dates = named("date")
    date = next((d for d in dates if (attr(d, "event") or "").lower() == "publication"), None)
    if date is None and dates:
        date = dates[0]

    modified = next(
        (
            text_of(n)
            for n in nodes
            if local(n.tag) == "meta" and attr(n, "property") == "dcterms:modified" and text_of(n)
        ),
        None,
    )

    # Series: EPUB 3 collection first, then the calibre convention.
    series, series_index = None, None
    collections = [
        n
        for n in nodes
        if local(n.tag) == "meta" and attr(n, "property") == "belongs-to-collection" and text_of(n)
    ]
    collection = next((c for c in collections if refinement(c, "collection-type") == "series"), None)
    if collection is None:
        collection = next((c for c in collections if refinement(c, "collection-type") is None), None)
    if collection is not None:
        series = text_of(collection)
        position = refinement(collection, "group-position")
        series_index = to_float(position)
    else:
        calibre = next(
            (n for n in nodes if local(n.tag) == "meta" and attr(n, "name") == "calibre:series"), None
        )
        if calibre is not None and collapse(attr(calibre, "content") or ""):
            series = collapse(attr(calibre, "content"))
            index_node = next(
                (n for n in nodes if local(n.tag) == "meta" and attr(n, "name") == "calibre:series_index"),
                None,
            )
            series_index = to_float(attr(index_node, "content")) if index_node is not None else None

    languages = named("language")
    publishers = named("publisher")
    metadata = {
        "title": title,
        "authors": [text_of(n) for n in named("creator")],
        "language": text_of(languages[0]) if languages else None,
        "identifier": text_of(chosen_id) if chosen_id is not None else None,
        "publisher": text_of(publishers[0]) if publishers else None,
        "published": text_of(date) if date is not None else None,
        "modified": modified,
        "series": series,
        "seriesIndex": series_index,
    }
    return metadata, nodes


def to_float(text):
    if text is None:
        return None
    try:
        return float(text.strip())
    except ValueError:
        return None


def read_manifest(package, opf_path):
    items, seen = [], set()
    manifest = first_child(package, "manifest")
    for node in children(manifest, "item"):
        ident, href = attr(node, "id"), attr(node, "href")
        if not ident or not href or is_external(href) or ident in seen:
            continue
        seen.add(ident)
        items.append(
            {
                "id": ident,
                "path": resolve(href, opf_path),
                "mediaType": attr(node, "media-type") or "",
                "properties": set((attr(node, "properties") or "").split()),
            }
        )
    return items


def read_spine(package, items):
    by_id = {item["id"]: item for item in items}
    spine_el = first_child(package, "spine")
    spine = []
    for node in children(spine_el, "itemref"):
        item = by_id.get(attr(node, "idref"))
        if item is None:
            continue
        linear = (attr(node, "linear") or "yes").strip().lower() != "no"
        spine.append({"item": item, "linear": linear})
    return spine, attr(spine_el, "toc")


# --------------------------------------------------------------------------- cover


class ImageFinder(html.parser.HTMLParser):
    """First <img src> or SVG <image href> in a page."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = None

    def handle_starttag(self, tag, attrs):
        if self.found:
            return
        values = dict(attrs)
        if tag == "img" and values.get("src"):
            self.found = values["src"]
        elif tag == "image":
            href = values.get("href") or values.get("xlink:href")
            if href:
                self.found = href


def find_cover(archive, items, metadata_nodes):
    def is_image(item):
        return item["mediaType"].lower().startswith("image/")

    for item in items:
        if "cover-image" in item["properties"] and is_image(item):
            return item

    cover_id = next(
        (attr(n, "content") for n in metadata_nodes if local(n.tag) == "meta" and attr(n, "name") == "cover"),
        None,
    )
    if cover_id:
        item = next((i for i in items if i["id"] == cover_id), None)
        if item is not None:
            if is_image(item):
                return item
            try:
                page = archive.read(item["path"])
            except KeyError:
                page = None
            if page is not None:
                finder = ImageFinder()
                finder.feed(page.decode("utf-8", errors="replace"))
                if finder.found and not is_external(finder.found):
                    target = resolve(finder.found, item["path"])
                    match = next((i for i in items if i["path"] == target and is_image(i)), None)
                    if match is not None:
                        return match

    return next(
        (
            i
            for i in items
            if is_image(i) and ("cover" in i["id"].lower() or "cover" in i["path"].lower())
        ),
        None,
    )


# --------------------------------------------------------------------------- table of contents


class NavParser(html.parser.HTMLParser):
    """Collects every <nav> of an XHTML navigation document as a tree of
    {title, href, children} nodes. Written as an event-driven state machine, deliberately
    unlike the recursive tree walk in the Swift implementation."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.navs = []  # [{"types": set, "items": [node]}]
        self.stack = []  # ("nav", items) | ("ol", target list or None) | ("li", node)
        self.label = None  # the <a>/<span> currently being read

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if self.label is not None:
            if tag == self.label["tag"]:
                self.label["depth"] += 1
            return
        top = self.stack[-1] if self.stack else None
        if tag == "nav":
            nav = {"types": set((values.get("epub:type") or "").split()), "items": []}
            self.navs.append(nav)
            self.stack.append(("nav", nav["items"]))
        elif tag in ("ol", "ul"):
            target = None
            if top and top[0] == "nav":
                target = top[1]
            elif top and top[0] == "li":
                target = top[1]["children"]
            self.stack.append(("ol", target))
        elif tag == "li":
            node = {"title": "", "href": None, "children": [], "labeled": False}
            if top and top[0] == "ol" and top[1] is not None:
                top[1].append(node)
            self.stack.append(("li", node))
        elif tag in ("a", "span") and top and top[0] == "li" and not top[1]["labeled"]:
            top[1]["labeled"] = True
            if tag == "a":
                top[1]["href"] = values.get("href")
            self.label = {"tag": tag, "depth": 1, "node": top[1], "parts": []}

    def handle_data(self, data):
        if self.label is not None:
            self.label["parts"].append(data)

    def handle_endtag(self, tag):
        if self.label is not None:
            if tag == self.label["tag"]:
                self.label["depth"] -= 1
                if self.label["depth"] == 0:
                    self.label["node"]["title"] = collapse("".join(self.label["parts"]))
                    self.label = None
            return
        wanted = {"nav": "nav", "ol": "ol", "ul": "ol", "li": "li"}.get(tag)
        if wanted and self.stack and self.stack[-1][0] == wanted:
            self.stack.pop()


def lift_untitled(nodes):
    """Entries without a title are dropped and their children take their place."""
    result = []
    for node in nodes:
        kids = lift_untitled(node["children"])
        if node["title"]:
            result.append({"title": node["title"], "href": node["href"], "children": kids})
        else:
            result.extend(kids)
    return result


def parse_nav(data):
    parser = NavParser()
    parser.feed(data.decode("utf-8", errors="replace"))
    parser.close()
    chosen = next((n for n in parser.navs if "toc" in n["types"]), None)
    if chosen is None:
        chosen = next((n for n in parser.navs if not (n["types"] & {"landmarks", "page-list"})), None)
    if chosen is None:
        return None
    return lift_untitled(chosen["items"])


def parse_ncx(data):
    root = ET.fromstring(data)
    nav_map = first_child(root, "navMap")
    if local(root.tag) != "ncx" or nav_map is None:
        return None

    def points(parent):
        nodes = []
        for point in children(parent, "navPoint"):
            title = ""
            label = first_child(point, "navLabel")
            if label is not None:
                text = next((e for e in label.iter() if local(e.tag) == "text"), None)
                title = text_of(text) if text is not None else ""
            content = first_child(point, "content")
            href = attr(content, "src") if content is not None else None
            nodes.append({"title": title, "href": href, "children": points(point)})
        return nodes

    return lift_untitled(points(nav_map))


def flatten_toc(nodes, base):
    flat = []

    def walk(level, depth):
        for node in level:
            path, fragment = None, None
            href = (node["href"] or "").strip()
            if href and not is_external(href):
                raw_path, _, raw_fragment = href.partition("#")
                path = resolve(raw_path, base)
                fragment = urllib.parse.unquote(raw_fragment) or None
            flat.append({"depth": depth, "title": node["title"], "path": path, "fragment": fragment})
            walk(node["children"], depth + 1)

    walk(nodes, 0)
    return flat


def read_toc(archive, items, spine_toc_id):
    """Nav document first, then the NCX; a TOC that cannot be read is simply empty."""
    nav_item = next((i for i in items if "nav" in i["properties"]), None)
    if nav_item is not None:
        try:
            nodes = parse_nav(archive.read(nav_item["path"]))
        except KeyError:
            nodes = None
        flat = flatten_toc(nodes, nav_item["path"]) if nodes else []
        if flat:
            return flat

    candidates = []
    if spine_toc_id:
        candidates += [i for i in items if i["id"] == spine_toc_id]
    candidates += [i for i in items if i["mediaType"] == NCX_MEDIA_TYPE]
    for ncx in candidates:
        try:
            nodes = parse_ncx(archive.read(ncx["path"]))
        except (KeyError, ET.ParseError):
            continue
        flat = flatten_toc(nodes, ncx["path"]) if nodes else []
        if flat:
            return flat
    return []


# --------------------------------------------------------------------------- per fixture


def head_crc(archive, info):
    return zlib.crc32(archive.read(info)[:4096])


def reference_for(name):
    with zipfile.ZipFile(os.path.join(FIXTURES, name)) as archive:
        infos = archive.infolist()
        entries = [
            {
                "path": info.filename,
                "method": info.compress_type,
                "compressedSize": info.compress_size,
                "uncompressedSize": info.file_size,
                "crc32": info.CRC,
                "isDirectory": info.is_dir(),
                "head4096Crc32": head_crc(archive, info),
            }
            for info in infos
        ]

        opf_path, package = read_package(archive)
        metadata, metadata_nodes = read_metadata(package)
        items = read_manifest(package, opf_path)
        spine, spine_toc_id = read_spine(package, items)
        cover = find_cover(archive, items, metadata_nodes)

        spine_rows = []
        for entry in spine:
            path = entry["item"]["path"]
            info = archive.getinfo(path)
            spine_rows.append(
                {
                    "path": path,
                    "linear": entry["linear"],
                    "size": info.file_size,
                    "crc32": info.CRC,
                    "head4096Crc32": head_crc(archive, info),
                }
            )

        result = dict(metadata)
        result.update(
            {
                "entries": entries,
                "opfPath": opf_path,
                "version": attr(package, "version"),
                "manifestCount": len(items),
                "spine": spine_rows,
                "coverPath": cover["path"] if cover is not None else None,
                "toc": read_toc(archive, items, spine_toc_id),
            }
        )
        return result


def check_known_facts(references):
    assert zlib.crc32(b"123456789") == KNOWN_CRC32_123456789, "zlib CRC-32 check value is wrong"
    for name, reference in references.items():
        assert reference["title"] == KNOWN_TITLES[name], (name, reference["title"])
        assert len(reference["spine"]) == KNOWN_SPINE_COUNTS[name], (name, len(reference["spine"]))
        mimetype = next(e for e in reference["entries"] if e["path"] == "mimetype")
        assert mimetype["method"] == 0, f"{name}: mimetype must be stored"
        for row in reference["spine"]:
            assert row["size"] > 0, (name, row["path"])
    # Pride and Prejudice has 63 chapter-level navPoints in its NCX (EPUB 2, no nav document).
    assert len(references["pride-epub2.epub"]["toc"]) == 63
    # Alice has 16 nav entries; its NCX agrees.
    assert len(references["alice-epub3.epub"]["toc"]) == 16
    # The synthetic fixture lists an NCX in its manifest but does not ship it: no TOC.
    assert references["hub-fixture.epub"]["toc"] == []
    assert references["hub-fixture.epub"]["series"] == "Fixtures"
    assert references["hub-fixture.epub"]["seriesIndex"] == 3.0


def main(argv):
    references = {name: reference_for(name) for name in EPUB_FIXTURES}
    check_known_facts(references)
    text = json.dumps(references, sort_keys=True, indent=2, ensure_ascii=False) + "\n"

    if "--check" in argv:
        with open(OUTPUT, encoding="utf-8") as handle:
            if handle.read() != text:
                print("epub-reference.json is stale: run python3 -I scripts/gen_epub_reference.py", file=sys.stderr)
                return 1
        print("epub-reference.json is up to date")
        return 0

    with open(OUTPUT, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print(f"wrote {os.path.relpath(OUTPUT, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
