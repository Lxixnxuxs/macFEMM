#!/usr/bin/env python3
"""Test the hypothesis that our axi Bx,By from femm_result_point_values
are off by a factor -(2π·r_meters) relative to Windows FEMM.

Reads report_macos.txt and report_windows.txt and, for each point probe
off-axis (r>0), prints:
  r (in)   win_By       scaled = -mac_By / (2π·r_m)    rel error
  r (in)   win_Bx       scaled = -mac_Bx / (2π·r_m)    rel error

If the hypothesis is correct, rel error should be <1% for all r>0.
On-axis points (r=0) are listed separately — the bug there is masked
because gradient-of-stored-quantity happens to vanish linearly with r.
"""
import sys, re, math

def parse(p):
    out={}
    for ln in open(p):
        ln=ln.strip()
        if not ln or ln.startswith("#"): continue
        parts = ln.rsplit(None, 1)
        if len(parts)!=2: continue
        k, v = parts
        try: out[k] = float(v)
        except ValueError: pass
    return out

mac = parse(sys.argv[1])
win = parse(sys.argv[2])

# Discover probe coords from keys like point/By/x,y
coords = set()
for k in mac:
    m = re.match(r'point/By/([^,]+),([^,]+)$', k)
    if m:
        coords.add((float(m.group(1)), float(m.group(2))))

LCONV_IN = 0.0254  # inches → meters

rows=[]
for (x,y) in sorted(coords):
    r_m = abs(x) * LCONV_IN
    mb_by  = mac.get(f"point/By/{x:g},{y:g}")
    wb_by  = win.get(f"point/By/{x:g},{y:g}")
    mb_bx  = mac.get(f"point/Bx/{x:g},{y:g}")
    wb_bx  = win.get(f"point/Bx/{x:g},{y:g}")
    if None in (mb_by, wb_by, mb_bx, wb_bx): continue
    if r_m > 0:
        scaled_by = -mb_by / (2*math.pi*r_m)
        scaled_bx = -mb_bx / (2*math.pi*r_m)
        err_by = abs(scaled_by - wb_by) / max(abs(scaled_by), abs(wb_by), 1e-30)
        err_bx = abs(scaled_bx - wb_bx) / max(abs(scaled_bx), abs(wb_bx), 1e-30)
        rows.append((x, y, wb_by, scaled_by, err_by, wb_bx, scaled_bx, err_bx))
    else:
        rows.append((x, y, wb_by, None, None, wb_bx, None, None))

print(f"{'x':>6} {'y':>6}  {'win_By':>12} {'scaled_mac':>14} {'err':>8}   {'win_Bx':>12} {'scaled_mac':>14} {'err':>8}")
for x,y,wy,sy,ey,wx,sx,ex in rows:
    if sy is None:
        print(f"{x:6.2f} {y:6.2f}  {wy:+.4e}    (r=0, skip)                 {wx:+.4e}    (r=0, skip)")
    else:
        print(f"{x:6.2f} {y:6.2f}  {wy:+.4e} {sy:+.4e} {ey*100:6.2f}%    {wx:+.4e} {sx:+.4e} {ex*100:6.2f}%")
