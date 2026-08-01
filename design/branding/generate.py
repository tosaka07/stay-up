#!/usr/bin/env python3
"""StayUp Identity 5b (Stream Behind) からブランド素材を書き出す。

デザイン上の座標は 64x64 の viewBox。マスクや rotate 変換は
Icon Composer / Xcode の SVG サブセットで落ちる可能性があるので、
すべて塗りのパス（直線＋円弧）に展開して出力する。

PNG はここで作った SVG から別途書き出したもの（README 参照）。
"""
import math, os, textwrap

OUT = os.path.abspath(os.path.dirname(__file__))  # 素材をその場で上書きする

# ---------------------------------------------------------------- color

def oklch_to_hex(L, C, h_deg):
    h = math.radians(h_deg)
    a, b = C * math.cos(h), C * math.sin(h)
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_**3, m_**3, s_**3
    r = +4.0767416621*l - 3.3077115913*m + 0.2309699292*s
    g = -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
    bb = -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
    def enc(u):
        u = 1.055 * (u ** (1/2.4)) - 0.055 if u > 0.0031308 else 12.92 * u
        return max(0, min(255, round(u * 255)))
    return "#%02X%02X%02X" % (enc(r), enc(g), enc(bb))

BG_TOP = oklch_to_hex(0.58, 0.16, 285)   # linear-gradient 150deg の始点
BG_BOTTOM = oklch_to_hex(0.30, 0.11, 268)
MARK_INK = oklch_to_hex(0.42, 0.14, 288)  # ライトのロックアップのマーク
TEXT_INK = oklch_to_hex(0.22, 0.01, 285)
TEXT_PAPER = oklch_to_hex(0.97, 0.002, 250)

# ---------------------------------------------------------------- geometry helpers

def fmt(v):
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s

def pt(p):
    return f"{fmt(p[0])} {fmt(p[1])}"

def circle_circle(c1, r1, c2, r2):
    """2円の交点。戻り値は (P, Q)。"""
    dx, dy = c2[0]-c1[0], c2[1]-c1[1]
    d = math.hypot(dx, dy)
    a = (d*d + r1*r1 - r2*r2) / (2*d)
    h = math.sqrt(r1*r1 - a*a)
    ux, uy = dx/d, dy/d
    px, py = -uy, ux
    base = (c1[0] + a*ux, c1[1] + a*uy)
    return ((base[0] + h*px, base[1] + h*py), (base[0] - h*px, base[1] - h*py))

def ang(c, p):
    return math.atan2(p[1]-c[1], p[0]-c[0])

def on_circle(c, r, a):
    return (c[0] + r*math.cos(a), c[1] + r*math.sin(a))

def arc_flags(c, r, pa, pb, keep):
    """pa->pb を結ぶ 2 つの弧のうち keep(midpoint)==True のものの (large, sweep)。"""
    a0, a1 = ang(c, pa), ang(c, pb)
    for sweep in (1, 0):
        delta = (a1 - a0) % (2*math.pi) if sweep else -((a0 - a1) % (2*math.pi))
        mid = on_circle(c, r, a0 + delta/2)
        if keep(mid):
            return (1 if abs(delta) > math.pi else 0), sweep
    raise RuntimeError("弧を判定できなかった")

def inside(c, r):
    return lambda p: math.hypot(p[0]-c[0], p[1]-c[1]) < r

def outside(c, r):
    f = inside(c, r)
    return lambda p: not f(p)

def crescent_path(c1, r1, c2, r2):
    """(c1,r1) から (c2,r2) を引いた三日月を 2 円弧のパスで返す。"""
    pa, pb = circle_circle(c1, r1, c2, r2)
    l1, s1 = arc_flags(c1, r1, pa, pb, outside(c2, r2))
    l2, s2 = arc_flags(c2, r2, pb, pa, inside(c1, r1))
    return (f"M{pt(pa)}A{fmt(r1)} {fmt(r1)} 0 {l1} {s1} {pt(pb)}"
            f"A{fmt(r2)} {fmt(r2)} 0 {l2} {s2} {pt(pa)}Z")

