# Sheafs

A small, native EPUB reader for iPhone and iPad (iOS 27.0 and later), built for the foldable iPhone Duo.
SwiftUI, TextKit and Foundation only. No web views, no third-party dependencies.

Website: https://kad-air.github.io/sheafs/ (the `docs/` folder, published by GitHub Pages).

- **Reads EPUB 2 and 3** with the system's own typography: New York, Georgia, Palatino, Charter and
  friends, paper / sepia / night themes, adjustable size, leading and margins, justified or ragged,
  hyphenation. Chapters are paginated like a book, not scrolled.
- **Made for iPhone Duo.** On the cover display it is a one-page reader with the system's vertical
  toolbar. Open the device in landscape and it becomes a two-page spread with the gutter on the
  fold. Fold it halfway like a book and the pages keep clear of the crease; stand it up like a
  laptop and the page moves to the upper half with reading controls below the fold. Fold and
  unfold mid-chapter and you stay on the same words.
- **OPDS catalogs.** Add any OPDS 1.2 catalog (self-hosted libraries, Calibre, Project Gutenberg),
  browse, search and download straight into the library.
- **Reading position sync** using the KOReader sync protocol ("kosync"), so a position set on one
  reader shows up on the others. The document key is the KOReader partial MD5 of the file bytes;
  positions are written as CREngine xpointers, the dialect KOReader and CrossPoint use.
- **Volume buttons turn pages** if you want them to (Settings → Appearance → Reading): up for
  the next page, down for the previous one.
- **Open in Sheafs** from Files, AirDrop and the share sheet, or drop EPUBs into the app's
  Documents folder.

## Building

Requirements: Xcode 27.1, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/bootstrap            # creates Config/Signing.xcconfig and generates Sheafs.xcodeproj
open Sheafs.xcodeproj        # or build from the command line:
xcodebuild -project Sheafs.xcodeproj -scheme Sheafs -destination 'platform=iOS Simulator,name=iPhone Duo' build
```

For a device build, put your Apple Developer team id in `Config/Signing.xcconfig`
(`DEVELOPMENT_TEAM = XXXXXXXXXX`). The file is git-ignored.

`scripts/check` is the one command that must pass before a change is done. It checks the tree for
leaked personal data, regenerates the Python reference data the tests are anchored on, runs the
`SheafsKit` tests on the Mac, builds the app for the iPhone Duo simulator and runs the app's own
tests there.

`scripts/hinge/hinge 110` folds the booted iPhone Duo simulator to 110° (book pose); `0` closes it,
`180` lays it flat, and `hinge orient landscape-left` turns it (device landscape shows the inner
display in portrait; partly folded, that is tabletop). See `THIRD_PARTY_NOTICES.md`.

`scripts/screenshots` takes the App Store screenshots in every pose on its own simulator, with
public-domain books from [Standard Ebooks](https://standardebooks.org), and checks each against
App Store Connect's iPhone Duo sizes. `scripts/marketing` turns them into App Store tiles (a headline
and the screenshot in a device frame) in each style under `marketing/styles`, from the copy in
`marketing/tiles.json`.

## Layout

- `Sheafs/` — the app: `App` (entry, tabs), `Library` (SwiftData models, import, grid), `Reader`
  (typesetting, pagination, the pager, Duo layout, chrome), `Catalog` (OPDS browser), `Settings`,
  `Sync` (kosync service), `Support`.
- `Packages/SheafsKit/` — a Foundation-only package with the EPUB container (`Zip`, `EPUB`), the
  XHTML-to-block converter and xpointer model (`Text`), the OPDS client (`OPDS`) and the KOReader
  sync client (`KOSync`). `swift test` runs on the Mac.
- `scripts/` — `check`, `bootstrap`, the Python reference generators, and the simulator hinge tool.
- `docs/` — the landing page GitHub Pages serves (`scripts/check-site` checks it).

## Sync setup

In Settings → Sync & Accounts → Reading Position Sync, enter the server URL (for a self-hosted server this may
include a path, e.g. `https://example.com/kosync/`), a user name and a password, then tap
*Register Account* once and *Test Connection*. Any reader that speaks the KOReader sync protocol
can share the account; the same EPUB file (byte for byte) must be on each device.

## Acknowledgements

Volume-button page turns follow the approach of [Readest](https://github.com/readest/readest)
(AGPL-3.0), which showed it working well on iOS; Sheafs' implementation is its own, and no Readest
code is included.

## License

MIT. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
