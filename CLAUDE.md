# Sheafs

Native EPUB reader for iPhone, iPad and the foldable iPhone Duo, iOS 27.0 and later. SwiftUI + TextKit + Foundation (plus
Metal for the page flip, LinkPresentation for the share sheet's header, PencilKit for markup) only; no web views, no third-party packages. Open source (MIT), so **no personal names, emails,
hostnames or secrets anywhere in the tree** — `scripts/check` greps for them and fails.

## Commands

```bash
scripts/bootstrap                 # Config/Signing.xcconfig (git-ignored) + `xcodegen generate`
scripts/check                     # THE gate: hygiene grep, the site (check-site), Python reference freshness,
                                  #   swift test, simulator build, simulator unit tests (SKIP_SIM_TESTS=1 skips the last)
                                  #   NO_APP=1 stops before the app build; DESTINATION overrides its destination
scripts/swift-parse               # swiftc -parse of every Swift file (no SDK); part of scripts/check step 3
                                  # CI: .github/workflows/check.yml runs scripts/check on PRs and main pushes
                                  #   (macOS runner, newest Xcode; app build only if it has the 27.1 SDK)
scripts/site-shots [name]...      # docs/assets/shots/*.png: the RAW screenshots in the App Store tiles' device
                                  #   frames (book, pair, tabletop, phone, iPad), transparent, no copy; needs Chrome
scripts/check-site [--render]     # the marketing site in docs/ (GitHub Pages, served from main at
                                  #   https://kad-air.github.io/sheafs/): links and assets resolve, meta/OG tags,
                                  #   the page's counts ("nine typefaces", "five highlight colors") against the
                                  #   enums in the code, asset weight; --render screenshots it with headless Chrome
scripts/check-auto-theme          # end to end on a simulator (SIM="iPhone Duo"): theme Automatic follows
                                  #   live Light/Dark flips, incl. the user's own Light/Dark picks (Sepia /
                                  #   pure Black) (reads the page colour off screenshots)
scripts/check-image-viewer        # end to end on a simulator (SIM="iPhone Duo"): a single tap on Alice's
                                  #   cover picture is a plain centre tap, a double tap opens it full screen
                                  #   at the JPEG's own pixels: the whole width on the cover display, only
                                  #   the tapped page's half in book pose (right page and left page), and it
                                  #   closes; folding shut closes it too (reads the picture's extent off
                                  #   screenshots, OUT=/tmp/sheafs-image-viewer)
scripts/check-volume-device       # on the PHONE (unlocked; DEVICE=<udid>, BOOK=<title>, APP=<built .app> or
                                  #   ASC_KEY_* to build): probes the volume one step at a time like presses
                                  #   and asserts each read, turned the right way (landed location) and was
                                  #   put back (the system reported the reference again); the simulator can't
scripts/screenshots [duo|iphone|ipad]  # App Store screenshots: every Duo pose on "iPhone Duo" (Sheafs is
                                  #   reinstalled there), portrait on "Sheafs Shots iPhone"/"iPad" (made if missing) → OUT=/tmp/sheafs-
                                  #   screenshots/{duo-inner,duo-cover,iphone,ipad}/; fresh install, Standard
                                  #   Ebooks books (CC0, cached); fails unless each shot is App Store Connect's
                                  #   size for its display, the hinge reads back, the `[layout]` line shows the
                                  #   pose and the frame has ink. Ask shots (Jane Eyre) need Apple Intelligence
                                  #   on this Mac and fail unless the model answered with passages (answer kept
                                  #   as <shot>.ask.txt); markup/highlights/catalog shots use the DEBUG hooks
                                  #   below. NO_BUILD=1 reuses the last build. iPhone/iPad
                                  #   need `scripts/screenshots prepare` (the iOS 27.0 runtime, 8 GB on the SSD,
                                  #   refused under 12 GB free) and an app whose minimum is 27.0;
                                  #   `scripts/screenshots teardown` deletes those simulators and that runtime
scripts/marketing                 # App Store marketing tiles from those shots: marketing/tiles.json (copy
                                  #   voices, tiles per device) × marketing/styles/*.css, rendered by headless
                                  #   Chrome at the exact App Store sizes → OUT=/tmp/sheafs-marketing (index.html,
                                  #   sheet-<device>.png). Fails on a wrong size, an alpha channel, copy that
                                  #   overflows or is covered, or a screenshot that fails to load (cyan frame:
                                  #   RAW/OUT are made absolute, a relative file:// URL once left every device
                                  #   an empty frame and passed; --selftest proves it fails); missing shots use
                                  #   a STANDIN- tile; --final refuses them. A tile's "width" shrinks its device.
                                  #   --export DIR (one --style, one --voice) writes tiles.json's `sets` in upload
                                  #   order as DIR/<ASC display type>/NN-<tile>.png; the committed upload set
                                  #   is marketing/screenshots/ (final/, raw/, README.md says how to remake it)
cd Packages/SheafsKit && swift test            # the core package, on the Mac, ~1 s
xcodebuild -project Sheafs.xcodeproj -scheme Sheafs -destination 'platform=iOS Simulator,name=iPhone Duo' build
scripts/release                   # fallback only (Xcode Cloud ships, below): archive + upload with an API key
                                  #   (ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID; build = commit count,
                                  #   refuses a dirty tree; --no-upload archives and checks only)
scripts/hinge/hinge 110           # fold the booted Duo simulator (0 closed … 180 flat); `get` reads it
scripts/gen-symbol [preview.svg]  # redraws the control's icon (SheafsWidget/…/sheafs.symbolset/sheafs.svg);
                                  #   a uv script (shapely); commit the SVG, the build validates it
scripts/gen-icon [--preview DIR]  # redraws the APP icon (AppIcon.appiconset: light, dark, tinted 1024s) and
                                  #   the site's icons (docs/assets: 256, 180, 64) from the SAME drawing
                                  #   (scripts/sheafs_mark.py) as SVG rendered by headless Chrome; commit the PNGs
scripts/check-icon [--selftest]   # reads those PNGs back against the drawing (part of scripts/check step 2)
scripts/hinge/hinge orient ll     # turn it: portrait | landscape-left (ll) | landscape-right (lr) | faceup…
                                  #   device landscape = inner display portrait; + a part fold = tabletop
xcrun simctl io <udid> screenshot --display=primary-1 out.png   # inner display (`primary` = cover)
```
`Sheafs.xcodeproj` and `Sheafs/Generated/Info.plist` are generated from `project.yml`; never edit
them, re-run `xcodegen generate` after adding files. Screenshots cannot be written to the external
volume by `simctl` (permission error) — write them under `/tmp` or the scratchpad.

**Shipping:** Xcode Cloud archives every merge to `main` and hands it to TestFlight.
`ci_scripts/ci_post_clone.sh` runs XcodeGen in the cloud (the project is git-ignored) and writes
`Config/Signing.xcconfig` from `CI_TEAM_ID`; the Sheafs target's `scheme:` in `project.yml` exists
so the scheme is SHARED, which Xcode Cloud needs (don't remove it). Xcode Cloud numbers the builds
itself, so don't also upload with `scripts/release` for the same version: the numbers collide.

Launch arguments: `-SheafsOpen <title fragment>` opens the first matching library book at launch;
`-SheafsCatalogURL <url> [-SheafsCatalogName <name>]` adds an OPDS catalog once (keeps keys out of
typed text and transcripts: build the URL in a shell variable);
`-SheafsGoTo <contents title | 0…1>` (with `-SheafsOpen`) moves to a contents entry (exact title, else
the first containing it) or to the paragraph at that fraction of the book that follows another paragraph
(a full spread, no orphaned heading), without a "Back to page N" trail;
`-SheafsAppearance quick|full` (with `-SheafsOpen`) opens the quick appearance panel or the detailed
sheet once the book is ready.
`-SheafsThemeSwitch paper|sepia|night|system` (with `-SheafsOpen`) switches the theme 5 s after the
book is ready, as tapping its swatch would.
`-SheafsSearch <text> [-SheafsSearchPick <n> [-SheafsSearchBack YES]]` (with `-SheafsOpen`) opens the
search sheet with `text` searched; with a pick it then takes the n-th result (1-based) as a tap would:
the jump and the painted hits, no taps needed (`[search] …` lines on stdout); with Back it then taps
"Back to page N" 3 s later, which must clear the hits.
`-SheafsBookmark toggle|jump` (with `-SheafsOpen`, once the page is laid out) toggles the bookmark on
the page at the position, or `jump(to:)`s to the book's first bookmark (leaving a "Back to page N"
trail); `-SheafsContents contents|bookmarks|notes` opens the contents sheet on that segment.
`-SheafsOpenImage <n>` (with `-SheafsOpen`) moves to the book's nth picture (1-based, reading order)
and, once its page is up, single-taps its middle (`PagerController.tap(at:)`, the single-tap
recognizer's action) and then double-taps it (`doubleTap(at:)`, the double-tap recognizer's action,
behind the same `acceptsDoubleTap` its `shouldReceive` uses; not the recognizers' timing);
`-SheafsOpenImageSide left` puts the picture's page on the left of a spread; `-SheafsCloseImageAfter
<s>` closes the viewer that long after, as ✕ does. The app prints `[tap] at … → center`,
`[image] double tap at …`, `[image] viewer shown … pixels=WxH … viewport=…` and `[image] viewer closed`.
`-SheafsFlipAuto forward|back
-SheafsFlipFreeze <0…1> [-SheafsFlipGrab <0…1 down the page>]` starts one page flip on its own
once the book is up and holds it at that amount, so `simctl io … screenshot` can catch the leaf
mid-air (the next tap lands it).
`-SheafsSelect <0…1>` (with `-SheafsOpen`) selects the sentence at that fraction of the reading
position's page 1 s after the book is up and opens the selection menu, as a long press would (simctl
cannot long-press); `-SheafsSelectThen share` then taps Share, so the share sheet can be screenshotted.
DEBUG builds only, for the App Store shots (`Reader/ScreenshotDemo.swift`): `-SheafsHighlightDemo
"<phrase>|<phrase>…"` (with `-SheafsOpen`) highlights the first place in the book each phrase occurs,
through the highlight colours, via the menu's own `add` (`-SheafsHighlightNote <text>` notes the first);
`-SheafsMarkupDemo "page=<phrase>|underline=<phrase>|circle=<phrase>|bracket=<phrase>|note=yes!"` puts
the first phrase at the top of the (right-hand) page, starts markup, draws hand-like strokes made from
the text's geometry onto the REAL canvases and ends markup like Done, so `MarkupSession.commit` anchors
and saves them as any drawing (`-SheafsMarkupStay YES` leaves markup up; `[demo] …` lines; the hand
only writes y, e, s, !); `-SheafsBrowse <catalog name>` opens the Catalogs tab on that catalog.
`xcrun simctl openurl <udid> "sheafs://open?book=<uuid>"` is the widget's tap (the simulator asks
"Open in Sheafs?" first; a real widget tap doesn't). `simctl get_app_container <udid>
io.sheafs.reader group.io.sheafs.reader` is the folder the widget reads.
Dropping `.epub` files into the app's Documents folder (`xcrun simctl get_app_container <udid>
io.sheafs.reader data`/Documents) imports them on the next launch or foreground.

Running on a real Duo, headless: the same `xcodebuild` with `-destination 'platform=iOS,id=<udid>'`,
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration` and an App Store Connect API key
(`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`), then `xcrun devicectl
device install app --device <udid> <Build/Products/Debug-iphoneos/Sheafs.app>`. `xcrun devicectl
device process launch --console --device <udid> io.sheafs.reader` streams the app's `print` output:
the reader logs a `[layout] …` line (size, safe area, regions, page frames) on every geometry change,
and `GeometryProbe` logs the raw reserved regions. The simulator is not the device for reserved
regions (see Duo behaviour below), so check layout changes on the phone.

## Architecture

- `Packages/SheafsKit` (Foundation + Compression + CryptoKit; builds on macOS so tests are fast):
  - `Zip/ZipArchive` — read-only ZIP (ZIP64, data descriptors, CRC-verified raw DEFLATE via Compression).
  - `EPUB/EPUBBook` — container.xml → OPF (metadata incl. calibre/EPUB3 series, manifest, full spine,
    cover) → TOC (EPUB3 nav first, NCX fallback). `EPUBPath.resolve/split` for hrefs. Lenient XML
    retry through an entity sanitizer.
  - `Text/XHTMLConverter` → `Chapter` of `Block`s (`Block.swift` is the contract). Tolerant hand-rolled
    tokenizer, NOT XMLParser. Every block records a CREngine `elementPath` (`/body/section[1]/p[3]`,
    1-based among same-tag siblings, void elements don't count) — the exact algorithm validated
    against real KOReader/CrossPoint device pointers; `scripts/gen_chapter_reference.py` is the
    Python twin. 🔴 Offsets contract: block text + "\n" per block, UTF-16 units, images and rules are
    exactly one U+FFFC; the app's `Typesetter` must (and does) produce an attributed string of the
    same length so a `textOffset` is an `NSAttributedString` index. `SheafsTests` pins it.
    The publisher's CSS (`Text/Stylesheet`): the head's `<link rel="stylesheet">`s (through a
    `StylesheetLibrary`, which reads and parses each zip path ONCE per book, single-flight under a
    per-file lock even while `BookSession` converts chapters in parallel, and follows `@import`)
    and `<style>` blocks (`<![CDATA[`/`<!--` wrappers stripped), in document order; a `media`
    attribute must be absent, `all` or `screen`. Selectors are tag/`.class`/`#id`/`*` compounds
    with descendant and child chains; a selector with anything else (pseudo-classes and -elements,
    attribute selectors, `+`/`~`) is dropped WHOLE, so `p::first-letter` never styles the paragraph.
    🔴 Rules inside `@supports` ALWAYS apply and inside `@media` when the query is absent, `all` or
    `screen` (not `print`, not feature queries): Standard Ebooks' core.css hides the title page's
    h1/p and the imprint/colophon h2 with `display:none` for ADE and shows them again inside
    `@supports(font-size: 0)`; honouring only the hide lost every SE title page. Other at-rule
    blocks (`@font-face`, `@page`) are skipped. Cascade: the tag's own style (`em` italic, `b`/`dt`
    bold: the user-agent sheet) first, then specificity and source order, then the `style`
    attribute, then `!important` (also `! important`); declarations on `html` reach `body`. Applied
    where the frame is built (`ChapterBuilder.cssProperties`), semantics only:
    italic/bold/small caps/underline/strike, ON and OFF (`font-style: normal` un-italicises an
    `<em>`); `vertical-align: super`/`sub` add raising, and `baseline` NEVER takes a `sup`/`sub`
    tag's away (normalize.css sets it on every `sup` and raises with `position`); center/right
    alignment; `display: none`, which skips the content like `hidden` while the element and its
    children still take their path steps (CREngine counts them) and their ids still record anchors
    at the offset where they stand (a note in a hidden `aside` doesn't fall back to offset 0).
    Small caps that replace the markup's bold (SE's `b, strong { font-variant: small-caps;
    font-weight: normal }`) carry `InlineStyle.boldAsSmallCaps`: `Typesetter.hasSmallCaps` reads
    the face's features, and Georgia, Palatino, Charter and Times New Roman have none, so there the
    run is drawn BOLD instead of vanishing into plain roman (`FontTests` records each family). 🔴
    `text-align: justify`/`left` (and `align="justify"`) read as `.natural`: justification is the
    reader's setting, and `Typesetter` justifies a `.justified` block whatever it says. Not read:
    colours, fonts, sizes, margins, text-indent, `text-transform` (it would change the text
    length); not supported: `text-decoration` propagation (a descendant's `none` does remove an
    ancestor's underline here, unlike a browser) and `@import` inside a `<style>` block.
    Hidden content shifts offsets, so positions and highlights saved before stylesheets were
    honoured are RE-ANCHORED on open (`Text/ChapterPositions`): the reading position follows
    `book.xpointer` when it names a block of the same chapter at another offset, and a highlight
    whose offsets no longer hold its quoted `text` moves to where its start/end pointers say, if
    the text is there (`BookSession.reanchor`, logged; else left alone); bookmarks follow their
    `xpointer` like the position. `StylesheetTests`,
    `ChapterPositionsTests`; `ChapterReferenceTests` runs every fixture chapter with and without
    its stylesheets against the Python reference.
    A `<table>` is ONE `.table(TableContent)` block: rows (each with its `tr`'s CREngine path) of
    cells (own runs, `th`/`thead` header flag, colspan, cell alignment), plus the caption. 🔴 Its
    text is one U+FFFC PER ROW plus one for the caption, joined by U+2028 (`objectText`; row k at
    offset 2k), NOT one U+FFFC for the whole table: each row is then its own line, so pagination
    breaks between rows and a 100-row list of illustrations is not cut at one page. The cell text is
    NOT in the plain text. Find-in-book searches it anyway: `FoldedText` folds each row's text
    (and the caption's) onto that row's ONE object character, so a hit in a table is that
    character, several hits in a row are several hits on it, and the snippet is the row's text.
    A selection or highlight there covers whole rows, and is QUOTED as the rows' text: `Chapter.displayText(in:)` / `TableContent.plainText`,
    used by the selection's text, Copy, Look Up, quote sharing, the highlight's `text`, the
    export, footnotes, bookmark labels and `PageView.accessibilityLabel`). Positions resolve to rows: `Chapter.pointer(at:)` gives a row's
    `tr` path with no `text()` offset, `Chapter.offset(of:exact:near:)` maps a pointer into a row or
    cell back onto its row, exactly (`near` picks the part of a row an image split;
    `BookSession.location(for:near:)`); re-anchoring compares a highlight's quote with
    `displayText` too, so highlights over rows re-anchor like any other. 🔴 Not every `<table>` is a table:
    `TableShape` (the converter holds a table's tokens back until its end tag, decides, replays)
    FLATTENS it into ordinary blocks, the old behaviour (a row of plain cells = one paragraph,
    cells joined by an em space; headings/paragraphs in cells = their own blocks), when a cell
    holds a heading, list, blockquote or `pre`, two or more paragraphs (`p`, or `div` with text;
    ONE `<p>` per cell is what calibre writes and stays a table), more than 600 non-space
    characters, or when the table has a single column. That is what LAYOUT tables need: as one
    row they'd be cut at the page and every anchor in them would resolve to the row. Blocks in a
    cell become U+2028 lines, a nested table flattens into its cell, cells outside any `tr` make
    one row, an image in a cell splits the table around it (both parts keep the table path; rows
    left with only empty cells are dropped and the rest of the split row carries on in its column,
    `Row.firstColumn`). The Python twin records tables too (`tables` per document, plus the loose
    `Fixtures/table-chapter.xhtml` and `table-shapes.xhtml`), makes the same flatten decision
    (`TableDecider`, two passes) and counts a `<p>` as a paragraph only outside kept tables;
    `TableTests` compares them with whitespace runs normalised, nothing looser.
  - `Text/XPointer` — `/body/DocFragment[N]/body/…/p[K]/text()[k].off` parse/serialize (N 1-based
    over the FULL spine). We always serialize with indices (CrossPoint style); parsing tolerates
    missing `[1]`.
  - `Companion/` — the reading companion's lookup (Ask, below), no model in it: `ReadSoFar` is 🔴 the
    spoiler wall: the text before a `ReadingLimit` cut into `Passage`s (paragraphs gathered to ~700
    UTF-16 units, headings start one, long paragraphs split at sentences, a block over the limit cut
    to the last whole word before it); `PassageIndex` (BM25 over folded words, plus proper names
    found mid-sentence, one- and two-word; `presentTerms` keeps only search words the read text has;
    first/last mentions); `AskContextBuilder` fills a character budget (a fifth for the passages just
    before the limit, then each term's first and last mention and the best matches, then chapter
    summaries latest first, then more matches) and ignores summaries at or past the limit's chapter;
    `RecapPlan` cuts a chapter into parts for summarising and keys a summary to the chapter's text.
    `CompanionTests`.
  - `Text/BookSearch` — find-in-book. `BookSearchIndex(chapters:)` folds each chapter's text ONCE
    (case, diacritics, width, NFKC, curly → straight quotes, whitespace runs → one space, soft
    hyphens and other default-ignorables dropped; one character at a time, the query the same way)
    into UTF-16 units mapped back to the original character's range, then every search is a scan.
    A `SearchHit` is `spineIndex` + a UTF-16 `range` in the chapter plain text (the position and
    highlight contract), always whole grapheme clusters; matches never cross blocks; `snippet(for:)`
    gives whole words either side. `BookSearchTests` pins hits against per-chapter counts Python
    made from the raw XHTML and against non-BMP/combining/ß cases.
  - `OPDS/` — Atom OPDS 1.2 parser (+ OpenSearch), `OPDSClient` (pre-emptive Basic auth, streaming
    download), `CatalogCopy` (what the library keeps of a downloaded entry: its Atom id, link and
    `updated`; `OPDSEntry.matches` finds the book by id, else link, else a `urn:uuid:` that is a whole
    segment of both paths, so a file the server renamed is still the same book; `isNewer(than:)` is
    the entry's `updated` past the copy's, or past `addedAt` for books from before; `CatalogShelf`
    indexes the library for a feed page; `CatalogCopyTests`). `KOSync/` — the vanilla KOReader sync protocol; `PartialMD5` is the document key
    (offsets 0, 1 KiB, 4 KiB … 1 GiB; 🔴 the i = −1 read is at offset 0, not 256, matching KOReader's
    32-bit shift — pinned against an independent Python digest, `2d54ce2c…` for hub-fixture.epub).
- `docs/` — the marketing site, plain HTML + one stylesheet, no JavaScript, no build step. GitHub
  Pages serves it from `main` (`/docs`), so a merge publishes it. Paths are RELATIVE (the site lives
  under `/sheafs/`), `.nojekyll` keeps Jekyll off it, and `assets/shots/*.png` are the raw
  screenshots in device frames, made by `scripts/site-shots` (which imports `scripts/marketing` for
  the frames and `marketing/base.css` for the layouts; never edit the PNGs by hand, re-run it). The
  headlines are HTML, in the App Store listing's casual voice; `scripts/check-site` holds its counts
  to the code and the shots to the script's list.
- `Sheafs/` (app, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 6 strict):
  - `App/` — `SheafsApp` (SwiftData container, environment objects, open-in, Documents import),
    `RootView` (tabs Library / Catalogs / Settings; the reader is a `fullScreenCover`).
  - `Library/` — `Models` (SwiftData `Book`: position = `spineIndex` + `textOffset` + `xpointer` +
    `progress`; `Catalog`), `Annotations` (SwiftData `Annotation`: a highlight = `bookID` +
    `spineIndex` + `startOffset`/`endOffset` in the SAME UTF-16 chapter offsets as the position,
    plus the CREngine pointers of both ends, the quoted `text`, a `note`, a `HighlightColor` and
    `isUnderline`; keyed by book id, not a relationship, so `LibraryStore.delete(book)` deletes them
    by hand; `AnnotationExport.markdown` for sharing a book's notes, `AnnotationExport.quote` for one
    selection: the text, a newline, `— Author, Title, Chapter`; both credit the book through
    `AnnotationExport.Credit`, so they can't drift; only the quote's attribution drops a chapter
    named like the book, the Markdown still heads it: a collection named after a later story;
    the Markdown ends with a "## Bookmarks" list), `Bookmarks` (SwiftData `Bookmark`: `bookID` + `spineIndex` + `textOffset` of the FIRST
    character of the page holding the position (the right page of a spread) + its `xpointer` + a
    `label` (the page's first words, `Bookmark.label`) + `createdAt`; keyed by book id like
    `Annotation`, deleted by hand with the book; the anchor is an offset, NEVER a page number:
    `PaginatedChapter.bookmarks(_:onPage:)` puts one on whichever page's range holds it, so it
    survives text-size changes, `BookmarkTests`), `LibraryStore` (files in Application
    Support/Books/<uuid>.epub, covers in Covers/<uuid>.jpg, import = copy + parse + partial MD5 +
    thumbnail, dedupe by partial MD5; `replaceFile(of:with:)` swaps a book's file IN PLACE (same
    id, so position, highlights and bookmarks stay; title, author, cover and partial MD5 become the
    new file's; refuses another book's bytes; `CatalogUpdateTests` with `alice-epub3-edited.epub`, a
    new cover and title made by a server-side editor, chapters byte-identical); `remember(_:link:…)`
    ties a book to its catalog entry; `annotations(for:)`/`bookmarks(for:)`/`add`/`delete`), `LibraryView` (cover grid;
    even column count when a fold is present, per the Duo HIG).
  - `Reader/` — `BookSession` (loads the EPUB and converts every chapter in a detached task; caches
    typeset+paginated chapters per style/page size; position ↔ progress ↔ xpointer ↔ TOC/href),
    `Typesetter` (Block → NSAttributedString with the user's fonts; a table block becomes one
    `TableRowAttachment` per row/caption, laid out by `TableLayout`: columns sized to content
    within the page width, too-wide tables scaled down and RE-MEASURED at each scale until they
    fit (type doesn't narrow in proportion; the search re-measures only each column's widest cells,
    then the whole table once); below 0.6 the WIDEST columns are cut to one level (`levelled`), so
    short words never break, cells in the reader's font at
    90 %, header bold, light rules, caption beneath; a row never exceeds the page minus the
    spacing around the table: a taller one is set smaller (to half size), only then cut. CoreText
    measuring, each distinct cell string once per scale (`TableLayout.Measurer`), run attributes
    and fonts made once per style and size (`CellStyler`); rows render lazily in `image(forBounds:…)` at the drawing context's scale,
    so nothing is cached and a style change re-typesets them with the rest; a 1 pt filler font and
    zero line spacing make the rows abut; links in cells are hit-tested through
    `PageView.tableLink` → `PaginatedChapter.attachmentFrame`; `TableLayoutTests`), `Paginator` (`PaginatedChapter`:
    one TextKit 1 `NSLayoutManager`, one `NSTextContainer` per page, drawn by `PageView`),
    `ReaderPager` (`UIPageViewController` .scroll whose units are spreads of 1–2 pages;
    tap zones turn pages, centre tap toggles chrome, link and highlight hit-testing; DOUBLE-TAP a
    picture to open it (Kindle's convention; a single tap on a picture does what it does anywhere):
    `PaginatedChapter.images(onPage:)` gives each attachment's character, `src` and drawn rect (its
    cell on the baseline; a missing picture's placeholder is not tagged, so it is plain text). 🔴 The
    double-tap recognizer's `shouldReceive` takes only touches ON a picture of the spread on screen
    (no selection, no turn in flight) and the single tap `require(toFail:)`s it, so the 0.3 s wait
    for a second tap happens only when the first lands on a picture; never let it take other touches.
    A double tap becomes `ReaderTap.image` with the page's window frame, and `ReaderView` overlays `ImageViewer`
    (`ImageViewer.swift`: the picture at its own resolution from `BookSession.fullImage`, not the
    page's downsampled attachment, in a zooming `UIScrollView` 1–4×, double-tap zoom, swipe down or ✕,
    the alt text as caption, Share; the page colour behind it, so the forced scheme holds). 🔴 Over a
    VERTICAL fold (flat or book pose, like the spread) the viewer keeps to the HALF of the window on
    the tapped page's side (`ImageViewerLayout.viewport`), never across the hinge; over an active
    horizontal fold (tabletop) the upper half; else the whole window. A display change that moves
    that viewport (fold, unfold, rotation, tabletop; not book pose ↔ flat) closes the viewer, since
    the tapped page's side is stale. Its buttons and caption keep clear of `CoverCamera` like the
    running head; `ImageViewerTests`, `scripts/check-image-viewer`; text
    SELECTION: a long press selects the word under the finger and grows by words while it moves,
    two `SelectionHandleView`s then adjust it by characters, a `UIEditMenuInteraction` offers
    Highlight / Note / Color / Copy / Share / Look Up; the selection lives in `PagerController`, the
    spread only provides geometry and the `PageView`s draw it; a tap, a page turn or a layout
    change clears it), `AnnotationViews` (`AnnotationEditorView`: colour, underline, note, show in
    book, delete; `NotesListView`: the Notes segment of the contents sheet, share as Markdown),
    `BookSearchView` (`BookSearchModel`, owned by `ReaderView` for the reader's life: builds the
    index detached on first open, searches debounced 250 ms off the main actor, each cancelling the
    last, lists the first 500 hits grouped by chapter with counts; reached from the toolbar's
    magnifying glass, the contents sheet and the tabletop deck. A result jumps through `jump(to:)`
    (so it leaves a "Back to page N" stop) to `BookSession.pageStart(showing:inSpine:)`: the page
    holding the hit, a chapter not laid out yet being laid out anchored at the hit's PARAGRAPH,
    not the hit, so the page isn't cut mid-line; the query's hits in that chapter become
    `HighlightMark`s with `isFound` (orange band under the glyphs, not tappable) until the next
    page turn, tap, jump or back (`show()` never reports a location change, so `jump(to:)` and
    `goBack()` clear them by hand); `FindInBookTests`),
    `QuoteShare` (Share in the menu: `UIActivityViewController` with its popover source at the selection (on
    the Duo, iOS 27 shows a centred card on both displays anyway); items are the quote text and a `QuoteCard` image, 1080 pt at scale 1 in the
    palette's page colour and the reader's font, as tall as the text up to 9:16 where TextKit ends
    the text with an ellipsis, on the card only (TextKit draws one only when the last kept line runs
    on in its paragraph; a cut at a paragraph's end gets "…" appended by hand); text-first targets
    (Messages, Mail, Notes, Reminders, Copy) get the text alone; the item sources are
    `nonisolated` (UIKit may ask for items off the main thread); the sheet's header is `LPLinkMetadata` (the card as icon, the book as
    title; without it a blank placeholder); Save Image needs `NSPhotoLibraryAddUsageDescription`
    in `project.yml` or the system leaves it out; Share clears the selection like Copy; the share
    sheet and Look Up (`LookUpController`, which reports its dismissal) are UIKit sheets SwiftUI
    can't see, so the pager reports them (`onSystemSheet`) and `volumeButtonsArmed` disarms the
    volume buttons while one is up;
    `QuoteShareTests`), MARKUP (`Markup.swift`, `SketchLayout.swift`, `Library/Sketches.swift`): the
    toolbar's Markup button hides the bars and `PagerController.beginMarkup()` puts a `PKCanvasView`
    over each page of the spread with the system `PKToolPicker` (drawing policy `.default`, so the
    system's "only Apple Pencil draws" setting holds); taps, selection, the flip pan and scrolling
    are OFF until Done; `MarkupBar` (over the right page's running head; the tool picker takes the
    bottom) turns pages (`markupTurn`: save, turn without animation, put the canvases up again) and
    ends it; volume buttons and `show()` (a fold, rotation or style change) save first. A marking is
    a SwiftData `Sketch` (`bookID`, chapter, the range of text it is on or beside with both
    pointers and the quoted `text`, the strokes as `PKDrawing` data, `SketchAnchors`, a JPEG
    thumbnail of the marking over its text cut from the page; keyed by book id, deleted with the
    book). 🔴 Strokes are anchored to TEXT, never to the page: EVERY control point stores an anchor
    character, an offset (x from that glyph or from the column edge, y from its baseline) and the
    start of its line when drawn (`SketchLayout.capture`), and `SketchLayout.place` puts each point
    back from where that character's glyph is NOW (`PaginatedChapter.glyphPlace`), on whichever
    page holds it: a stroke over the text (≥ half its points over glyphs, inside the column: circle,
    underline, strike-through) keeps each point to the character under it in EMS, so it stretches
    with its words (🔴 a point over a gap, or over a word at either end holding under a tenth of
    the stroke's points on that line, keeps to the nearest letter of a word the stroke IS over:
    a circle's clearance grazes the words beside it, and anchoring there tore the circle apart
    when they wrapped away), and two points that shared a line and no longer do are not joined
    (an underline is cut where its words now wrap); a stroke the size of a passage (2+ lines tall
    and thin, or across half the column or more: a bracket, a circle around a paragraph, a
    scribble through it) is a `.block`: 🔴 it holds the passage as a whole (first character of its
    first line in `characters`, last of its last in `lineStarts`) and each point's place down the
    run of lines (0…1 by lines, ems beyond either end) and across the column (0…1, points out in
    the margin), and is stretched over wherever that run is now, cut at a page break (anchoring
    each point to its line's first character scattered brackets and paragraph circles: after a
    reflow those characters are mid-line; old `.span` brackets still place that way); anything else (margin
    notes, arrows, 4+ small strokes = handwriting anywhere) is rigid, all of a marking's from one
    reference character (the first one its text strokes hold, else the nearest) and the column edge
    on its side, moved as one to stay on the page. At the layout it was drawn in a marking comes back
    to within float precision. Pages draw the placed strokes OVER the glyphs (`PageView.drawSketches`,
    `PKDrawing.image` under the page's light/dark trait so PencilKit adapts dark inks like its
    canvas; also on the flip's leaves) and hide them while their canvas is up. `MarkupSession.commit`
    tells strokes apart by `randomSeed` (pieces of one stroke placed apart get derived seeds): a
    marking with a stroke erased, moved, recoloured or with new strokes drawn against it is
    captured again from the canvases, its points on no canvas kept as they were; other new strokes
    form new markings, one per cluster (bounds within 0.8 em); the session's `sketches` are updated
    at once and `ReaderView` writes the edits (`LibraryStore.apply(_:for:)`). Markings re-anchor
    on open like highlights (`BookSession.reanchor(_ sketches:)` shifts every anchor). The notes
    list shows them with the highlights in reading order (`NotesListView.entries`): thumbnail +
    text, tap to go there, swipe to delete; the Markdown export quotes their text. Not synced.
    `SketchTests`. `BookmarkViews` (`BookmarksListView`: the Bookmarks segment, between Contents and Notes; label,
    chapter, date; tap = `jump(to:)`, swipe to delete; the segment is kept between openings),
    `ReaderLayout`
    (`PageLayout.compute`: safe areas + reserved regions → page frames; see Duo below),
    `ReaderView` (chrome: system toolbar + glass progress strip, contents/appearance/footnote sheets,
    sync pull on open / debounced push; `@Query` of the book's annotations → `HighlightMark`s →
    `BookSession.marks`, which every spread reads as it appears; the same for bookmarks →
    `BookmarkMark`s → `BookSession.bookmarks`, drawn by `PageView` as a ribbon hanging from the top
    edge over the text's right edge (left of the cover camera's hole; the running head narrows to
    clear it), never added to the text; the toolbar's (and `ReaderDeck`'s) bookmark toggle reflects
    the page holding the position (from `laidOutChapter`, never laying one out) and adds a bookmark
    at that page's first character or removes every bookmark on it; every `jump(to:)` — link, contents, note,
    slider, accepted sync — pushes the place it left onto a `ReturnTrail`, shown as a glass "Back to
    page N" capsule over the folio of the page holding the position (in the progress strip while
    the bars are up); ✕ forgets the trail, paging back onto a stop drops it; `ReturnTrailTests`), `ReaderSettings` (incl. the
    last-used highlight colour; the shared slider ranges/grids and `step(_:by:grid:in:)`), `Theme`,
    `AppearanceView` (the detailed sheet, also embedded in Settings), `QuickAppearanceView`.
    Appearance is two-level: the toolbar's (and the tabletop deck's) Appearance button hides the bars
    and floats `QuickAppearanceView` over the bottom of the page (themes, size, font, spacing,
    margins, justify/hyphenate/indent), so the text being adjusted stays visible; a centre tap or ✕
    closes it, edge taps still turn pages, and its sliders button steps through to the detailed sheet.
    Over a vertical fold (spread, book pose) the panel keeps to the LEFT page: off the fold, and the
    right page, which holds the reading position, stays in view. Its −/+ buttons move along the
    detailed sliders' grids (`QuickAppearanceTests`). Fonts are picked from `FontList` (each name in
    its own face; a popover from the panel, a pushed page from the sheet), not a `Menu`/menu
    `Picker`: system menus draw every item in the system font. `FontTests` checks every family is
    really installed (a missing one falls back to the system font without a word) and records
    which have small caps. Blockquotes are NOT italicised by the typesetter (letters and epigraphs
    are blockquotes; the book's markup and stylesheet say what in them is italic).
  - `Reader/Ask/` — Ask About the Book (setting `askEnabled`, off by default; Settings → Ask About
    the Book): questions on plot and characters answered by Apple's on-device model (Foundation
    Models, Apple Intelligence devices only; `AskEngine.availability`) from the text up to the END
    OF THE PAGE holding the position (`ReaderView.readingLimit`), never further. The context is
    4096 tokens for prompt and answer together (`SystemLanguageModel.contextSize`, TN3193), so
    `AskModel` asks the model for search words (names, the other names the same people go by,
    picked from the read text's names; cut to `presentTerms`), builds the context with
    `AskContextBuilder` (budget at 3 characters a token; a context-too-long error retries at 3/5),
    and streams the answer; the model is never told the title or author and is told to use only
    the excerpts. `RecapBuilder` summarises FINISHED chapters (wholly before the reader's) in the
    background while the reader is up and Ask is on, latest first, chunk-and-carry (each part
    rewrites the running summary), pausing while a question is answered; stored per book as JSON
    in Application Support/Recaps (`RecapStore`, deleted with the book). Guardrails are
    `.permissiveContentTransformations` (book text is violent). `AskPanel` floats over the bottom of
    the page like the quick appearance panel (left page over a vertical fold; a centre tap or ✕
    closes it; edge taps and the volume buttons still turn pages, and turning on moves the limit
    on, never back: `AskModel.extendLimit`). It shows one answer with the passages it came from (`AskContext.citations`: the context's
    excerpts, recent ones included, scored by the answer's words they share);
    tapping one jumps there with the panel up, and the panel carries "Back to page N" (it can
    cover the folio's). Finished answers and their passages are saved per book as JSON in
    Application Support/Ask (`AskHistoryStore`, newest 200, deleted with the book; the panel's
    history and Settings delete them too) and listed under the panel's clock button. A follow-up
    question carries the previous answer only from this opening and within the current limit.
    `-SheafsAsk <question>` (with `-SheafsOpen`) asks once and prints `[ask]` lines;
    `-SheafsAskOpen 1` opens the panel and prints the saved questions; `-SheafsAskSource <n>`
    then opens the answer's nth passage. Not on the tabletop deck.
  - `Reader/VolumeButtons` — `VolumeButtonPager` (setting `volumeButtonsTurn`, off by default):
    up = next page, down = previous (`Press.turnsForward`, the owner's choice). iOS has no public
    volume-button event outside a camera session (`AVCaptureEventInteraction` reaches only apps
    actively using the camera), so this is the trick Readest uses too: an active `.playback` +
    `.mixWithOthers` session makes `outputVolume` observable; `PressReader` reads a press as a step
    from the PREVIOUS reading, and after EVERY press the hidden `MPVolumeView`'s slider (searched
    for in its subtree each time, else the one it had when made; on the simulator it swaps the
    slider for a label once in a window) puts the volume back to a reference, so the level is
    back within milliseconds (a blip, if music is playing). The first reading within 1 s of a
    put-back that lands nearer the reference is that landing, not a press, 🔴 and the landing
    BECOMES the reference: the device moves in its own steps (Duo, iOS 27.1: 0.0, 0.05, 0.15,
    0.2, 0.25, 0.3), a put-back to a value off that grid lands beside it (0.125 → 0.15) and one to
    a value the device reported lands exactly (0.25 → 0.25), and build 7, which kept aiming at
    0.125, read every landing as a press and turned pages at random. The reference starts as the
    user's volume kept within 0.1…0.9 (at 0 a down press changes nothing and goes unseen; inside
    that range the level is not moved at all). The volume view sits ON screen (origin, 1 pt,
    alpha 0.01): off-screen it no longer hid the system volume HUD on iOS 27; on screen it does
    (confirmed on the Duo, keep it there). `ReaderView.volumeButtonsArmed` runs it only while the
    scene is active, the book is ready, the regions are known and no sheet is up (SwiftUI sheets, and the pager's UIKit share sheet and Look Up), and arming
    RETRIES until the pager is in a window (it appears after the regions; arming once gave up
    silently). Stop restores the user's volume. `VolumeButtonTests` replays the device's log. The
    simulator can't press the buttons (and setting the hidden slider there changes nothing: no
    volume route), so `scripts/check-volume-device` runs on the phone. Every step (arming
    decisions with each condition, session state, the volume view's subview tree, each reading
    with the reference, each turn with the location before it and where it landed) goes through
    `VolumeLog.note`: a public `Logger` notice (category `volume`), stdout (for `devicectl
    … launch --console`) AND an in-memory buffer shown and copied in Settings → About → Volume
    Button Log, so a TestFlight run can be read without a Mac.
    `-SheafsVolumeProbe up,down,…` (arms the buttons whatever the setting says) moves the volume
    one step through the slider per entry, `-SheafsVolumeProbeGap` s apart, from 1.5 s after arming.
  - `Reader/PageFlip/` — the default page turn (`ReaderSettings.pageTurn`, `.flip` or `.slide`): a
    leaf of paper hinged at the spine that bends and falls over. `PageFlipPhysics` is the model
    (`PageCurl`: the sheet lies flat to `flat`, wraps a cylinder of `radius`, the rest lies turned
    over on top; the sheet's length is always the page width, the free edge goes where the finger
    is, the bend travels to the spine and then shrinks as the leaf falls; `tilt` lets the held
    corner lead; `FlipSpring` is the critically damped release). `PageFlipShader` is the Metal
    fragment shader (inverse mapping per pixel: turned-over part, back and front of the bend,
    flat part, else the page beneath; lighting, a cast shadow beyond the leaf's silhouette, a
    mirrored show-through "ghost" for the back of a single page). `PageFlipView` (MTKView, opaque,
    covers the pager while a turn is in flight) renders pages to textures through
    `PageView.render(in:)`. `PageFlipDriver` builds the scene for a turn (a spread turns like a
    book: the leaf's back is the page that lands face up on the other side; a single display is a
    pad printed on one side), follows the pan or runs the spring on a CADisplayLink, and calls
    `PagerController.install(spread:…)` under the opaque leaf as the turn starts and `announce(location:)` a frame after it lands (the save and the prefetch never share the landing frame). `SheafsTests`
    pins the physics against numerical integration, and `PageFlipShadowTests` renders the real
    shader offscreen (leaf red, page beneath blue, so blue reads the shade) and pins the shadow.
  - `Catalog/` — OPDS browser (catalog list, add/edit, feed browser with pagination/search,
    entry detail + download → `LibraryStore.importBook`). When the entry's `updated` is newer than
    the book's `sourceUpdated` the grid badge reads Update and the entry offers Update →
    `LibraryStore.replaceFile`. 🔴 The partial MD5 changes with the file, so the kosync key does: a
    server that keeps the old key as an alias of the new returns the same position under either;
    any other starts the new key empty and gets the next saved position. `Book.sourceEntryID` /
    `sourceUpdated` are optional (a lightweight SwiftData migration); books from before have neither
    and are matched by link or UUID, measured from `addedAt`.
    `BuiltInCatalog` (Standard Ebooks, Project Gutenberg): `seed(into:)` at launch adds each one
    ONCE, keyed by id in `UserDefaults` (`SheafsSeededCatalogs`), after the user's own and never
    beside a feed they already have (`isSameFeed`: host case and trailing slash ignored); a deleted
    one stays deleted and comes back only from Add Catalog's Free Catalogs section. Once added it is
    an ordinary `Catalog`. Standard Ebooks' OPDS feed is for Patrons Circle members (Basic auth,
    their email as the username, password unchecked): on a 401 the browser shows `signInNote`.
    Gutenberg's documented OPDS start is `search.opds/` (its XML OPDS is due to be replaced by
    OPDS 2 JSON in 2027). `BuiltInCatalogTests`.
  - `Settings/` — `SettingsView` is a short grouped list (Reading → `AppearanceView(embedded: true)`,
    Library → storage stats, Sync & Accounts → the kosync account, About), each row pushing its
    own screen (`LibrarySettingsView`, `SyncSettingsView`, `AboutSettingsView`). `Sync/SyncService` — kosync
    settings (password in the keychain) + `pull`/`push`.
- `SheafsWidget/` (app extension, `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`: WidgetKit's
  providers are nonisolated) — "Continue Reading", `systemSmall` only: the most recently read book's
  cover (blurred cover behind it), a progress bar, tap → `sheafs://open?book=<uuid>`. `Shared/`
  (`RecentBook.swift`) is compiled into BOTH targets: `RecentBookShelf` is the app group
  `group.io.sheafs.reader` (`recent-book.json` + a 480 px `recent-cover.jpg`), `SheafsLink` the URL.
  The widget cannot see SwiftData or Application Support, so the app pushes a snapshot:
  `LibraryStore.publishRecentBook()` (most recent = `lastOpenedAt ?? addedAt`, like the library grid)
  runs at launch, on import/delete, on reader open and on every saved position; it writes and
  reloads the timeline only when the snapshot changed (progress rounded to whole percents). The
  timeline policy is `.never`. `SheafsApp.onOpenURL` sends `sheafs://` to
  `AppNavigation.open(bookWithID:in:)` and everything else to import. `WidgetTests` pins the URL
  type, the embedded extension and the app group entitlement (fails without it).
  `ContinueReadingControl` (same extension) is the Lock Screen corner / Control Center / Action
  button CONTROL: a `ControlWidgetButton` running `ContinueReadingIntent` (`Shared/`, compiled into
  BOTH targets, also a Shortcuts action). 🔴 The intent is FOREGROUND mode: the system brings the
  app up and runs it in the APP process, where `ContinueReading.handler` (set in `SheafsApp.init`)
  opens `library.mostRecentBook()`. A background intent in the extension returning `OpenURLIntent`
  ran but opened nothing from Control Center (`openAppWhenRun: NO`, the link was dropped). Its icon
  is the custom symbol `sheafs` (SheafsWidget/Assets.xcassets/sheafs.symbolset, an SF Symbols v3
  template with Regular-S/M/L drawn by `scripts/gen-symbol`): controls take only symbol images
  (tinted and scaled by the system), a bitmap draws nothing. The symbol and the APP ICON are one
  drawing, `scripts/sheafs_mark.py` (three tilted sheets, text lines, drop cap; plain Python):
  `scripts/gen-icon` renders it in colour for `AppIcon.appiconset` (light opaque, dark opaque,
  tinted = greys on a transparent ground, the three `Contents.json` appearances) and for the
  site's icons, with headless Chrome at each exact size, and `scripts/check-icon` reads the
  committed PNGs back against the drawing (ink at each line's centre, the accent at the drop
  cap, a strip of each back sheet, the stack centred), so the icon can't be hand-edited or go
  stale, and its `--selftest` proves a flat or shifted icon fails. Never edit the PNGs by hand. Its label is the book's title, so
  `publishRecentBook()` also calls `ControlCenter.reloadControls`. `WidgetTests` checks the intent
  is in BOTH bundles' `Metadata.appintents` and the icon loads as a symbol (`isSymbolImage`).

## iPhone Duo behaviour (the point of the app)

Guidance followed: Apple's HIG "Designing for iPhone Duo" (size classes, don't move continuous
reading content for the fold, vertical bars are the system's job, keep controls consistent across
poses, even grid columns over the fold, reserved regions for custom layout, hinge angle only for
effects). APIs used: `GeometryProxy.reservedRegions(kind: .division, options:
[.includeInactive])`, standard `.toolbar` (the system puts items in the vertical bar on the cover
display and inner-landscape), `toolbarVisibility(_:for: .statusBar)`, `ToolbarOverflowMenu`,
`visibilityPriority`.

`PageLayout.compute` (tested in `SheafsTests`):
- cover display / inner portrait flat → one page (measure capped at ~38 em on wide screens);
- inner landscape, flat (INACTIVE vertical division) or book pose (ACTIVE) → a two-page spread
  whose gutter is the division frame + 2 pt each side, at least `minimumFoldGutter` (44 pt), centred
  on the fold. 🔴 The SAME in both poses: the simulator reports the hinge as one 40 pt region
  (455.5, 0, 40 × 669) flat and folded, only `isActive` changes, and a pose-dependent pad (14 vs
  2 pt) made the pages 441 vs 453 pt wide, so every line re-broke on unfolding;
- tabletop/laptop (active horizontal division) → the page on the upper half, `ReaderDeck` (progress,
  prev/next, contents, text size, appearance) on the lower half. The page STANDS on a surface
  (`Reader/TabletopBase.swift`): `TabletopBaseView` (in `PagerController`, above the pages, below the
  flip view) runs from the page's bottom edge down in `ReaderPalette.surface` (a shade under the
  paper; the deck uses it too), with a block of sheet edges under the page (7 sheets at the start of
  the book, 1 at the end) and a contact shadow; the page's last 22 pt shade a little as if curving
  over the fold (`PageView.curvesOverFold`). A turn draws the surface as a fifth texture, the leaf
  stops at the page's edge (`PageFlipDriver.leafHeight`) and its shadow spills onto the surface,
  fading with the distance from the edge (`TabletopEdgeTests`; `TEST_RUNNER_SHEAFS_TABLETOP_RENDERS=1`
  writes renders of it to the simulator's tmp/sheafs-tabletop);
- the cover display's camera hole (`CoverCamera`, a known spot, not read from the system) pushes the
  text below it (or the folio band up, if the interface turns it to the bottom).
Both pages of a spread share one text size, so one pagination serves both. The reading position is
the first character of the RIGHT-hand page of a spread (the left page shows what came just before,
or is blank at the very start). Pagination is ANCHORED: the first layout of a chapter after a
size/style change forces a page break at the position (`PaginatedChapter(anchor:)`, two TextKit
parts: each part is ONE tall container cut into pages at line-fragment boundaries; the part before
the anchor is cut BACKWARD from it so its short page lands at the chapter start, not right before
the position), so the line that was at the top of the cover page is the first line of the right
page after unfolding, and vice versa. Margins like Books: running head at the top (book title on a
left page, chapter title on a right or single page), the book-wide page number centred at the
bottom (`BookSession.bookPages`: exact for laid-out chapters, estimated by text length for the
rest), and the chrome strip says "136 of 594 · 18 pages left in chapter".
🔴 Geometry comes from a GeometryReader that does NOT ignore the safe area (inside one that does,
`proxy.safeAreaInsets` is all zeros and the pages ran under the vertical bar): the layout works in
window coordinates (`proxy.size` + insets, regions shifted by the insets) and the pager is a full-
window view offset back by the insets. The system keeps an 84 pt trailing inset for the vertical
bar even with the status bar hidden. Both displays read FULL BLEED under that strip and the bars
overlay the page on tap (`fullBleed`); the only thing avoided is the cover display's camera hole.
🔴 The fold comes from a SEPARATE full-window reader (`WindowRegions`, a background `GeometryReader`
with `ignoresSafeArea`, stored in `@State`): the DEVICE reports only the regions that intersect the
reader's frame; the SIMULATOR reports every region regardless.
🔴 The cover camera is HARD-CODED (`CoverCamera`), not read from `.occlusion` reserved regions: the
system also reports the status-bar cluster and Live Activities as occlusions, on both displays,
coming and going while reading, and the API cannot tell them from hardware; avoiding them moved
the text around (Live Activities pushed the inner spread down). The hole is a 37 pt square
29⅓ pt (88 px) in from the top and right edges in portrait, i.e. window (399.67, 29.33, 37 × 37) on
the 466 × 678 pt cover window, as the device reported it; it turns with the window scene's
interface orientation (`InterfaceOrientationReader`): hinge down (the hinge is the cover's right edge
in portrait; interface `.landscapeRight`) puts it at the TOP LEFT, hinge up at the bottom right, where
it widens the folio band instead. The simulator does not rotate the cover display's UI, so landscape
can only be checked on the phone (`[layout] … camera=… orientation=…`); a window of that size without a fold is the
cover display. The text starts 2 pt below the hole (Books runs right up to it), and the running head
(`PageView.headFrame`) narrows symmetrically to stay clear of it. Don't bring occlusions back.
Folio band 30 pt, the
folio centred ~50 pt above the display's bottom edge, like Books; the page frame stops at the home
indicator's zone. Page breaks are judged by a line's GLYPH bottom (`Paginator`), not its fragment
rect, which carries the trailing line/paragraph spacing: otherwise the last line that fits is dropped.
🔴 Nothing but the display itself moves the text (`SteadyPageGeometry`, `SteadyPageGeometryTests`).
The bars change the safe areas, so they are learned per display state (window size + fold
position/activity + camera) during the first 1.5 s, then LOCKED: later changes on the same display
are ignored, and the bars overlay the page. A fold, unfold, rotation or book pose is a new display
state and is followed at once; a size change while the bars are up hides them first.

## Landmines
- 🔴 The app runs on iOS 27.0, but the Duo's APIs (`reservedRegions`, `ReservedRegion`) are 27.1, the
  Duo's own release: iPhones and iPads go from 27.0 to 27.2, so a 27.1 minimum would install on the Duo
  only. Read the fold and the camera through `GeometryProxy.divisions()` / `occlusions()`
  (`Support/ReservedRegions.swift`, empty before 27.1), never `reservedRegions` directly; building at the
  27.0 target makes the compiler refuse an unguarded call. `Packages/SheafsKit` declares 27.0 too.
- Themes: Paper, Sepia, Night, Black (pure #000 for OLED) and Automatic, which stands for the user's
  `ReaderSettings.lightTheme` / `darkTheme` (Paper / Night by default; pickers in `AppearanceView`).
  Resolve with `settings.palette(system:)` from the DEVICE scheme, never the reader's forced one:
  Automatic with Night for Light mode forces `.dark`, and resolving from that jumped to the Dark pick.
- The reader ALWAYS forces a colour scheme (`ReaderPalette.colorScheme`, the resolved palette's
  `isDark`), so the bars match the page even when Automatic's Light pick is dark. Two traps: `preferredColorScheme(nil)` does not undo
  an earlier forced scheme on the presentation (Night → Automatic stayed dark in Light mode), and the
  environment's `colorScheme` is the forced one, so reading the device's scheme from it latched the
  first value. The device's scheme comes from the window scene's traits (`SystemColorSchemeReader`),
  which no override touches. `scripts/check-auto-theme` pins both (`-SheafsThemeSwitch`). Seeding the
  settings there: once the app has saved, its container plist outranks `simctl spawn defaults write`,
  so the script removes the container's key first.
- The pager's `UIScrollView` has `contentInsetAdjustmentBehavior = .never` (set on every layout pass,
  the scroll view is created lazily): the page frames already include the safe areas. The same pass
  makes its pan `require(toFail:)` the selection handles' pans, so dragging a handle never swipes
  the page; the long press disables scrolling while the finger is down.
- 🔴 Links are stored under `.sheafsLink`, never `NSAttributedString.Key.link`: TextKit draws a
  `.link` run system blue and underlined whatever its foreground colour says. Links within the book
  (index entries, glossary terms; note markers are superscripts) draw in the text colour, like the
  publisher's stylesheet almost always asks; only `Typesetter.isExternal` links get `palette.link`.
  `LinkStyleTests` renders pages and counts blue pixels.
- 🔴 Links are stored under `.sheafsLink`, never `NSAttributedString.Key.link`: TextKit draws a
  `.link` run system blue and underlined whatever its foreground colour says (it hid the theme's
  link colour, and made an edition's index links look like web links). Every link draws in
  `palette.link` with a dotted underline, none under a superscript note marker.
  `LinkStyleTests` renders pages and counts the pixels.
- Highlights are painted by `PageView` UNDER the glyphs (`PaginatedChapter.rects(for:page:)` =
  TextKit enclosing rects shifted by the page top) and the selection over them; nothing is added to
  the attributed string, so the offsets contract and the pagination cache are untouched. Highlights
  are not synced: the vanilla kosync protocol carries only the position.
- `ReaderSettings.Stored` must keep NEW keys optional (`highlightColor: HighlightColor?`): a
  non-optional key missing from the saved JSON fails the whole decode and silently resets every
  setting.
- The same layout pass turns the scroll view's scrolling OFF while pages flip (the flip's own pan
  takes the swipe; it yields to the selection long press and the handles) and back on for slide.
- The flip shader is a Swift string compiled on the device (`PageFlipShader.source`,
  `device.makeLibrary(source:)`), not a `.metal` file: the Metal toolchain is an optional Xcode
  component that is not installed here, and `scripts/check` must build on any Mac. Keep it so.
  `FlipUniforms` (Swift) and `FlipUniforms` (shader) are plain floats in the same order; the view
  asserts the float count. If the flip view cannot be made (no Metal, shader error) or Reduce Motion
  is on, pages slide.
- 🔴 The flip's cast shadow comes from the leaf's silhouette in EACH ROW: the crest of the bend if
  the sheet reaches it there, else the free edge still rising, deepening and widening with that
  point's height. Gating it on the crest alone made it fill in row by row while a corner led (the
  axis tilts), a hard-edged block sweeping up the page on a slow drag, and left a lifted edge short
  of the crest with no shadow. `PageFlipShadowTests` fails on that (steps along the edge and
  between frames of a slow drag, shade beside a lifted edge).
- 🔴 A page texture is the page's bounds stretched onto the whole rounded pixel grid
  (`PageFlipView.texture(for:scale:device:)`), not drawn at the display scale: in tabletop the page
  ends at the fold, 455.5 pt = 1366.5 px, and the half-painted last row (alpha 0.5, premultiplied)
  drew a grey line across the display during every turn. `PageFlipEdgeTests`.
- Page textures are cached per `PageSlot` and dropped on layout/palette/style changes; anything
  else that changes what a page draws (highlights, bookmark ribbons, selection) must call
  `PageFlipDriver.invalidateTextures()` or the leaf shows stale content.
- Never call `BookSession.paginatedChapter` for a chapter other than the one on screen from view
  code (body, labels): it lays the chapter out UNANCHORED and caches it, so returning there shows
  pages cut differently from the ones you left (and mutating observed state mid-draw bounced the
  bars off). Use `laidOutChapter` (cache only); the back button stores its page number when leaving.
- Pagination runs on the main actor, synchronously, on demand (neighbours prefetched). A single
  huge spine item (whole-book-in-one-file EPUBs) will hitch on open; move it off-main if it bites.
- The closed iPhone Duo is asymmetrical: the hinge runs down the LEFT edge of the cover display
  (cover facing you) with square corners; only the right edge is rounded. The `duo-cover` frame in
  `scripts/marketing`/`marketing/base.css` (`.hinge-left`) draws it so for both the App Store tiles
  and the site's shots; `scripts/site-shots --selftest` fails if it goes round again.
- `hub-fixture.epub`'s manifest lists an NCX that isn't in the archive — `toc` is empty, no error.
- Simulator input: the iOS Simulator MCP's taps and rotation reach the inner display (coordinates in
  the lit screen's points); `-SheafsOpen` / launch args reach reader states and `scripts/hinge/hinge`
  sets poses. `xcrun simctl launch --console-pty <udid> io.sheafs.reader …` captures `print` output.
- 🔴 Rotating the Duo simulator: `xcrun devicectl device orientation set` prints success and changes
  NOTHING (Safari on the cover stays portrait), and Xcode 27 has no Simulator.app. `hinge
  orient` works: it posts Device Hub's `orientation-picker-control` HID event (next to the hinge
  slider's), which the simulator's `locationd` turns into the device pose SpringBoard rotates by
  (`log show … 'process == "locationd"'` says "Orientation set to: …"). Test rotation with an app
  that rotates: Settings and the home screen stay portrait on the cover display. `simctl io …
  screenshot` comes out in the interface orientation, at App Store Connect's sizes as is. The
  system's own `tabletopPose` stays "Ambiguous" (it wants gravity input we cannot send), but the
  reserved regions do report the active horizontal fold, which is all `PageLayout` reads.
- Page numbers of chapters not laid out yet are estimates (`BookSession.bookPages`) and shift when a
  neighbour is laid out, most visibly deep into a book (a spread numbered 304 with 301 under the
  turning leaf); `scripts/screenshots` keeps its positions early in each book.
- kosync `progress` strings from other devices are treated as opaque for comparison
  (`book.lastSyncedPointer`) and only *resolved* via `XPointer`; never rewrite them.
