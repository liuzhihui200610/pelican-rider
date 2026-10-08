"""
程序化生成游戏资产：有机曲面模型(OBJ) + 贴图(PNG) + 音效(WAV)
不依赖 Blender / 任何第三方库，纯 Python 标准库。
坐标约定：Y 轴向上，角色前进方向 = -Z，地面 y=0。
"""
import math, os, struct, zlib, wave, random

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets")
os.makedirs(OUT, exist_ok=True)
random.seed(7)

# ---------------------------------------------------------------- 向量工具
def sub(a, b): return (a[0]-b[0], a[1]-b[1], a[2]-b[2])
def add(a, b): return (a[0]+b[0], a[1]+b[1], a[2]+b[2])
def mul(a, s): return (a[0]*s, a[1]*s, a[2]*s)
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a, b): return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]
def norm(a):
    l = math.sqrt(dot(a, a)) or 1e-9
    return (a[0]/l, a[1]/l, a[2]/l)

# ---------------------------------------------------------------- 参数曲面（数值法线）
def param_surface(F, nu=40, nv=26, eps=1e-3):
    verts, uvs = [], []
    for i in range(nu + 1):
        u = i / nu
        for j in range(nv + 1):
            v = j / nv
            verts.append(F(u, v))
            uvs.append((u, v))
    tris = []
    for i in range(nu):
        for j in range(nv):
            a = i * (nv + 1) + j
            b = (i + 1) * (nv + 1) + j
            c = (i + 1) * (nv + 1) + j + 1
            d = i * (nv + 1) + j + 1
            tris.append((a, b, c))
            tris.append((a, c, d))
    normals = []
    for i in range(nu + 1):
        u = i / nu
        for j in range(nv + 1):
            v = j / nv
            uu0, uu1 = max(u - eps, 0.0), min(u + eps, 1.0)
            vv0, vv1 = max(v - eps, 0.0), min(v + eps, 1.0)
            du = sub(F(uu1, v), F(uu0, v))
            dv = sub(F(u, vv1), F(u, vv0))
            n = cross(du, dv)
            if dot(n, n) < 1e-12:
                p = F(u, v)
                n = norm(p)
            normals.append(norm(n))
    return verts, uvs, normals, tris

def ellipsoid(rx, ry, rz, center=(0, 0, 0), taper=0.0, squashy=1.0):
    def F(u, v):
        th = 2 * math.pi * u
        ph = math.pi * v
        s = math.sin(ph)
        x = rx * s * math.cos(th)
        z = rz * s * math.sin(th)
        y = ry * math.cos(ph) * squashy
        # 后端(+Z)收窄，形成蛋形/鸟身
        f = 1.0 - taper * (z / rz)
        return (center[0] + x * f, center[1] + y, center[2] + z)
    return param_surface(F, 30, 20)

def revolve(profile, center=(0, 0, 0), nu=30):
    """profile: [(radius, y), ...] 从下到上"""
    def sample(t):
        t = min(max(t, 0.0), 1.0)
        x = t * (len(profile) - 1)
        i = min(int(x), len(profile) - 2)
        f = x - i
        r0, y0 = profile[i]
        r1, y1 = profile[i + 1]
        return r0 + (r1 - r0) * f, y0 + (y1 - y0) * f
    def F(u, v):
        r, y = sample(v)
        th = 2 * math.pi * u
        return (center[0] + r * math.cos(th), center[1] + y, center[2] + r * math.sin(th))
    return param_surface(F, nu, max(len(profile) * 6, 16))

def tube(path, radius, nu=26, nv=10, radial_seg=None):
    """path: 点列表(>=2) 或函数 t->点；radius: float 或 函数 t->float"""
    P = path if callable(path) else (lambda t: sample_polyline(path, t))
    R = radius if callable(radius) else (lambda t: radius)
    def F(u, v):
        t = v
        p = P(t)
        t0, t1 = max(t - 1e-3, 0.0), min(t + 1e-3, 1.0)
        tan = norm(sub(P(t1), P(t0)))
        ref = (0.0, 1.0, 0.0) if abs(tan[1]) < 0.9 else (1.0, 0.0, 0.0)
        n1 = norm(cross(tan, ref))
        n2 = norm(cross(n1, tan))
        r = R(t)
        th = 2 * math.pi * u
        off = add(mul(n1, r * math.cos(th)), mul(n2, r * math.sin(th)))
        return add(p, off)
    return param_surface(F, nu, nv)

def sample_polyline(pts, t):
    t = min(max(t, 0.0), 1.0)
    x = t * (len(pts) - 1)
    i = min(int(x), len(pts) - 2)
    f = x - i
    a, b = pts[i], pts[i + 1]
    return tuple(a[k] + (b[k] - a[k]) * f for k in range(3))

