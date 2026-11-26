# Orbit42 圖示產生器（2026-11-24 Keng：選 B「實渲染・思考中」→ 分深淺色自動切換 → 球心加小小的金色 42）
# 素材：assets/icon-src/ball_render.png ＝ App 實際渲染的智能體（只留球）。要重新渲染：
#   ORBIT_OFFSCREEN=1 ORBIT_TEST_W=1200 ORBIT_TEST_H=1200 ORBIT_WEB_DIR=<Orbit42>/windows/Orbit42.Engine.Win/Board/Web \
#   ORBIT_TEST_SPHERE_SHOT=assets/icon-src/ball_render.png ORBIT_TEST_SPHERE_JS='karaIconShot({noRibbons:true}); const st=document.createElement("style"); st.textContent="*,*::before,*::after{background-image:none!important} html,body{background:#000!important}"; document.head.appendChild(st); karaSetState("thinking");' \
#   .build/debug/Orbit42      （等 png 出現再關掉；1200x1200 視窗時球心約在 (600, 470)）
# 用法：python3 scripts/make_icon_render.py
# 產出：
#   assets/Orbit42.icon/Assets/ball_{dark,light}.png   Icon Composer 圖層（透明）；build_app.sh 用 actool 編成 Assets.car（Finder／桌面自動切深淺）
#   assets/Orbit42-{dark,light}.png、Orbit42.png        Mac 成品（圓角底）；Dock 圖示 App 開著時跟著深淺色換（DockIcon.swift）
#   ios/.../AppIcon.appiconset/icon-{1024,dark}.png      iPhone（滿版不透明，系統自己裁圓角；深色是 iOS 18 起的深色外觀）
# 深色：綠殼＋白分段環、黑底；淺色：黑殼＋紅分段環、淺灰白底（Keng：深色不准紅，淺色才用紅）。底框不能透明：macOS 26 會塞進淺灰框。
import os, json
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance, ImageChops, ImageFont
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLD = (212, 175, 55)
src = Image.open(f"{R}/assets/icon-src/ball_render.png").convert("RGB").crop((600 - 345, 470 - 345, 600 + 345, 470 + 345))
im = ImageEnhance.Brightness(src).enhance(2.4)
glow = im.filter(ImageFilter.GaussianBlur(12)); imG = ImageChops.add(im, ImageEnhance.Brightness(glow).enhance(.8))
mask = Image.new("L", im.size, 0); ImageDraw.Draw(mask).ellipse((8, 8, 682, 682), fill=255); mask = mask.filter(ImageFilter.GaussianBlur(10))

def layer(s, light):
    s = Image.composite(s, Image.new("RGB", s.size), mask); p = s.load(); out = Image.new("RGBA", s.size); q = out.load()
    for y in range(s.height):
        for x in range(s.width):
            r, g, b = p[x, y]; a = max(r, g, b)
            if a < 14: q[x, y] = (0, 0, 0, 0); continue
            if not light: q[x, y] = (min(255, r * 255 // a), min(255, g * 255 // a), min(255, b * 255 // a), a); continue
            green = g > r * 1.25 and g > b * 1.25      # 綠殼→近黑；白／灰分段環→紅
            q[x, y] = (24, 24, 24, min(255, int(a * 1.95))) if green else (215, 38, 27, min(255, int(a * 1.1)))
    big = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)); big.alpha_composite(out.resize((820, 820), Image.LANCZOS), (102, 102))
    return big

def gold42(img, light):
    # 球心小小的金色 42（App 球心時鐘秒數跳到 42 那一秒的金色）；底下墊一層柔和暗影／亮影讓它從殼的線條裡浮出來
    f = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 118); f.set_variation_by_axes([700]) if hasattr(f, "set_variation_by_axes") else None
    d = ImageDraw.Draw(Image.new("L", (1, 1))); bb = d.textbbox((0, 0), "42", font=f)
    w, h = bb[2] - bb[0], bb[3] - bb[1]; x, y = 512 - w / 2 - bb[0], 512 - h / 2 - bb[1]
    halo = Image.new("RGBA", img.size, (0, 0, 0, 0)); hd = ImageDraw.Draw(halo)
    hd.ellipse((512 - 120, 512 - 92, 512 + 120, 512 + 92), fill=(246, 246, 246, 210) if light else (0, 0, 0, 200))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(26)))
    t = Image.new("RGBA", img.size, (0, 0, 0, 0)); ImageDraw.Draw(t).text((x, y), "42", font=f, fill=GOLD + (255,), stroke_width=4, stroke_fill=GOLD + (255,))      # 細描邊＝加粗
    if not light: img.alpha_composite(Image.composite(Image.new("RGBA", img.size, GOLD + (120,)), Image.new("RGBA", img.size, (0, 0, 0, 0)), t.split()[3].filter(ImageFilter.GaussianBlur(10))))
    img.alpha_composite(t); return img

def squircle(lay, bg, size=1024, inset=100, rad=185, full=False):
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0) if not full else bg)
    if not full:
        sq = Image.new("RGBA", (size - 2 * inset, size - 2 * inset), bg); mk = Image.new("L", sq.size, 0)
        ImageDraw.Draw(mk).rounded_rectangle((0, 0, sq.width - 1, sq.height - 1), rad, fill=255); base.paste(sq, (inset, inset), mk)
    base.alpha_composite(lay); return base

BG = {"dark": (0, 0, 0, 255), "light": (246, 246, 246, 255)}
layers = {"dark": gold42(layer(imG, False), False), "light": gold42(layer(im, True), True)}
os.makedirs(f"{R}/assets/Orbit42.icon/Assets", exist_ok=True)
for k, lay in layers.items():
    lay.save(f"{R}/assets/Orbit42.icon/Assets/ball_{k}.png")
    squircle(lay, BG[k]).save(f"{R}/assets/Orbit42-{k}.png")
squircle(layers["dark"], BG["dark"]).save(f"{R}/assets/Orbit42.png")
# iPhone：滿版、不透明（系統裁圓角）；球放大一點填滿
ios = f"{R}/ios/Orbit42Phone/Assets.xcassets/AppIcon.appiconset"
for k, name in (("light", "icon-1024.png"), ("dark", "icon-dark.png")):
    lay = layers[k].crop((92, 92, 932, 932)).resize((1024, 1024), Image.LANCZOS)
    full = Image.new("RGBA", (1024, 1024), BG[k]); full.alpha_composite(lay); full.convert("RGB").save(f"{ios}/{name}")
json.dump({"images": [
    {"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "icon-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1}}, open(f"{ios}/Contents.json", "w"), indent=2)
print("ok")
