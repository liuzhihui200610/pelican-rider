class_name PelicanRig
extends Node3D

## V109-C「脱胎换骨」· 运行时骨架蒙皮器
## ============================================================================
## 背景（为什么必须这么做）
##   `assets/ai/ai_pelican.glb` 经 GLB 二进制解析 + Godot 内省双重确认：
##     1 node / 1 mesh / 1 primitive / **无 skin**（无骨骼）；
##   再做**三角形连通分量分析**：19987 个唯一顶点全部连通 → 整只鹈鹕是**单连通壳**。
##   所以：
##     · 硬"切部件"会在连续曲面上留下裂缝（不可接受）；
##     · 只有"不切网格、只加权重"的**蒙皮（skinning）**能既保留 AI 贴图/法线/UV，
##       又让头 / 翅 / 腿 / 尾 独立运动。
##
## 方案
##   在运行时把焊死网格重建为 Skeleton3D + Skin + 带 ARRAY_BONES/ARRAY_WEIGHTS 的 ArrayMesh。
##   顶点**位置一个不动**，绑定姿势 = 静止姿势 → 静止时形变恒等（与原模型像素级一致）。
##
## 骨骼（"实例空间"：Y 上、高≈1.023、喙朝 +X、尾朝 -X、左右为 ±Z）
##   root(骨盆, 无权重·仅作父节点)
##     ├─ spine(躯干)  ← 权重兜底，承载呼吸/前倾
##     │    ├─ head(颈根枢轴)      头+喙+帽   → 可回看/啄食
##     │    ├─ wing_l / wing_r     左/右翅    → 可扇动/收展
##     │    └─ tail                尾羽       → 可摆动
##     ├─ leg_l(左髋)
##     └─ leg_r(右髋)
##
## 权重来源（对 27234 顶点逐点解析，见 CHANGELOG）：
##   腿  Y<0.20（左右 Z 中心 ∓0.09/0.11）· 翅 Y0.28–0.58 且 |Z|>0.18
##   颈根 Y≈0.64 · 喙伸到 X≈0.49 · 尾 X<-0.30

# ---------------------------------------------------------------- 骨骼定义
# pos = 骨骼**枢轴点**（旋转中心），均在实例空间
const BONE_DEFS: Array = [
	{"name": "root",   "parent": -1, "pos": Vector3(0.00, 0.30, 0.00)},
	{"name": "spine",  "parent":  0, "pos": Vector3(-0.02, 0.44, 0.00)},
	{"name": "head",   "parent":  1, "pos": Vector3(-0.02, 0.64, 0.00)},
	{"name": "wing_l", "parent":  1, "pos": Vector3(-0.06, 0.54, -0.10)},
	{"name": "wing_r", "parent":  1, "pos": Vector3(-0.06, 0.54,  0.10)},
	{"name": "tail",   "parent":  1, "pos": Vector3(-0.26, 0.46,  0.00)},
	{"name": "leg_l",  "parent":  0, "pos": Vector3( 0.02, 0.28, -0.09)},
	{"name": "leg_r",  "parent":  0, "pos": Vector3( 0.02, 0.28,  0.09)},
]

var skeleton: Skeleton3D
var mesh_inst: MeshInstance3D
var bone_idx: Dictionary = {}          # name -> index
var rest_local: Array = []             # index -> Vector3（相对父骨）
var rest_global: Array = []            # index -> Vector3（骨架空间）
var aabb := AABB()                     # 实例空间包围盒（供外部做归一化定位）
var _ref_mesh: ArrayMesh = null        # --rigprobe 用：未蒙皮对照网格

# 动画状态（骨骼级，叠加在 V108-C 的整身姿态层之上）
var _head_yaw := 0.0
var _head_pitch := 0.0
var _spine_pitch := 0.0
var _tail_yaw := 0.0