def torus(R, r, center=(0, 0, 0), axis='z', nu=32, nv=14):
    def F(u, v):
        a = 2 * math.pi * u
        b = 2 * math.pi * v
        rr = R + r * math.cos(b)
        x, y = rr * math.cos(a), rr * math.sin(a)
        z = r * math.sin(b)
        if axis == 'z':
            # 圆环在 XY 平面，孔朝 Z
            return (center[0] + x, center[1] + y, center[2] + z)
        elif axis == 'y':
            # 圆环在 XZ 平面，孔朝 Y（平放）
            return (center[0] + x, center[1] + z, center[2] + y)
        else:
            # axis='x'：圆环在 YZ 平面，孔朝 X（立着的车轮！）
            return (center[0] + z, center[1] + x, center[2] + y)
    return param_surface(F, nu, nv)

def box(cx, cy, cz, sx, sy, sz):
    v = []
    for dx in (-sx / 2, sx / 2):
        for dy in (-sy / 2, sy / 2):
            for dz in (-sz / 2, sz / 2):
                v.append((cx + dx, cy + dy, cz + dz))
    idx = [(0,1,3),(0,3,2),(4,6,7),(4,7,5),(0,4,5),(0,5,1),
           (2,3,7),(2,7,6),(0,2,6),(0,6,4),(1,5,7),(1,7,3)]
    tris = [(v[a], v[b], v[c]) for a, b, c in idx]
    verts, uvs, normals, out = [], [], [], []
    for a, b, c in tris:
        n = norm(cross(sub(b, a), sub(c, a)))
        base = len(verts)
        for p in (a, b, c):
            verts.append(p); uvs.append((0.0, 0.0)); normals.append(n)
        out.append((base, base + 1, base + 2))
    return verts, uvs, normals, out

# ---------------------------------------------------------------- 合并 / 写出
def merge(meshes):
    verts, uvs, normals, tris = [], [], [], []
    for m in meshes:
        off = len(verts)
        verts += m[0]; uvs += m[1]; normals += m[2]
        for a, b, c in m[3]:
            tris.append((a + off, b + off, c + off))
    return verts, uvs, normals, tris

def write_obj(name, mesh):
    verts, uvs, normals, tris = mesh
    p = os.path.join(OUT, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write("# procedural asset\n")
        for v in verts: f.write("v %.5f %.5f %.5f\n" % v)
        for uv in uvs: f.write("vt %.5f %.5f\n" % uv)
        for n in normals: f.write("vn %.5f %.5f %.5f\n" % n)
        for a, b, c in tris:
            f.write("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (
                a+1, a+1, a+1, b+1, b+1, b+1, c+1, c+1, c+1))
    print("  obj:", name, len(verts), "verts")

# ================================================================ 角色：鹈鹕 + 自行车
FRONT, REAR = -1.0, 1.0          # 前进 = -Z
WH = 0.34                        # 轮半径
AXLE_F = (0.0, WH, FRONT * 0.58)
AXLE_R = (0.0, WH, REAR * 0.58)
BB = (0.0, 0.30, 0.02)           # 中轴
SEAT = (0.0, 0.90, 0.14)
HEAD_TUBE = (0.0, 0.92, FRONT * 0.40)

def feather(origin, direction, length, width, droop=0.0):
    """一根羽毛：从 origin 沿 direction 延伸，末端收尖"""
    d = norm(direction)
    def path(t):
        return (origin[0] + d[0] * length * t,
                origin[1] + d[1] * length * t - droop * t * t,
                origin[2] + d[2] * length * t)
    return tube(path, lambda t: width * (1 - t) ** 0.7 + 0.004, nu=10, nv=6)

