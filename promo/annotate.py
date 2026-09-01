#!/usr/bin/env python3
"""Annotate the claudepad Launchpad photo with an in-image legend."""
from PIL import Image, ImageDraw, ImageFont

SRC = '/root/.claude/uploads/10180bed-b00d-5597-bffd-46e6469c76d7/68840d46-image.jpg'
OUT = 'claudepad_annotated.jpg'

im = Image.open(SRC).convert('RGB')
W, H = im.size          # 5712 x 4284
S = W / 1400.0          # all layout coords below are in 1400-wide space

overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(overlay)

FB = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
FR = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
def font(path, size): return ImageFont.truetype(path, int(size * S))

# palette
CHIP_BG   = (14, 16, 22, 216)
TXT       = (245, 246, 248, 255)
TXT_DIM   = (176, 182, 192, 255)
ACCENT    = (247, 158, 96, 255)     # warm orange for branding
LINE      = (32, 35, 43, 255)
GREEN     = (52, 235, 140, 255)
ORANGE    = (255, 150, 66, 255)
YELLOW    = (247, 226, 92, 255)
BLUE      = (46, 158, 250, 255)
RED       = (245, 90, 84, 255)

def rrect(x0, y0, x1, y1, r, fill):
    d.rounded_rectangle([x0*S, y0*S, x1*S, y1*S], radius=r*S, fill=fill)

def text(x, y, s, f, fill):
    d.text((x*S, y*S), s, font=f, fill=fill)

def tw(s, f):
    b = d.textbbox((0, 0), s, font=f)
    return (b[2] - b[0]) / S

def dot(x, y, r, color):
    d.ellipse([(x-r)*S, (y-r)*S, (x+r)*S, (y+r)*S], fill=color)

def ring(x, y, r=9, color=LINE, wd=3.2):
    d.ellipse([(x-r)*S, (y-r)*S, (x+r)*S, (y+r)*S], outline=color, width=int(wd*S))

def line(p0, p1, color=LINE, wd=2.6):
    d.line([p0[0]*S, p0[1]*S, p1[0]*S, p1[1]*S], fill=color, width=int(wd*S))

# ---------------------------------------------------------------- chips
# a chip = rounded panel with rows; each row = list of segments
# segment = ('t', string, font, fill) or ('d', radius, color)
PAD_X, GAP_SEG, GAP_ROW = 16, 7, 8

def chip(x, y, rows, radius=12):
    widths, heights = [], []
    for row in rows:
        w_, h_ = 0, 0
        for seg in row:
            if seg[0] == 't':
                _, s, f, _ = seg
                b = d.textbbox((0, 0), s, font=f)
                w_ += (b[2]-b[0])/S + GAP_SEG
                h_ = max(h_, (b[3])/S + 4)
            else:
                _, r, _ = seg
                w_ += 2*r + GAP_SEG
                h_ = max(h_, 2*r)
        widths.append(w_ - GAP_SEG); heights.append(h_)
    cw = max(widths) + 2*PAD_X
    ch = sum(heights) + GAP_ROW*(len(rows)-1) + 2*PAD_X*0.75
    rrect(x, y, x+cw, y+ch, radius, CHIP_BG)
    cy = y + PAD_X*0.75
    for row, rh in zip(rows, heights):
        cx = x + PAD_X
        for seg in row:
            if seg[0] == 't':
                _, s, f, fill = seg
                b = d.textbbox((0, 0), s, font=f)
                text(cx, cy + (rh - b[3]/S)/2 - 1, s, f, fill)
                cx += (b[2]-b[0])/S + GAP_SEG
            else:
                _, r, color = seg
                dot(cx + r, cy + rh/2, r, color)
                cx += 2*r + GAP_SEG
        cy += rh + GAP_ROW
    return (x, y, x+cw, y+ch)

def connect(rect, target, r=9):
    """leader line from nearest chip edge point to a ring at target"""
    x0, y0, x1, y1 = rect
    tx, ty = target
    ax = min(max(tx, x0+14), x1-14)
    ay = min(max(ty, y0+10), y1-10)
    if ty < y0:   ay = y0
    elif ty > y1: ay = y1
    elif tx < x0: ax = x0
    else:         ax = x1
    # shorten the line so it stops at the ring edge
    dx, dy = tx-ax, ty-ay
    L = max((dx*dx+dy*dy) ** .5, 1e-6)
    ex, ey = tx - dx/L*(r+3), ty - dy/L*(r+3)
    line((ax, ay), (ex, ey))
    ring(tx, ty, r)

f_title = font(FB, 46)
f_bold  = font(FB, 21)
f_sub   = font(FR, 17.5)
f_tag   = font(FR, 21)
f_small = font(FR, 16.5)

# ---------------------------------------------------------------- title panel
tp = chip(38, 36, [
    [('t', 'claudepad', f_title, TXT)],
    [('t', 'a Launchpad as a physical dashboard', f_tag, TXT_DIM)],
    [('t', 'for parallel Claude Code sessions', f_tag, TXT_DIM)],
    [('t', 'Swift + CoreMIDI + Claude Code hooks · zero dependencies', f_small, TXT_DIM)],
    [('t', 'github.com/katspaugh/claudepad', f_bold, ACCENT)],
], radius=16)

# ---------------------------------------------------------------- sessions chip
ca = chip(120, 362, [
    [('t', 'one column = one Claude session', f_bold, TXT)],
    [('d', 7, GREEN), ('t', 'idle', f_sub, TXT_DIM),
     ('d', 7, ORANGE), ('t', 'working', f_sub, TXT_DIM),
     ('d', 7, YELLOW), ('t', 'needs input', f_sub, TXT_DIM)],
    [('t', 'press a pad = focus that terminal', f_sub, TXT_DIM)],
])
connect(ca, (252, 579))
connect(ca, (420, 568))
connect(ca, (540, 558))

# ---------------------------------------------------------------- subagents chip
cc = chip(568, 592, [
    [('t', 'subagents', f_bold, TXT)],
    [('d', 7, BLUE), ('t', 'one pad per running agent', f_sub, TXT_DIM)],
])
connect(cc, (472, 597))
connect(cc, (315, 661))

# ---------------------------------------------------------------- CI chip
cd = chip(648, 692, [
    [('t', 'PR CI status', f_bold, TXT)],
    [('d', 7, GREEN), ('t', 'pass', f_sub, TXT_DIM),
     ('d', 7, RED), ('t', 'fail', f_sub, TXT_DIM),
     ('d', 7, BLUE), ('t', 'running', f_sub, TXT_DIM)],
    [('t', 'press = open the PR', f_sub, TXT_DIM)],
])
connect(cd, (585, 722))

# ---------------------------------------------------------------- effort chip
ce = chip(668, 806, [
    [('t', 'effort level', f_bold, TXT)],
    [('t', 'tap to bump: low → max', f_sub, TXT_DIM)],
])
connect(ce, (598, 776))

# ---------------------------------------------------------------- preset chip
cf = chip(620, 892, [
    [('t', 'model preset', f_bold, TXT)],
    [('t', 'tap to cycle — types /model into the session', f_sub, TXT_DIM)],
])
connect(cf, (606, 845))

im = Image.alpha_composite(im.convert('RGBA'), overlay).convert('RGB')
im = im.resize((2400, int(H/W*2400)), Image.LANCZOS)
im.save(OUT, quality=93)
print('saved', OUT, im.size)
