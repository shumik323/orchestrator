#!/bin/bash
# Сверка рендера страницы с кадрами Figma: скрин headless Chrome на каждой ширине → пиксельный
# дифф с кадром (PIL) → тепловая карта → страница сравнения с сеткой и onion-skin.
#
# Usage: bash scripts/compare-figma.sh <url> <outdir> <имя>=<ширина>x<высота>:<кадр.jpg|png> [...]
#   bash scripts/compare-figma.sh http://127.0.0.1:8899/belleza.html /tmp/cmp \
#     desktop=1440x1000:docs/specs/belleza-hero/figma-desktop.jpg \
#     mobile=490x1000:docs/specs/belleza-hero/figma-mobile.jpg
# Нужны: Google Chrome, python3 с Pillow и numpy. Страница должна быть уже поднята (любой http).
# CMP_WRAP_BASE — http-адрес каталога <outdir>, если он раздаётся тем же сервером, что и страница:
# тогда обёртка same-origin и может выключить анимации внутри iframe; без него — file:// и анимации бегут.
# Порог «заметной разницы» — DIFF_THRESHOLD (0–255, по умолчанию 40) после блюра 1px: гасит шум
# антиалиасинга, но оставляет сдвиги в 1–2px как контуры — их и надо смотреть глазами.
set -u
[ $# -ge 3 ] || { sed -n '2,10p' "$0"; exit 2; }
URL="$1"; OUT="$2"; shift 2
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { printf 'нет Chrome: %s (задай CHROME=...)\n' "$CHROME" >&2; exit 2; }
python3 -c 'import PIL, numpy' 2>/dev/null || { printf 'нужны python3 + Pillow + numpy: pip3 install pillow numpy\n' >&2; exit 2; }
mkdir -p "$OUT/render" "$OUT/figma" "$OUT/heat"
manifest=""
for spec in "$@"; do
  name="${spec%%=*}"; rest="${spec#*=}"; size="${rest%%:*}"; ref="${rest#*:}"
  w="${size%x*}"; h="${size#*x}"
  [ -f "$ref" ] || { printf 'нет кадра %s\n' "$ref" >&2; exit 2; }
  cp "$ref" "$OUT/figma/$name.${ref##*.}"
  shot="$OUT/render/$name.png"; rm -f "$shot"
  # Chrome клампит окно к ширине ≥ 500 (замер 20.09: --window-size=490 → innerWidth 500, страница
  # свёрстана на 500 и обрезана), поэтому страница рендерится в iframe нужной ширины внутри
  # окна ≥ 520, а скрин кропается до w×h ниже в python.
  wrap="$OUT/render/wrap-$name.html"
  # Анимации в кадре стоят, а в рендере бегут (marquee уехал за 8 с виртуального времени): для диффа
  # ставим их на паузу в нулевом кадре; работает только для same-origin страницы, иначе молча нет.
  printf '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;background:#fff}iframe{display:block;border:0}</style></head><body><iframe src="%s" width="%s" height="%s" onload="try{var d=this.contentDocument,s=d.createElement(\x27style\x27);s.textContent=\x27*,*::before,*::after{animation:none!important}\x27;d.head.appendChild(s)}catch(e){}"></iframe></body></html>' "$URL" "$w" "$h" > "$wrap"
  ww=$(( w < 520 ? 520 : w ))
  if [ -n "${CMP_WRAP_BASE:-}" ]; then wrap_url="$CMP_WRAP_BASE/render/wrap-$name.html"; else wrap_url="file://$wrap"; fi
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$OUT/.chrome-$name" \
    --window-size="${ww},${h}" --virtual-time-budget=8000 --screenshot="$shot" "$wrap_url" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 40); do [ -s "$shot" ] && break; sleep 1; done
  sleep 1; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ -s "$shot" ] || { printf 'рендер %s не снялся (Chrome, URL?)\n' "$name" >&2; exit 1; }
  manifest="$manifest$name $w $h figma/$name.${ref##*.}"$'\n'
