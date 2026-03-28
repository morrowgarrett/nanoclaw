#!/bin/bash
set -euo pipefail

# Extract a single frame from a video using ffmpeg
VIDEO=""
TIME="00:00:01"
INDEX=""
OUT="/tmp/frame.jpg"
FORMAT="jpg"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --time) TIME="$2"; shift 2 ;;
    --index) INDEX="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) VIDEO="$1"; shift ;;
  esac
done

if [ -z "$VIDEO" ]; then
  echo "Usage: frame.sh <video> [--time HH:MM:SS] [--index N] [--out path] [--format jpg|png]" >&2
  exit 1
fi

if [ ! -f "$VIDEO" ]; then
  echo "Error: Video file not found: $VIDEO" >&2
  exit 1
fi

if [ -n "$INDEX" ]; then
  # Extract by frame index
  ffmpeg -i "$VIDEO" -vf "select=eq(n\,$INDEX)" -vframes 1 -y "$OUT" 2>/dev/null
else
  # Extract by timestamp
  ffmpeg -ss "$TIME" -i "$VIDEO" -vframes 1 -y "$OUT" 2>/dev/null
fi

if [ -f "$OUT" ]; then
  SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT" 2>/dev/null)
  echo "Frame saved: $OUT ($SIZE bytes)"
else
  echo "Error: Failed to extract frame" >&2
  exit 1
fi
