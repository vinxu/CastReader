#!/usr/bin/env python3
"""Compose App Store In-App Event media from generated backgrounds and real UI.

The generated study-desk images are intentionally text-free. This script keeps
the product UI pixel-accurate by compositing the original App Store screenshots
instead of asking an image model to redraw the interface.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "AppStoreAssets" / "in-app-events" / "back-to-school-2026"
RAW_SCREENSHOT_DIR = ROOT / "AppStoreAssets" / "new"


def cover(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(
        image.convert("RGB"),
        size,
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    ).convert("RGBA")


def rounded_phone_panel(
    screenshot: Image.Image,
    *,
    height: int,
    rotation: float,
) -> Image.Image:
    screenshot = screenshot.convert("RGBA")
    width = round(screenshot.width * height / screenshot.height)
    screenshot = screenshot.resize((width, height), Image.Resampling.LANCZOS)

    radius = max(24, round(width * 0.075))
    screen_mask = Image.new("L", screenshot.size, 0)
    ImageDraw.Draw(screen_mask).rounded_rectangle(
        (0, 0, width - 1, height - 1),
        radius=radius,
        fill=255,
    )
    screenshot.putalpha(screen_mask)

    border = max(10, round(width * 0.025))
    framed = Image.new("RGBA", (width + border * 2, height + border * 2), (0, 0, 0, 0))
    frame_mask = Image.new("L", framed.size, 0)
    ImageDraw.Draw(frame_mask).rounded_rectangle(
        (0, 0, framed.width - 1, framed.height - 1),
        radius=radius + border,
        fill=255,
    )
    frame = Image.new("RGBA", framed.size, (255, 255, 255, 255))
    frame.putalpha(frame_mask)
    framed.alpha_composite(frame)
    framed.alpha_composite(screenshot, (border, border))

    shadow_pad = max(60, round(width * 0.18))
    shadow = Image.new(
        "RGBA",
        (framed.width + shadow_pad * 2, framed.height + shadow_pad * 2),
        (0, 0, 0, 0),
    )
    shadow_mask = Image.new("L", shadow.size, 0)
    ImageDraw.Draw(shadow_mask).rounded_rectangle(
        (
            shadow_pad,
            shadow_pad + max(8, round(height * 0.015)),
            shadow_pad + framed.width - 1,
            shadow_pad + framed.height - 1 + max(8, round(height * 0.015)),
        ),
        radius=radius + border,
        fill=120,
    )
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(max(18, round(width * 0.05))))
    shadow.putalpha(shadow_mask)
    shadow.alpha_composite(framed, (shadow_pad, shadow_pad))

    return shadow.rotate(
        rotation,
        resample=Image.Resampling.BICUBIC,
        expand=True,
    )


def add_focus_glow(canvas: Image.Image, box: tuple[int, int, int, int]) -> None:
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle(box, radius=180, fill=(255, 90, 0, 42))
    glow = glow.filter(ImageFilter.GaussianBlur(55))
    canvas.alpha_composite(glow)


def paste_centered(canvas: Image.Image, panel: Image.Image, center: tuple[int, int]) -> None:
    canvas.alpha_composite(
        panel,
        (center[0] - panel.width // 2, center[1] - panel.height // 2),
    )


def compose_landscape(import_screen: Image.Image, explain_screen: Image.Image) -> Path:
    background = Image.open(ASSET_DIR / "generated-study-landscape.png")
    canvas = cover(background, (1920, 1080))
    add_focus_glow(canvas, (450, 100, 1470, 1030))

    import_panel = rounded_phone_panel(import_screen, height=820, rotation=-5.0)
    explain_panel = rounded_phone_panel(explain_screen, height=900, rotation=4.0)
    paste_centered(canvas, import_panel, (790, 560))
    paste_centered(canvas, explain_panel, (1180, 530))

    output = ASSET_DIR / "event-card-1920x1080.png"
    canvas.convert("RGB").save(output, format="PNG", optimize=True)
    return output


def compose_portrait(import_screen: Image.Image, explain_screen: Image.Image) -> Path:
    background = Image.open(ASSET_DIR / "generated-study-portrait.png")
    canvas = cover(background, (1080, 1920))
    add_focus_glow(canvas, (110, 170, 980, 1770))

    import_panel = rounded_phone_panel(import_screen, height=1030, rotation=-4.0)
    explain_panel = rounded_phone_panel(explain_screen, height=1220, rotation=4.0)
    paste_centered(canvas, import_panel, (330, 760))
    paste_centered(canvas, explain_panel, (735, 1160))

    output = ASSET_DIR / "event-details-1080x1920.png"
    canvas.convert("RGB").save(output, format="PNG", optimize=True)
    return output


def main() -> None:
    import_screen = Image.open(RAW_SCREENSHOT_DIR / "IMG_3463.PNG")
    explain_screen = Image.open(RAW_SCREENSHOT_DIR / "IMG_3476.PNG")
    outputs = [
        compose_landscape(import_screen, explain_screen),
        compose_portrait(import_screen, explain_screen),
    ]
    for output in outputs:
        with Image.open(output) as image:
            print(f"{output.relative_to(ROOT)}: {image.width}x{image.height}")


if __name__ == "__main__":
    main()
