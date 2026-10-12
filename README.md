# Imager

A Mac app that makes PNG, JPEG, GIF and SVG files smaller without changing how they look. Drop
files or folders on the window and every image is run through a set of open-source optimizers;
the smallest result replaces the file and the original goes to the Trash. A remake of ImageOptim
for macOS 26 and later.

- Drop images or folders on the window or the Dock icon, use File › Add Images… (⌘O), or pick
  "Optimize with Imager" in the Finder's Services menu. Folders are searched for images.
- **Lossless** (default) never changes a pixel: invisible metadata is removed and the image data is
  recompressed. Safe to run on anything, any number of times.
- **Lossy** (toolbar button, or Optimize › Mode) also re-encodes images above the quality levels
  in Settings › Quality (80% by default for JPEG, PNG and GIF) for much smaller files.
- The list shows the original and current size, the percentage saved and which tool won.
  Optimize Again (⌘R) runs files once more at a higher effort level; Stop (⌘.) keeps the best
  result so far; Revert to Original (⌥⌘Z) brings the original back from the Trash; Quick Look
  with the space bar.
- Settings: effort level (fastest to insane), which tools run, metadata stripping, preserving
  permissions and dates, low priority, and what happens when a batch finishes.
- **Convert** (toolbar menu, Settings › Convert, or Optimize › Convert To) re-encodes every dropped
  image as AVIF, HEIC, JPEG or PNG first. AVIF is written by the bundled `avif-encode` helper
  (libavif + libaom), because Apple's own AVIF encoder tiles anything over 512 px into a grid that
  Firefox can't display; HEIC, JPEG and PNG use the encoder built into macOS 26.
  Quality is a slider (80% by default). With a format chosen, HEIC, WebP, TIFF and BMP files are
  accepted as well. The converted file takes the original's name with the new extension and the
  original goes to the Trash (or stays, with a switch); converted JPEGs and PNGs then go through the
  optimizers. Animated GIFs and SVGs are left in their own format.
- Everything runs on the Mac; nothing is uploaded.

## How it works

Each file is identified by its first bytes and planned like ImageOptim does it: tools that
change the content (a lossy pass, metadata stripping, Zopfli's transparent-pixel cleanup) run
first, one at a time; pure recompressors then run in parallel, each starting from the smallest
file so far, and the smallest output wins. Files that couldn't be shrunk are remembered (by
content and settings, in `~/Library/Caches/fm.beard.Imager/Results.db`) so they are skipped
next time.

| Format | Tools |
| --- | --- |
| PNG | pngquant (lossy only), OptiPNG, AdvPNG, Zopfli, pngcrush (off by default) |
| JPEG | jpegoptim, MozJPEG's jpegtran |
| GIF | Gifsicle (lossy mode uses its `--lossy` option) |
| SVG | SVGO, run inside the app with JavaScriptCore |
| AVIF output | avif-encode (libavif 1.3 + libaom 3.12), single-item files like avifenc and Squoosh |

The command-line tools are universal (arm64 + x86_64) executables in `Helpers/` (avif-encode is
arm64 only, like the app), embedded into `Contents/MacOS` and signed by the build.
`Tools/build-tools.sh` fetches their sources (pinned versions; no Rust; cmake comes from a local
Python venv) and rebuilds them; the results are checked in so the app builds without it. SVGO is
bundled as `Imager/Resources/svgo.js` by the same script.

## Project notes

- Xcode 27 project, macOS 26 or later, Swift with approachable concurrency and MainActor default
  isolation. Sources live in `Imager/` as a synchronized folder: `Model/` has the queue, jobs,
  tool wrappers, file saving and the results cache; `Views/` the SwiftUI.
- `ImageConverter` wraps ImageIO (`CGImageDestination`) for HEIC/JPEG/PNG and the `avif-encode`
  helper (`Tools/avif-encode/main.c`) for AVIF; `FileSaver.placeConverted`
  names and places the result and `revertConversion` undoes it.
- `OptimizationJob` owns one file's pipeline (conversion first, then the tools); `OptimizationQueue` holds the list, walks folders
  and limits concurrent tool processes to the core count (`CPUScheduler`). `ToolProcess` wraps
  `Process` so a cancelled task kills the tool. `FileSaver` replaces the file (in place when
  preserving permissions) and trashes the original for Revert.
- Debug-only helpers: `IMAGER_DEBUG_OPEN=/a.png:/b.jpg` adds files at launch,
  `IMAGER_SNAPSHOT=/path.png` (with `IMAGER_SNAPSHOT_DELAY` seconds and `IMAGER_SNAPSHOT_QUIT=1`)
  writes a picture of the window. When testing from a shell while the app is also running from
  Xcode, quit only your own instance.
- Icon: `swift Tools/make-icon.swift Imager/Assets.xcassets/AppIcon.appiconset` regenerates
  the icon set (teal-to-blue tile, photo card squeezed by four arrows).
- Licenses: Imager itself is MIT. The bundled tools keep their own licenses (GPL for pngquant,
  AdvanceCOMP, jpegoptim and Gifsicle; Apache, zlib, BSD, IJG and MIT for the rest); they are
  separate executables invoked as processes, and their sources are the pinned versions in
  `Tools/build-tools.sh`. Credits are in the About window (`Imager/Resources/Credits.html`).

## Releases and updates

Updates ship through Sparkle (SPM, 2.6+). The feed is
`https://beardfm.app/imager/appcast.xml`, kept in the beardfm.app site repo at
`site/static/imager/appcast.xml`; DMGs live at `site/static/downloads/Imager-<version>.dmg`
(plus `Imager.dmg` for the always-latest link). The EdDSA signing key is in the login keychain
under the Sparkle account `imager`; its public key is `SUPublicEDKey` in `Info.plist`.

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (Sparkle compares the latter) and
   optionally write `release-notes/<version>.html`.
2. `Tools/release.sh` builds, signs the helpers, Sparkle and the app with Developer ID, and
   packages `dist/Imager <version>.dmg`. Add `--notarize` to notarize, and `--notarize --upload`
   to also sign the update, copy it into beardfm.app, add it to the appcast and deploy the site.
   Commit the beardfm.app changes afterwards.

## License

MIT. See [LICENSE](LICENSE).
