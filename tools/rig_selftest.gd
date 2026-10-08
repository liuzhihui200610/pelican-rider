extends SceneTree
## V109-C 骨架蒙皮自检（回归测试）
## 用法：godot --headless --path . --script res://tools/rig_selftest.gd
## 覆盖 V109 踩过的三个致命坑，任一回归立即报红：
##   ① 绑定点必须建立在"入树之后"（树外赋值 → 渲染端无效绑定 → 网格被放大 1.27² 并上移）
##   ② 骨骼局部偏移必须减父骨的**全局位置**（否则逐级累加，头骨会跑到 y≈0.94）
##   ③ 骨骼静止姿势与绑定姿势一致 → 静止时形变恒等（枢轴偏移必须 ≈ 0）
const RigS = preload("res://scripts/pelican_rig.gd")

var _fail := 0

func _check(ok: bool, msg: String) -> void:
	print(("  [OK] " if ok else "  [FAIL] ") + msg)
	if not ok:
		_fail += 1

func _init():
	_run()

func _run():
	print("=== PelicanRig 自检 ===")
	var rig = RigS.create("res://assets/ai/ai_pelican.glb")
	if rig == null:
		print("  [FAIL] 骨架构建失败（RigS.create 返回 null）")
		quit(1); return

	# ---- 建树前的期望值 ----
	_check(rig.skeleton.get_bone_count() == 8, "骨骼数 = 8（实际 %d）" % rig.skeleton.get_bone_count())
	var size: Vector3 = rig.aabb.size
	_check(absf(size.y - 1.0227) < 0.01, "包围盒高 ≈ 1.023（实际 %.4f）" % size.y)
	var arr: Array = rig.mesh_inst.mesh.surface_get_arrays(0)
	var nv := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_check((arr[Mesh.ARRAY_BONES] as PackedInt32Array).size() == nv * 4, "ARRAY_BONES 长度 = 顶点数×4")
	_check((arr[Mesh.ARRAY_WEIGHTS] as PackedFloat32Array).size() == nv * 4, "ARRAY_WEIGHTS 长度 = 顶点数×4")
	_check(arr[Mesh.ARRAY_TEX_UV] != null and arr[Mesh.ARRAY_NORMAL] != null, "UV / 法线已保留（画风不变）")

	# 权重归一化检查（每个顶点 4 个权重和为 1）
	var wts: PackedFloat32Array = arr[Mesh.ARRAY_WEIGHTS]
	var bad := 0
	for i in nv:
		var s := wts[i * 4] + wts[i * 4 + 1] + wts[i * 4 + 2] + wts[i * 4 + 3]
		if absf(s - 1.0) > 0.001:
			bad += 1
	_check(bad == 0, "全部 %d 个顶点权重已归一化（异常 %d）" % [nv, bad])

	# ---- 权重解剖分区检查（比截图更硬的证据：直接断言"抬翅不会拖胖躯干"）----
	# 依据 pelican_rig.gd 的权重函数：翼影响带 |Z|∈[0.205,0.27] 且 Y∈[0.30,0.70]；
	# 腿 Y<0.36；spine 兜底必须覆盖躯干中轴。若有人把翼混合带起点调低，此项立刻报红。
	var bios: PackedInt32Array = arr[Mesh.ARRAY_BONES]
	var verts2: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var wing_min_az := 1e9      # 被翼骨主导(权重>0.5)的顶点里的最小 |Z|
	var wing_cnt := 0
	var spine_min_az := 1e9     # 被 spine 主导的顶点里的最小 |Z|（应能触及中轴）
	var leg_max_y := -1e9
	var leg_cnt := 0
	for i in nv:
		var v: Vector3 = verts2[i]
		var bi := [bios[i * 4], bios[i * 4 + 1], bios[i * 4 + 2], bios[i * 4 + 3]]
		var bw := [wts[i * 4], wts[i * 4 + 1], wts[i * 4 + 2], wts[i * 4 + 3]]
		for k in 4:
			var w: float = bw[k]
			if w <= 0.5:
				continue
			var b: int = bi[k]
			if b == 3 or b == 4:                                  # wing_l / wing_r
				wing_cnt += 1
				wing_min_az = minf(wing_min_az, absf(v.z))
			elif b == 1:                                          # spine
				spine_min_az = minf(spine_min_az, absf(v.z))
			elif b == 6 or b == 7:                                # leg_l / leg_r
				leg_cnt += 1
				leg_max_y = maxf(leg_max_y, v.y)
	_check(wing_cnt > 0 and wing_min_az >= 0.19,
		"翼骨主导顶点全部在 |Z|≥0.19（实际最小 %.3f，共 %d 点）→ 抬翅不拖拽躯干中轴" % [wing_min_az, wing_cnt])
	_check(spine_min_az < 0.10, "spine 兜底覆盖躯干中轴（最小 |Z| = %.3f）" % spine_min_az)
	_check(leg_cnt > 0 and leg_max_y < 0.42,
		"腿骨主导顶点全部在 Y<0.42（实际最高 %.3f，共 %d 点）" % [leg_max_y, leg_cnt])

	# ---- 坑②：骨骼枢轴必须落在统计出来的解剖位置上 ----
	var expect := {
		"root": Vector3(0.00, 0.30, 0.00), "spine": Vector3(-0.02, 0.44, 0.00),
		"head": Vector3(-0.02, 0.64, 0.00), "wing_l": Vector3(-0.06, 0.54, -0.10),
		"wing_r": Vector3(-0.06, 0.54, 0.10), "tail": Vector3(-0.26, 0.46, 0.00),
		"leg_l": Vector3(0.02, 0.28, -0.09), "leg_r": Vector3(0.02, 0.28, 0.09),
	}
	var worst := 0.0
	for n in expect:
		var i: int = rig.bone_idx[n]
		worst = maxf(worst, rig.skeleton.get_bone_global_rest(i).origin.distance_to(expect[n]))
	_check(worst < 0.001, "8 根骨枢轴全部正确（最大偏差 %.5f）" % worst)

	# ---- 坑①：蒙皮绑定必须在入树后建立 ----
	get_root().add_child(rig)
	await process_frame
	await process_frame
	_check(rig.mesh_inst.skin != null, "入树后 mesh_inst.skin 已建立（坑①）")
	_check(rig.mesh_inst.get_skin_reference() != null, "入树后 skin reference 有效（坑①）")

	# ---- 坑③：静止时形变恒等 → 骨骼全局姿势原点 = 绑定姿势原点 ----
	var h: int = rig.bone_idx["head"]
	var off: float = rig.skeleton.get_bone_global_pose(h).origin.distance_to(rig.rest_global[h] as Vector3)
	_check(off < 0.001, "静止态 head 骨枢轴偏移 ≈ 0（实际 %.5f）（坑③）" % off)

	# ---- 姿态可动性：设定 40° 后局部姿势必须改变（蒙特卡洛式抽检）----
	var before: Transform3D = rig.skeleton.get_bone_pose(h)
	rig._set_bone_euler("head", Vector3(0, deg_to_rad(40), 0), 1.0)
	var after: Transform3D = rig.skeleton.get_bone_pose(h)
	_check(before.basis.get_euler().distance_to(after.basis.get_euler()) > 0.1,
		"set_bone_pose_rotation 生效（局部姿势已改变）")

	print("=== 结果：%s（失败 %d 项）===" % ["全部通过" if _fail == 0 else "有失败", _fail])
	quit(1 if _fail > 0 else 0)
