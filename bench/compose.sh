#!/bin/bash
# compose.sh — build the before/after demo video from two screen-capture takes
# plus the measured median numbers.
#
# Usage:
#   ./compose.sh <native.mov> <strafe.mov> <native_median_ms> <strafe_median_ms> [specs_line]
#
# Produces (under docs/media/):
#   demo.mp4       title card -> native segment (lower-third caption) -> strafe
#                  segment (lower-third caption) -> closing card (specs + repo).
#                  H.264, ~1080p-ish, target < 8 MB.
#   demo-loop.mp4  short side-by-side hstack of the two switch moments, no cards,
#                  target < 3 MB, for a README autoplay embed.
#
# NUMBERS ARE PARAMETERS. Nothing is baked in — pass the medians produced by
# `bench run` and the specs line from `bench specs`.
#
# ------------------------------------------------------------------------------
# DEPENDENCY NOTE (important): stock Homebrew ffmpeg is built WITHOUT libfreetype,
# so the `drawtext` filter is UNAVAILABLE. This script therefore renders every
# piece of text to a transparent PNG using macOS's own CoreText (via JavaScript
# for Automation, always present), then composites those PNGs with ffmpeg's
# `overlay` filter. The only ffmpeg filters used — color, overlay, scale, pad,
# fade, concat, hstack, format — are all present in stock Homebrew ffmpeg.
# ------------------------------------------------------------------------------
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <native.mov> <strafe.mov> <native_median_ms> <strafe_median_ms> [specs_line]" >&2
  exit 2
fi

NATIVE_MOV="$1"
STRAFE_MOV="$2"
NATIVE_MS="$3"
STRAFE_MS="$4"
SPECS_LINE="${5:-}"

REPO_URL="https://github.com/rileycx/strafe"

for f in "$NATIVE_MOV" "$STRAFE_MOV"; do
  [[ -f "$f" ]] || { echo "error: input not found: $f" >&2; exit 1; }
done
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/docs/media"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Output geometry. 1920x1080 canvas; source takes are scaled to fit.
CW=1920
CH=1080
FPS=30

# --- Text -> transparent PNG via CoreText (no drawtext dependency) -----------
# render_text <text> <out.png> <fontSize> <wPx> <hPx> <r> <g> <b> <a> <weight>
# weight: one of regular|medium|bold|heavy. Coordinates in PIXELS; render at the
# canvas resolution so overlay is crisp.
render_text() {
  local text="$1" out="$2" fs="$3" w="$4" h="$5" r="$6" g="$7" b="$8" a="$9" weight="${10:-bold}"
  TEXT="$text" OUT="$out" FS="$fs" W="$w" H="$h" R="$r" G="$g" B="$b" A="$a" WEIGHT="$weight" \
  osascript -l JavaScript <<'JS'
ObjC.import('AppKit');
ObjC.import('Foundation');
var env = $.NSProcessInfo.processInfo.environment;
function e(k){ return ObjC.unwrap(env.objectForKey(k)); }
var text = e('TEXT'), out = e('OUT');
var fs = parseFloat(e('FS')), w = parseInt(e('W')), h = parseInt(e('H'));
var r = parseFloat(e('R')), g = parseFloat(e('G')), b = parseFloat(e('B')), a = parseFloat(e('A'));
var weightMap = {
  regular: $.NSFontWeightRegular, medium: $.NSFontWeightMedium,
  bold: $.NSFontWeightBold, heavy: $.NSFontWeightHeavy
};
var weight = weightMap[e('WEIGHT')] || $.NSFontWeightBold;
// Draw into an explicit 1:1-pixel bitmap context. NSImage.lockFocus renders at
// the display's 2x backing scale, and drawInRect's paragraph centering
// mis-places text through the JXA bridge — drawAtPoint with a measured width
// is deterministic (verified empirically; do not "simplify" back).
var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
  null, w, h, 8, 4, true, false, $.NSCalibratedRGBColorSpace, 0, 0);
$.NSGraphicsContext.saveGraphicsState;
$.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
var attrs = $.NSMutableDictionary.alloc.init;
attrs.setObjectForKey($.NSFont.systemFontOfSizeWeight(fs, weight), $.NSFontAttributeName);
attrs.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(r, g, b, a), $.NSForegroundColorAttributeName);
var ns = $.NSString.alloc.initWithUTF8String(text);
var size = ns.sizeWithAttributes(attrs);
ns.drawAtPointWithAttributes(
  $.NSMakePoint((w - size.width) / 2.0, (h - size.height) / 2.0), attrs);
$.NSGraphicsContext.currentContext.flushGraphics;
$.NSGraphicsContext.restoreGraphicsState;
var png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSMutableDictionary.alloc.init);
png.writeToFileAtomically($.NSString.alloc.initWithUTF8String(out), true);
JS
}

