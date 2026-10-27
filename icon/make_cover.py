#!/usr/bin/env python3
"""Draws the two pictures at the top of the README: assets/cover.png and assets/social-preview.png.

    python3 icon/make_cover.py             # writes both files into assets/
    python3 icon/make_cover.py build       # writes them under build/assets/

Everything is drawn from scratch with Pillow, so the cover matches the app it advertises and no
screenshot of one particular machine ends up in the repository. The scene is the one the macOS cover
used: a message typed on the Persian layout, and the popup offering to fix it — now with a Windows
title bar and a Windows-style flyout under the caret.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_icon import draw_app_icon, font_file, render, shape  # noqa: E402

DESIGN = (1920, 960)

INK = (7, 26, 24)
INK_LIGHT = (13, 74, 68)
MINT = (94, 234, 212)
TEAL = (15, 94, 87)
WHITE = (255, 255, 255)
CARD_TEXT = (17, 26, 25)
POPUP_BACK = (17, 26, 25)
POPUP_DIM = (154, 168, 165)
RED = (239, 68, 68)

TYPED = "فاهس هدسفثشی"  # "this instead", typed on the Persian layout
FIXED = "this instead"

_FONTS = {}


def fnt(size, bold=True):
    """A font at `size` pixels; bold uses the bold face when one is available."""
    key = (round(size), bold)
    if key not in _FONTS:
        path = font_file()
        if not bold:
            alternative = path.replace("Bold", "").replace("bold", "")
            path = alternative if os.path.exists(alternative) else path
        _FONTS[key] = ImageFont.truetype(path, max(1, round(size)))
    return _FONTS[key]


class Canvas:
    """Draws in the 1920x960 design space at whatever pixel size the image has."""

    def __init__(self, image):
        self.image = image
        self.scale = image.size[0] / DESIGN[0]
        self.draw = ImageDraw.Draw(image)

    def s(self, value):
        return value * self.scale

    def point(self, *values):
        return tuple(self.s(value) for value in values)

    def text(self, xy, string, size, color, bold=True, anchor="la", rtl=False):
        body = shape(string) if rtl else string
        self.draw.text(self.point(*xy), body, font=fnt(self.s(size), bold), fill=color, anchor=anchor)
        return body

    def width(self, string, size, bold=True, rtl=False):
        body = shape(string) if rtl else string
        return self.draw.textlength(body, font=fnt(self.s(size), bold))

def background(size):
    """Dark teal gradient with a soft glow and the faint plus grid from the original cover."""
    scale = size[0] / DESIGN[0]
    dark = Image.new("RGB", size, INK)
    light = Image.new("RGB", size, INK_LIGHT)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).ellipse((-size[0] * 0.15, -size[1] * 0.9, size[0] * 1.3, size[1] * 1.5), fill=190)
    mask = mask.filter(ImageFilter.GaussianBlur(size[0] * 0.06))
    image = Image.composite(light, dark, mask)

    draw = ImageDraw.Draw(image)
    tint = (20, 60, 55)
    step = max(8, int(64 * scale))
    for y in range(step, size[1], step):
        for x in range(step, size[0], step):
            if (x // step + y // step) % 3:
                continue
            arm = max(1, int(3 * scale))
            draw.line((x - arm, y, x + arm, y), fill=tint, width=max(1, int(scale)))
            draw.line((x, y - arm, x, y + arm), fill=tint, width=max(1, int(scale)))
    return image.convert("RGBA")


def card(canvas, box, radius, fill, blur=26, drop=16, shadow=110):
    image = canvas.image
    shadow_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow_layer).rounded_rectangle([canvas.s(v) for v in box], canvas.s(radius),
                                                    fill=(0, 0, 0, shadow))
    image.alpha_composite(shadow_layer.filter(ImageFilter.GaussianBlur(canvas.s(blur))),
                          (0, int(canvas.s(drop))))
    canvas.draw.rounded_rectangle([canvas.s(v) for v in box], canvas.s(radius), fill=fill)


def squiggle(canvas, x0, x1, y, step=15, amplitude=6, width=3):
    points = []
    up = True
    x = x0
    while x < x1:
        points.append((canvas.s(x), canvas.s(y - amplitude if up else y + amplitude)))
        x += step
        up = not up
    canvas.draw.line(points, fill=RED, width=max(2, int(canvas.s(width))), joint="curve")


def draw_scene(image):
    canvas = Canvas(image)
    scale = canvas.scale
    draw = canvas.draw

    # ---- left: icon, name, pitch ----
    icon = render(1024, draw_app_icon).resize((int(canvas.s(200)), int(canvas.s(200))), Image.Resampling.LANCZOS)
    image.alpha_composite(icon, (int(canvas.s(120)), int(canvas.s(100))))

    canvas.text((120, 340), "LayoutFixer", 110, WHITE, anchor="la")
    canvas.text((124, 470), "Typed in the wrong layout?", 46, (236, 245, 243))
    canvas.text((124, 540), "Just press Tab.", 46, MINT)

    x = 124
    for label in ("Windows 10 & 11", "English ⇄ فارسی", "Free & open source"):
        size = 26
        pad = 18
        body = shape(label) if "فارسی" in label else label
        width = canvas.draw.textlength(body, font=fnt(canvas.s(size))) / scale + pad * 2
        box = [canvas.s(v) for v in (x, 660, x + width, 730)]
        draw.rounded_rectangle(box, canvas.s(35), fill=(255, 255, 255, 26), outline=(255, 255, 255, 44),
                               width=max(1, int(scale)))
        draw.text((canvas.s(x + pad), canvas.s(695)), body, font=fnt(canvas.s(size)), fill=WHITE, anchor="lm")
        x += width + 20

    # ---- right: a window with the mistyped message ----
    card(canvas, (960, 190, 1790, 470), 18, (252, 253, 253, 255))
    draw.line([canvas.s(960), canvas.s(268), canvas.s(1790), canvas.s(268)], fill=(226, 233, 232),
              width=max(1, int(scale)))
    for index, glyph in enumerate(("min", "max", "close")):
        cx = canvas.s(1790 - 44 - index * 50)
        cy = canvas.s(229)
        color = (200, 76, 72) if glyph == "close" else (140, 152, 150)
        arm = canvas.s(7)
        width = max(1, int(canvas.s(2)))
        if glyph == "min":
            draw.line((cx - arm, cy + arm, cx + arm, cy + arm), fill=color, width=width)
        elif glyph == "max":
            draw.rectangle((cx - arm, cy - arm, cx + arm, cy + arm), outline=color, width=width)
        else:
            draw.line((cx - arm, cy - arm, cx + arm, cy + arm), fill=color, width=width)
            draw.line((cx - arm, cy + arm, cx + arm, cy - arm), fill=color, width=width)

    typed_size = 60
    typed_width = canvas.width(TYPED, typed_size, rtl=True) / scale
    right = 1740
    canvas.text((right, 372), TYPED, typed_size, CARD_TEXT, anchor="rm", rtl=True)
    draw.rectangle([canvas.s(v) for v in (right - typed_width - 18, 330, right - typed_width - 11, 400)],
                   fill=(20, 184, 166))
    squiggle(canvas, right - typed_width - 8, right + 8, 418)

    # ---- the popup, under the caret: dark card, mint bar on the left ----
    card(canvas, (1190, 500, 1810, 686), 6, POPUP_BACK + (255,), blur=20, drop=8, shadow=130)
    draw.rectangle([canvas.s(v) for v in (1190, 500, 1196, 686)], fill=MINT)
    canvas.text((1224, 540), FIXED, 52, WHITE)
    chip = [canvas.s(v) for v in (1224, 604, 1322, 654)]
    draw.rounded_rectangle(chip, canvas.s(6), outline=MINT, width=max(1, int(canvas.s(2))))
    draw.text((chip[0] + canvas.s(16), (chip[1] + chip[3]) / 2), "Tab", font=fnt(canvas.s(26)), fill=MINT,
              anchor="lm")
    draw.text((chip[2] + canvas.s(20), (chip[1] + chip[3]) / 2), "fix & switch to English",
              font=fnt(canvas.s(24)), fill=POPUP_DIM, anchor="lm")

    # ---- the Tab key, bottom right ----
    key = Image.new("RGBA", image.size, (0, 0, 0, 0))
    kd = ImageDraw.Draw(key)
    box = [canvas.s(v) for v in (1570, 770, 1800, 890)]
    kd.rounded_rectangle([box[0], box[1] + canvas.s(14), box[2], box[3] + canvas.s(14)], canvas.s(16),
                          fill=(6, 46, 42, 255))
    kd.rounded_rectangle(box, canvas.s(16), fill=(250, 253, 252, 255))
    kd.text((box[0] + canvas.s(28), box[1] + canvas.s(38)), "tab", font=fnt(canvas.s(30)), fill=TEAL, anchor="lm")
    arrow_y = box[1] + canvas.s(86)
    width = max(2, int(canvas.s(5)))
    kd.line((box[0] + canvas.s(30), arrow_y, box[0] + canvas.s(112), arrow_y), fill=TEAL, width=width)
    kd.line((box[0] + canvas.s(88), arrow_y - canvas.s(18), box[0] + canvas.s(112), arrow_y), fill=TEAL, width=width)
    kd.line((box[0] + canvas.s(88), arrow_y + canvas.s(18), box[0] + canvas.s(112), arrow_y), fill=TEAL,
            width=width)
    kd.line((box[0] + canvas.s(130), arrow_y - canvas.s(26), box[0] + canvas.s(130), arrow_y + canvas.s(26)),
            fill=TEAL, width=width)
    image.alpha_composite(key.rotate(-7, resample=Image.Resampling.BICUBIC,
                                     center=(int((box[0] + box[2]) / 2), int((box[1] + box[3]) / 2))))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    assets = os.path.join(out, "assets")
    os.makedirs(assets, exist_ok=True)

    cover = Image.new("RGBA", DESIGN, INK)
    draw_scene(cover)
    Image.alpha_composite(background(DESIGN), cover).convert("RGB").save(os.path.join(assets, "cover.png"),
                                                                        optimize=True)

    big = (2560, 1280)  # drawn twice as large, then halved, so small text stays crisp
    wide = Image.new("RGBA", big, INK)
    draw_scene(wide)
    Image.alpha_composite(background(big), wide).convert("RGB").resize((1280, 640),
                                                                      Image.Resampling.LANCZOS).save(
        os.path.join(assets, "social-preview.png"), optimize=True)

    print(f"wrote {assets}/cover.png and {assets}/social-preview.png")


if __name__ == "__main__":
    main()