def rot(p, center, deg):
    a = math.radians(deg)
    dx, dy = p[0]-center[0], p[1]-center[1]
    return (center[0] + dx*math.cos(a) - dy*math.sin(a),
            center[1] + dx*math.sin(a) + dy*math.cos(a))

def capsule_from_rect(x, y, w, h, deg, center):
    """rx=h/2 の角丸矩形を回転させたカプセルを塗りパスで返す。"""
    r = h/2
    a = rot((x + r, y + r), center, deg)
    b = rot((x + w - r, y + r), center, deg)
    ux, uy = (b[0]-a[0]), (b[1]-a[1])
    ln = math.hypot(ux, uy); ux, uy = ux/ln, uy/ln
    px, py = -uy, ux          # 左手側の法線
    off = (r*px, r*py)
    a1 = (a[0]+off[0], a[1]+off[1]); a2 = (a[0]-off[0], a[1]-off[1])
    b1 = (b[0]+off[0], b[1]+off[1]); b2 = (b[0]-off[0], b[1]-off[1])
    # 端キャップは軸から外側へ回る半円。b1->b2 と a2->a1 は同じ回転方向になる。
    _, sweep = arc_flags(b, r, b1, b2, outside(a, ln))
    return (f"M{pt(a1)}L{pt(b1)}A{fmt(r)} {fmt(r)} 0 0 {sweep} {pt(b2)}"
            f"L{pt(a2)}A{fmt(r)} {fmt(r)} 0 0 {sweep} {pt(a1)}Z")

def line_circle(p0, u, c, r, which):
    """点 p0・方向 u の直線と円の交点。which=0 が軸方向で手前側（左下側）。"""
    fx, fy = p0[0]-c[0], p0[1]-c[1]
    b = fx*u[0] + fy*u[1]
    disc = b*b - (fx*fx + fy*fy - r*r)
    if disc < 0:
        raise RuntimeError("直線が円と交わらない")
    sq = math.sqrt(disc)
    t = (-b - sq, -b + sq)[which]
    return (p0[0] + t*u[0], p0[1] + t*u[1])

# ---------------------------------------------------------------- 5b の素の座標（64x64）

C = (32.0, 32.0)
SLASH_DEG = -40.0

# アプリアイコン（大サイズ・合成 c5b と同じ）
ICON_MOON = dict(c1=C, r1=22.0, c2=(46.0, 19.0), r2=19.5)
ICON_SLASH = (4.0, 28.5, 56.0, 7.0)                   # x, y, w, h（rx=h/2）
ICON_BANDS = [(2.0, 8.7, 37.6, 7.0),
              (24.4, 28.5, 37.6, 7.0),
              (10.4, 48.3, 37.6, 7.0)]
OP_BANDS, OP_MOON, OP_SLASH = 0.26, 0.68, 0.50

# ロゴマーク / メニューバー active
MARK_MOON = dict(c1=C, r1=21.5, c2=(44.0, 21.0), r2=17.0)
MARK_SLASH = (4.0, 28.5, 56.0, 7.0)
MB_SLASH = (5.0, 29.5, 54.0, 5.0)                     # 描く斜線（細い）
MB_GAP = (2.0, 27.5, 60.0, 9.0)                       # 抜く帯（太い）
MB_IDLE_MOON = dict(c1=C, r1=22.0, c2=(46.0, 19.0), r2=19.0)

# ---------------------------------------------------------------- 変換（64 -> 1024 キャンバス）

# デザインのタイルは 108px、内容は inset 17px。→ 内容は一辺の 74/108
CONTENT = 1024 * 74 / 108
SCALE = CONTENT / 64
MARGIN = (1024 - CONTENT) / 2

def to1024(p):
    return (MARGIN + p[0]*SCALE, MARGIN + p[1]*SCALE)

def scaled_crescent(spec):
    return crescent_path(to1024(spec["c1"]), spec["r1"]*SCALE,
                         to1024(spec["c2"]), spec["r2"]*SCALE)

