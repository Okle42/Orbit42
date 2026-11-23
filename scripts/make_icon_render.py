# Orbit42 圖示（2026-11-24 Keng 選 B「實渲染・思考中」）：用 App 實際渲染的智能體做圖示。
# 1) 螢幕外渲染只留球的畫面（sphere.html 的 window.karaIconShot 拿掉量表、衛星、時鐘、介面）：
#    ORBIT_OFFSCREEN=1 ORBIT_TEST_W=1200 ORBIT_TEST_H=1200 SHOWORK_WEB_DIR=<ShoWork42>/windows/ShoWork.Win/Board/Web \
#    SHOWORK_TEST_SPHERE_SHOT=ball.png SHOWORK_TEST_SPHERE_JS='karaIconShot({noRibbons:true}); const st=document.createElement("style"); st.textContent="*,*::before,*::after{background-image:none!important} html,body{background:#000!important}"; document.head.appendChild(st); karaSetState("thinking");' \
#    .build/debug/Orbit42      （等 ball.png 出現再關掉）
# 2) python3 scripts/make_icon_render.py ball.png  ⇒ assets/Orbit42.png＋assets/Orbit42.icns
# 底框為什麼不能透明：macOS 26 起 Dock／Finder 會把非圓角方形的圖示硬塞進淺灰圓角框，所以用純黑底（跟球的背景同色）。
import sys, os, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance, ImageChops
src = sys.argv[1]; root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
im = Image.open(src).convert("RGB").crop((600 - 345, 470 - 345, 600 + 345, 470 + 345))      # 1200x1200 視窗時球心約在 (600, 470)
im = ImageEnhance.Brightness(im).enhance(2.4)
glow = im.filter(ImageFilter.GaussianBlur(12)); im = ImageChops.add(im, ImageEnhance.Brightness(glow).enhance(.8))
m = Image.new("L", im.size, 0); ImageDraw.Draw(m).ellipse((8, 8, 682, 682), fill=255); m = m.filter(ImageFilter.GaussianBlur(10))
im = Image.composite(im, Image.new("RGB", im.size), m).resize((800, 800), Image.LANCZOS)
base = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)); sq = Image.new("RGB", (824, 824), (0, 0, 0)); sq.paste(im, (12, 12))
mk = Image.new("L", (824, 824), 0); ImageDraw.Draw(mk).rounded_rectangle((0, 0, 823, 823), 185, fill=255)
base.paste(sq, (100, 100), mk); base.save(f"{root}/assets/Orbit42.png")
d = tempfile.mkdtemp(suffix=".iconset")
for s in (16, 32, 128, 256, 512):
    base.resize((s, s), Image.LANCZOS).save(f"{d}/icon_{s}x{s}.png"); base.resize((s * 2, s * 2), Image.LANCZOS).save(f"{d}/icon_{s}x{s}@2x.png")
subprocess.run(["iconutil", "-c", "icns", d, "-o", f"{root}/assets/Orbit42.icns"], check=True)
