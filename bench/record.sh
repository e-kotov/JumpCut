#!/bin/bash
# record.sh <output.mov> <seconds>
#
# Region screen-capture of the main display EXCLUDING the menu bar, so a take
# never shows menu-bar extras (clock, wifi, battery %, user name, VPN, etc.) —
# all of which can leak personal data. We compute the main-display point size
# and the menu-bar height, then capture the rect below the menu bar.
#
# macOS 26 `screencapture` flag notes (verified on 26.x):
#   -v            record video
#   -V<seconds>   limit duration; the value is ATTACHED to the flag (no space):
#                 -V5, not -V 5. A space makes screencapture treat the number as
#                 a filename argument.
#   -R<x,y,w,h>   capture rect, ALSO attached: -R0,24,1512,958.
#   -x            no capture sound.
#   Coordinates are in POINTS (not backing pixels) with a top-left origin.
#
# TCC: the FIRST run triggers a Screen Recording permission prompt. Grant it,
# then re-run. Nothing is recorded until you approve.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <output.mov> <seconds>" >&2
  exit 2
fi

OUT="$1"
SECS="$2"

if ! [[ "$SECS" =~ ^[0-9]+$ ]]; then
  echo "error: seconds must be a positive integer (got '$SECS')" >&2
  exit 2
fi

# Main-display point size via AppKit (no third-party tools). This prints:
#   <width> <height> <menubarHeight>
read -r W H MENUBAR < <(/usr/bin/osascript -l JavaScript <<'JS'
ObjC.import('AppKit');
var screen = $.NSScreen.mainScreen;
var full = screen.frame;
var visible = screen.visibleFrame;
// Menu bar height = gap between the top of the full frame and the top of the
// visible frame (which excludes the menu bar).
var menubar = (full.origin.y + full.size.height) - (visible.origin.y + visible.size.height);
[Math.round(full.size.width), Math.round(full.size.height), Math.round(menubar)].join(' ');
JS
)

# Fallback if AppKit somehow yields a zero menu-bar height (e.g. auto-hide on):
# 24 points is the classic macOS menu-bar height. On notched displays the menu
# bar is taller; adjust here if your take still shows it.
if [[ -z "${MENUBAR:-}" || "$MENUBAR" -eq 0 ]]; then
  MENUBAR=24
  echo "note: menu-bar height read as 0; falling back to ${MENUBAR}pt" >&2
fi

CONTENT_H=$(( H - MENUBAR ))
RECT="0,${MENUBAR},${W},${CONTENT_H}"

echo "==> Recording main display below the menu bar"
echo "    display: ${W}x${H}pt, menu bar: ${MENUBAR}pt -> rect ${RECT}, ${SECS}s"
echo "    (first run prompts for Screen Recording permission)"

# -x silences the capture UI sound; -V and -R values are attached per notes above.
screencapture -v -x "-V${SECS}" "-R${RECT}" "$OUT"

echo "Wrote: $OUT"
echo "REMINDER: before publishing, scrub the frame for any personal content."