def build_character():
    # --- 身体：饱满但不圆球，后端收窄 ---
    body = ellipsoid(0.32, 0.36, 0.42, center=(0.0, 1.16, 0.10), taper=0.26)
    write_obj("pelican_body.obj", body)

    # --- 头 + S 形颈（高度适中，不再像长颈龙）---
    head_shape = ellipsoid(0.15, 0.145, 0.16, center=(0.0, 1.74, FRONT * 0.12))
    def neck_path(t):
        y = 1.32 + 0.38 * t
        z = 0.12 + FRONT * 0.24 * t
        return (0.0, y, z)
    neck = tube(neck_path, lambda t: 0.125 - 0.04 * t, nu=20, nv=14)
    write_obj("pelican_head.obj", merge([head_shape, neck]))

    # --- 巨喙 + 下垂喉囊（鹈鹕标志）---
    def beak_path(t):
        z = FRONT * (0.24 + 0.72 * t)
        y = 1.70 - 0.08 * t
        return (0.0, y, z)
    beak = tube(beak_path, lambda t: 0.088 * (1 - t) ** 0.6 + 0.010, nu=24, nv=20)
    write_obj("pelican_beak.obj", beak)
    pouch = ellipsoid(0.17, 0.22, 0.28, center=(0.0, 1.46, FRONT * 0.38), squashy=1.35)
    write_obj("pelican_pouch.obj", pouch)

    # --- 贝雷帽（贴合头顶，不再浮空）---
    hat = ellipsoid(0.16, 0.055, 0.16, center=(0.02, 1.90, FRONT * 0.10))
    nub = ellipsoid(0.045, 0.03, 0.045, center=(0.02, 1.945, FRONT * 0.10))
    write_obj("pelican_hat.obj", merge([hat, nub]))

    # --- 红围巾（系在颈中部 + 两条飘带）---
    ring = torus(0.13, 0.045, center=(0.0, 1.58, FRONT * 0.02), axis='y', nu=24, nv=10)
    ribbons = []
    for sx in [-0.05, 0.06]:
        ribbons.append(feather((sx, 1.56, 0.08), (sx * 3.0, 0.10, 1.0), 0.44, 0.05, droop=0.10))
    write_obj("pelican_scarf.obj", merge([ring] + ribbons))

    write_obj("pelican_eye.obj", ellipsoid(0.042, 0.046, 0.042, center=(0, 0, 0)))

    # --- 翅膀：折叠贴在身侧、翼尖朝后下方（原来向前伸像两条胳膊）---
    wing_main = ellipsoid(0.06, 0.15, 0.30, center=(0.0, -0.05, 0.12), taper=0.30)
    write_obj("pelican_wing.obj", wing_main)
    tips = []
    for i in range(3):
        a = -0.22 + i * 0.22
        tips.append(feather((0.0, -0.08, 0.26), (0.0, -0.30 + a * 0.12, 1.0),
                            0.28 + i * 0.03, 0.038, droop=0.05))
    write_obj("pelican_wingtip.obj", merge(tips))

    # --- 尾羽 ---
    tails = []
    for i in range(3):
        a = -0.28 + i * 0.28
        tails.append(feather((0.0, 1.10, 0.42), (math.sin(a) * 0.4, 0.30, 1.0), 0.30, 0.05))
    write_obj("pelican_tail.obj", merge(tails))

    # --- 腿 + 蹼足 ---
    thigh = tube([(0.0, 0.0, 0.0), (0.02, -0.16, 0.03), (0.03, -0.32, 0.0)], 0.048, nu=16, nv=8)
    shin = tube([(0.03, -0.32, 0.0), (0.02, -0.48, -0.02), (0.0, -0.60, 0.02)], 0.036, nu=16, nv=8)
    foot = ellipsoid(0.08, 0.028, 0.14, center=(0.0, -0.628, 0.07))
    write_obj("pelican_leg.obj", merge([thigh, shin, foot]))

    # --- 路边草丛与碎石（让地面不再是一块光板）---
    blades = []
    for i in range(7):
        a = i * math.tau / 7
        blades.append(feather((math.sin(a) * 0.06, 0.0, math.cos(a) * 0.06),
                               (math.sin(a) * 0.55, 1.0, math.cos(a) * 0.55),
                               0.30 + (i % 3) * 0.08, 0.022, droop=0.06))
    write_obj("prop_tuft.obj", merge(blades))

    # --- 车轮：轴必须朝左右(X)，轮盘落在 YZ 平面才能"向前滚" ---
    #   （之前做成 axis='z' = 轮盘朝前后，等于把轮子装歪了 90°）
    tire = torus(WH - 0.032, 0.032, center=(0, 0, 0), axis='x', nu=40, nv=14)   # 细胎
    rim = torus(WH - 0.055, 0.012, center=(0, 0, 0), axis='x', nu=40, nv=10)    # 车圈
    hub = ellipsoid(0.045, 0.03, 0.03, center=(0, 0, 0))
    write_obj("bike_wheel.obj", merge([tire, rim, hub]))
    # 辐条：从花鼓连到车圈，位于 YZ 平面（与轮盘同面）
    spokes = []
    for i in range(12):
        a = i * math.tau / 12   # 必须整圈 2π：用 π 只会画出半边辐条
        spokes.append(tube(
            lambda t, a=a: (0.0, (WH - 0.07) * t * math.sin(a), (WH - 0.07) * t * math.cos(a)),
            0.006, nu=6, nv=4))
    write_obj("bike_spokes.obj", merge(spokes))
    # 白边：胎侧一圈细白环（不能再宽，否则轮子变白饼）
    write_obj("bike_whitewall.obj", torus(WH - 0.045, 0.013, center=(0, 0, 0), axis='x', nu=40, nv=8))
    # 车头灯（灯体 + 透镜）
    lamp_body = tube([(0.0, 0.0, 0.0), (0.0, 0.0, 0.09)], 0.052, nu=14, nv=4)
    lamp_lens = ellipsoid(0.055, 0.055, 0.03, center=(0.0, 0.0, 0.10))
    write_obj("bike_lamp.obj", merge([lamp_body, lamp_lens]))

    # --- 车架（管线 + 关节球；前叉单独导出为橙色件） ---
    segs = [
        (HEAD_TUBE, BB, 0.038),            # 下管
        (BB, SEAT, 0.036),                 # 座管
        (SEAT, HEAD_TUBE, 0.032),          # 上管
        (BB, AXLE_R, 0.028),               # 链条下叉
        (SEAT, AXLE_R, 0.024),             # 座位后叉
    ]
    parts = []
    for a, b, r in segs:
        parts.append(tube([a, (tuple((a[k]+b[k])/2 for k in range(3))), b], r, nu=16, nv=8))
        parts.append(ellipsoid(r*1.55, r*1.55, r*1.55, center=a))
    write_obj("bike_frame.obj", merge(parts))
    write_obj("bike_fork.obj", tube([HEAD_TUBE, AXLE_F], 0.030, nu=12, nv=6))
    # 牙盘与飞轮：薄盘要垂直于轴（X 方向薄）
    write_obj("bike_chainring.obj", ellipsoid(0.028, 0.15, 0.15, center=BB))
    write_obj("bike_cog.obj", ellipsoid(0.022, 0.07, 0.07, center=AXLE_R))
    # 链条（上下两股：牙盘 → 后飞轮）+ 后飞轮
    write_obj("bike_chain.obj", merge([
        tube([(0.0, BB[1] + 0.13, BB[2] + 0.02), (0.0, AXLE_R[1] + 0.06, AXLE_R[2])], 0.012, nu=10, nv=4),
        tube([(0.0, BB[1] - 0.13, BB[2] + 0.02), (0.0, AXLE_R[1] - 0.05, AXLE_R[2])], 0.012, nu=10, nv=4)]))

    # --- 车把 ---
    def bar_path(t):
        y = 0.98 + 0.05 * math.sin(math.pi * t)
        z = FRONT * (0.38 + 0.06 * t)
        if t < 0.5:
            x = -0.26 * (t / 0.5)
        else:
            x = -0.26 * (1 - (t - 0.5) / 0.5)
        return (x, y, z)
    handle = tube(bar_path, 0.026, nu=16, nv=26)
    stem = tube([HEAD_TUBE, (0.0, 0.98, FRONT * 0.38)], 0.030, nu=14, nv=6)
    write_obj("bike_handlebar.obj", merge([handle, stem]))

    # --- 座垫 ---
    write_obj("bike_seat.obj", ellipsoid(0.085, 0.032, 0.15, center=SEAT))

    # --- 曲柄 + 脚踏（原点 = 中轴，随踩踏旋转） ---
    arm = tube([(0.0, 0.0, 0.0), (0.10, -0.12, 0.0)], 0.022, nu=12, nv=6)
    pedal = box(0.13, -0.14, 0.0, 0.10, 0.022, 0.07)
    write_obj("bike_crank.obj", merge([arm, pedal]))

