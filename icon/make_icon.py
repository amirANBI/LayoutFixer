#!/usr/bin/env python3
"""Draws the LayoutFixer icons for Windows: the app icon, the tray icon and its paused twin.

Same picture as the macOS version drew with Swift: "stacked keys" — an English A key tilted behind
a Persian ش key that is coming to the front. Every frame is vector-drawn at its own pixel size, so
a 16 px tray icon is not a shrunk screenshot of a 1024 px master.

    python3 icon/make_icon.py                 # writes Resources/*.ico and icon/icon_1024.png
    python3 icon/make_icon.py build/icons     # write somewhere else (scripts/make-icons.sh does this)

Needs Pillow. With `arabic_reshaper` and `python-bidi` installed the Persian letters are joined;
without them the isolated forms are used, which at these sizes is barely visible.
"""

import io
import os
import struct
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

CANVAS = 1024.0        # the app icon is drawn in a 1024 unit square
TRAY_CANVAS = 36.0     # the tray icon in a 36 unit square, and rendered down to 16

TEAL = (15, 94, 87)              # 0F5E57
TEAL_LIGHT = (20, 184, 166)      # 14B8A6
MINT = (94, 234, 212)           # 5EEAD4
MINT_SIDE = (11, 74, 68)        # 0B4A44, the side of the mint key
WHITE_SIDE = (11, 59, 54)       # 0B3B36, the side of the white key
TRAY_COLOR = (45, 212, 191, 255)          # 2DD4BF
TRAY_COLOR_PAUSED = (126, 143, 140, 255)  # desaturated: LayoutFixer is off

ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/segoeuib.ttf",
    "C:/Windows/Fonts/tahomabd.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]

_FACES = {}


def face(size_in_pixels):
    pixels = max(1, int(round(size_in_pixels)))
    if pixels not in _FACES:
        _FACES[pixels] = ImageFont.truetype(font_file(), pixels)
    return _FACES[pixels]


def font_file():
    for candidate in FONT_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    raise SystemExit("no TrueType font found: install DejaVu, or run this where Segoe UI lives")


def shape(text):
    """Join the letters of a Persian string, when the shaping helpers are available."""
    try:
        import arabic_reshaper
        from bidi.algorithm import get_display

        return get_display(arabic_reshaper.reshape(text))
    except Exception:
        return text


def scale_of(image):
    return image.size[0] / CANVAS


def draw_text(image, size, color, text, center, persian=False):
    """`size` and `center` are canvas units; the glyph is centred on that point."""
    scale = scale_of(image)
    font = face(size * scale)
    body = shape(text) if persian else text
    draw = ImageDraw.Draw(image)
    left, top, right, bottom = draw.textbbox((0, 0), body, font=font)
    draw.text((center[0] * scale - (left + right) / 2.0, center[1] * scale - (top + bottom) / 2.0),
              body, font=font, fill=color)


def keycap(layer, box, radius, face_color, side_color, depth, glyph, glyph_color, glyph_size, persian=False):
    """A keycap: its side sticking out under the lit face, and a letter in the middle of it."""
    scale = scale_of(layer)
    x, y, w, h = [value * scale for value in box]
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle((x, y + depth * scale, x + w, y + h + depth * scale), radius * scale, fill=side_color)
    draw.rounded_rectangle((x, y, x + w, y + h), radius * scale, fill=face_color)
    center = (box[0] + box[2] / 2.0, box[1] + box[3] / 2.0)
    draw_text(layer, glyph_size, glyph_color, glyph, center, persian)


def gradient_body(layer, box, radius, top_color, bottom_color):
    """The rounded square of the app icon, filled with a vertical gradient."""
    size = layer.size[0]
    scale = size / CANVAS
    x, y, w, h = [value * scale for value in box]
    gradient = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(gradient)
    steps = max(2, int(h))
    for step in range(steps):
        t = step / (steps - 1)
        color = tuple(round(top_color[i] + (bottom_color[i] - top_color[i]) * t) for i in range(3)) + (255,)
        draw.rectangle((x, y + h * step / steps, x + w, y + h * (step + 1) / steps + 1), fill=color)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((x, y, x + w, y + h), radius * scale, fill=255)
    gradient.putalpha(mask)
    layer.alpha_composite(gradient)


def soft_shadow(layer, box, radius, blur, drop, alpha):
    size = layer.size[0]
    scale = size / CANVAS
    x, y, w, h = [value * scale for value in box]
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((x, y, x + w, y + h), radius * scale, fill=(0, 0, 0, alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur * scale))
    layer.alpha_composite(shadow, (0, int(drop * scale)))


