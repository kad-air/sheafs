# Sheafs

Native EPUB reader for iPhone, iPad and the foldable iPhone Duo, iOS 27.0 and later. SwiftUI + TextKit + Foundation (plus
Metal for the page flip) only; no web views, no third-party packages. Open source (MIT), so **no personal names, emails,
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
                                  #   live Light/Dark flips (reads the page colour off screenshots)
scripts/screenshots [duo|iphone|ipad]  # App Store screenshots: every Duo pose on "iPhone Duo" (Sheafs is
                                  #   reinstalled there), portrait on "Sheafs Shots iPhone"/"iPad" (made if missing) → OUT=/tmp/sheafs-
                                  #   screenshots/{duo-inner,duo-cover,iphone,ipad}/; fresh install, Standard
                                  #   Ebooks books (CC0, cached); fails unless each shot is App Store Connect's
                                  #   size for its display, the hinge reads back, the `[layout]` line shows the
                                  #   pose and the frame has ink. NO_BUILD=1 reuses the last build. iPhone/iPad
                                  #   need `scripts/screenshots prepare` (the iOS 27.0 runtime, 8 GB on the SSD,
                                  #   refused under 12 GB free) and an app whose minimum is 27.0;
                                  #   `scripts/screenshots teardown` deletes those simulators and that runtime
scripts/marketing                 # App Store marketing tiles from those shots: marketing/tiles.json (copy
                                  #   voices, tiles per device) × marketing/styles/*.css, rendered by headless
                                  #   Chrome at the exact App Store sizes → OUT=/tmp/sheafs-marketing (index.html,
                                  #   sheet-<device>.png). Fails on a wrong size, an alpha channel, copy that
                                  #   overflows or is covered; missing shots use a STANDIN- tile; --final refuses them
cd Packages/SheafsKit && swift test            # the core package, on the Mac, ~1 s
xcodebuild -project Sheafs.xcodeproj -scheme Sheafs -destination 'platform=iOS Simulator,name=iPhone Duo' build
scripts/release                   # fallback only (Xcode Cloud ships, below): archive + upload with an API key
                                  #   (ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID; build = commit count,
                                  #   refuses a dirty tree; --no-upload archives and checks only)