# ================================================================ 道具 / 场景
def build_props():
    # 路障锥（带底座）
    write_obj("prop_cone.obj", revolve([
        (0.0, 0.0), (0.30, 0.0), (0.28, 0.04), (0.16, 0.55), (0.03, 1.05), (0.0, 1.15),
    ]))
    # 油桶（带环箍）
    write_obj("prop_barrel.obj", revolve([
        (0.0, 0.0), (0.34, 0.02), (0.38, 0.12), (0.36, 0.30), (0.40, 0.42),
        (0.36, 0.60), (0.38, 0.80), (0.34, 0.94), (0.30, 1.05), (0.0, 1.05),
    ]))
    # 石头（低模棱面 + 噪声位移）
    rock = ellipsoid(0.30, 0.24, 0.28, center=(0, 0.24, 0))
    verts, uvs, normals, tris = rock
    nv2 = []
    for i, p in enumerate(verts):
        n1 = math.sin(p[0] * 9.0) * math.cos(p[2] * 8.0) * 0.05
        n2 = math.sin(p[1] * 7.0 + 1.3) * 0.04
        nv2.append((p[0] + n1, max(p[1] + n2, 0.01), p[2] + n1 * 0.7))
    # 平面着色（每个三角独立法线）
    V, U, N, T = [], [], [], []
    for a, b, c in tris:
        base = len(V)
        n = norm(cross(sub(nv2[b], nv2[a]), sub(nv2[c], nv2[a])))
        for k in (a, b, c):
            V.append(nv2[k]); U.append(uvs[k]); N.append(n)
        T.append((base, base + 1, base + 2))
    write_obj("prop_rock.obj", (V, U, N, T))

    # 小鱼（身体 + 尾鳍 + 背鳍）
    fb = ellipsoid(0.16, 0.13, 0.24, center=(0, 0, 0))
    ft = ellipsoid(0.02, 0.14, 0.13, center=(0, 0.0, 0.30))   # 尾鳍(+Z 后)
    ff = ellipsoid(0.015, 0.07, 0.10, center=(0, 0.13, 0.02)) # 背鳍
    write_obj("prop_fish.obj", merge([fb, ft, ff]))

    # 路边灌木（低矮圆润，双球叠加）
    b1 = ellipsoid(0.44, 0.34, 0.44, center=(0.0, 0.30, 0.0))
    b2 = ellipsoid(0.30, 0.26, 0.30, center=(0.34, 0.22, 0.18))
    b3 = ellipsoid(0.26, 0.22, 0.26, center=(-0.30, 0.24, -0.16))
    write_obj("prop_bush.obj", merge([b1, b2, b3]))

    # 路灯（锥形杆 + 弯臂 + 灯头）
    pole = tube([(0, 0, 0), (0, 1.8, 0), (0, 3.6, 0)], lambda t: 0.095 - 0.03 * t, nu=16, nv=8)
    arm_t = tube([(0, 3.6, 0), (0, 3.88, 0), (0.38, 4.02, 0)], 0.055, nu=12, nv=10)
    lamp_head = ellipsoid(0.17, 0.10, 0.36, center=(0.58, 3.96, 0.0))
    write_obj("prop_lamp.obj", merge([pole, arm_t, lamp_head]))

    # 护栏（3 根立柱 + 2 道横梁，一段 4m）
    posts = [box(i * 2.0, 0.55, 0.0, 0.11, 1.1, 0.11) for i in range(3)]
    beam_hi = tube([(0, 0.88, 0), (2.0, 0.88, 0), (4.0, 0.88, 0)], 0.05, nu=10, nv=8)
    beam_lo = tube([(0, 0.42, 0), (2.0, 0.42, 0), (4.0, 0.42, 0)], 0.045, nu=10, nv=8)
    write_obj("prop_guardrail.obj", merge(posts + [beam_hi, beam_lo]))

    # 车前篮（藤编小筐，参照图放在车把前）
    basket = revolve([(0.0, 0.0), (0.17, 0.0), (0.21, 0.14), (0.19, 0.17), (0.145, 0.17), (0.13, 0.03)])
    write_obj("bike_basket.obj", basket)
    # （白边轮胎圈已在 build_character 中生成，此处勿重复）

    # 棕榈树：弯干 + 垂坠棕榈叶（双色分开导出）
    def palm_path(t):
        return (0.5 * t * t, 3.4 * t, 0.1 * t)
    palm_trunk = tube(palm_path, lambda t: 0.17 - 0.06 * t, nu=14, nv=10)
    write_obj("palm_trunk.obj", palm_trunk)
    top = palm_path(1.0)
    fronds = []
    for i in range(7):
        a = i * math.tau / 7
        d = (math.sin(a) * 0.9, -0.28 - 0.05 * (i % 3), math.cos(a) * 0.9)
        fronds.append(feather(top, d, 1.7 + (i % 3) * 0.25, 0.10, droop=0.55))
    write_obj("palm_fronds.obj", merge(fronds))

    # 帆船（远景：船体 + 桅杆 + 三角帆）
    hull = ellipsoid(0.55, 0.22, 1.5, center=(0, 0.18, 0))
    mast = tube([(0, 0.3, 0), (0, 1.9, 0)], 0.045, nu=8, nv=4)
    sail = revolve([(0.0, 0.0), (0.0, 0.02), (0.85, 0.55), (0.0, 1.35)], center=(0, 0.42, 0), nu=3)
    write_obj("prop_boat.obj", merge([hull, mast, sail]))

    # 白色栏杆（海岸桥，8m 一段：8 柱 + 双横梁，对齐参考图）
    posts = [box(i * (8.0 / 7.0), 0.55, 0.0, 0.08, 1.0, 0.08) for i in range(8)]
    beam_hi = tube([(0, 0.86, 0), (8.0, 0.86, 0)], 0.045, nu=8, nv=6)
    beam_lo = tube([(0, 0.48, 0), (8.0, 0.48, 0)], 0.04, nu=8, nv=6)
    write_obj("rail_white.obj", merge(posts + [beam_hi, beam_lo]))

    # 灯塔（远景剪影）
    tower = revolve([(0.0, 0.0), (2.4, 0.0), (2.0, 0.12), (1.4, 4.0), (1.3, 4.3),
                     (1.45, 4.4), (1.45, 5.1), (0.85, 5.5), (0.0, 5.5)], nu=16)
    light_room = ellipsoid(0.55, 0.5, 0.55, center=(0, 5.8, 0))
    roof = revolve([(0.0, 0.0), (0.95, 0.0), (0.0, 0.8)], center=(0, 6.2, 0), nu=14)
    write_obj("prop_lighthouse.obj", merge([tower, light_room, roof]))

    # 车把前叉（橙色，单独导出便于双色）
    write_obj("bike_fork.obj", tube([HEAD_TUBE, AXLE_F], 0.030, nu=12, nv=6))
    # （牙盘/链条/飞轮已在 build_character 中生成，此处勿重复覆盖）

    # 海滨小木屋（屋身 + 双坡屋顶 + 门）
    hut_body = box(0, 1.1, 0, 2.4, 2.2, 2.0)
    hut_roof = revolve([(0.0, 0.0), (1.85, 0.85), (0.0, 0.85)], center=(0, 2.2, 0), nu=4)
    hut_door = box(0, 0.55, 1.01, 0.7, 1.1, 0.08)
    write_obj("prop_hut.obj", merge([hut_body, hut_roof, hut_door]))

    # 停在栏杆上的海鸥（身体 + 头 + 喙 + 尾）
    pb = ellipsoid(0.11, 0.09, 0.17, center=(0, 0.10, 0))
    ph = ellipsoid(0.065, 0.065, 0.07, center=(0, 0.20, FRONT * 0.10))
    pbeak = tube([(0, 0.20, FRONT * 0.15), (0, 0.19, FRONT * 0.28)], lambda t: 0.022 * (1 - t) + 0.004, nu=8, nv=6)
    ptail = feather((0, 0.11, 0.14), (0, 0.12, 1.0), 0.16, 0.045)
    write_obj("prop_bird_perched.obj", merge([pb, ph, pbeak, ptail]))

    # 轮胎堆（三层轮胎叠放）
    t1 = torus(0.30, 0.12, center=(0, 0.12, 0), axis='y', nu=24, nv=10)
    t2 = torus(0.30, 0.12, center=(0.03, 0.35, 0.02), axis='y', nu=24, nv=10)
    t3 = torus(0.28, 0.11, center=(0.05, 0.56, 0.03), axis='y', nu=24, nv=10)
    write_obj("prop_tires.obj", merge([t1, t2, t3]))

    # 水马（塑料注水护栏）
    wb = box(0, 0.36, 0, 1.30, 0.55, 0.42)
    wt = box(0, 0.74, 0, 1.30, 0.16, 0.48)
    wf = box(0, 0.06, 0, 1.42, 0.12, 0.56)
    write_obj("prop_barrier.obj", merge([wb, wt, wf]))

    # 交通牌（黄牌方牌 + 杆）
    sign_pole = tube([(0, 0, 0), (0, 2.3, 0)], 0.045, nu=10, nv=4)
    plate = box(0, 2.35, 0, 0.62, 0.62, 0.04)
    write_obj("prop_sign.obj", merge([sign_pole, plate]))

    # 沙滩遮阳伞（伞面 + 杆）
    canopy = revolve([(0.0, 0.30), (0.10, 0.26), (0.55, 0.10), (0.95, 0.0)], nu=20)
    upole = tube([(0, 0, 0), (0, 0.3, 0)], 0.03, nu=8, nv=3)
    write_obj("prop_umbrella.obj", merge([canopy, upole]))

    # 树（树干 + 三层锥形树冠，分开导出便于双色）
    trunk = tube([(0, 0, 0), (0, 0.9, 0), (0, 1.8, 0)], lambda t: 0.20 - 0.07 * t, nu=14, nv=6)
    c1 = revolve([(0.0, 0.0), (1.45, 0.55), (0.0, 2.10)], center=(0, 1.55, 0), nu=18)
    c2 = revolve([(0.0, 0.0), (1.05, 0.45), (0.0, 1.60)], center=(0, 2.30, 0), nu=18)
    c3 = revolve([(0.0, 0.0), (0.65, 0.35), (0.0, 1.10)], center=(0, 3.00, 0), nu=18)
    write_obj("tree_trunk.obj", trunk)
    write_obj("tree_leaves.obj", merge([c1, c2, c3]))