# 与 main.gd 的 `enum PState` **必须逐项一致**（此处复制值以避免双向依赖）。
# 若主脚本改了枚举顺序，这里必须同步改，否则动作会错位到别的状态上。
const PS_RIDING := 0
const PS_STEERING := 1
const PS_JUMP_START := 2
const PS_AIRBORNE := 3
const PS_LANDING := 4
const PS_COLLECTING := 5
const PS_NEAR_MISS := 6
const PS_HIT := 7
const PS_GAME_OVER := 8
const PS_RESPAWN := 9


# ============================================================ 构建
## 从 GLB 场景构建可蒙皮骨架。失败返回 null。
static func create(glb_path: String) -> PelicanRig:
	if not ResourceLoader.exists(glb_path):
		return null
	var ps: PackedScene = load(glb_path)
	if ps == null:
		return null
	var src: Node3D = ps.instantiate() as Node3D
	if src == null:
		return null
	var mi: MeshInstance3D = _find_mesh(src)
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() < 1:
		src.queue_free()
		return null

	var rig := PelicanRig.new()
	rig.name = "PelicanRig"
	if not rig._rebuild(mi, _rel_transform(mi, src)):
		src.queue_free()
		return null
	src.queue_free()
	return rig


static func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r != null:
			return r
	return null


## 求 node 相对 anc 的累积变换（含中间所有 Node3D 的 transform）
static func _rel_transform(node: Node3D, anc: Node3D) -> Transform3D:
	var t := Transform3D()
	var cur: Node = node
	while cur != null and cur != anc:
		var c3 := cur as Node3D
		if c3 != null:
			t = c3.transform * t
		cur = cur.get_parent()
	return t


