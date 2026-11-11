"""PNG to WebP for the site: about 1600px wide and under 80 KB."""
import sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
for quality in (82, 76, 70, 64, 58):
    im.save(dst, "WEBP", quality=quality, method=6, alpha_quality=80)
    size = __import__("os").path.getsize(dst)
    if size <= 80 * 1024:
        break
print(f"{dst.rsplit('/', 1)[-1]}: {im.width}x{im.height}, q{quality}, {size // 1024} KB")
