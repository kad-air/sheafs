# Sheafs

Native EPUB reader for iOS 27.1 and the foldable iPhone Duo. SwiftUI + TextKit + Foundation only;
no web views, no third-party packages. Open source (MIT), so **no personal names, emails,
hostnames or secrets anywhere in the tree** — `scripts/check` greps for them and fails.

## Commands

```bash
scripts/bootstrap                 # Config/Signing.xcconfig (git-ignored) + `xcodegen generate`
scripts/check                     # THE gate: hygiene grep, Python reference freshness, swift test,
                                  #   simulator build, simulator unit tests (SKIP_SIM_TESTS=1 skips the last)
cd Packages/SheafsKit && swift test            # the core package, on the Mac, ~1 s
xcodebuild -project Sheafs.xcodeproj -scheme Sheafs -destination 'platform=iOS Simulator,name=iPhone Duo' build
scripts/hinge/hinge 110           # fold the booted Duo simulator (0 closed … 180 flat); `get` reads it
xcrun simctl io <udid> screenshot --display=primary-1 out.png   # inner display (`primary` = cover)
```
`Sheafs.xcodeproj` and `Sheafs/Generated/Info.plist` are generated from `project.yml`; never edit
them, re-run `xcodegen generate` after adding files. Screenshots cannot be written to the external
volume by `simctl` (permission error) — write them under `/tmp` or the scratchpad.