def rotate_about(layer, degrees, center):
    """Positive turns the image counter-clockwise, like the CoreGraphics original did."""
    scale = scale_of(layer)
    return layer.rotate(degrees, resample=Image.Resampling.BICUBIC,
                        center=(center[0] * scale, center[1] * scale))


def render(size, draw_fn):
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_fn(image)
    return image


# MARK: - the app icon

def draw_app_icon(image):
    body = (100, 100, 824, 824)
    soft_shadow(image, body, 185, 24, 10, 80)
    gradient_body(image, body, 185, TEAL_LIGHT, TEAL)

    # English key, tilted back.
    back = Image.new("RGBA", image.size, (0, 0, 0, 0))
    keycap(back, (230, 230, 380, 370), 76, MINT + (255,), MINT_SIDE + (255,), 20, "A", TEAL + (255,), 200)
    image.alpha_composite(rotate_about(back, 12, (420, 420)))

    # Persian key, in front.
    front = Image.new("RGBA", image.size, (0, 0, 0, 0))
    soft_shadow(front, (420, 420, 380, 380), 76, 30, 14, 70)
    keycap(front, (420, 420, 380, 380), 76, (255, 255, 255, 255), WHITE_SIDE + (255,), 30,
           "ش", TEAL + (255,), 220, persian=True)
    image.alpha_composite(rotate_about(front, -6, (610, 610)))


# MARK: - the tray icon

def draw_tray_icon(image, color=TRAY_COLOR):
    """A filled key with A and ش cut out, in the style of the Windows input indicator: the letters
    are the taskbar showing through, so it reads on a light and a dark tray alike."""
    size = image.size[0]
    scale = size / TRAY_CANVAS
    body = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((1 * scale, 1 * scale, 35 * scale, 35 * scale), 8 * scale, fill=color)

    holes = Image.new("L", (size, size), 0)
    probe = ImageDraw.Draw(holes)
    for glyph, glyph_size, center, persian in (("A", 17, (11.5, 11.5), False), ("ش", 20, (24.5, 24.5), True)):
        font = face(glyph_size * scale)
        text = shape(glyph) if persian else glyph
        left, top, right, bottom = probe.textbbox((0, 0), text, font=font)
        probe.text((center[0] * scale - (left + right) / 2.0, center[1] * scale - (top + bottom) / 2.0),
                   text, font=font, fill=255)

    body.putalpha(ImageChops.subtract(body.getchannel("A"), holes))
    image.alpha_composite(body)


# MARK: - output

def write_ico(path, images):
    """One PNG frame per size. Windows reads PNG entries inside .ico since Vista, which saves us from
    hand-writing 32-bit DIBs and their AND masks."""
    entries = []
    for size, image in images:
        buffer = io.BytesIO()
        image.save(buffer, "PNG", optimize=True)
        entries.append((size, buffer.getvalue()))

    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = len(header) + 16 * len(entries)
    directory = b""
    data = b""
    for size, blob in entries:
        field = 0 if size >= 256 else size  # a zero byte means 256 in the icon directory
        directory += struct.pack("<BBBBHHII", field, field, 0, 0, 1, 32, len(blob), offset + len(data))
        data += blob
    with open(path, "wb") as handle:
        handle.write(header + directory + data)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    resources = os.path.join(out, "Resources")
    icon_dir = os.path.join(out, "icon")
    os.makedirs(resources, exist_ok=True)
    os.makedirs(icon_dir, exist_ok=True)

    render(1024, draw_app_icon).save(os.path.join(icon_dir, "icon_1024.png"))
    write_ico(os.path.join(resources, "AppIcon.ico"), [(size, render(size, draw_app_icon)) for size in ICON_SIZES])
    for name, color in (("TrayIcon.ico", TRAY_COLOR), ("TrayIconPaused.ico", TRAY_COLOR_PAUSED)):
        frames = [(size, render(size, lambda image, size=size, color=color: draw_tray_icon(image, color)))
                  for size in ICON_SIZES]
        write_ico(os.path.join(resources, name), frames)

    print(f"wrote AppIcon.ico, TrayIcon.ico and TrayIconPaused.ico to {resources}")
    print(f"wrote icon/icon_1024.png  (sizes: {' '.join(map(str, ICON_SIZES))})")


if __name__ == "__main__":
    main()
