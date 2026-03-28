# Video Frames

Extract frames or clips from video files using ffmpeg.

## Usage

```bash
bash /workspace/skills/video-frames/scripts/frame.sh <video> [options]
```

## Options

- `--time HH:MM:SS` — Extract frame at timestamp (default: 00:00:01)
- `--index N` — Extract Nth frame (0-based)
- `--out /path/to/output.jpg` — Output path (default: /tmp/frame.jpg)
- `--format png` — Output format: jpg or png (default: jpg)

## Examples

```bash
# Frame at 30 seconds
bash /workspace/skills/video-frames/scripts/frame.sh video.mp4 --time 00:00:30

# First frame
bash /workspace/skills/video-frames/scripts/frame.sh video.mp4 --index 0

# Save as PNG
bash /workspace/skills/video-frames/scripts/frame.sh video.mp4 --time 00:01:00 --format png --out /tmp/scene.png
```

After extracting, use `Read` to view the image.
