# Brainrot Background Loops

Royalty-free 9:16 vertical video loops used by the brainrot reading mode.

## Required Files

- `liquid.mp4` — fluid / paint mixing
- `cubes.mp4` — satisfying block cutting
- `slime.mp4` — slime stretching
- `marbles.mp4` — marble runs
- `paper.mp4` — paper folding / origami

## Specs

- **Aspect ratio**: 9:16 (720×1280 recommended)
- **Length**: 10–15s loop, seamless loop point
- **Audio**: muted / no audio
- **Codec**: H.264 mp4
- **File size**: target 2–3 MB each

## Sources

Download royalty-free clips from:
- [Pexels Videos](https://www.pexels.com/videos/) — search "satisfying", "slime", "marbles"
- [Pixabay Videos](https://pixabay.com/videos/) — same keywords
- [Coverr](https://coverr.co/)

All clips must be CC0 / Pexels License / Pixabay License (commercial use OK, no attribution required).

## Fallback Behavior

If any mp4 fails to load, the player falls back to a CSS gradient animation
(see `bg-fallback` in `src/ui/brainrot-player-styles.ts`). Users can click the
bg area to cycle through loops.