done
printf '%s' "$manifest" > "$OUT/manifest.txt"
CMP_URL="${CMP_URL:-$URL}" DIFF_THRESHOLD="${DIFF_THRESHOLD:-40}" python3 - "$OUT" <<'PY'
import sys, os, json, numpy as np
from PIL import Image, ImageFilter
out = sys.argv[1]; thr = int(os.environ.get("DIFF_THRESHOLD", "40")); stats = {}; rows = []
for line in open(f"{out}/manifest.txt"):
    name, w, h, ref = line.split(); w, h = int(w), int(h)
    r = Image.open(f"{out}/render/{name}.png").convert("RGB")
    if r.size != (w, h): r = r.crop((0, 0, w, h))  # окно шире iframe — кроп до кадра
    f = Image.open(f"{out}/{ref}").convert("RGB")
    if f.size != r.size: f = f.resize(r.size)
    a = np.asarray(r.filter(ImageFilter.GaussianBlur(1)), dtype=np.int16)
    b = np.asarray(f.filter(ImageFilter.GaussianBlur(1)), dtype=np.int16)
    d = np.abs(a - b).max(axis=2)
    hot = float((d > thr).mean() * 100)
    t = np.clip(d / 160.0, 0, 1)
    heat = np.stack([255 * np.clip(t * 2, 0, 1), 255 * np.clip(1 - abs(t - 0.5) * 2, 0, 1), 255 * np.clip(1 - t * 2, 0, 1)], axis=2)
    base = np.asarray(r.convert("L").convert("RGB"), dtype=np.float32) * 0.35
    mix = np.where((d > thr)[..., None], heat, base).astype(np.uint8)
    Image.fromarray(mix).save(f"{out}/heat/{name}.png", optimize=True)
    stats[name] = {"hot_pct": round(hot, 2), "mean_diff": round(float(d.mean()), 1), "threshold": thr}
    rows.append((name, w, h, ref))
    print(f"{name}: {hot:.1f}% пикселей с разницей > {thr}, средняя разница {d.mean():.1f}/255")
json.dump(stats, open(f"{out}/heat/stats.json", "w"))
url = os.environ.get("CMP_URL", "")
html = ["<!doctype html><html lang='ru'><head><meta charset='utf-8'><title>рендер против Figma</title><style>",
"body{margin:0;padding:16px;font:14px system-ui;background:#eee;color:#222}h2{margin:24px 0 8px}",
".tools{display:flex;gap:18px;align-items:center;margin:8px 0 12px;flex-wrap:wrap}.tools label{display:flex;gap:6px;align-items:center}",
".row{display:flex;gap:16px;align-items:flex-start;overflow-x:auto}.col{flex:0 0 auto}.col>span{display:block;margin-bottom:4px;color:#555}",
"iframe,img{border:1px solid #999;display:block;background:#fff}.stack{position:relative}.onion{position:absolute;top:0;left:0;pointer-events:none;border:0;opacity:0}",
".grid{position:absolute;inset:0;pointer-events:none;display:none;background-image:repeating-linear-gradient(0deg,rgba(0,200,255,.35) 0 1px,transparent 1px 8px),repeating-linear-gradient(90deg,rgba(0,200,255,.35) 0 1px,transparent 1px 8px)}",
"body.grid-on .grid{display:block}.stat{color:#555}</style></head><body>",
"<p>Слева рендер страницы, в центре кадр Figma, справа тепловая карта диффа: жёлтое и красное — пиксели с разницей выше порога после блюра 1px. Сетка 8px и onion-skin — сверху.</p>",
"<div class='tools'><label><input type='checkbox' id='grid'> сетка 8px</label><label>onion-skin: Figma поверх рендера <input type='range' id='onion' min='0' max='100' value='0'> <span id='onionv'>0%</span></label></div>"]
for name, w, h, ref in rows:
    s = stats[name]
    html.append(f"<h2>{name} {w}×{h} <span class='stat'>· расхождение {s['hot_pct']}% пикселей, средняя разница {s['mean_diff']}/255</span></h2><div class='row'>"
        f"<div class='col'><span>рендер</span><div class='stack'><iframe src='{url}' width='{w}' height='{h}'></iframe><img class='onion' src='{ref}' width='{w}' height='{h}'><div class='grid'></div></div></div>"
        f"<div class='col'><span>Figma</span><img src='{ref}' width='{w}'></div>"
        f"<div class='col'><span>тепловая карта</span><img src='heat/{name}.png' width='{w}'></div></div>")
html.append("<script>document.getElementById('grid').onchange=e=>document.body.classList.toggle('grid-on',e.target.checked);"
  "const r=document.getElementById('onion');r.oninput=()=>{document.querySelectorAll('.onion').forEach(i=>i.style.opacity=r.value/100);document.getElementById('onionv').textContent=r.value+'%'};</script></body></html>")
open(f"{out}/compare.html", "w").write("\n".join(html))
print("страница:", f"{out}/compare.html")
PY