echo "==> Rendering text overlays (CoreText, no drawtext)…"
render_text "strafe" "$WORK/title_main.png" 180 "$CW" 260 1 1 1 1 heavy
render_text "instant macOS Space switching" "$WORK/title_sub.png" 70 "$CW" 140 0.75 0.78 0.85 1 medium

render_text "native macOS: ${NATIVE_MS} ms to interactive" "$WORK/cap_native.png" 64 "$CW" 120 1 1 1 1 bold
render_text "with strafe: ${STRAFE_MS} ms to interactive" "$WORK/cap_strafe.png" 64 "$CW" 120 1 1 1 1 bold

render_text "${SPECS_LINE}" "$WORK/close_specs.png" 46 "$CW" 100 0.75 0.78 0.85 1 regular
render_text "${REPO_URL}" "$WORK/close_repo.png" 56 "$CW" 110 1 1 1 1 medium

# --- Cards: solid background + centered text overlays ------------------------
# Title card (2s): deep-blue background, main + subtitle.
echo "==> Building title card…"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0x0d1a4d:s=${CW}x${CH}:r=${FPS}:d=2" \
  -i "$WORK/title_main.png" -i "$WORK/title_sub.png" \
  -filter_complex "\
    [1:v]scale=${CW}:-1[t1];[2:v]scale=${CW}:-1[t2];\
    [0:v][t1]overlay=(W-w)/2:(H-h)/2-70[a];\
    [a][t2]overlay=(W-w)/2:(H-h)/2+140,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$WORK/title.mp4"

# Closing card (2.5s): specs line + repo URL.
echo "==> Building closing card…"
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0x0d1a4d:s=${CW}x${CH}:r=${FPS}:d=2.5" \
  -i "$WORK/close_specs.png" -i "$WORK/close_repo.png" \
  -filter_complex "\
    [1:v]scale=${CW}:-1[c1];[2:v]scale=${CW}:-1[c2];\
    [0:v][c1]overlay=(W-w)/2:(H-h)/2-40[a];\
    [a][c2]overlay=(W-w)/2:(H-h)/2+90,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$WORK/close.mp4"

# --- Segments: scale a take to the canvas, add a lower-third caption ----------
# scale to fit within the canvas, pad to exact size, then overlay a translucent
# lower-third bar (drawbox) + the caption PNG.
build_segment() {
  local src="$1" cap_png="$2" out="$3"
  ffmpeg -y -loglevel error \
    -i "$src" -i "$cap_png" \
    -filter_complex "\
      [0:v]scale=${CW}:${CH}:force_original_aspect_ratio=decrease,\
pad=${CW}:${CH}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=${FPS}[base];\
      [base]drawbox=x=0:y=ih-200:w=iw:h=140:color=black@0.55:t=fill[bar];\
      [1:v]scale=${CW}:-1[cap];[bar][cap]overlay=(W-w)/2:H-190,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p "$out"
}

echo "==> Building native segment…"
build_segment "$NATIVE_MOV" "$WORK/cap_native.png" "$WORK/seg_native.mp4"
echo "==> Building strafe segment…"
build_segment "$STRAFE_MOV" "$WORK/cap_strafe.png" "$WORK/seg_strafe.mp4"

# --- Concatenate title -> native -> strafe -> close --------------------------
echo "==> Concatenating full demo…"
ffmpeg -y -loglevel error \
  -i "$WORK/title.mp4" -i "$WORK/seg_native.mp4" \
  -i "$WORK/seg_strafe.mp4" -i "$WORK/close.mp4" \
  -filter_complex "[0:v][1:v][2:v][3:v]concat=n=4:v=1:a=0,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p \
  -movflags +faststart "$OUT_DIR/demo.mp4"

# --- Loop: side-by-side hstack of the two switch moments, no cards -----------
# Half-width each so the pair fits the canvas; short and quiet for README embed.
echo "==> Building side-by-side loop…"
HW=$(( CW / 2 ))
ffmpeg -y -loglevel error \
  -i "$NATIVE_MOV" -i "$STRAFE_MOV" \
  -i "$WORK/cap_native.png" -i "$WORK/cap_strafe.png" \
  -filter_complex "\
    [0:v]scale=${HW}:${CH}:force_original_aspect_ratio=decrease,\
pad=${HW}:${CH}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=${FPS}[l];\
    [1:v]scale=${HW}:${CH}:force_original_aspect_ratio=decrease,\
pad=${HW}:${CH}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=${FPS}[r];\
    [l][r]hstack=inputs=2,format=yuv420p[v]" \
  -map "[v]" -c:v libx264 -preset slow -crf 30 -pix_fmt yuv420p \
  -movflags +faststart "$OUT_DIR/demo-loop.mp4"

echo ""
echo "Wrote:"
ls -lh "$OUT_DIR/demo.mp4" "$OUT_DIR/demo-loop.mp4" | awk '{print "  " $5 "  " $9}'
echo ""
echo "If demo.mp4 > 8 MB or demo-loop.mp4 > 3 MB, raise the respective -crf"
echo "(26 / 30 above) and re-run, or trim the input takes to the switch moment."