def scaled_capsule(rect):
    x, y, w, h = rect
    p = to1024((x, y))
    return capsule_from_rect(p[0], p[1], w*SCALE, h*SCALE, SLASH_DEG, to1024(C))

# ---------------------------------------------------------------- 出力

def write(path, body):
    full = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(body if body.endswith("\n") else body + "\n")
    print("wrote", path)

def svg(w, h, inner, extra=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}"{extra}>\n{textwrap.indent(inner, "  ")}\n</svg>')

# 背景（CSS の linear-gradient(150deg, ...) を userSpaceOnUse に落とす）
def gradient_line(size, deg):
    a = math.radians(deg)
    dx, dy = math.sin(a), -math.cos(a)
    length = abs(size*math.sin(a)) + abs(size*math.cos(a))
    c = size/2
    return ((c - dx*length/2, c - dy*length/2), (c + dx*length/2, c + dy*length/2))

g0, g1 = gradient_line(1024, 150)
write("app-icon/background.svg", svg(1024, 1024, f'''<defs>
  <linearGradient id="stayup-bg" gradientUnits="userSpaceOnUse"
    x1="{fmt(g0[0])}" y1="{fmt(g0[1])}" x2="{fmt(g1[0])}" y2="{fmt(g1[1])}">
    <stop offset="0" stop-color="{BG_TOP}"/>
    <stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
</defs>
<rect width="1024" height="1024" fill="url(#stayup-bg)"/>'''))

# 帯は水平（回転なし）
def scaled_hband(rect):
    x, y, w, h = rect
    p = to1024((x, y))
    return capsule_from_rect(p[0], p[1], w*SCALE, h*SCALE, 0.0, to1024(C))

# レイヤーは不透明の白一色で書き出す。色と不透明度は Icon Composer 側で与える。
# デザイン上の不透明度（OP_*）は preview-composite にだけ焼く。
bands = "\n".join(f'<path d="{scaled_hband(b)}"/>' for b in ICON_BANDS)
write("app-icon/layer-1-bands.svg",
      svg(1024, 1024, '<g fill="#FFFFFF">\n' + textwrap.indent(bands, "  ") + "\n</g>"))
write("app-icon/layer-2-moon.svg",
      svg(1024, 1024, f'<path fill="#FFFFFF" d="{scaled_crescent(ICON_MOON)}"/>'))
write("app-icon/layer-3-slash.svg",
      svg(1024, 1024, f'<path fill="#FFFFFF" d="{scaled_capsule(ICON_SLASH)}"/>'))

write("app-icon/preview-composite.svg", svg(1024, 1024, f'''<defs>
  <linearGradient id="stayup-bg" gradientUnits="userSpaceOnUse"
    x1="{fmt(g0[0])}" y1="{fmt(g0[1])}" x2="{fmt(g1[0])}" y2="{fmt(g1[1])}">
    <stop offset="0" stop-color="{BG_TOP}"/>
    <stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
  <clipPath id="stayup-squircle">
    <rect width="1024" height="1024" rx="230" ry="230"/>
  </clipPath>
</defs>
<g clip-path="url(#stayup-squircle)">
  <rect width="1024" height="1024" fill="url(#stayup-bg)"/>
  <g fill="#FFFFFF" fill-opacity="{OP_BANDS}">
{textwrap.indent(bands, "    ")}
  </g>
  <path fill="#FFFFFF" fill-opacity="{OP_MOON}" d="{scaled_crescent(ICON_MOON)}"/>
  <path fill="#FFFFFF" fill-opacity="{OP_SLASH}" d="{scaled_capsule(ICON_SLASH)}"/>
</g>'''))

# ---------------------------------------------------------------- メニューバー

