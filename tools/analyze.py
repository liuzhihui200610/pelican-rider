import sys
from PIL import Image
import numpy as np

def classify(r, g, b):
    # returns a short tag + display char
    mx, mn = max(r, g, b), min(r, g, b)
    if mx - mn < 18:  # near-grey/white -> could be haze/road/sand/cloud
        if b > 200 and r > 200 and g > 200:
            return 'W'   # white/haze
        if mx < 70:
            return '.'   # dark
        if r > g and r > b:
            return 'S'   # sand-ish grey-tan (fallback)
        return 'L'       # light grey
    # colorful
    if b >= r and b >= g and b > 120:
        return 'B'       # sky/sea blue
    if g >= r and g >= b and g > 90:
        return 'G'       # vegetation green
    if r > g and r > b and r > 120:
        # tan/brown/red/orange
        if b < 90 and g < 140:
            return 'T'   # brown/tan (sand/ground)
        return 'R'       # red/orange accent
    return '?'           # other

def analyze(path, cols=40, rows=20):
    im = Image.open(path).convert('RGB')
    W, H = im.size
    arr = np.asarray(im).astype(np.float32)
    mean = arr.reshape(-1, 3).mean(0)
    std = arr.reshape(-1, 3).std(0).mean()
    # downsample grid
    sx, sy = W / cols, H / rows
    grid = []
    sky = 0; total = 0
    for ry in range(rows):
        row = []
        for rx in range(cols):
            x0, x1 = int(rx*sx), int((rx+1)*sx)
            y0, y1 = int(ry*sy), int((ry+1)*sy)
            cell = arr[y0:y1, x0:x1].reshape(-1, 3).mean(0)
            tag = classify(*cell)
            row.append(tag)
            total += 1
            if tag in ('B',):  # count blue as sky-ish
                sky += 1
        grid.append(row)
    # horizon: first row (top->down) where blue fraction drops below 0.4
    horizon = None
    for ry in range(rows):
        row = grid[ry]
        bluefrac = sum(1 for c in row if c in ('B',)) / cols
        if bluefrac < 0.4:
            horizon = ry / rows
            break
    # build text
    sym = {'B':'░','G':'▓','T':'▒','S':'░','W':' ','L':'░','R':'#','.':'.','?':'.'}
    lines = []
    for row in grid:
        lines.append(''.join(sym.get(c, '.') for c in row))
    print('='*70)
    print(f'FILE: {path.split("/")[-1]}  size={W}x{H}')
    print(f'mean RGB = ({mean[0]:.0f},{mean[1]:.0f},{mean[2]:.0f})  global std={std:.0f}')
    print(f'sky/blue fraction = {sky/total:.2f}  horizon(at ~{horizon:.2f} from top if found)')
    print('grid (B=sky/sea G=green T=tan R=red # W=white . =dark):')
    for ln in lines:
        print('  ' + ln)
    # crude color map per cell using letters too
    print('labels:')
    for ln in grid:
        print('  ' + ''.join(ln))
    print()

for p in sys.argv[1:]:
    analyze(p)