func _rebuild(src_mi: MeshInstance3D, rel: Transform3D) -> bool:
	var src_mesh: ArrayMesh = src_mi.mesh
	var arrays: Array = src_mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return false
	var vtx: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if vtx.is_empty():
		return false

	# ---- 1) 顶点烘焙到实例空间（源网格本地是 Z-up，实例空间是 Y-up）----
	var nb := rel.basis.inverse().transposed()
	var n_verts := vtx.size()
	var verts := PackedVector3Array(); verts.resize(n_verts)
	var normals := PackedVector3Array(); normals.resize(n_verts)
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var has_nrm := nrm != null and nrm.size() == n_verts
	var mn := Vector3(1e9, 1e9, 1e9)
	var mx := Vector3(-1e9, -1e9, -1e9)
	for i in n_verts:
		var p := rel * vtx[i]
		verts[i] = p
		mn = mn.min(p)
		mx = mx.max(p)
		if has_nrm:
			normals[i] = (nb * nrm[i]).normalized()
	aabb = AABB(mn, mx - mn)

	# ---- 2) 逐顶点权重 → 每点取权重最大的 4 根骨 ----
	var bone_ids := PackedInt32Array(); bone_ids.resize(n_verts * 4)
	var bone_wts := PackedFloat32Array(); bone_wts.resize(n_verts * 4)
	for i in n_verts:
		var w := _weights_for(verts[i])
		# 取前 4 大
		var order := [0, 1, 2, 3, 4, 5, 6, 7]
		order.sort_custom(func(a, b): return w[a] > w[b])
		var tot := 0.0
		for k in 4:
			tot += w[order[k]]
		if tot <= 0.000001:
			bone_ids[i * 4 + 0] = 1   # 兜底给 spine
			bone_wts[i * 4 + 0] = 1.0
			continue
		for k in 4:
			bone_ids[i * 4 + k] = order[k]
			bone_wts[i * 4 + k] = w[order[k]] / tot

	# ---- 3) 组装 ArrayMesh（位置不变，仅追加骨骼数据）----
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	if has_nrm:
		out[Mesh.ARRAY_NORMAL] = normals
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		out[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
	if arrays[Mesh.ARRAY_TANGENT] != null:
		out[Mesh.ARRAY_TANGENT] = arrays[Mesh.ARRAY_TANGENT]
	if arrays[Mesh.ARRAY_INDEX] != null:
		out[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
	out[Mesh.ARRAY_BONES] = bone_ids
	out[Mesh.ARRAY_WEIGHTS] = bone_wts
	var nm := ArrayMesh.new()
	nm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	# 原材质（AI PBR：albedo + normal）原样沿用 → 画风不变
	nm.surface_set_material(0, src_mi.get_active_material(0))

	# ---- 4) Skeleton3D ----
	skeleton = Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	add_child(skeleton)
	rest_local.clear(); rest_global.clear(); bone_idx.clear()
	for d in BONE_DEFS:
		var n: String = d["name"]
		skeleton.add_bone(n)
		var idx := skeleton.get_bone_count() - 1
		bone_idx[n] = idx
		var local: Vector3 = d["pos"]
		var parent: int = d["parent"]
		if parent >= 0:
			# 必须减**父骨的全局位置**（不是父骨的局部偏移，否则偏移会逐级累加）
			local = local - (rest_global[parent] as Vector3)
		rest_local.append(local)
		rest_global.append(d["pos"])
		if parent >= 0:
			skeleton.set_bone_parent(idx, parent)
		skeleton.set_bone_rest(idx, Transform3D(Basis(), local))
	# 静止姿势 = 绑定姿势 → 未动画时形变恒等
	skeleton.reset_bone_poses()

	# ---- 5) Skin 与绑定：延后到 _ready()（节点进入场景树）再建立 ----
	# 原因：MeshInstance3D 的蒙皮参考（skin reference）需要可解析的 skeleton 路径；
	# 在树外先赋值会让渲染端拿到无效绑定 → 网格被错误形变（V109-C 排查记录）。

	# ---- 6) 蒙皮网格（与骨架同级、同变换 → 共享空间）----
	mesh_inst = MeshInstance3D.new()
	mesh_inst.name = "SkinnedPelican"
	mesh_inst.mesh = nm
	add_child(mesh_inst)
	# 供 --rigprobe 对照用（未蒙皮的原始网格，同一顶点空间）
	if OS.get_cmdline_args().has("--rigprobe"):
		var ref_arr: Array = []
		ref_arr.resize(Mesh.ARRAY_MAX)
		ref_arr[Mesh.ARRAY_VERTEX] = verts
		if has_nrm:
			ref_arr[Mesh.ARRAY_NORMAL] = normals
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			ref_arr[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
		if arrays[Mesh.ARRAY_INDEX] != null:
			ref_arr[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
		_ref_mesh = ArrayMesh.new()
		_ref_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ref_arr)
		_ref_mesh.surface_set_material(0, src_mi.get_active_material(0))
	return true


## 进入场景树后建立蒙皮绑定（渲染端的 skin reference 需要有效路径）
func _ready() -> void:
	if mesh_inst == null or skeleton == null:
		return
	var skin: Skin = skeleton.create_skin_from_rest_transforms()
	skeleton.register_skin(skin)
	mesh_inst.skeleton = mesh_inst.get_path_to(skeleton)
	mesh_inst.skin = skin
	reset_pose()
	if _ref_mesh != null:
		var ref_mi := MeshInstance3D.new()
		ref_mi.name = "RefUnskinned"
		ref_mi.mesh = _ref_mesh
		ref_mi.position = Vector3(0, 0, -1.6)   # 侧视时并排
		add_child(ref_mi)
		print("[RIG-探针] 已并排放置未蒙皮对照网格")


## 逐顶点权重（返回值按 BONE_DEFS 顺序索引）
func _weights_for(v: Vector3) -> Array:
	var y := v.y
	var z := v.z
	var x := v.x
	var az := absf(z)
	# 左右柔和分离（0=左/-Z，1=右/+Z）
	var r := smoothstep(-0.02, 0.14, z)
	var l := 1.0 - r
	# 各部位影响因子（平滑过渡 → 无裂缝）
	var f_leg := 1.0 - smoothstep(0.12, 0.36, y)                                     # 腿：越低越强
	var f_head := smoothstep(0.56, 0.72, y)                                          # 头：越高越强
	var f_wing := smoothstep(0.205, 0.27, az) \
		* smoothstep(0.30, 0.38, y) \
		* (1.0 - smoothstep(0.60, 0.70, y))                                          # 翅：侧面 + 中段高
	# 注：|Z| 起点取 0.205（混合带仅 0.065 宽）—— 起点过低会把躯干两侧也拉进翅膀，
	# 抬翅时躯干跟着"变胖"（--rigdemo 极端姿态实测发现）
	var f_tail := smoothstep(0.26, 0.40, -x) * (1.0 - smoothstep(0.58, 0.68, y))      # 尾：后段
	f_tail *= (1.0 - f_wing) * (1.0 - f_leg)

	var w := [
		0.0,                                   # 0 root（不承载顶点）
		maxf(0.0, 1.0 - (f_head + f_wing + f_tail + f_leg)),  # 1 spine 兜底
		f_head,                                # 2 head
		f_wing * l,                            # 3 wing_l
		f_wing * r,                            # 4 wing_r
		f_tail,                                # 5 tail
		f_leg * l,                             # 6 leg_l
		f_leg * r,                             # 7 leg_r
	]
	return w


# ============================================================ 动画
## 骨骼姿态（每物理帧调用）。参数与主脚本的状态机 / 曲柄相位对齐。
##  pedal_phase: 与车轮曲柄同相位；cadence: 0~1；grounded: 是否着地
func pose_bones(delta: float, pedal_phase: float, cadence: float, grounded: bool,
		pstate: int, pstate_time: float) -> void:
	if skeleton == null:
		return
	var rate := clampf(delta * 9.0, 0.0, 1.0)

	# ---- 腿：蹬踏（绕 Z 轴前后摆，左右反相）----
	# AI 鹈鹕的脚本来就在脚踏上，"踩下去"比"整个身体颠"直观得多
	var pedal_amp := deg_to_rad(22.0) * (0.45 + 0.55 * cadence)
	var leg_l_ang := sin(pedal_phase) * pedal_amp
	var leg_r_ang := sin(pedal_phase + PI) * pedal_amp
	# 空中：双腿收起（不再空踩）
	if pstate == PS_AIRBORNE or pstate == PS_LANDING:
		leg_l_ang = lerpf(leg_l_ang, deg_to_rad(-16.0), 0.7)
		leg_r_ang = lerpf(leg_r_ang, deg_to_rad(-16.0), 0.7)
	_set_bone_euler("leg_l", Vector3(0, 0, leg_l_ang), rate)
	_set_bone_euler("leg_r", Vector3(0, 0, leg_r_ang), rate)

	# ---- 翅：着地贴身微颤 / 空中扇翅 / 擦身张开 ----
	var wing_spread := 0.0     # 绕 Y：向外展开
	var wing_lift := 0.0       # 绕 X：向上抬起
	if grounded:
		wing_lift = sin(pedal_phase * 0.5) * 0.05
	else:
		# 空中：一次大幅扇翅（频率 3.2Hz）+ 展开
		var flap := sin(pstate_time * 20.0) * 0.55
		wing_lift = 0.35 + flap
		wing_spread = 0.28
	if pstate == PS_NEAR_MISS and pstate_time < 0.45:   # 受惊张翅
		wing_lift = lerpf(wing_lift, 0.85, 1.0 - pstate_time / 0.45)
		wing_spread = lerpf(wing_spread, 0.55, 1.0 - pstate_time / 0.45)
	_set_bone_euler("wing_l", Vector3(-wing_lift, 0, -wing_spread), rate)
	_set_bone_euler("wing_r", Vector3(-wing_lift, 0, wing_spread), rate)

	# ---- 头：正常微摆 / 吃鱼下啄 / 擦身回看 / 撞车前甩 ----
	var t_yaw := sin(pedal_phase * 0.35) * deg_to_rad(2.5)
	var t_pitch := -deg_to_rad(1.5) * cadence
	match pstate:
		PS_COLLECTING:   # 前探啄食
			var k := clampf(pstate_time / 0.35, 0.0, 1.0)
			t_pitch += deg_to_rad(22.0) * sin(k * PI)
		PS_NEAR_MISS:    # 受惊回看（甩头向后）
			var k2 := clampf(pstate_time / 0.5, 0.0, 1.0)
			t_yaw += deg_to_rad(42.0) * sin(k2 * PI)
			t_pitch += deg_to_rad(9.0) * sin(k2 * PI)
		PS_HIT:          # 撞车前甩
			t_pitch += deg_to_rad(16.0)
	_head_yaw = lerpf(_head_yaw, t_yaw, rate)
	_head_pitch = lerpf(_head_pitch, t_pitch, rate)
	_set_bone_euler("head", Vector3(0, _head_yaw, _head_pitch), 1.0)

	# ---- 躯干：呼吸 + 加速前倾（与整身姿态层叠加，幅度更小）----
	var breath := sin(pedal_phase * 2.0) * deg_to_rad(1.6)
	var t_spine := deg_to_rad(2.5) * cadence + breath
	_spine_pitch = lerpf(_spine_pitch, t_spine, rate)
	_set_bone_euler("spine", Vector3(0, 0, _spine_pitch), 1.0)

	# ---- 尾羽：随速度轻摆 ----
	var t_tail := sin(pedal_phase * 0.6) * deg_to_rad(7.0) * (0.3 + 0.7 * cadence)
	_tail_yaw = lerpf(_tail_yaw, t_tail, rate)
	_set_bone_euler("tail", Vector3(0, _tail_yaw, 0), 1.0)


# 直接对骨骼姿态赋欧拉角（内部转四元数）；rate<1 时向目标插值
var _cur_rot: Dictionary = {}
func _set_bone_euler(bone_name: String, euler: Vector3, rate: float) -> void:
	if not bone_idx.has(bone_name):
		return
	var idx: int = bone_idx[bone_name]
	var target := Quaternion.from_euler(euler)
	var cur: Quaternion = _cur_rot.get(bone_name, Quaternion())
	if rate < 1.0:
		cur = cur.slerp(target, rate)
	else:
		cur = target
	_cur_rot[bone_name] = cur
	# 姿势为**局部变换**：位置固定为静止位置，仅改旋转（枢轴 = 骨骼原点）
	skeleton.set_bone_pose_position(idx, rest_local[idx])
	skeleton.set_bone_pose_rotation(idx, cur)
	skeleton.set_bone_pose_scale(idx, Vector3.ONE)


## 复位到静止姿势（重开 / 切机位时可调用）
func reset_pose() -> void:
	_cur_rot.clear()
	_head_yaw = 0.0
	_head_pitch = 0.0
	_spine_pitch = 0.0
	_tail_yaw = 0.0
	if skeleton != null:
		skeleton.reset_bone_poses()


## 调试：把指定骨固定到给定欧拉角（度），用于离线审查极端动作的形变质量。
## 规格 "骨名:degX,degY,degZ"，多根骨用分号分隔，例："--rigdemo=head:0,50,0;wing_l:-35,0,-20"
func demo_pose(spec: String) -> void:
	if skeleton == null:
		return
	var applied := {}
	for part in spec.split(";"):
		var kv := part.split(":")
		if kv.size() != 2:
			continue
		var nm := kv[0].strip_edges()
		if not bone_idx.has(nm):
			continue
		var d := kv[1].split(",")
		var ex := deg_to_rad(float(d[0])) if d.size() > 0 else 0.0
		var ey := deg_to_rad(float(d[1])) if d.size() > 1 else 0.0
		var ez := deg_to_rad(float(d[2])) if d.size() > 2 else 0.0
		_set_bone_euler(nm, Vector3(ex, ey, ez), 1.0)
		applied[nm] = true
	# 未指定的骨一律回到静止（保证对照干净）
	for n in bone_idx:
		if not applied.has(n):
			_set_bone_euler(n, Vector3.ZERO, 1.0)