def mb_active_pieces():
    """三日月を「抜く帯」で 2 片に割ったパス群（64x64 座標）。"""
    c1, r1 = MARK_MOON["c1"], MARK_MOON["r1"]
    c2, r2 = MARK_MOON["c2"], MARK_MOON["r2"]
    horns = circle_circle(c1, r1, c2, r2)

    a = math.radians(SLASH_DEG)
    u = (math.cos(a), math.sin(a))            # 帯の軸方向
    p = (-u[1], u[0])                         # 法線（左手側）
    half = MB_GAP[3] / 2
    lower = (C[0] + half*p[0], C[1] + half*p[1])   # 法線 +側の縁を通る点
    upper = (C[0] - half*p[0], C[1] - half*p[1])

    # 帯が三日月を横切るのは左下側だけなので、どちらの円も手前側の交点を採る。
    pieces = []
    for edge, keep_side in ((lower, +1), (upper, -1)):
        q_big = line_circle(edge, u, c1, r1, 0)
        q_cut = line_circle(edge, u, c2, r2, 0)
        # この片に属するホーン = 帯から keep_side 側にあるもの
        horn = next(h for h in horns
                    if ((h[0]-C[0])*p[0] + (h[1]-C[1])*p[1]) * keep_side > half)
        # 片は帯の片側だけにあるので、弧の判定には「帯のどちら側か」も足す。
        # これがないと、ホーンを跨いだ反対側の弧が選ばれてしまう。
        def band_side(q, keep_side=keep_side):
            return ((q[0]-C[0])*p[0] + (q[1]-C[1])*p[1]) * keep_side > 0
        out_cut, in_big = outside(c2, r2), inside(c1, r1)
        l1, s1 = arc_flags(c1, r1, q_big, horn,
                           lambda q: out_cut(q) and band_side(q))
        l2, s2 = arc_flags(c2, r2, horn, q_cut,
                           lambda q: in_big(q) and band_side(q))
        pieces.append(f"M{pt(q_big)}A{fmt(r1)} {fmt(r1)} 0 {l1} {s1} {pt(horn)}"
                      f"A{fmt(r2)} {fmt(r2)} 0 {l2} {s2} {pt(q_cut)}L{pt(q_big)}Z")
    return pieces

def cap64(rect):
    x, y, w, h = rect
    return capsule_from_rect(x, y, w, h, SLASH_DEG, C)

mb_paths = mb_active_pieces() + [cap64(MB_SLASH)]
write("menu-bar/menubar-active.svg",
      svg(64, 64, '<g fill="#000000">\n'
          + textwrap.indent("\n".join(f'<path d="{d}"/>' for d in mb_paths), "  ")
          + "\n</g>"))
write("menu-bar/menubar-idle.svg",
      svg(64, 64, f'<path fill="#000000" d="{crescent_path(**{"c1": MB_IDLE_MOON["c1"], "r1": MB_IDLE_MOON["r1"], "c2": MB_IDLE_MOON["c2"], "r2": MB_IDLE_MOON["r2"]})}"/>'))

# ---------------------------------------------------------------- ロゴ

mark_moon = crescent_path(MARK_MOON["c1"], MARK_MOON["r1"], MARK_MOON["c2"], MARK_MOON["r2"])
mark_slash = cap64(MARK_SLASH)

write("logo/mark.svg", svg(64, 64, f'''<path fill="currentColor" d="{mark_moon}"/>
<path fill="currentColor" fill-opacity="0.62" d="{mark_slash}"/>''',
      extra=' fill="none"'))

def lockup(mark_fill, mark_op, slash_op, text_fill):
    return svg(196, 40, f'''<g transform="translate(3 3) scale(0.53125)">
  <path fill="{mark_fill}" fill-opacity="{mark_op}" d="{mark_moon}"/>
  <path fill="{mark_fill}" fill-opacity="{slash_op}" d="{mark_slash}"/>
</g>
<text x="49" y="20" fill="{text_fill}" dominant-baseline="central"
  font-family="Helvetica Neue, Helvetica, sans-serif" font-size="24" font-weight="600"
  letter-spacing="-0.672">StayUp</text>''')

write("logo/lockup-light.svg", lockup(MARK_INK, "1", "0.62", TEXT_INK))
write("logo/lockup-dark.svg", lockup("#FFFFFF", "0.82", "0.6", TEXT_PAPER))

print("\ncolors:", BG_TOP, BG_BOTTOM, MARK_INK, TEXT_INK, TEXT_PAPER)