scripts/hinge/hinge 110           # fold the booted Duo simulator (0 closed … 180 flat); `get` reads it
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
`-SheafsFlipAuto forward|back
-SheafsFlipFreeze <0…1> [-SheafsFlipGrab <0…1 down the page>]` starts one page flip on its own
once the book is up and holds it at that amount, so `simctl io … screenshot` can catch the leaf
mid-air (the next tap lands it).
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
  - `Text/XPointer` — `/body/DocFragment[N]/body/…/p[K]/text()[k].off` parse/serialize (N 1-based
    over the FULL spine). We always serialize with indices (CrossPoint style); parsing tolerates
    missing `[1]`.
  - `OPDS/` — Atom OPDS 1.2 parser (+ OpenSearch), `OPDSClient` (pre-emptive Basic auth, streaming
    download). `KOSync/` — the vanilla KOReader sync protocol; `PartialMD5` is the document key
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
    by hand; `AnnotationExport.markdown` for sharing), `LibraryStore` (files in Application
    Support/Books/<uuid>.epub, covers in Covers/<uuid>.jpg, import = copy + parse + partial MD5 +
    thumbnail, dedupe by partial MD5; `annotations(for:)`/`add`/`delete`), `LibraryView` (cover grid;
    even column count when a fold is present, per the Duo HIG).
  - `Reader/` — `BookSession` (loads the EPUB and converts every chapter in a detached task; caches
    typeset+paginated chapters per style/page size; position ↔ progress ↔ xpointer ↔ TOC/href),
    `Typesetter` (Block → NSAttributedString with the user's fonts), `Paginator` (`PaginatedChapter`:
    one TextKit 1 `NSLayoutManager`, one `NSTextContainer` per page, drawn by `PageView`),
    `ReaderPager` (`UIPageViewController` .scroll whose units are spreads of 1–2 pages;
    tap zones turn pages, centre tap toggles chrome, link and highlight hit-testing; text
    SELECTION: a long press selects the word under the finger and grows by words while it moves,
    two `SelectionHandleView`s then adjust it by characters, a `UIEditMenuInteraction` offers
    Highlight / Note / Color / Copy / Look Up; the selection lives in `PagerController`, the
    spread only provides geometry and the `PageView`s draw it; a tap, a page turn or a layout
    change clears it), `AnnotationViews` (`AnnotationEditorView`: colour, underline, note, show in
    book, delete; `NotesListView`: the Notes segment of the contents sheet, share as Markdown),
    `ReaderLayout`
    (`PageLayout.compute`: safe areas + reserved regions → page frames; see Duo below),
    `ReaderView` (chrome: system toolbar + glass progress strip, contents/appearance/footnote sheets,
    sync pull on open / debounced push; `@Query` of the book's annotations → `HighlightMark`s →
    `BookSession.marks`, which every spread reads as it appears; every `jump(to:)` — link, contents, note,
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
    really installed (a missing one falls back to the system font without a word).
  - `Reader/VolumeButtons` — `VolumeButtonPager` (setting `volumeButtonsTurn`, off by default):
    up = next page, down = previous (`Press.turnsForward`, the owner's choice). An active `.playback` + `.mixWithOthers` session makes
    `outputVolume` observable; `PressReader` reads a press as a step from the PREVIOUS reading.
    The volume really moves with each press; only within 0.1 of either end does the hidden
    `MPVolumeView`'s slider (searched for in its subtree each time, else the one it had when made;
    on the simulator it swaps the slider for a label once in a window) put it back to a reference
    (the user's volume kept within 0.25…0.75), and the first reading within 1 s that lands nearer
    the reference is that put-back, not a press. 🔴 Device readings move in the device's own steps
    (Duo, iOS 27.1: 0.0, 0.05, 0.15, 0.2…), so a put-back never lands exactly on the reference:
    build 7 put back after EVERY press and read each landing as a press the other way (pages
    turned at random). The volume view sits ON screen (origin, 1 pt, alpha 0.01): off-screen it no
    longer hid the system volume HUD on iOS 27; on screen it does (confirmed on the Duo, keep it
    there). `ReaderView.volumeButtonsArmed` runs it only while the scene is
    active, the book is ready, the regions are known and no sheet is up, and arming RETRIES until
    the pager is in a window (it appears after the regions; arming once gave up silently). Stop
    restores the user's volume. `VolumeButtonTests` pins the press logic. The simulator can't
    press the buttons (and setting the hidden slider there changes nothing: no volume route), so
    verify on the phone. Every step (arming decisions with each condition, session state, the
    volume view's subview tree, each reading, each turn) goes through `VolumeLog.note`: a public
    `Logger` notice (category `volume`) AND an in-memory buffer shown and copied in Settings →
    About → Volume Button Log, so a TestFlight run can be read without a Mac.
    `-SheafsVolumeProbe up|down` moves the volume one step through the slider 1.5 s after arming.
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
    entry detail + download → `LibraryStore.importBook`).
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
  prev/next, contents, text size, appearance) on the lower half;
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
- The reader ALWAYS forces a colour scheme (`ReaderPalette.colorScheme(for:system:)`): the theme's own
  for a fixed theme, the device's for Automatic. Two traps: `preferredColorScheme(nil)` does not undo
  an earlier forced scheme on the presentation (Night → Automatic stayed dark in Light mode), and the
  environment's `colorScheme` is the forced one, so reading the device's scheme from it latched the
  first value. The device's scheme comes from the window scene's traits (`SystemColorSchemeReader`),
  which no override touches. `scripts/check-auto-theme` pins both (`-SheafsThemeSwitch`).
- The pager's `UIScrollView` has `contentInsetAdjustmentBehavior = .never` (set on every layout pass,
  the scroll view is created lazily): the page frames already include the safe areas. The same pass
  makes its pan `require(toFail:)` the selection handles' pans, so dragging a handle never swipes
  the page; the long press disables scrolling while the finger is down.
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
- Page textures are cached per `PageSlot` and dropped on layout/palette/style changes; anything
  else that changes what a page draws (highlights, selection) must call
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