# ================================================================ 道路
def build_road():
    W, L = 9.0, 6000.0
    half = W / 2
    # 路面（UV 沿长度重复，供沥青贴图使用）
    verts = [(-half, 0.0, 200.0), (half, 0.0, 200.0), (half, 0.0, 200.0 - L), (-half, 0.0, 200.0 - L)]
    uvs = [(0.0, 0.0), (1.0, 0.0), (1.0, L / 9.0), (0.0, L / 9.0)]
    normals = [(0, 1, 0)] * 4
    tris = [(0, 1, 2), (0, 2, 3)]
    write_obj("road_surface.obj", (verts, uvs, normals, tris))

    # 中央虚线（合并成一个网格，产生真实速度感）
    dashes = []
    z = 100.0
    while z > 200.0 - L:
        dashes.append(box(0.0, 0.012, z, 0.16, 0.02, 3.2))
        z -= 9.0
    write_obj("road_dashes.obj", merge(dashes))
    # 两侧实线
    lines = []
    zz = 200.0
    while zz > 200.0 - L:
        lines.append(box(-half + 0.30, 0.012, zz, 0.14, 0.02, 60.0))
        lines.append(box(half - 0.30, 0.012, zz, 0.14, 0.02, 60.0))
        zz -= 60.0
    write_obj("road_lines.obj", merge(lines))

