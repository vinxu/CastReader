#!/usr/bin/env python3
"""
Generate App Icons for Xcode 13 iOS project.
Takes a 1024x1024 source image and generates all required sizes.
"""

import os
import json
from PIL import Image

# Xcode 13 iOS App Icon sizes
# Format: (size_pt, scale, idiom, filename)
ICON_SIZES = [
    # iPhone Notification
    (20, 2, "iphone", "icon-20@2x.png"),
    (20, 3, "iphone", "icon-20@3x.png"),
    # iPhone Settings
    (29, 2, "iphone", "icon-29@2x.png"),
    (29, 3, "iphone", "icon-29@3x.png"),
    # iPhone Spotlight
    (40, 2, "iphone", "icon-40@2x.png"),
    (40, 3, "iphone", "icon-40@3x.png"),
    # iPhone App
    (60, 2, "iphone", "icon-60@2x.png"),
    (60, 3, "iphone", "icon-60@3x.png"),
    # iPad Notification
    (20, 1, "ipad", "icon-20-ipad.png"),
    (20, 2, "ipad", "icon-20@2x-ipad.png"),
    # iPad Settings
    (29, 1, "ipad", "icon-29-ipad.png"),
    (29, 2, "ipad", "icon-29@2x-ipad.png"),
    # iPad Spotlight
    (40, 1, "ipad", "icon-40-ipad.png"),
    (40, 2, "ipad", "icon-40@2x-ipad.png"),
    # iPad App
    (76, 1, "ipad", "icon-76.png"),
    (76, 2, "ipad", "icon-76@2x.png"),
    # iPad Pro App
    (83.5, 2, "ipad", "icon-83.5@2x.png"),
    # App Store
    (1024, 1, "ios-marketing", "icon-1024.png"),
]


def generate_icons(source_path: str, output_dir: str):
    """Generate all icon sizes from source image."""

    # Create output directory if not exists
    os.makedirs(output_dir, exist_ok=True)

    # Open source image
    source = Image.open(source_path)
    if source.size != (1024, 1024):
        print(f"Warning: Source image is {source.size}, resizing to 1024x1024")
        source = source.resize((1024, 1024), Image.LANCZOS)

    # Convert to RGBA if needed
    if source.mode != "RGBA":
        source = source.convert("RGBA")

    # Generate each size
    images_info = []
    for size_pt, scale, idiom, filename in ICON_SIZES:
        pixel_size = int(size_pt * scale)

        # Resize image
        resized = source.resize((pixel_size, pixel_size), Image.LANCZOS)

        # Save as PNG
        output_path = os.path.join(output_dir, filename)
        resized.save(output_path, "PNG")
        print(f"Generated: {filename} ({pixel_size}x{pixel_size})")

        # Add to images info for Contents.json
        images_info.append({
            "size": f"{size_pt}x{size_pt}" if size_pt == int(size_pt) else f"{size_pt}x{size_pt}",
            "idiom": idiom,
            "filename": filename,
            "scale": f"{scale}x"
        })

    # Generate Contents.json
    contents = {
        "images": images_info,
        "info": {
            "version": 1,
            "author": "xcode"
        }
    }

    contents_path = os.path.join(output_dir, "Contents.json")
    with open(contents_path, "w") as f:
        json.dump(contents, f, indent=2)
    print(f"Generated: Contents.json")

    print(f"\nDone! All icons saved to: {output_dir}")


if __name__ == "__main__":
    import sys

    # Default paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    default_source = os.path.join(script_dir, "icon.png")
    default_output = os.path.join(script_dir, "CastReader/Assets.xcassets/AppIcon.appiconset")

    # Get source path from argument or use default
    source_path = sys.argv[1] if len(sys.argv) > 1 else default_source
    output_dir = sys.argv[2] if len(sys.argv) > 2 else default_output

    if not os.path.exists(source_path):
        print(f"Error: Source image not found: {source_path}")
        print(f"Usage: python {sys.argv[0]} [source_image.png] [output_dir]")
        sys.exit(1)

    generate_icons(source_path, output_dir)
