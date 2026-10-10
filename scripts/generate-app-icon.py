"""Draws Glanslate's app icon and writes the AppIcon.appiconset images.

Usage: python3 scripts/generate-app-icon.py Glanslate/Assets.xcassets/AppIcon.appiconset
Requires Pillow and the DejaVu Sans Bold font.
"""
import json, os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

out_dir = sys.argv[1]
S = 4096  # supersampled 1024 canvas (x4)
k = S / 1024

def rr(draw, box, r, fill):
    draw.rounded_rectangle([v * k for v in box], radius=r * k, fill=fill)

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Soft drop shadow beneath the squircle, per the macOS icon grid (824pt body).
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([100 * k, 112 * k, 924 * k, 936 * k], radius=186 * k, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * k))
canvas.alpha_composite(shadow)

# Body: a calm blue with a gentle vertical falloff.
body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
top, bottom = (72, 132, 255), (40, 82, 222)
grad = Image.new("RGBA", (1, S))
for y in range(S):
    t = y / (S - 1)
    grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
grad = grad.resize((S, S))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([100 * k, 100 * k, 924 * k, 924 * k], radius=186 * k, fill=255)
body.paste(grad, (0, 0), mask)
canvas.alpha_composite(body)

# Subtle top highlight for depth, fading out toward the middle.
fade = Image.new("L", (1, S))
for y in range(S):
    t = y / (S - 1)
    fade.putpixel((0, y), int(30 * max(0.0, 1 - t / 0.55)))
fade = fade.resize((S, S))
highlight = Image.new("RGBA", (S, S), (255, 255, 255, 0))
highlight.putalpha(Image.composite(fade, Image.new("L", (S, S), 0), mask))
canvas.alpha_composite(highlight)

font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", int(230 * k))

def card(box, fill, glyph, color, shadow_alpha):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if shadow_alpha:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([v * k for v in (box[0], box[1] + 14, box[2], box[3] + 14)], radius=64 * k, fill=(10, 20, 80, shadow_alpha))
        sh = sh.filter(ImageFilter.GaussianBlur(18 * k))
        layer.alpha_composite(sh)
    d = ImageDraw.Draw(layer)
    rr(d, box, 64, fill)
    cx, cy = (box[0] + box[2]) / 2 * k, (box[1] + box[3]) / 2 * k
    d.text((cx, cy), glyph, font=font, fill=color, anchor="mm")
    canvas.alpha_composite(layer)

# Back card: translucent, the source script.
card((262, 262, 602, 602), (255, 255, 255, 70), "A", (255, 255, 255, 255), 0)
# Front card: the translation, crisp white.
card((422, 422, 762, 762), (255, 255, 255, 246), "Я", (44, 88, 226, 255), 70)

master = canvas.resize((1024, 1024), Image.LANCZOS)

specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
images = []
for size, scale in specs:
    px = size * scale
    name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
    master.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, name))
    images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(out_dir, "Contents.json"), "w"), indent=2)