# ================================================================ 贴图（PNG，无第三方库）
def write_png(path, w, h, pixels):
    has_a = len(pixels[0]) == 4
    ct = 6 if has_a else 2
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw += bytes(pixels[y * w + x])
    comp = zlib.compress(bytes(raw), 9)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ct, 0, 0, 0))
    png += chunk(b"IDAT", comp)
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("  png:", os.path.basename(path), "%dx%d" % (w, h))

def value_noise(w, h, scale, seed=1):
    rnd = random.Random(seed)
    gw, gh = max(w // scale, 2), max(h // scale, 2)
    grid = [[rnd.random() for _ in range(gw + 1)] for _ in range(gh + 1)]
    out = []
    for y in range(h):
        fy = y / h * gh
        y0 = int(fy); ty = fy - y0
        for x in range(w):
            fx = x / w * gw
            x0 = int(fx); tx = fx - x0
            def sm(a, b, t):
                t = t * t * (3 - 2 * t)
                return a + (b - a) * t
            v = sm(sm(grid[y0][x0], grid[y0][x0 + 1], tx),
                   sm(grid[y0 + 1][x0], grid[y0 + 1][x0 + 1], tx), ty)
            out.append(v)
    return out

def fbm(w, h, scales, weights, seed):
    """多倍频叠加噪声"""
    out = [0.0] * (w * h)
    for s, wt in zip(scales, weights):
        n = value_noise(w, h, s, seed)
        for i in range(w * h):
            out[i] += n[i] * wt
    return out

def build_textures():
    # 卡通渐变 ramp（平滑过渡，柔光质感——对齐参考图的柔和光影）
    W, H = 128, 8
    px = []
    for y in range(H):
        for x in range(W):
            t = x / (W - 1)
            s = t * t * (3 - 2 * t)
            v = 0.30 + 0.70 * (0.35 * s + 0.65 * t)
            c = int(255 * v)
            px.append((c, c, c))
    write_png(os.path.join(OUT, "toon_ramp.png"), W, H, px)

    # 地面贴图（asphalt/grass/sand）已改用 AI 生成的高质量贴图，
    # 生成器只在文件缺失时才用程序化噪声兜底，避免覆盖 AI 贴图
    if not os.path.exists(os.path.join(OUT, "asphalt.png")):
        # 沥青路面（1024，三倍频颗粒 + 裂纹）
        W = H = 1024
        n = fbm(W, H, [6, 20, 64], [0.45, 0.35, 0.20], 11)
        crack = value_noise(W, H, 16, 13)
        px = []
        for y in range(H):
            for x in range(W):
                v = n[y * W + x]
                g = int(44 + v * 46)
                # 细裂纹：噪声接近极值时轻微压暗（太重会像迷宫，参考图沥青很干净）
                c = crack[y * W + x]
                if abs(c - 0.5) < 0.022:
                    g = int(g * 0.82)
                px.append((g, g + 2, g + 6))
        write_png(os.path.join(OUT, "asphalt.png"), W, H, px)

    # 草地：AI 贴图存在则跳过
    if not os.path.exists(os.path.join(OUT, "grass.png")):
        # 草地（1024，草丛团块 + 色斑）
        W = H = 1024
        n = fbm(W, H, [8, 26, 90], [0.4, 0.35, 0.25], 31)
        patch = value_noise(W, H, 14, 33)
        px = []
        for y in range(H):
            for x in range(W):
                i = y * W + x
                v = n[i]
                p = patch[i]
                r = int(58 + v * 46 + p * 12)
                g = int(132 + v * 74 + p * 18)
                b = int(52 + v * 34 + p * 8)
                px.append((min(r, 255), min(g, 255), min(b, 255)))
        write_png(os.path.join(OUT, "grass.png"), W, H, px)

    # 羽毛细节（256，柔和羽片纹理）
    W = H = 256
    n = fbm(W, H, [7, 24], [0.55, 0.45], 21)
    px = []
    for y in range(H):
        for x in range(W):
            v = n[y * W + x]
            c = int(226 + v * 28)
            px.append((c, c, min(c + 5, 255)))
    write_png(os.path.join(OUT, "feather.png"), W, H, px)

    # 阳光眩光（径向渐变，面向太阳时叠加）
    W = H = 256
    px = []
    for y in range(H):
        for x in range(W):
            d = math.hypot(x - W / 2, y - H / 2) / (W * 0.5)
            a = max(0.0, 1.0 - d)
            a = a * a
            px.append((255, 240, 210, int(255 * a * a)))
    write_png(os.path.join(OUT, "glare.png"), W, H, px)

    # 藤编纹理（车筐）
    W = H = 128
    px = []
    for y in range(H):
        for x in range(W):
            v = (math.sin(x * 0.6) * 0.5 + 0.5) * 0.6 + (math.sin(y * 0.35) * 0.5 + 0.5) * 0.4
            c = int(120 + v * 80)
            px.append((c, int(c * 0.72), int(c * 0.42), 255))
    write_png(os.path.join(OUT, "wicker.png"), W, H, px)

    # 自行车道标志（白线喷绘，透明底，画在路面上）
    W = H = 256
    px = [(0, 0, 0, 0)] * (W * H)
    cx, cy = W * 0.5, H * 0.62

    def put(x, y, col):
        if 0 <= x < W and 0 <= y < H:
            px[int(y) * W + int(x)] = col

    def disc(cx0, cy0, r0, r1, col):
        rr = int(r1) + 2
        for dy in range(-rr, rr + 1):
            for dx in range(-rr, rr + 1):
                d = math.hypot(dx, dy)
                if r0 <= d <= r1:
                    put(cx0 + dx, cy0 + dy, col)

    def line(x0, y0, x1, y1, w0, col):
        steps = int(max(abs(x1 - x0), abs(y1 - y0))) * 2 + 1
        for i in range(steps + 1):
            t = i / steps
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            for dy in range(-w0, w0 + 1):
                for dx in range(-w0, w0 + 1):
                    if dx * dx + dy * dy <= w0 * w0:
                        put(x + dx, y + dy, col)

    white = (245, 245, 245, 235)
    # 两个轮子
    disc(cx - 52, cy + 38, 34, 40, white)
    disc(cx + 52, cy + 38, 34, 40, white)
    # 车架
    line(cx - 52, cy + 38, cx - 6, cy - 18, 4, white)
    line(cx - 6, cy - 18, cx + 40, cy + 38, 4, white)
    line(cx - 6, cy - 18, cx + 22, cy - 18, 4, white)
    line(cx + 22, cy - 18, cx - 52, cy + 38, 4, white)
    line(cx + 22, cy - 18, cx + 52, cy + 38, 3, white)
    # 车把与座垫
    line(cx - 14, cy - 34, cx + 4, cy - 34, 4, white)
    line(cx - 6, cy - 18, cx - 14, cy - 34, 3, white)
    line(cx + 26, cy - 32, cx + 44, cy - 32, 4, white)
    line(cx + 22, cy - 18, cx + 26, cy - 32, 3, white)
    # 上方箭头
    line(cx, cy - 66, cx, cy - 96, 5, white)
    line(cx - 12, cy - 84, cx, cy - 100, 4, white)
    line(cx + 12, cy - 84, cx, cy - 100, 4, white)
    write_png(os.path.join(OUT, "bike_symbol.png"), W, H, px)

# ================================================================ 音效（WAV）
SR = 44100
def write_wav(name, samples):
    p = os.path.join(OUT, name)
    with wave.open(p, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        frames = bytearray()
        for s in samples:
            s = max(-1.0, min(1.0, s))
            frames += struct.pack("<h", int(s * 32000))
        w.writeframes(bytes(frames))
    print("  wav:", name, "%.2fs" % (len(samples) / SR))

def build_audio():
    def env(i, n, a=0.01, r=0.6):
        t = i / n
        if t < a: return t / a
        return max(0.0, (1.0 - (t - a) / (1.0 - a))) ** r

    # 跳跃：上滑音
    n = int(SR * 0.20); out = []
    for i in range(n):
        t = i / SR
        f = 420 + 520 * (t / 0.20)
        out.append(math.sin(2 * math.pi * f * t) * env(i, n, 0.02, 1.4) * 0.5)
    write_wav("sfx_jump.wav", out)

    # 收集：两声清脆
    n = int(SR * 0.22); out = []
    for i in range(n):
        t = i / SR
        f = 1050 if t < 0.09 else 1560
        out.append((math.sin(2 * math.pi * f * t) * 0.45 + math.sin(4 * math.pi * f * t) * 0.12)
                   * env(i, n, 0.01, 1.8))
    write_wav("sfx_collect.wav", out)

    # 撞车：噪声 + 低频闷响
    n = int(SR * 0.55); out = []
    rnd = random.Random(3)
    for i in range(n):
        t = i / SR
        noise = (rnd.random() * 2 - 1) * math.exp(-t * 9) * 0.55
        thud = math.sin(2 * math.pi * (110 - 60 * t) * t) * math.exp(-t * 7) * 0.6
        out.append((noise + thud) * min(1.0, t / 0.005))
    write_wav("sfx_crash.wav", out)

    # 背景音乐：柔和琶音循环
    dur = 8.0
    n = int(SR * dur); out = []
    scale = [261.63, 329.63, 392.00, 523.25, 659.25, 783.99]
    for i in range(n):
        t = i / SR
        step = int(t / 0.25) % 6
        lt = (t % 0.25) / 0.25
        f = scale[step]
        a = math.exp(-lt * 3.2) * 0.16
        s = (math.sin(2 * math.pi * f * t) * 0.7 +
             math.sin(2 * math.pi * f * 2 * t) * 0.18 +
             math.sin(2 * math.pi * f * 0.5 * t) * 0.20)
        # 淡入淡出，便于无缝循环
        fade = min(1.0, t / 0.4, (dur - t) / 0.4)
        out.append(s * a * fade)
    write_wav("music_loop.wav", out)

    # 风声循环（低通噪声，音量随速度调）
    dur = 6.0
    n = int(SR * dur); out = []
    prev = 0.0
    rnd = random.Random(9)
    for i in range(n):
        t = i / SR
        raw = rnd.random() * 2 - 1
        prev = prev * 0.97 + raw * 0.03
        amp = 0.5 + 0.5 * math.sin(t * 0.8)
        fade = min(1.0, t / 0.5, (dur - t) / 0.5)
        out.append(prev * 6.0 * amp * fade * 0.5)
    write_wav("wind_loop.wav", out)

if __name__ == "__main__":
    print("生成角色模型…"); build_character()
    print("生成道具/场景…"); build_props()
    print("生成道路…");    build_road()
    print("生成贴图…");    build_textures()
    print("生成音效…");    build_audio()
    print("完成 →", OUT)