Launch arguments: `-SheafsOpen <title fragment>` opens the first matching library book at launch;
`-SheafsCatalogURL <url> [-SheafsCatalogName <name>]` adds an OPDS catalog once (keeps keys out of
typed text and transcripts: build the URL in a shell variable).
Dropping `.epub` files into the app's Documents folder (`xcrun simctl get_app_container <udid>
io.sheafs.reader data`/Documents) imports them on the next launch or foreground.

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
  - `Text/XPointer` — `/body/DocFragment[N]/body/…/p[K]/text()[k].off` parse/serialize (N 1-based
    over the FULL spine). We always serialize with indices (CrossPoint style); parsing tolerates
    missing `[1]`.
  - `OPDS/` — Atom OPDS 1.2 parser (+ OpenSearch), `OPDSClient` (pre-emptive Basic auth, streaming
    download). `KOSync/` — the vanilla KOReader sync protocol; `PartialMD5` is the document key
    (offsets 0, 1 KiB, 4 KiB … 1 GiB; 🔴 the i = −1 read is at offset 0, not 256, matching KOReader's
    32-bit shift — pinned against an independent Python digest, `2d54ce2c…` for hub-fixture.epub).
- `Sheafs/` (app, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 6 strict):
  - `App/` — `SheafsApp` (SwiftData container, environment objects, open-in, Documents import),
    `RootView` (tabs Library / Catalogs / Settings; the reader is a `fullScreenCover`).
  - `Library/` — `Models` (SwiftData `Book`: position = `spineIndex` + `textOffset` + `xpointer` +
    `progress`; `Catalog`), `LibraryStore` (files in Application Support/Books/<uuid>.epub, covers in
    Covers/<uuid>.jpg, import = copy + parse + partial MD5 + thumbnail, dedupe by partial MD5),
    `LibraryView` (cover grid; even column count when a fold is present, per the Duo HIG).
  - `Reader/` — `BookSession` (loads the EPUB and converts every chapter in a detached task; caches
    typeset+paginated chapters per style/page size; position ↔ progress ↔ xpointer ↔ TOC/href),
    `Typesetter` (Block → NSAttributedString with the user's fonts), `Paginator` (`PaginatedChapter`:
    one TextKit 1 `NSLayoutManager`, one `NSTextContainer` per page, drawn by `PageView`),
    `ReaderPager` (`UIPageViewController` .scroll whose units are spreads of 1–2 pages;
    tap zones turn pages, centre tap toggles chrome, link hit-testing), `ReaderLayout`
    (`PageLayout.compute`: safe areas + reserved regions → page frames; see Duo below),
    `ReaderView` (chrome: system toolbar + glass progress strip, contents/appearance/footnote sheets,
    sync pull on open / debounced push), `ReaderSettings`, `Theme`, `AppearanceView`.
  - `Catalog/` — OPDS browser (catalog list, add/edit, feed browser with pagination/search,
    entry detail + download → `LibraryStore.importBook`).
  - `Settings/` — sync account, appearance link, library stats, about. `Sync/SyncService` — kosync
    settings (password in the keychain) + `pull`/`push`.

## iPhone Duo behaviour (the point of the app)

Guidance followed: Apple's HIG "Designing for iPhone Duo" (size classes, don't move continuous
reading content for the fold, vertical bars are the system's job, keep controls consistent across
poses, even grid columns over the fold, reserved regions for custom layout, hinge angle only for
effects). APIs used: `GeometryProxy.reservedRegions(kind: .division/.occlusion, options:
[.includeInactive])`, standard `.toolbar` (the system puts items in the vertical bar on the cover
display and inner-landscape), `toolbarVisibility(_:for: .statusBar)`, `ToolbarOverflowMenu`,
`visibilityPriority`.

`PageLayout.compute` (tested in `SheafsTests`):
- cover display / inner portrait flat → one page (measure capped at ~38 em on wide screens);
- inner landscape, flat → the INACTIVE vertical division (zero-width, centre) → two-page spread with a
  14 pt gutter each side of the fold;
- book pose (active vertical division) → spread with the gutter = the division frame + 2 pt;
- tabletop/laptop (active horizontal division) → the page on the upper half, `ReaderDeck` (progress,
  prev/next, contents, text size, appearance) on the lower half;
- an active occlusion touching the top edge (inner camera) pushes the page down.
Both pages of a spread share one text size, so one pagination serves both. The reading position is
the first character of the RIGHT-hand page of a spread (the left page shows what came just before,
or is blank at the very start). Pagination is ANCHORED: the first layout of a chapter after a
size/style change forces a page break at the position (`PaginatedChapter(anchor:)`, two TextKit
parts), so the line that was at the top of the cover page is the first line of the right page
after unfolding, and vice versa. Running feet: single page = chapter title + "n of m · %"; spread
= title on the left page, numbers on the right (title repeated on the right only when its chapter
differs or the left page is blank).
🔴 Geometry comes from a GeometryReader that does NOT ignore the safe area (inside one that does,
`proxy.safeAreaInsets` is all zeros and the pages ran under the vertical bar): the layout works in
window coordinates (`proxy.size` + insets, regions shifted by the insets) and the pager is a full-
window view offset back by the insets. The system keeps an 84 pt trailing inset for the vertical
bar even with the status bar hidden. On the inner display (a fold region exists) the pages read
FULL BLEED under that strip and the bars overlay them on tap (`fullBleed`); the cover display keeps
the side inset because the camera sits in that strip.
🔴 While the chrome is visible the layout keeps the chrome-hidden SAFE AREAS (`ReaderView.
effectiveInput`) but still follows fold/camera/size — otherwise the bars' insets would repaginate
under the reader's eyes on every tap; the bars overlay the page instead. A size change (fold,
rotate) while the bars are up hides them first, so the stored insets are always reading ones.

## Landmines
- The pager's `UIScrollView` has `contentInsetAdjustmentBehavior = .never` (set on every layout pass,
  the scroll view is created lazily): the page frames already include the safe areas.
- Pagination runs on the main actor, synchronously, on demand (neighbours prefetched). A single
  huge spine item (whole-book-in-one-file EPUBs) will hitch on open; move it off-main if it bites.
- `hub-fixture.epub`'s manifest lists an NCX that isn't in the archive — `toc` is empty, no error.
- Simulator taps bind to the cover display; use `-SheafsOpen` / launch args to reach inner-display
  states, and `scripts/hinge/hinge` for poses.
- kosync `progress` strings from other devices are treated as opaque for comparison
  (`book.lastSyncedPointer`) and only *resolved* via `XPointer`; never rewrite them.
