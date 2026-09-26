# Brainrot Background Loops

Vertical gameplay loops used by the brainrot reading mode. The browser extension uses VP9
WebM; CastReader Desktop uses the matching H.264 MP4 files.

## Canonical Storage

The public objects live under:

`https://zqxgmqygirtpttnrvjpf.supabase.co/storage/v1/object/public/castreader-public/ai-reader-web/video/`

Both formats must exist for every basename:

- `gta-1`, `gta-2`
- `minecraft-1`, `minecraft-2`, `minecraft-3`, `minecraft-4`, `minecraft-5`
- `minecraft-11`, `minecraft-12`, `minecraft-13`
- `subway-1`, `subway-2`

## Specs

- **Aspect ratio**: 9:16
- **Length**: approximately 60–75 seconds
- **Audio**: muted / no audio
- **Browser codec**: VP9 WebM
- **Desktop codec**: H.264 MP4

## Sources

Download royalty-free clips from:
- [Pexels Videos](https://www.pexels.com/videos/) — search "satisfying", "slime", "marbles"
- [Pixabay Videos](https://pixabay.com/videos/) — same keywords
- [Coverr](https://coverr.co/)

All clips must be CC0 / Pexels License / Pixabay License (commercial use OK, no attribution required).

## Fallback Behavior

If every WebM fails to load, the browser player falls back to a CSS gradient animation
(see `bg-fallback` in `src/ui/brainrot-player-styles.ts`). Users can click the
bg area to cycle through loops.
