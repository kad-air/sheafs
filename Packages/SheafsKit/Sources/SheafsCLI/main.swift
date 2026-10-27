import Foundation
import SheafsKit

// A small command-line window into SheafsKit, for poking at real books and servers from the Mac:
//   swift run sheafs-cli epub <file.epub>          metadata, spine, TOC, chapter stats
//   swift run sheafs-cli chapter <file.epub> <n>   the blocks of spine item n (0-based)
//   swift run sheafs-cli md5 <file>                the KOReader partial MD5 (kosync document key)
//   swift run sheafs-cli opds <url> [user] [pass]  fetch and summarize an OPDS feed
//   swift run sheafs-cli kosync <base> <user> <pass> [document]   authorize, then read a position

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: sheafs-cli epub|chapter|md5|opds|kosync ...\n".utf8))
    exit(64)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let command = args.first else { usage() }

switch command {
case "epub":
    guard args.count == 2 else { usage() }
    let book = try EPUBBook(url: URL(fileURLWithPath: args[1]))
    let m = book.metadata
    print("title:      \(m.title)")
    print("authors:    \(m.authors.joined(separator: ", "))")
    print("language:   \(m.language ?? "-")")
    print("identifier: \(m.identifier ?? "-")")
    if let series = m.series { print("series:     \(series) #\(m.seriesIndex.map { String($0) } ?? "?")") }
    print("version:    \(book.version ?? "-")   opf: \(book.opfPath)   cover: \(book.coverItem?.path ?? "-")")
    print("spine (\(book.spine.count)):")
    let converter = XHTMLConverter()
    let stylesheets = StylesheetLibrary(book: book)
    var total = 0
    for (i, item) in book.spine.enumerated() {
        let chapter = converter.convert((try? book.data(for: item.item)) ?? Data(), documentPath: item.item.path,
                                        stylesheets: stylesheets)
        total += chapter.textLength
        print(String(format: "  %3d  %-50@ %7d chars  %4d blocks%@", i, item.item.path, chapter.textLength, chapter.blocks.count,
                     item.linear ? "" : "  (non-linear)"))
    }
    print("total text: \(total) UTF-16 units")
    print("toc (\(book.flattenedTOC.count)):")
    for entry in book.flattenedTOC {
        print("  " + String(repeating: "  ", count: entry.depth) + entry.title + "  → " + (entry.path ?? "?") + (entry.fragment.map { "#" + $0 } ?? ""))
    }

case "chapter":
    guard args.count == 3, let index = Int(args[2]) else { usage() }
    let book = try EPUBBook(url: URL(fileURLWithPath: args[1]))
    guard index >= 0, index < book.spine.count else { fail("spine index out of range") }
    let item = book.spine[index].item
    let chapter = XHTMLConverter().convert(try book.data(for: item), documentPath: item.path,
                                           stylesheets: StylesheetLibrary(book: book))
    print("title: \(chapter.title ?? "-")  length: \(chapter.textLength)  anchors: \(chapter.anchorOffsets.count)")
    for block in chapter.blocks {
        var kind = "\(block.kind)"
        var text = block.text.count > 80 ? String(block.text.prefix(77)) + "…" : block.text
        if case .table(let table) = block.kind {
            kind = "table(\(table.rows.count)×\(table.columnCount)\(table.caption == nil ? "" : ", caption"))"
            text = table.rows.first.map { $0.cells.map(\.text).joined(separator: " | ") } ?? ""
        }
        let styled = block.runs.filter { !$0.style.isEmpty }.count
        let notes = (block.alignment == .natural ? "" : " [\(block.alignment)]") + (styled == 0 ? "" : " {\(styled) styled runs}")
        print(String(format: "%6d  %-34@ %@%@  %@", block.textOffset, block.elementPath, kind, notes, text))
    }

case "md5":
    guard args.count == 2 else { usage() }
    print(try PartialMD5.digest(fileAt: URL(fileURLWithPath: args[1])))

case "opds":
    guard args.count >= 2, let url = URL(string: args[1]) else { usage() }
    let credentials = args.count >= 4 ? OPDSCredentials(username: args[2], password: args[3]) : nil
    let client = OPDSClient(credentials: credentials)
    let feed = try await client.feed(at: url)
    print("title: \(feed.title)   kind: \(feed.kind)   entries: \(feed.entries.count)")
    print("next: \(feed.nextURL?.absoluteString ?? "-")   previous: \(feed.previousURL?.absoluteString ?? "-")")
    print("search: \(feed.searchLink?.href.absoluteString ?? "-")")
    for entry in feed.entries.prefix(60) {
        if entry.isNavigation {
            print("  ▸ \(entry.title)  → \(entry.navigationLink?.href.absoluteString ?? "?")")
        } else {
            print("  • \(entry.title) — \(entry.authors.joined(separator: ", "))  epub: \(entry.epubLink?.href.absoluteString ?? "-")")
        }
    }

case "kosync":
    guard args.count >= 4, let base = URL(string: args[1]) else { usage() }
    let client = KOSyncClient(credentials: KOSyncCredentials(serverURL: base, username: args[2], password: args[3]),
                              device: "sheafs-cli", deviceID: "cli")
    print("healthcheck: \(try await client.healthcheck())")
    try await client.authorize()
    print("authorized as \(args[2])")
    if args.count >= 5 {
        if let progress = try await client.progress(for: args[4]) {
            print("document:   \(progress.document)")
            print("progress:   \(progress.progress)")
            print("percentage: \(progress.percentage)")
            print("device:     \(progress.device ?? "-")   at \(progress.timestamp.map { "\($0)" } ?? "-")")
        } else {
            print("no position stored for \(args[4])")
        }
    }

default:
    usage()
}
