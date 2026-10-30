# App Store screenshots

What is here:

- `final/<display type>/NN-<tile>.png`: the upload sets, one folder per App Store Connect display type, in
  upload order. Every file is the exact App Store size for its display, RGB with no alpha channel.
  - `APP_IPHONE_DUO`: iPhone Duo, 10 tiles, inner display 2853×2007 and cover display 1398×2034 mixed.
  - `APP_IPHONE_67`: iPhone 6.9", 10 tiles, 1320×2868.
  - `APP_IPAD_PRO_3GEN_129`: iPad 13", 10 tiles, 2064×2752 portrait and 2752×2064 landscape.
- `raw/<device>/`: the simulator screenshots the tiles are made from (status bar 9:41, full battery and
  signal). `*.ask.txt` beside an Ask shot is the on-device model's answer and passages as the app logged
  them, so the answer in the picture can be checked against a real run.
- `current/`: git-ignored. What App Store Connect has now, downloaded read-only for comparison (the last
  command below).

All books on screen are public domain, from Standard Ebooks (CC0 text and covers): Jane Eyre for Ask,
markup, highlights and notes; Pride and Prejudice, Moby-Dick, The Great Gatsby, Dracula, Frankenstein and
the rest of the library as before. The catalog shot is Project Gutenberg's live most-downloaded list.

## Regenerate

Everything runs on this Mac, headless. The captions are in `marketing/tiles.json` (voice `casual`, the
App Store listing's voice), the look in `marketing/base.css` and `marketing/styles/folio.css`.

```bash
# 1. Raw screenshots: builds the Debug app, installs it fresh on each simulator, imports the books and
#    shoots every pose. simctl cannot write to the external volume, so shoot to /tmp and copy.
#    The Duo run reinstalls Sheafs on the shared "iPhone Duo" simulator: take the lock if other
#    sessions use it. Ask needs Apple Intelligence on this Mac (the simulator uses the host's model).
OUT=/tmp/sheafs-screenshots scripts/screenshots iphone ipad
OUT=/tmp/sheafs-screenshots /tmp/sheafs-sim/with-sim scripts/screenshots duo
rsync -a --delete --exclude '.*' /tmp/sheafs-screenshots/ marketing/screenshots/raw/

# 2. Captioned tiles, and the upload sets in order (fails on a wrong size, alpha, overflowing copy,
#    a screenshot that did not load, a stand-in, or a set over 10). `scripts/marketing --selftest`
#    proves the did-not-load check fails.
RAW=marketing/screenshots/raw OUT=/tmp/sheafs-marketing \
  scripts/marketing --style folio --voice casual --export marketing/screenshots/final

# 3. Check every upload file: size and no alpha.
sips -g pixelWidth -g pixelHeight -g hasAlpha marketing/screenshots/final/*/*.png

# Optional: what App Store Connect has now (read only).
ASC_READ_ONLY=1 asc screenshots download --version-localization <localization id> \
  --output-dir marketing/screenshots/current
```

`/tmp/sheafs-marketing/index.html` shows every tile; `sheet-<device>.png` is a contact sheet per device.

## How the new shots are made

- **Ask** (`-SheafsAsk`): the iPhone and iPad open Jane Eyre at chapter X and ask "Why was Jane sent to
  Lowood?". The Duo's panel, over the left page, shows only about 340 characters whole, so it asks "Where
  is Jane being sent?" at chapter V. The answer is whatever the on-device model says on that run;
  `scripts/screenshots` fails unless the model is available, the answer finished, is more than a few words
  and cites passages, and asks again (up to 4 times) when an answer is too long for the panel.
  **Answers differ between runs and the model gets details wrong often**, so read each `.ask.txt` against
  the book before uploading and re-take that shot if anything is off:
  `ONLY=inner-landscape-9-ask OUT=/tmp/sheafs-duo-ask /tmp/sheafs-sim/with-sim scripts/screenshots duo`,
  then copy the PNG and `.ask.txt` into `raw/duo-inner/`. Of about 40 questions tried, most failed:
  "Who is Mr. Rochester?" (he "visits frequently"), "Who is Miss Temple?" (called a teacher, she is the
  superintendent), "Who is Bessie?" (put at Lowood, past the reading position), "Who was Mr. Reed?" (made
  Jane's father).
- **Highlights and Pencil markup** (`-SheafsHighlightDemo`, `-SheafsMarkupDemo`, DEBUG builds only): the
  simulator has no Pencil and cannot long-press, so these hooks find phrases in the book, make highlights
  through the same path as the selection menu, and draw strokes onto the real markup canvases, which are
  then saved by the same commit as a drawing (anchored to the text, so they reflow). The strokes are
  made from the text's geometry by `Sheafs/Reader/ScreenshotDemo.swift`.
- **Catalogs** (`-SheafsBrowse Gutenberg`, DEBUG only): opens the built-in Project Gutenberg catalog. Needs
  the network; Gutenberg's list changes over time.
