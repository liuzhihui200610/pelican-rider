extends Node3D

# ============================================================
# 鹈鹕骑手 3D —— Godot 4 / 真实物理 / 赛璐璐卡通渲染
# 程序化有机模型 + 描边 + 梦幻配色 + 粒子 + 音效 + 卡片式 UI
# ============================================================

const ROAD_HALF := 4.5
const START_SPEED := 11.0      # 起步速度（原来 18，太猛）
const MAX_SPEED := 26.0        # 最高速度（原来 48）
const ACCEL := 8.0             # 加速度（更平缓）
const JUMP_SPEED := 9.0       # 调低：之前 12.5 冲量过大，滞空约 2.5s 太飘；9.0 约 1.6s 更跟手
const MASS := 80.0
const STEER_SPEED := 5.2
const FISH_BASE := 5.0
const NEAR_MISS_BONUS := 3.0
const COMBO_STEP := 5
const SAVE_PATH := "user://best.cfg"

# ---------- 节点 ----------
var player: RigidBody3D
var visual: Node3D
var camera: Camera3D
var ground_check: RayCast3D
var grass: Node3D
var backdrop: Node3D
var road_group: Node3D   # 道路三件套（路面+虚线+边线）打包跟随玩家，避免长直路跑到尽头
var sun: DirectionalLight3D
var dust: GPUParticles3D

var wheel_f: Node3D
var wheel_b: Node3D
var scarf: Node3D
var crank_a: Node3D
var crank_b: Node3D
var leg_l: Node3D
var leg_r: Node3D
var wing_l: Node3D
var wing_r: Node3D

var music: AudioStreamPlayer
var sfx_jump: AudioStreamPlayer
var sfx_collect: AudioStreamPlayer
var sfx_crash: AudioStreamPlayer

var obstacles: Array = []
var fishes: Array = []
var scenery: Array = []
var palms: Array = []   # 棕榈树（单独记录以便做风吹摇摆）
var swayables: Array = []   # 灌木/遮阳伞等也会随风轻摆（让整个世界一起呼吸）
# 生成游标：始终保证玩家前方 AHEAD 米内已经铺好内容（不再"跑过了才刷出来"）
const AHEAD := 200.0
var obstacle_cursor := -70.0
var fish_cursor := -50.0
var scenery_cursor := -30.0
var rail_cursor := -20.0
var lamp_cursor := -40.0
var decal_cursor := -60.0
var sign_cursor := -80.0
var umbrella_cursor := -45.0
var hut_cursor := -140.0
var verge_cursor := -15.0   # 路肩草丛 / 碎石

# ---------- 状态 ----------
var started := false
var game_over := false
var score := 0.0
var max_dist := 0.0        # 最远骑行距离
var bonus_score := 0.0     # 小鱼 / 连击 / 擦身奖励
var fish_count := 0
var combo := 0
var best := 0.0
var shake := 0.0
var jump_buffer := 0.0      # 跳跃输入缓冲：落地前 0.14s 内按跳也能触发，操作更跟手
var game_time := 0.0

# ---------- V108-B：角色状态机 ----------
# 目的（方案 §3.2）：让动画 / 声音 / 镜头 / 粒子统一监听同一个状态，
# 消除"撞车时仍在跳跃""重开后旧音效""落地和起跳同时触发"这类冲突。
enum PState {
	RIDING,       # 正常骑行
	STEERING,     # 转向中
	JUMP_START,   # 起跳瞬间
	AIRBORNE,     # 空中
	LANDING,      # 落地缓冲
	COLLECTING,   # 吃鱼反馈
	NEAR_MISS,    # 擦身反馈
	HIT,          # 撞击瞬间
	GAME_OVER,    # 已结束
	RESPAWN,      # 重开重建
}
var pstate: int = PState.RESPAWN   # 初始为"待重开"，_start_game 后进入 RIDING
var pstate_time := 0.0             # 当前状态已持续秒数
var pstate_prev: int = -1          # 上一状态（供状态切换判断）

# ---------- 昼夜循环 ----------
const DAY_LENGTH := 150.0          # 一整个昼夜的秒数
var day_time := 0.30               # 0=日出 0.25=正午 0.5=日落 0.75=深夜
var sun_moon: DirectionalLight3D   # 月光
var env_ref: Environment
var sky_mat: ShaderMaterial       # 程序化天空（夜晚星空/昼夜渐变）
var sky_pano_mat: PanoramaSkyMaterial   # AI 生成的真实全景天空
var sky_node: Sky
var cloud_mat: ShaderMaterial   # 云的专用材质（双色积云）
var grass_mat: ShaderMaterial   # V104：草地程序化材质（风扫草浪/色斑/近路枯草/夜晚压暗内置）
var sand_mat: StandardMaterial3D    # 沙滩（夜晚压暗）
var ocean_mat: ShaderMaterial
var road_shader_mat: ShaderMaterial   # V104：路面程序化材质（贴图滚动 + 车辙/坑洼/裂缝）
var paint_mat: ShaderMaterial         # V104：标线磨损材质（漆面剥落 + 夜间回反射）
var dashes_node: MeshInstance3D       # V104：中央虚线（循环滚动，世界坐标静止）
var lamp_lights: Array = []
var lamp_glow_mat: StandardMaterial3D
var lamp_cone_mats: Array = []   # 路灯下的光锥材质（黄昏/夜晚渐显，V99）
var tail_light: OmniLight3D
var head_light: SpotLight3D       # 车头灯（聚光灯，真实光锥）
var tail_bulb: MeshInstance3D
var tail_mat: StandardMaterial3D
var birds: Array = []
var clouds: Array = []      # 供云朵飘动使用
var boats: Array = []       # 供帆船航行使用
var lh_lamps: Array = []        # 灯塔顶灯材质（夜晚发光）
var lh_beam_pivots: Array = []  # 灯塔旋转光束的转动轴
var lh_beam_mats: Array = []    # 灯塔光束材质（夜里更亮）
# 描边粗细系数（厚度用）。是否显示由 outline_on 控制，O 键实时切换——
# 描边是画风取舍（卡通勾边 vs 写实无描边），交由玩家自己选，不再由代码擅自决定。
var outline_scale := 0.30
var outline_on := false      # 默认关（写实向）；按 O 可随时开
var outline_nodes: Array = []
var battery := 100.0
var max_speed_stat := 0.0
var speed_fx: GPUParticles3D
var wind: AudioStreamPlayer
var cam_mode := 0            # 0追尾 1低角度 2侧面 3第一人称
var quality_mode := 0        # 0高 1中 2低（Q 键切换：不同机器平衡画质/帧率）
var bPrevCam := false
var crash_orbit := 0.0
var steer_sm := 0.0         # 平滑后的转向值（供相机侧移使用）
var best_combo := 0         # 本局最高连击
var combo_timer := 0.0      # 连击窗口剩余秒数：断掉就清零（V98 修 bug：combo 原本只增不减，"连击"失去技巧意义）
const COMBO_WINDOW := 4.0   # 连续吃到下一条鱼的宽容窗口（秒）
var fp_hide: Array = []     # 第一人称需要隐藏的部件（头/喙/喉囊/帽子/眼睛）
var pelican_parts: Array = []   # 程序化鹈鹕的全部部件（AI 模型加载后整体隐藏）
var ai_pelican: Node3D      # AI 生成的 3D 鹈鹕（存在时替换程序化版）
var ai_rig: PelicanRig = null   # V109-C：AI 鹈鹕的运行时骨架蒙皮器（有它才可单独动头/翅/腿/尾）
var ai_rider: Node3D        # AI 生成的"鹈鹕骑自行车"整体模型（最高优先级）
var ai_rot := -90.0          # AI 模型朝向（度）：参考图是侧视，车长沿 X 轴，转 -90° 才是"朝前"
var ai_flip := false        # AI 模型朝向翻转（若用户报告它屁股朝前）
# ---------- V108-C：角色（AI 鹈鹕）姿态动画 ----------
# AI 鹈鹕是焊死的单一网格，程序化腿/翅已被隐藏 → 用"身体相对车架的俯仰/侧倾/抬升"
# 制造生命感（方案 §3.3：在获得骨骼模型之前，先用姿态层实现可见的动作）。
var ai_base_pos := Vector3.ZERO   # AI 鹈鹕基准位置（避免每帧累加漂移）
var ai_base_rot := Vector3.ZERO   # AI 鹈鹕基准旋转
var body_pitch := 0.0             # 身体俯仰（弧度，前倾为正）
var body_roll := 0.0              # 身体侧倾（弧度）
var body_lift := 0.0              # 身体相对车架的抬升（米）

# AI 模型开关：
# - USE_AI_RIDER（整组"鹈鹕骑自行车"合并网格）会隐藏全部程序化可动部件（轮/曲柄/腿/翅），
#   角色变"死"的静态网格（用户投诉僵硬）。保持关闭。
# - USE_AI_PELICAN（仅鹈鹕本体，高保真脸/身）作身体，程序化自行车 + 腿 + 翅仍显示并动画，
#   于是"高保真模型 + 真实蹬踏/扶把动作"兼得。已重新开启。
const USE_AI_RIDER := false
const USE_AI_PELICAN := true
var decal_mat: StandardMaterial3D   # 路面标线共享材质（夜间发光）
var island_mat: StandardMaterial3D   # V103：远岛剪影材质（白天显、黄昏淡出）
var foam_mat: StandardMaterial3D    # 浪花材质（起伏动画）
var night_windows: Array = []   # 远景建筑的窗户材质（夜晚亮起）
var palm_scene: PackedScene     # AI 生成的高保真棕榈（替换程序化棕榈）
var ai_night_orig: Dictionary = {}   # V101：AI 模型自带材质 {材质: 原始albedo}，夜里统一压暗（亮绿纸板的修复）
var lamp_scene: PackedScene     # AI 生成的高保真路灯（替换程序化路灯）
var hut_scene: PackedScene      # AI 生成的高保真海边小屋（替换程序化 prop_hut）
var hut_glow_mat: StandardMaterial3D   # 小屋门廊灯（夜里暖光，替代原来的窗贴片）
var boat_scene: PackedScene      # AI 生成的高保真帆船（替换程序化 prop_boat）
var bush_scene: PackedScene      # AI 生成的高保真海边灌木（替换程序化 prop_bush）
var bike_lamp_mat: StandardMaterial3D   # 车头灯（夜晚发光）
var char_fill: OmniLight3D              # 夜间角色补光
var next_milestone := 250.0
var was_grounded := true
var squash := 0.0           # 落地缓冲形变
var _z_base := 0.0           # 转向侧倾收敛基准（避免蛇形摇摆叠加漂移）
var glare_node: MeshInstance3D
var glare_mat: StandardMaterial3D
var cur_sun_dir := Vector3(0.35, 1.0, 0.0)
var cur_night_f := 0.0

var _verify := false
var _frames := 0
var _stress := false
var _shot := false          # --shot：离屏渲染截图自检（不开窗口）
var _shot_frame := 260
var _autoshot := false      # --autoshot：窗口模式自动截图并退出（真正渲染）
var _fulltest := false     # --fulltest：自动化全场景回归测试
var _reloading := false     # 重开进行中：解绑期间的帧一律让出，避免访问已释放的节点
static var _stress_runs := 0  # 压力测试累计重开次数（跨 reload 持久，用于确认 reload 压测确实在跑）
var _nogod := false          # --nogod：压力测试中也允许撞障碍（压测撞车+重开路径）
var _jump_before_y: float = 0.0
var _bare := false          # --bare：极简环境（排查过曝用）
var _hide_groups: PackedStringArray = []   # --hide=backdrop,scenery,...
var _auto_cam := 0          # --autocam=N：自检时指定机位
var _auto_day := -1.0       # --autoday=0.75：自检时指定时段
var _auto_name := "shot"    # --shotname=xxx：输出文件名
var _scroll_test := -1.0    # --scrollat=X：固定路面 scroll 做视觉 A/B（-1=正常随玩家滚动）

# ---------- UI ----------
var hud_root: Control
var start_root: Control
var over_root: Control
var lbl_score: Label
var lbl_fish: Label
var lbl_combo: Label
var combo_bar: ProgressBar
var lbl_stats: Label
var battery_bar: ProgressBar
var speed_gauge: SpeedGauge
var over_stats: Label
var start_best: Label
var pause_root: Control
var muted := false

# ---------- V108-A：调试 HUD / 性能采样 ----------
# 调试面板只在 --debug 参数或 F3 键下显示，不进入正式开始界面（方案要求）。
var _debug_hud := false        # 调试面板开关
var debug_root: Control
var debug_label: Label
var _perf := false             # --perf：性能采样模式（跑够帧数 → 打印统计 → 自动退出）
var _perf_frames := 1200       # 采样帧数（60fps ≈ 20 秒），--perfframes=N 可调
var _perf_sum := 0.0
var _perf_min := 1.0e9
var _perf_max := 0.0
var _perf_n := 0
var _rig_frozen := false       # V109-C：--rigfrozen 冻结骨架动画（隔离测试：验证蒙皮静止态与原网格是否一致）
var _rig_demo := ""            # V109-C：--rigdemo=骨名:degX,degY,degZ 固定某骨姿态（离线审查极端动作）

# ============================================================ 生命周期
func _ready() -> void:
	# 主脚本常驻处理输入（否则暂停后连 Esc 都收不到，按钮也点不动）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_verify = OS.get_cmdline_args().has("--verify")
	_stress = OS.get_cmdline_args().has("--stress")
	_shot = OS.get_cmdline_args().has("--shot")
	_autoshot = OS.get_cmdline_args().has("--autoshot")
	_bare = OS.get_cmdline_args().has("--bare")
	_nogod = OS.get_cmdline_args().has("--nogod")
	for a in OS.get_cmdline_args():
		if a.begins_with("--hide="):
			_hide_groups = a.split("=")[1].split(",")
	for a in OS.get_cmdline_args():
		if a.begins_with("--autocam="):
			_auto_cam = int(a.split("=")[1])
		elif a.begins_with("--autoday="):
			_auto_day = float(a.split("=")[1])
		elif a.begins_with("--shotname="):
			_auto_name = a.split("=")[1]
		elif a.begins_with("--scrollat="):
			_scroll_test = float(a.split("=")[1])
		elif a == "--flipai":
			ai_rot += 180.0
		elif a.begins_with("--airot="):
			ai_rot = float(a.split("=")[1])
	for a in OS.get_cmdline_args():
		if a.begins_with("--shotat="):
			_shot_frame = int(a.split("=")[1])
	# V108-A：调试 HUD / 性能采样参数
	_debug_hud = OS.get_cmdline_args().has("--debug")
	_perf = OS.get_cmdline_args().has("--perf")
	# V109-C：--rigfrozen 冻结骨架动画（用于验证"蒙皮静止时是否与原网格一致"的隔离测试）
	_rig_frozen = OS.get_cmdline_args().has("--rigfrozen")
	for a in OS.get_cmdline_args():
		if a.begins_with("--rigdemo="):
			_rig_demo = a.split("=")[1]
	for a in OS.get_cmdline_args():
		if a.begins_with("--perfframes="):
			_perf_frames = int(a.split("=")[1])
		elif a.begins_with("--perfq="):
			quality_mode = clampi(int(a.split("=")[1]), 0, 2)   # 性能采样时指定画质档（0高/1中/2低）
	_load_best()
	_build_environment()
	_build_world()
	_build_player()
	_fulltest = OS.get_cmdline_args().has("--fulltest")
	if _fulltest and FileAccess.file_exists("user://ft_done"):
		# 上一轮测试触发过重开：本场景未走完 _build_audio/_build_ui（hud 为空），
		# 必须拦住 _physics_process 对空节点的访问，再退出
		_reloading = true
		print("[FT] 重开后重建完成  障碍=", obstacles.size(), " 鱼=", fishes.size(),
			" 场景=", scenery.size(), " 分数=", roundf(score), " 电量=", roundf(battery),
			" 音乐=", (music != null), " 风声=", (wind != null))
		get_tree().quit()
		return
	_build_audio()
	_build_ui()
	# AI 高保真棕榈（存在即用，与 AI 鹈鹕画风统一）
	if ResourceLoader.exists("res://assets/ai/ai_palm.glb"):
		palm_scene = load("res://assets/ai/ai_palm.glb")
		if palm_scene != null:
			print("[AI] 棕榈模型已就绪")
	if ResourceLoader.exists("res://assets/ai/ai_lamp.glb"):
		lamp_scene = load("res://assets/ai/ai_lamp.glb")
		if lamp_scene != null:
			print("[AI] 路灯模型已就绪")
	# AI 高保真海边小屋（替换程序化 prop_hut 低模，PBR 3 万面）
	hut_scene = null
	if ResourceLoader.exists("res://assets/ai/ai_hut.glb"):
		hut_scene = load("res://assets/ai/ai_hut.glb")
		if hut_scene != null:
			print("[AI] 小屋模型已就绪")
	# AI 高保真帆船（替换程序化 prop_boat 低模）
	boat_scene = null
	if ResourceLoader.exists("res://assets/ai/ai_boat.glb"):
		boat_scene = load("res://assets/ai/ai_boat.glb")
		if boat_scene != null:
			print("[AI] 帆船模型已就绪")
	# AI 高保真灌木（替换程序化 prop_bush 低模）
	bush_scene = null
	if ResourceLoader.exists("res://assets/ai/ai_bush.glb"):
		bush_scene = load("res://assets/ai/ai_bush.glb")
		if bush_scene != null:
			print("[AI] 灌木模型已就绪")
	# 排查开关：按组隐藏节点（每帧生效，覆盖动态生成）
	if not _hide_groups.is_empty():
		_apply_hide_groups()
	if _verify:
		print("[BOOT] ok  best=", best)

# V104c：--hide 抽成可重入函数。原先只在 _ready 跑一次，而 scenery/obstacles 都是
# 游戏开始后才 spawn 的 → hide 全部落空（调试拍图时树/障碍根本藏不掉）。现在
# _physics_process 每 30 帧重跑一次，覆盖新 spawn 的节点（仅调试路径有此开销）。
func _apply_hide_groups() -> void:
	if _hide_groups.has("backdrop") and backdrop:
		backdrop.visible = false
	if _hide_groups.has("player") and player:
		player.visible = false
	if _hide_groups.has("scenery"):
		for n in scenery:
			if is_instance_valid(n):
				n.visible = false
	if _hide_groups.has("obstacles"):
		for n in obstacles:
			if is_instance_valid(n):
				n.visible = false
	if _hide_groups.has("fishes"):
		for n in fishes:
			if is_instance_valid(n):
				n.visible = false

func _physics_process(delta: float) -> void:
	# 树暂停时停掉一切游戏逻辑（本节点是 ALWAYS 模式，需手动让出）
	if get_tree().paused:
		return
	# 重开（reload_current_scene）后旧节点会被解绑，但本帧可能仍在跑：
	# 此时访问 global_position / 子节点会刷 !is_inside_tree() 错。直接让出。
	if not is_inside_tree() or _reloading or not is_instance_valid(player):
		return
	# 关键子节点（sun/camera）在场景解绑时可能先于本节点被释放，
	# 一旦失效立即让出，避免 look_at/全局变换访问报错
	if not is_instance_valid(sun) or not is_instance_valid(camera):
		return
	_frames += 1
	if not _hide_groups.is_empty() and _frames % 30 == 0:
		_apply_hide_groups()   # V104c：覆盖游戏开始后新 spawn 的节点（调试 --hide 用）
	# V108-A：调试 HUD 刷新（节流每 6 帧，降低自身开销）
	if _debug_hud and debug_label != null and _frames % 6 == 0:
		_update_debug_hud()
	# V108-A：性能采样（--perf）——跑够帧数后打印统计并自动退出，用于建立三档画质基线
	if _perf:
		if _frames > 90:   # 跳过启动 / 首次着色器编译阶段（不代表稳态性能）
			var _fps_now := Performance.get_monitor(Performance.TIME_FPS)
			_perf_sum += _fps_now
			_perf_min = minf(_perf_min, _fps_now)
			_perf_max = maxf(_perf_max, _fps_now)
			_perf_n += 1
		if _frames >= _perf_frames:
			var _avg := _perf_sum / maxf(float(_perf_n), 1.0)
			# 纯 ASCII 输出：避免中文在外部脚本/PowerShell 读取时编码错乱
			var _line := "[PERF] q=%s day=%.2f cam=%d frames=%d avg=%.1f min=%.1f max=%.1f nodes=%d draws=%d" % [
				["high", "mid", "low"][quality_mode], day_time, cam_mode, _perf_n,
				_avg, _perf_min, _perf_max,
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))]
			print(_line)
			# 同时落盘：Windows GUI 版 Godot 的 stdout 在外部不可见，必须靠文件取结果
			var _pf := FileAccess.open("res://perf_last.txt", FileAccess.WRITE)
			if _pf != null:
				_pf.store_line(_line)
				_pf.close()
			get_tree().quit()
			return
	if _fulltest:
		_fulltest_step()

	# ---- 昼夜循环（白天 → 黄昏 → 夜晚 → 黎明）----
	# V108-A：perf 基线若显式指定时段，则冻结昼夜推进 → 同一档采样期间光照恒定，可复现可对比
	if not (_perf and _auto_day >= 0.0):
		day_time = fmod(day_time + delta / DAY_LENGTH, 1.0)
	var theta := day_time * TAU
	# 太阳高度做"压扁"：正午也只到约 57°（不再 90° 垂直暴晒），全天都有斜射暖光与可见长影，
	# 更有"晒太阳"的自然接地感；同时保留深夜能沉到 -0.25（保证 night_f 满值、夜晚真黑）
	# 太阳高度做"非对称曲线"（V99）：之前是单一正弦，正午也只有 ~27° 掠射，晒不出夏日感。
	# 现在：升段(0→1)振幅 0.62 → 正午 el≈0.72（约 46°，真正的夏日高日头，影子短而硬）；
	#       降段(0→-1)振幅 0.40 → 下落更慢 → **黄金时刻/夕阳时段更长**，暖光停留更久。
	# 高度仍由 sin(theta) 驱动昼夜相位；午夜 el≈-0.30 → night_f 满值、夜晚真黑。
	var _s := sin(theta)
	var _el_t := (0.10 + 0.62 * _s) if _s >= 0.0 else (0.10 + 0.40 * _s)
	var sun_dir := Vector3(-0.42, _el_t, -0.80 - 0.18 * cos(theta)).normalized()
	var el := sun_dir.y
	var day_f := clampf((el - 0.05) / 0.30, 0.0, 1.0)
	var night_f := clampf((0.05 - el) / 0.30, 0.0, 1.0)
	var dusk_f := clampf(1.0 - day_f - night_f, 0.0, 1.0)
	# 黄金时刻权重：峰值在 el≈0.06（太阳贴近地平线），驱动暖色/低角度长影
	var golden := clampf(1.0 - absf(el - 0.06) / 0.26, 0.0, 1.0)
	var lamp_f := clampf((0.20 - el) / 0.28, 0.0, 1.0)   # 路灯/窗光提前在黄昏点亮（el<0.20 起、el<-0.08 满亮），消除"日落但灯没亮"的死区
	cur_sun_dir = sun_dir
	cur_night_f = night_f
	# 天空：AI 全景是"黄昏海岸"画 → 只在黄昏用它（晚霞与黄金时刻吻合，海平线也贴合）；
	# 白天/夜晚用程序化天空（白天正蓝、夜里星空）。之前白天也用全景 → 正午顶着晚霞，
	# 整个画面蒙奶白纱（发灰发白的真正根源），蓝色天空才配得上正午的太阳。
	if sky_pano_mat != null and sky_node != null:
		if dusk_f > 0.35 and night_f < 0.60:
			sky_node.sky_material = sky_pano_mat
			sky_pano_mat.energy_multiplier = 1.10
		else:
			sky_node.sky_material = sky_mat
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sun.look_at_from_position(Vector3(0, 40, 0), Vector3(0, 40, 0) - sun_dir)
	# 关键：参考图实测"亮度 0.79 / 过曝仅 1% / 对比 0.155"
	# = 大面积柔和光：环境光(天光)为主、阳光直射很弱 → 亮而不爆、阴影不黑
	# 夏日直射光：正午偏白暖（接近真实太阳色温 5500K），能量更足 → 晒得亮、影子硬
	sun.light_energy = 2.20 * day_f + 1.90 * dusk_f
	# 太阳色：夏日暖白 → 黄金时刻/夕阳的橙红 → 黄昏的深橙红。
	# 关键改进：夕阳不再只靠 day_f 反向插值（那样正午一偏就发橙），而是**直接用 golden 权重**，
	# 让"低角度=火红夕照"独立可控，且 golden 只在地平线附近生效、高日头仍是明亮暖白。
	var sun_summer := Color(1.0, 0.89, 0.72)   # V105：更暖的金色直射（0.94/0.82 → 0.89/0.72）——与偏青的天空环境光拉开冷暖对比，电影感 teal & orange 分级
	var sun_low := Color(1.0, 0.62, 0.30).lerp(Color(1.0, 0.46, 0.22), dusk_f * 0.7)
	sun.light_color = sun_summer.lerp(sun_low, golden * 0.92)
	sun_moon.look_at_from_position(Vector3(0, 40, 0), Vector3(0, 40, 0) + sun_dir)
	sun_moon.light_energy = 1.15 * night_f   # 0.85→1.05（V99）→1.15（V102b）：夜植压暗后月照略提，剪影不糊死
	# 天光为主，但压低总量：环境光取自天空。之前 0.82（白天）配合奶白全景 = 全画面泛白，
	# 现在白天用蓝天 + 更低的环境光，画面才通透
	# 环境光：白天靠天光（夏日暖亮），夜里**必须压到很低** —— 环境光是"夜空发灰"的元凶
	# （V98 审计：夜空亮度 0.32/0.34/0.36 偏灰，就是 0.50 的底子把夜色抬亮了）
	env_ref.ambient_light_energy = 0.16 + 0.36 * day_f + 0.10 * dusk_f   # V102：0.42→0.36，天光蓝染收敛、阳光主导（蓝天环境光把所有朝上面染蓝，降档保通透）
	env_ref.fog_light_color = Color(0.95, 0.66, 0.55).lerp(Color(0.58, 0.70, 0.85), day_f).lerp(Color(0.02, 0.03, 0.08), night_f)
	# 云：白天柔白 → 黄昏染粉金（晚霞烧云）→ 夜里暗蓝剪影
	var dusk_warm := Color(1.00, 0.72, 0.55)
	cloud_mat.set_shader_parameter("top_color", Color(1.00, 1.00, 1.00).lerp(dusk_warm, dusk_f * 0.55).lerp(Color(0.07, 0.09, 0.17), night_f))
	cloud_mat.set_shader_parameter("bot_color", Color(0.74, 0.80, 0.92).lerp(Color(1.00, 0.60, 0.48), dusk_f * 0.65).lerp(Color(0.04, 0.05, 0.11), night_f))
	cloud_mat.set_shader_parameter("alpha", lerpf(0.74, 0.08, night_f))   # V101：夜里云几乎不可见（0.30 的灰团像脏抹布，真实夜云只剩一丝轮廓）
	# 草地/沙滩夜里压暗（否则夜里草地还是艳绿色，假）
	if grass_mat != null:
		grass_mat.set_shader_parameter("night_f", night_f)   # V104：夜晚压暗已内置 shader
	sand_mat.albedo_color = Color(1, 1, 1).lerp(Color(0.26, 0.23, 0.20), night_f)      # 夜里暖暗，避免蓝灰假感
	# V103：远岛剪影仅白天可见（黄昏 AI 全景接管海平线，避免"灰板压绘画"打架）
	if island_mat != null:
		island_mat.albedo_color.a = clampf(day_f * 1.3 - 0.15, 0.0, 1.0)
	# 全局夜幕系数：收敛所有材质的边缘光（否则角色夜里像发光体）
	RenderingServer.global_shader_parameter_set("night_dim", night_f)
	# V101：AI 高模（棕榈/灌木）自带 PBR 材质不吃 night_dim → 夜里叶片亮绿像发光纸板。
	# 材质跨实例共享：记录原始 albedo，夜里统一乘暗系数（保色相只压亮度，真实夜景植被是暗剪影）
	for m in ai_night_orig:
		m.albedo_color = ai_night_orig[m] * lerpf(1.0, 0.32, night_f)   # V102b：0.20 死黑 19.8% 过头（剪影糊成黑洞），0.32 保住暗部可读
	# V106：foliage shader 的夜间压暗在 shader 内部（贴图 × tint 后再乘暗），必须单独驱动 night_f ——
	# 否则新换的 ShaderMaterial 完全不受夜暗控制，夜里棕榈/灌木依然亮绿（修 V101 老问题的升级版遗漏）。
	for fm in _foliage_cache.values():
		if fm is ShaderMaterial:
			fm.set_shader_parameter("night_f", night_f)
	ocean_mat.set_shader_parameter("day_f", day_f * (1.0 - night_f))
	ocean_mat.set_shader_parameter("night_f", night_f)        # 夜海月光倒影随夜色强弱
	ocean_mat.set_shader_parameter("sun_dir", cur_sun_dir)   # 海面太阳闪光方向（随昼夜更新）
	if paint_mat != null:
		paint_mat.set_shader_parameter("night_f", night_f)   # V104：标线夜里微回反射
	# 浪花起伏（呼吸感）
	if foam_mat != null:
		foam_mat.albedo_color.a = 0.32 + 0.20 * (0.5 + 0.5 * sin(day_time * TAU * 3.0))
	# 清理已被回收路灯的失效光源/光锥引用（防止数组无限增长）
	for i in range(lamp_lights.size() - 1, -1, -1):
		if not is_instance_valid(lamp_lights[i]):
			lamp_lights.remove_at(i)
	for i in range(lamp_cone_mats.size() - 1, -1, -1):
		if not is_instance_valid(lamp_cone_mats[i]):
			lamp_cone_mats.remove_at(i)
	for L in lamp_lights:
		if is_instance_valid(L):
			# 只点亮玩家附近的路灯（省算力，也更像真实光池）
			var d: float = L.global_position.distance_to(player.global_position)
			var near := 1.0 - clampf((d - 30.0) / 55.0, 0.0, 1.0)
			# 能量 2.6→4.2：range 加大后需要更强能量才在路面读出"亮斑"（V99）
			L.light_energy = 4.2 * lamp_f * near
			# 淡入时先亮灯罩、后铺地面，避免"啪"地一下
			L.light_specular = 0.35 + 0.65 * lamp_f
			# 立方阴影很贵：只让**最近的一盏**投影，其余关掉 → 夜里依然有影子，帧率不炸
			L.shadow_enabled = (d < 26.0)
	# 路灯下的光锥：黄昏就微微可见，夜里最明显（V105b：fade uniform 驱动软光锥）
	for cm2 in lamp_cone_mats:
		if is_instance_valid(cm2):
			cm2.set_shader_parameter("fade", 0.050 * lamp_f + 0.085 * lamp_f * lamp_f)
	if lamp_glow_mat != null:
		lamp_glow_mat.emission_energy_multiplier = 0.25 + 3.2 * lamp_f
	for wm2 in night_windows:
		wm2.albedo_color = Color(1.0, 0.88, 0.60, lamp_f * 0.9)
	# 灯塔顶灯 + 光束随夜色亮起
	for lm in lh_lamps:
		lm.emission_energy_multiplier = 2.2 * lamp_f
	if hut_glow_mat != null:
		hut_glow_mat.emission_energy_multiplier = 0.3 + 3.0 * lamp_f   # 小屋门廊灯黄昏亮起
	for bmat in lh_beam_mats:
		bmat.albedo_color.a = 0.03 + 0.06 * lamp_f   # 夜光束更淡更柔，不再盖成实心米黄楔
	if decal_mat != null:
		decal_mat.emission_energy_multiplier = 0.12 + 0.75 * lamp_f   # 夜里标线被车灯照亮
	if music != null and is_instance_valid(music):
		music.volume_db = -9.0 - 6.0 * cur_night_f
	tail_light.light_energy = 0.9 * lamp_f
	char_fill.light_energy = 0.22 * night_f   # 0.45 会把角色照成灯泡；只留一点补光保可读
	head_light.light_energy = 1.8 * night_f
	tail_mat.emission_energy_multiplier = 0.25 + 0.8 * night_f
	if bike_lamp_mat != null:
		bike_lamp_mat.emission_energy_multiplier = 0.2 + 3.2 * night_f
	# 飞鸟（双向飞、上下浮、扇翅）
	for b in birds:
		if is_instance_valid(b):
			var spd := float(b.get_meta("spd", 2.0))
			var dir := float(b.get_meta("dir", 1.0))
			var ph := float(b.get_meta("ph", 0.0))
			var by := float(b.get_meta("by", 50.0))
			b.position.x += delta * spd * dir
			b.position.y = by + sin(game_time * 1.4 + ph) * 1.3
			b.rotation.z = sin(game_time * 7.0 + ph) * 0.5
			if dir > 0.0 and b.position.x > 330.0:
				b.position.x = -330.0
			elif dir < 0.0 and b.position.x < -330.0:
				b.position.x = 330.0
	# 会动的世界：云在飘、船在行（"别是死掉的"）
	for c in clouds:
		c.position.x += 1.6 * delta
		var cph := float(c.get_meta("ph", 0.0))
		c.position.y = float(c.get_meta("by", 100.0)) + sin(game_time * 0.5 + cph) * 2.5
		var cs := 1.0 + sin(game_time * 0.3 + cph) * 0.03
		c.scale = Vector3(cs, cs, cs)
		if c.position.x > 620.0:
			c.position.x -= 1240.0
	for bt in boats:
		bt.position.z += 2.2 * delta
		bt.rotation.y += 0.05 * delta
		var bph := float(bt.get_meta("ph", 0.0))
		bt.position.y = sin(game_time * 0.8 + bph) * 0.6        # 随浪起伏
		bt.rotation.z = sin(game_time * 0.6 + bph) * 0.06       # 横摇
		if bt.position.z > 260.0:
			bt.position.z -= 900.0
			bt.position.x = -45.0 - randf() * 150.0
	# 灯塔旋转光束（昼夜都在转，夜里更亮）
	for bp in lh_beam_pivots:
		bp.rotation.y += delta * 0.5

	# 棕榈随风轻摆（"别是死掉的"）——从树根摆动，树梢幅度最大
	for p in palms:
		if is_instance_valid(p):
			var ph := float(p.get_meta("sway_ph", 0.0))
			p.rotation.z = sin(game_time * 1.1 + ph) * 0.04
			p.rotation.x = cos(game_time * 0.8 + ph) * 0.022
	# 灌木 / 遮阳伞也随风轻摆（幅度更小），整个世界一起呼吸
	for s in swayables:
		if is_instance_valid(s):
			var ph := float(s.get_meta("sway_ph", 0.0))
			var amp := float(s.get_meta("sway_amp", 0.02))
			s.rotation.z = sin(game_time * 1.3 + ph) * amp

	# 必须包含 _stress：此前漏了它 → --stress 模式下游戏从未开始（障碍/鱼/场景恒为 0），
	# 压力测试一直在空转，完全没有覆盖到真实游玩逻辑（这正是"测试全绿但仍有 bug"的原因）
	if (_verify or _autoshot or _fulltest or _stress or _perf) and _frames == 30 and not started:
		_start_game()
	if _shot and _frames == _shot_frame:
		# 真正渲染一帧后抓成 PNG（自检用，不会弹任何窗口）
		await get_tree().create_timer(0.08).timeout
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("res://shot.png")
			print("[SHOT] saved ", img.get_size())
		else:
			print("[SHOT] 抓图失败：viewport 无图像")
	# V108-A 修复：--perf 也消费 --autocam/--autoday。
	# 此前只判 (_autoshot or _shot)，导致 perf 基线 8 档实际全是"同一时刻同一机位"，
	# 只有画质档在变 → 数据看似有 8 档、实则 3 档有效（自查发现的假象）。
	if (_autoshot or _shot or _perf) and _frames == 2:
		cam_mode = _auto_cam
		if _auto_day >= 0.0:
			day_time = _auto_day
		_apply_camera_mode()
	if _autoshot and _frames == 240:
		# 窗口模式自检：真正渲染一帧 → 存图 → 自动退出（全程无需操作）
		# 注意：不论是否已 game_over 都抓图并退出，否则撞车发生在 240 帧前会既不存图也不退出 → 进程挂死（验证阻塞）
		await get_tree().create_timer(0.08).timeout
		var img2 := get_viewport().get_texture().get_image()
		if img2 != null:
			img2.save_png("res://%s.png" % _auto_name)
			print("[AUTOSHOT] saved ", img2.get_size())
		get_tree().quit()
	if _autoshot and _frames == 360:
		# 兜底：万一 240 帧逻辑异常未退出，强制存图+退出，绝不挂死验证流程
		var img3 := get_viewport().get_texture().get_image()
		if img3 != null:
			img3.save_png("res://%s.png" % _auto_name)
		print("[AUTOSHOT] fallback quit at 360")
		get_tree().quit()
	if _verify and _frames == 300:
		print("[VERIFY] 位置=", player.global_position, " 分数=", roundf(score),
			" 障碍=", obstacles.size(), " 鱼=", fishes.size(), " 树=", scenery.size(),
			" 速度=", snappedf(-player.linear_velocity.z, 0.1))
	if _verify and not _stress and _frames == 350 and not game_over:
		_crash()          # 自验撞车路径
	if _stress:
		# 长局无敌 + 周期性强制重开，循环压测 reload 路径（实测最易出 bug 的地方）
		if _frames % 1000 == 0:
			print("[STRESS] 帧=", _frames, " 累计重开=", _stress_runs, " 子物体=", get_child_count(),
				" 障碍=", obstacles.size(), " 鱼=", fishes.size(), " 场景=", scenery.size(),
				" 路灯光=", lamp_lights.size(), " 分数=", roundf(score),
				" 电量=", snappedf(battery, 0.1), " 时段=", _phase_name())
		# 周期性扰动：切换机位 / 画质档 / 描边，压测这些玩家可操作的代码路径
		if _frames > 0 and _frames % 1500 == 0:
			cam_mode = (cam_mode + 1) % 4
			_apply_camera_mode()
		if _frames > 0 and _frames % 2000 == 0:
			quality_mode = (quality_mode + 1) % 3
			_apply_quality()
		if _frames > 0 and _frames % 2500 == 0:
			_toggle_outline()
		# 强制把每局推进到深夜星空段（night_f>0.85 → 切星空 shader），确保该切换每次都压到
		if _frames == 1500:
			day_time = 0.78
		# 一局跑到约 2000 帧（含深夜星空段）强制重开，循环压测 reload 路径
		# （用户上报 bug 的重灾区）；电量耗尽路径会自然触发 _crash(-1) 同样重开
		if not game_over and _frames >= 2000:
			_crash(-3)
		# 死亡后自动重开（deferred 避免中途释放节点），重开计数累加
		if game_over and _frames > 120:
			_stress_runs += 1
			if _stress_runs >= 6:
				print("[STRESS] 完成 ", _stress_runs, " 次重开压测，干净退出")
				get_tree().quit()
				return
			_reloading = true
			get_tree().call_deferred("reload_current_scene")
	if _verify and _frames == 390:
		print("[VERIFY2] game_over=", game_over, " best=", best)
	if _verify and _frames == 400:
		# 自检：依次切换 4 个机位，确认相机逻辑不炸
		cam_mode = (cam_mode + 1) % 4
	if _verify and _frames in [420, 440, 460]:
		cam_mode = (cam_mode + 1) % 4
	if _verify and _frames == 480:
		print("[SELFTEST] 机位切换完成 cam_mode=", cam_mode,
			" 子物体数=", get_child_count(),
			" 障碍=", obstacles.size(), " 场景=", scenery.size(), " 鱼=", fishes.size(),
			" 路灯光=", lamp_lights.size(), " 分数=", roundf(score),
			" 距离分=", roundf(max_dist), " 奖励分=", roundf(bonus_score),
			" 电量=", roundf(battery))

	if not started:
		if Input.is_action_just_pressed("ui_accept"):
			_start_game()
		return
	if game_over:
		# V108-B：撞击后先留在 HIT 表现期（慢动作 + 羽毛四溅），再转 GAME_OVER
		if pstate == PState.HIT:
			pstate_time += delta
			if pstate_time >= 0.30:
				_set_pstate(PState.GAME_OVER)
		_camera_update(delta)
		if Input.is_key_pressed(KEY_R) or Input.is_action_just_pressed("ui_accept"):
			Engine.time_scale = 1.0
			_reloading = true
			# 必须延迟到物理步之外再重载，否则节点在 _physics_process 中途被释放 → 刷 !is_inside_tree 错
			get_tree().call_deferred("reload_current_scene")
		return

	game_time += delta
	var vz := player.linear_velocity.z
	var forward_speed := -vz

	# 真实物理：持续施力前进
	if forward_speed < _max_speed():
		player.apply_central_force(Vector3(0, 0, -MASS * ACCEL))

	# 切换视角（C 键，4 机位）
	var ck := Input.is_key_pressed(KEY_C)
	if ck and not bPrevCam:
		cam_mode = (cam_mode + 1) % 4
		_apply_camera_mode()
	bPrevCam = ck

	# 左右转向（更跟手）
	var steer := 0.0
	if Input.is_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"):
		steer -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"):
		steer += 1.0
	var lv := player.linear_velocity
	lv.x = lerpf(lv.x, steer * STEER_SPEED, 0.22)
	player.linear_velocity = lv
	steer_sm = lerpf(steer_sm, steer, 0.12)
	# 转向侧倾：用收敛基准 _z_base 存"纯转向分量"，再叠加慢速蛇形摇摆，避免每帧累加漂移
	_z_base = lerpf(_z_base, -steer * 0.16, 0.15)
	visual.rotation = Vector3(0, 0, _z_base + sin(game_time * 1.15) * 0.03)

	# 跳跃（真实冲量 + 输入缓冲：落地前 0.14s 内按跳也能触发，操作更跟手）
	jump_buffer = maxf(jump_buffer - delta, 0.0)
	if Input.is_action_just_pressed("ui_accept"):
		jump_buffer = 0.14
	if ground_check.is_colliding() and jump_buffer > 0.0:
		player.apply_central_impulse(Vector3(0, MASS * JUMP_SPEED, 0))
		sfx_jump.play()
		jump_buffer = 0.0
		_set_pstate(PState.JUMP_START)   # V108-B：进入起跳状态（驱动压身/展翅）

	# 骑行动画
	var spin := forward_speed * delta / 0.34
	wheel_f.rotate_x(spin)
	wheel_b.rotate_x(spin)
	var phase := game_time * maxf(forward_speed * 0.32, 4.0)
	crank_a.rotation = Vector3(phase, 0, 0)
	crank_b.rotation = Vector3(phase + PI, PI, 0)
	# 骑行生命感：整组骑行台随蹬踏"活"起来（AI 模型是焊死网格，无法单独转肢体，
	# 故用全身节奏运动把"钉在轮子上的雕像"变成"在踩车的人"）
	var cadence := maxf(forward_speed / MAX_SPEED, 0.05)
	# 上下颠：双谐波（蹬踏主频 + 身体起伏），振幅随速度略增 —— 这是"在踩车"最直观的信号
	var bob := sin(phase * 2.0) * (0.07 + 0.05 * cadence) + sin(phase) * 0.025
	# 前后泵动：踩踏时身体随踏板前后微微摆动
	var pump := sin(phase) * 0.045
	# 蛇形摇摆：自行车手本能地左右微摆，低频、慢
	var weave := sin(game_time * 1.15) * 0.035
	# 高速路面细颤：速度越快越明显的贴地微震（呼吸/活物感）
	var buzz := sin(game_time * 27.0) * 0.012 * cadence
	visual.position = Vector3(weave, -0.62 + bob + buzz, pump)
	# V108-B：状态机推进（grounded 提前一次采样，状态机与动画共用，避免重复射线）
	var grounded := ground_check.is_colliding()
	_update_pstate(delta, grounded, steer)
	# V108-C：角色姿态动画（AI 鹈鹕身体相对车架的俯仰/侧倾/抬升）
	_update_body_pose(forward_speed)
	# V109-C：骨架层动画（头回看 / 翅扇动 / 腿蹬踏 / 尾摆动）——与整身姿态层叠加
	if ai_rig != null and is_instance_valid(ai_rig):
		if _rig_demo != "":
			ai_rig.demo_pose(_rig_demo)      # 调试：固定姿态（离线审查极端动作的形变）
		elif not _rig_frozen:
			ai_rig.pose_bones(delta, phase,
				clampf(forward_speed / MAX_SPEED, 0.0, 1.0), grounded, pstate, pstate_time)
	# 高速前倾 + 空中抬头：用姿态变化补出速度感
	var lean := deg_to_rad(-4.0) * clampf(forward_speed / MAX_SPEED, 0.0, 1.0)
	if not grounded:
		lean += deg_to_rad(5.0)
	visual.rotation.x = lerpf(visual.rotation.x, lean, 0.10)
	# 蹬踏与曲柄同步（脚蹬动作，加大摆幅更明显）
	var pedal := sin(phase)
	leg_l.rotation = Vector3(pedal * 0.6, 0, 0)
	leg_r.rotation = Vector3(sin(phase + PI) * 0.6, 0, 0)
	# 翅膀：着地时前伸"扶车把"，腾空时展开滑翔（解决"僵硬/没有骑车动作"）
	if grounded and not was_grounded:
		squash = 1.0                    # 落地缓冲：轻微下蹲
	was_grounded = grounded
	squash = maxf(squash - delta * 4.5, 0.0)
	visual.scale = Vector3(1.0 + squash * 0.10, 1.0 - squash * 0.14, 1.0 + squash * 0.10)
	var flutter := sin(game_time * 9.0) * 0.18
	if grounded:
		# 翅膀前伸、微微下垂去扶车把，并带轻微颤动
		wing_l.rotation.x = lerpf(wing_l.rotation.x, 0.95, 0.12)
		wing_l.rotation.z = lerpf(wing_l.rotation.z, 0.10 + flutter, 0.15)
		wing_r.rotation.x = lerpf(wing_r.rotation.x, 0.95, 0.12)
		wing_r.rotation.z = lerpf(wing_r.rotation.z, -0.10 - flutter, 0.15)
	else:
		# 腾空展翅滑翔
		wing_l.rotation.x = lerpf(wing_l.rotation.x, 0.10, 0.12)
		wing_l.rotation.z = lerpf(wing_l.rotation.z, 1.25, 0.15)
		wing_r.rotation.x = lerpf(wing_r.rotation.x, 0.10, 0.12)
		wing_r.rotation.z = lerpf(wing_r.rotation.z, -1.25, 0.15)
	# V108-C：围巾飘动随速度增强，起跳/空中额外上扬（角色"活"的细节）
	var scarf_amp := 0.05 + 0.09 * clampf(forward_speed / MAX_SPEED, 0.0, 1.0)
	if pstate == PState.AIRBORNE or pstate == PState.JUMP_START:
		scarf_amp += 0.10
	scarf.rotation = Vector3(sin(game_time * 3.0) * scarf_amp, 0, cos(game_time * 2.3) * scarf_amp * 1.2)

	dust.emitting = ground_check.is_colliding()

	# 计分：距离分 + 奖励分分离（以前奖励会被距离分 maxf 吃掉）
	var travelled := -player.global_position.z
	max_dist = maxf(max_dist, travelled)
	score = max_dist + bonus_score

	_follow_world()
	_spawn_logic(delta)

	# 障碍碰撞判定（手动比依赖物理信号更可靠，可防高速穿透）：
	# 玩家与障碍在水平方向足够接近且未跳起越过时才判撞车
	if started and not game_over:
		var pp := player.global_position
		for ob in obstacles:
			if not is_instance_valid(ob):
				continue
			var op: Vector3 = ob.global_position
			# 压力测试开"无敌"：专跑长局以覆盖完整昼夜 + 海量生成/回收，避免刚开局就撞死
			# （--nogod 时允许撞障碍，压测撞车+重开路径）
			if absf(pp.x - op.x) < 1.2 and absf(pp.z - op.z) < 0.95 and pp.y < 1.7:
				if not (_stress and not _nogod):
					_crash(int(ob.get_meta("kind", 0)))
				break

	_camera_update(delta)

	# 连击窗口倒计时：超时断连（这是"连击"有意义的前提 —— V98 bugfix）
	if combo > 0:
		combo_timer -= delta
		if combo_timer <= 0.0:
			if combo >= COMBO_STEP:
				_pop_text("连击结束 x%d" % combo, Color(0.7, 0.7, 0.8))
			combo = 0
			combo_timer = 0.0
	# HUD
	var spd := -player.linear_velocity.z
	max_speed_stat = maxf(max_speed_stat, spd)
	battery = maxf(battery - delta * (0.30 + spd * 0.02), 0.0)
	if battery <= 0.001 and not game_over:
		_crash(-1)   # 电量耗尽 = 强制结束本局
	lbl_score.text = str(int(score))
	lbl_fish.text = "小鱼 %d" % fish_count
	lbl_combo.text = ("连击 x%d" % combo) if combo >= 2 else ""
	if combo_bar != null:
		combo_bar.visible = combo >= 2
		combo_bar.value = clampf(combo_timer, 0.0, COMBO_WINDOW)
	lbl_stats.text = "最高  %d km/h\n里程  %.2f km\n时段  %s" % [
		int(max_speed_stat * 3.6), score / 1000.0, _phase_name()]
	battery_bar.value = battery
	# 每 250m 一个里程碑：飘字 + 回电奖励（骑得越远越需要取舍：回电=续航，但撞车就全没了）
	if max_dist >= next_milestone:
		var bonus_batt := 22.0
		battery = minf(battery + bonus_batt, 100.0)
		bonus_score += 30.0
		_pop_text("%d m 里程碑  +%d%% 电量" % [int(next_milestone), int(bonus_batt)], Color(0.55, 1.0, 0.75))
		_spawn_sparkle(player.global_position + Vector3(0, 1.2, 0))
		next_milestone += 250.0
	speed_gauge.set_speed(spd)
	speed_fx.emitting = spd > MAX_SPEED * 0.72
	if wind:
		if wind != null and is_instance_valid(wind):
			wind.volume_db = lerpf(-38.0, -10.0, clampf(spd / MAX_SPEED, 0.0, 1.0))

# ============================================================ 环境
func _build_environment() -> void:
	var we := WorldEnvironment.new()
	env_ref = Environment.new()

	var sky := Sky.new()
	sky_node = sky
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	# 白天用 AI 生成的真实全景天空（有真实积云）；夜晚切回星空 shader
	if ResourceLoader.exists("res://assets/sky_pano.png"):
		sky_pano_mat = PanoramaSkyMaterial.new()
		sky_pano_mat.panorama = load("res://assets/sky_pano.png")
		sky_pano_mat.energy_multiplier = 1.0
		sky.sky_material = sky_pano_mat
		print("[AI] 全景天空已加载")
	else:
		sky.sky_material = sky_mat
	sky.sky_material = sky_pano_mat if sky_pano_mat != null else sky_mat
	env_ref.sky = sky
	env_ref.background_mode = Environment.BG_SKY
	env_ref.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env_ref.ambient_light_sky_contribution = 1.0
	env_ref.ambient_light_energy = 0.90   # 环境光压低：1.25 会把所有东西泡成灰白（截图实测）

	env_ref.tonemap_mode = Environment.TONE_MAPPER_AGX   # 电影胶片响应：高光滚降比 ACES 更像电影
	env_ref.tonemap_exposure = 1.05

	if not _bare:
		# SDFGI 仍关：室外大场景会把光照抹平发灰。
		# V98 反转 SSR 的决定 —— 旧版关它是因为当时材质是"假光照"，开了只会拖影发糊；
		# 现在 _toon 已走完整 PBR，湿沥青/海边的屏幕空间反射是"真实感"的主要来源之一。
		env_ref.sdfgi_enabled = false
		env_ref.ssr_enabled = true
		env_ref.ssr_max_steps = 48
		env_ref.ssr_fade_in = 0.15
		env_ref.ssr_fade_out = 4.0
		env_ref.ssr_depth_tolerance = 0.22
		# 环境光遮蔽：小而紧的接触阴影（家具落地感/细节清晰度）
		env_ref.ssao_enabled = true
		env_ref.ssao_radius = 0.32
		env_ref.ssao_intensity = 1.55
		env_ref.ssao_power = 1.8
		env_ref.ssao_detail = 0.6      # 细节层：把小物件/草丛的接触阴影也咬出来（"细腻"的关键）
		env_ref.ssao_light_affect = 0.0
		env_ref.ssil_enabled = true
		env_ref.ssil_radius = 4.0
		env_ref.ssil_intensity = 1.35
		env_ref.ssil_sharpness = 0.90
		env_ref.ssil_normal_rejection = 1.0   # 排除法线不匹配的样本 → 少出彩色噪点
		# 阳光辉光：只让太阳本身外溢（阈值提高 + 收紧 bloom），
		# 之前 bloom 0.16 + 阈值 1.02 会把整片亮天空都晕成白纱罩在画面上（奶白感元凶之二）
		env_ref.glow_enabled = true
		env_ref.glow_bloom = 0.10          # 更宽更柔的泛光：阳光 / 海面碎金晕开，电影感
		env_ref.glow_hdr_threshold = 1.28  # V105b：1.15 时黄金时刻直视太阳糊成一坨白斑，抬高阈值只留真正的高光核心
		env_ref.glow_intensity = 0.36      # V105b：0.45 泛光过浓，太阳周边一圈白雾感，收紧后高光更"结实"
		env_ref.glow_map_strength = 0.7
		env_ref.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT  # 柔光混合：晕开但不发白（曾因 bloom 过曝发灰，这里守住）

		# 空气透视轻雾（保留）：远处自然淡出、有纵深
		env_ref.fog_enabled = true
		env_ref.fog_light_color = Color(0.58, 0.70, 0.85)   # 白天冷调雾色（运行时随昼夜覆盖）
		env_ref.fog_density = 0.0006          # 轻雾：远处给一点空气透视，但不再把远景吞掉
		env_ref.fog_aerial_perspective = 0.5
		env_ref.fog_sky_affect = 0.0          # 天空（AI 全景）不吃雾，海平线保持清晰
		env_ref.fog_sun_scatter = 0.12        # 雾里的太阳晕：远处天边一圈暖光（V100：0.20→0.12，收掉白天泛白）

		# 体积雾 + 体积光（god rays / 大气光柱）：低密度短程，只让阳光从云隙 / 地平线斜插进场景，
		# 是"顶级电影感"的关键。密度刻意压低 + sky_affect 小，绝不回到之前"灰蒙白纱"的坑。
		env_ref.volumetric_fog_enabled = true
		env_ref.volumetric_fog_density = 0.005   # V100b：0.008 时海平面仍有明显白雾带（掠射穿雾路径长），0.005 保 god rays 去白纱
		env_ref.volumetric_fog_albedo = Color(0.82, 0.86, 0.95)  # 冷调薄雾
		env_ref.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
		env_ref.volumetric_fog_emission_energy = 0.0
		env_ref.volumetric_fog_anisotropy = 0.7
		env_ref.volumetric_fog_length = 80.0
		env_ref.volumetric_fog_detail_spread = 2.0
		env_ref.volumetric_fog_ambient_inject = 0.5
		env_ref.volumetric_fog_sky_affect = 0.30
		env_ref.volumetric_fog_gi_inject = 0.0

		# 胶片调色：向参考图实测值靠（亮度↑ 对比↓↓ 饱和↓）
		env_ref.adjustment_enabled = true
		env_ref.adjustment_brightness = 1.0
		env_ref.adjustment_contrast = 1.10      # 1.18 把草/天都推到过饱和霓虹感；收回，保自然
		env_ref.adjustment_saturation = 1.06    # 1.25 → 草地发霓虹绿、天空过饱和；降到接近中性

	we.environment = env_ref
	add_child(we)
	_apply_quality()   # 应用默认画质档（Q 键可切）

	sun = DirectionalLight3D.new()
	sun.light_energy = 2.4
	sun.light_color = Color(1.0, 0.70, 0.46)      # 黄昏暖橙
	sun.shadow_enabled = true
	# V99 阴影重做：之前只用默认单级阴影贴图 + max_distance 130，
	# 近处阴影和远处阴影共用一张图 → 近处也不够锐利，且 130m 外直接没影子（影子"断掉"很假）。
	# 现在用 **4 级 CSM（Cascaded Shadow Map）**：把视锥切成 4 段，近处给高精度、远处覆盖更远。
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	# ⭐ V100 真 bug 修复：Godot 4 的 split_1/2/3 是 max_distance 的【比例 0~1】，不是米！
	# V99 写成 12/45/110 → 阴影相机数学崩坏 → 全场景零阴影（A/B 默认单级阴影实测有影，锁定此因）。
	# 换算（max 260m）：0.10→26m / 0.30→78m / 0.60→156m，近处高精度、远处全覆盖。
	sun.directional_shadow_split_1 = 0.10    # 最近一段覆盖 26m → 角色/近处物体阴影极锐
	sun.directional_shadow_split_2 = 0.30
	sun.directional_shadow_split_3 = 0.60
	sun.directional_shadow_max_distance = 260.0   # 130→260：远处也有影子，不会在中途"断掉"
	sun.directional_shadow_blend_splits = true   # 段与段之间平滑过渡，避免分层可见的硬边
	sun.directional_shadow_fade_start = 0.92
	sun.shadow_blur = 1.35            # 2.0→1.35：夏日阳光硬，柔化少一点更" crisp"（CSM 已自带软化）
	sun.shadow_bias = 0.035           # 抑制自阴影痤疮（acne）
	sun.shadow_normal_bias = 0.045    # 消除掠射角自阴影条纹
	sun.shadow_transmittance_bias = 0.12
	sun.shadow_opacity = 0.92         # 阴影不是纯黑：留一点天光渗透，更自然
	sun.light_angular_distance = 0.0  # V100：0.6 是"太阳盘面角直径(弧度)"，0.6rad≈34° → 半影把所有阴影彻底糊没（全程无影的真凶！真实太阳仅0.0093rad；0=锐利硬影）
	sun.light_volumetric_fog_energy = 1.0   # 阳光体积光柱（god rays）：配合 env 体积雾，从地平线/云隙斜插进场景
	add_child(sun)
	# 太阳低垂在前进方向右前方：长影子 + 逆光暖轮廓（对齐参考图黄昏光）
	sun.look_at_from_position(Vector3(0, 40, 0), Vector3(-0.40, -0.22, 0.89))

	# 相机侧补光：改成天空的冷色反弹光（原来 0.55 的粉色常亮光会把阳光的方向感冲淡）
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.28
	fill.light_color = Color(0.78, 0.85, 1.0)
	fill.shadow_enabled = false
	add_child(fill)
	fill.look_at_from_position(Vector3(0, 40, 0), Vector3(0.15, -0.35, -0.55))

	# 月光（夜晚的冷色定向光，与太阳相对）
	sun_moon = DirectionalLight3D.new()
	sun_moon.light_color = Color(0.58, 0.70, 0.98)   # 偏蓝的月色（更"夜"，别偏绿）
	sun_moon.shadow_enabled = true
	sun_moon.shadow_blur = 2.0
	sun_moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun_moon.directional_shadow_max_distance = 200.0
	sun_moon.shadow_opacity = 0.75      # 月影比日影淡（大气散射），别和白天一样黑
	sun_moon.light_energy = 0.0
	sun_moon.light_volumetric_fog_energy = 0.6   # 月光体积光柱（夜晚淡淡一道）
	add_child(sun_moon)

func _build_world() -> void:
	# ---- 草地（跟随玩家，带贴图）----
	grass = Node3D.new()
	add_child(grass)
	var gm := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(234, 2000)   # 草地只铺路面右侧（x -12..+222），不再盖住海
	# 大尺度色调斑驳：细分 + 双频柏林噪声顶点色，破除"一块死平绿布"的塑料感（审计帧最大短板）
	plane.subdivide_width = 30
	plane.subdivide_depth = 240
	var garr := plane.get_mesh_arrays()
	var gverts: PackedVector3Array = garr[Mesh.ARRAY_VERTEX]
	var gnoise := FastNoiseLite.new()
	gnoise.noise_type = FastNoiseLite.TYPE_PERLIN
	gnoise.seed = 11
	gnoise.frequency = 0.018
	var gnoise2 := FastNoiseLite.new()
	gnoise2.noise_type = FastNoiseLite.TYPE_PERLIN
	gnoise2.seed = 29
	gnoise2.frequency = 0.075
	var gcols := PackedColorArray()
	gcols.resize(gverts.size())
	for gi in gverts.size():
		var gv: Vector3 = gverts[gi]
		var npatch := gnoise.get_noise_2d(gv.x, gv.z)   # 大斑块（明暗草丛）
		var nfine := gnoise2.get_noise_2d(gv.x, gv.z)   # 细碎起伏
		var bright := 1.0 + npatch * 0.30 + nfine * 0.09   # V102：0.20→0.30，斑块对比加大（右侧大草地不再"平绿布"）
		var warm := nfine * 0.5 + npatch * 0.5          # 有的斑块偏暖黄绿（晒干草），有的偏冷深绿
		gcols[gi] = Color(clampf(bright * (1.0 + warm * 0.16), 0.45, 1.38),
			clampf(bright, 0.45, 1.38),
			clampf(bright * (1.0 - warm * 0.20), 0.45, 1.38))
	garr[Mesh.ARRAY_COLOR] = gcols
	var gmesh := ArrayMesh.new()
	gmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, garr)
	gm.mesh = gmesh
	# V104：草地换程序化着色器（shaders/grass.gdshader）——风扫草浪沿路流动、
	#   大尺度干湿草皮色差、近路枯草带、高频颗粒；几何顶点色斑驳保留（相乘叠加）。
	#   夜晚压暗逻辑从 main.gd 搬进 shader（night_f uniform）。
	grass_mat = ShaderMaterial.new()
	grass_mat.shader = load("res://shaders/grass.gdshader")
	grass_mat.set_shader_parameter("albedo_tex", load("res://assets/grass_hd.png" if ResourceLoader.exists("res://assets/grass_hd.png") else "res://assets/grass.png"))   # V106：2048 增强版（去水印）
	grass_mat.set_shader_parameter("normal_tex", load("res://assets/grass_normal.png"))
	grass_mat.set_shader_parameter("tint", Color(0.50, 0.62, 0.44))
	grass_mat.set_shader_parameter("uv_scale", Vector2(40, 200))   # V105：26/120→40/200 贴图密度×1.6（草叶细节从 61px/m 升到 ~97px/m，配合各向异性不再糊）
	grass_mat.set_shader_parameter("night_f", 0.0)
	gm.material_override = grass_mat
	gm.position.y = -0.05
	gm.position.x = 112.5   # 草地左边缘收到 x=-4.5（路缘）：左侧全是沙+海，不再被草盖住
	grass.add_child(gm)
	var gbody := StaticBody3D.new()
	var gcol := CollisionShape3D.new()
	var gshape := BoxShape3D.new()
	gshape.size = Vector3(420, 1.0, 2000)
	gcol.shape = gshape
	gcol.position.y = -0.5
	gbody.add_child(gcol)
	grass.add_child(gbody)

	# 黄昏沙滩（路左侧，对齐参考图海岸线）
	var sand := MeshInstance3D.new()
	var sand_plane := PlaneMesh.new()
	sand_plane.size = Vector2(7.0, 2000)
	sand.mesh = sand_plane
	sand_mat = StandardMaterial3D.new()
	sand_mat.albedo_texture = load("res://assets/sand.png")   # AI 生成贴图
	sand_mat.uv1_scale = Vector3(8, 90, 1)
	sand_mat.albedo_color = Color(0.86, 0.72, 0.50)   # 更暖的沙色（之前偏粉白）
	sand_mat.normal_enabled = true
	sand_mat.normal_texture = load("res://assets/sand_normal.png")
	sand_mat.normal_scale = 0.8
	sand_mat.roughness = 1.0
	sand.material_override = sand_mat
	sand.position = Vector3(-(ROAD_HALF + 3.5), -0.02, 0)   # 沙带收窄 13m→7m：海更靠近路，骑行者余光里一直有海（海岸感）
	sand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass.add_child(sand)

	# 海面（波浪 shader，低粗糙度吃太阳反光）
	var ocean := MeshInstance3D.new()
	var ocean_plane := PlaneMesh.new()
	ocean_plane.size = Vector2(1986, 2200)
	ocean.mesh = ocean_plane
	var ocean_mat_inst := ShaderMaterial.new()
	ocean_mat_inst.shader = load("res://shaders/ocean.gdshader")
	ocean.material_override = ocean_mat_inst
	ocean_mat = ocean_mat_inst
	ocean_mat.set_shader_parameter("wave_height", 0.38)   # 法线扰动强度（略加大：海更有呼吸感）
	ocean.position = Vector3(-1004.4, 0.02, 0)   # 右缘 -11.4：贴着新沙带外缘(沙带 -11.5..-4.5)，海进入画面视野
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass.add_child(ocean)

	# 岸边浪花线（参考图海岸线白色泡沫）
	var foam := MeshInstance3D.new()
	var foam_plane := PlaneMesh.new()
	foam_plane.size = Vector2(2.4, 2200)
	foam.mesh = foam_plane
	var foam_mat_inst := StandardMaterial3D.new()
	foam_mat_inst.albedo_color = Color(1, 1, 1, 0.45)
	foam_mat_inst.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foam_mat_inst.roughness = 0.6
	foam.material_override = foam_mat_inst
	foam_mat = foam_mat_inst
	foam.position = Vector3(-11.3, 0.10, 0)   # 浪花贴着沙滩与海面交界线（水际线随沙带收窄移到 -11.3）
	foam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass.add_child(foam)

	# ---- 大气浮尘 / 海沫微粒：阳光里飘动的微光，给画面加景深与"活着"的魔法感（不新建贴图资源，运行期用渐变纹理）----
	var motes := GPUParticles3D.new()
	motes.amount = 240
	motes.lifetime = 7.5
	motes.emitting = true
	motes.visibility_aabb = AABB(Vector3(-70.0, -3.0, -70.0), Vector3(140.0, 34.0, 140.0))
	var mpm := ParticleProcessMaterial.new()
	mpm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mpm.emission_box_extents = Vector3(36.0, 8.0, 46.0)
	mpm.direction = Vector3(0.12, 1.0, 0.06)
	mpm.spread = 22.0
	mpm.initial_velocity_min = 0.18
	mpm.initial_velocity_max = 0.55
	mpm.gravity = Vector3(0.0, 0.04, 0.0)
	mpm.linear_accel_min = -0.03
	mpm.linear_accel_max = 0.03
	mpm.scale_min = 0.05
	mpm.scale_max = 0.18
	mpm.angle_min = 0.0
	mpm.angle_max = 360.0
	var mgrad := Gradient.new()
	mgrad.add_point(0.0, Color(1.0, 0.98, 0.92, 0.95))
	mgrad.add_point(0.55, Color(1.0, 0.96, 0.86, 0.40))
	mgrad.add_point(1.0, Color(1.0, 0.96, 0.86, 0.0))
	# 注意：Godot 4.7 的 ParticleProcessMaterial.color_ramp 是 Texture2D 类型（不是 Gradient），
	# 这里不接 color_ramp，改用下方材质 albedo_texture（径向渐变软点）+ 加法混合做柔和微粒。
	var mgtex := GradientTexture2D.new()
	mgtex.gradient = mgrad
	mgtex.fill = GradientTexture2D.FILL_RADIAL
	mgtex.width = 64
	mgtex.height = 64
	var mmat := StandardMaterial3D.new()
	mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mmat.albedo_color = Color(1.0, 0.97, 0.90, 1.0)
	mmat.albedo_texture = mgtex
	mmat.emission_enabled = true
	mmat.emission = Color(1.0, 0.95, 0.85)
	mmat.emission_energy_multiplier = 0.55
	mmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	motes.material_override = mmat
	grass.add_child(motes)

	# ---- 道路（跟随玩家：真实沥青贴图 + 虚线，打包成 road_group 一起 treadmill）----
	road_group = Node3D.new()
	add_child(road_group)
	var road := MeshInstance3D.new()
	road.mesh = load("res://assets/road_surface.obj")
	# V104：路面彻底换程序化着色器（shaders/road.gdshader）——
	#   贴图 UV 每帧随玩家位移滚动（treadmill 下纹理真正流动，不再"冻结传送带"），
	#   叠加三层细节：大尺度老化色斑/光影流动、轮迹磨光带/积水洼/油渍/裂缝/修补条/路缘土污、高频颗粒。
	road_shader_mat = ShaderMaterial.new()
	road_shader_mat.shader = load("res://shaders/road.gdshader")
	road_shader_mat.set_shader_parameter("albedo_tex", load("res://assets/asphalt_hd.png" if ResourceLoader.exists("res://assets/asphalt_hd.png") else "res://assets/asphalt.png"))   # V106：2048 增强版（去水印）
	road_shader_mat.set_shader_parameter("normal_tex", load("res://assets/asphalt_normal.png"))
	road_shader_mat.set_shader_parameter("tint", Color(0.78, 0.78, 0.78))
	road_shader_mat.set_shader_parameter("scroll", 0.0)
	road.material_override = road_shader_mat
	road_group.add_child(road)

	# （V104 起轮胎磨痕不再用几何叠层：两条恒定宽度的半透明暗带已搬进 shader 做成
	#   带羽化渐变 + 粗糙度分区 + 沿路深浅起伏的"轮迹磨光带"，质感高一档且无 z-fighting 风险）

	var dashes := MeshInstance3D.new()
	dashes.mesh = load("res://assets/road_dashes.obj")
	# V104：标线换磨损着色器（漆面剥落露沥青底 + 夜间微回反射），替代恒定色 toon
	paint_mat = ShaderMaterial.new()
	paint_mat.shader = load("res://shaders/road_paint.gdshader")
	paint_mat.set_shader_parameter("paint_col", Color(0.86, 0.86, 0.82))
	paint_mat.set_shader_parameter("night_f", 0.0)
	dashes.material_override = paint_mat
	dashes.position.y = 0.015   # V104c：抬高 1.5cm 消除与路面共面的深度冲突隐患（视觉无感）
	road_group.add_child(dashes)
	dashes_node = dashes   # V104：treadmill 中做循环滚动（虚线世界坐标静止 = 相对玩家向后飞）

	var lines := MeshInstance3D.new()
	lines.mesh = load("res://assets/road_lines.obj")
	lines.material_override = paint_mat   # V104：边线共用同一磨损材质
	lines.position.y = 0.015   # V104c：同虚线，消除与路面共面隐患
	road_group.add_child(lines)

	# V103：路缘石（路面两侧的混凝土收边条——柏油"完工"的关键一笔，跟着 road_group 一起 treadmill）
	var curb_mat := _toon(Color(0.58, 0.58, 0.55), {"roughness": 0.92, "spec_strength": 0.05})
	for side in [-1.0, 1.0]:
		var curb := MeshInstance3D.new()
		var cbm := BoxMesh.new()
		cbm.size = Vector3(0.26, 0.16, 6000.0)
		curb.mesh = cbm
		curb.position = Vector3(side * (ROAD_HALF + 0.16), 0.062, -2800.0)
		curb.material_override = curb_mat
		road_group.add_child(curb)

	# ---- 远景（山 + 云，跟随地平线）----
	backdrop = Node3D.new()
	add_child(backdrop)
	# 远山/海岸线现已由 AI 全景天空（sky_pano.png，含海平线小镇/山丘/灯塔/帆船）
	# 作为环境背景统一提供；此处不再叠加 3D 山丘/小镇剪影，避免与绘画海岸线重复、更干净。
	# V103：海上远岛 + 右侧远岸剪影（仅白天可见，黄昏全景接管时淡出）——夏日海平线不再空无一物
	island_mat = StandardMaterial3D.new()
	island_mat.albedo_color = Color(0.52, 0.60, 0.68, 1.0)   # V103b：压得更低更霾（高远山只剩一条霾色轮廓）
	island_mat.roughness = 1.0
	island_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # 恒定剪影色（大气透视色），不随光照变化
	island_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var island_spec := [[-720.0, -260.0, 300.0, 13.0], [-1000.0, 140.0, 400.0, 17.0], [-1300.0, -560.0, 480.0, 21.0], [1000.0, -420.0, 620.0, 12.0]]
	for spec in island_spec:
		var isl := MeshInstance3D.new()
		var ibm := BoxMesh.new()
		ibm.size = Vector3(spec[2], spec[3], 30.0)
		isl.mesh = ibm
		isl.position = Vector3(spec[0], spec[3] * 0.18, spec[1])
		isl.material_override = island_mat
		backdrop.add_child(isl)
	# 云（专用 shader 的双色积云：顶白底蓝灰，占屏面积大，值得做好）
	if cloud_mat == null:
		cloud_mat = ShaderMaterial.new()
		cloud_mat.shader = load("res://shaders/cloud.gdshader")
		cloud_mat.set_shader_parameter("alpha", 0.72)
		cloud_mat.set_shader_parameter("puff_radius", 9.0)
	for i in range(28):
		var cloud := Node3D.new()
		var pr := 5.0 + randf() * 9.0            # 每团云的泡半径（大小不一更自然）
		for j in range(4):
			var puff := MeshInstance3D.new()
			var s := SphereMesh.new()
			s.radius = pr * (0.7 + randf() * 0.5)
			s.height = s.radius * 1.55
			puff.mesh = s
			puff.material_override = cloud_mat
			puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			puff.position = Vector3((randf() - 0.5) * pr * 2.6, (randf() - 0.5) * pr * 0.7,
									(randf() - 0.5) * pr * 1.8)
			cloud.add_child(puff)
		var cy := 70.0 + randf() * 110.0
		cloud.position = Vector3((randf() - 0.5) * 1500.0, cy, -320.0 - randf() * 600.0)
		cloud.set_meta("ph", randf() * TAU)   # 飘动相位（上下轻浮 + 轻微呼吸）
		cloud.set_meta("by", cy)
		backdrop.add_child(cloud)
		clouds.append(cloud)

	# 海上帆船（对齐参考图）——更多、且随浪起伏（上下浮 + 横摇）
	for i in range(9):
		var boat := Node3D.new()
		boat.position = Vector3(-45.0 - randf() * 150.0, 0.0, -150.0 - randf() * 480.0)
		boat.rotation = Vector3(0, randf() * TAU, 0)
		var bs := randf_range(0.9, 1.9)
		boat.scale = Vector3(bs, bs, bs)
		if boat_scene != null:
			# AI 高保真帆船（PBR 自带材质，船长归一到 ~4.5m × 随机系数）
			var binst := boat_scene.instantiate() as Node3D
			if binst != null:
				var bbb := _node_aabb(binst)
				var bs2 := 4.5 / maxf(maxf(bbb.size.x, bbb.size.z), 0.01)
				binst.scale = Vector3(bs2, bs2, bs2)
				binst.position = Vector3(-bs2 * bbb.get_center().x, -bs2 * bbb.position.y, -bs2 * bbb.get_center().z)
				boat.add_child(binst)
				_diag_aabb("BOAT", boat)
		else:
			var bm := MeshInstance3D.new()
			bm.mesh = load("res://assets/prop_boat.obj")
			bm.material_override = _toon(Color(0.96, 0.93, 0.86), {"rim_strength": 0.5, "spec_strength": 0.3})
			boat.add_child(bm)
		boat.set_meta("ph", randf() * TAU)
		backdrop.add_child(boat)
		boats.append(boat)

	# 远处灯塔（参考图剪影）+ 旋转光束（夜里扫海面，强"活着"信号）
	# 保留一座真正的 3D 灯塔（位于 AI 绘画海岸线前方），夜里旋转扫海面光束 + 顶灯，
	# 作为"活着"的动态信标；其余远景交给 AI 全景绘画。
	var lh_cfgs := [
		{"pos": Vector3(-95.0, 0.0, -430.0), "scl": Vector3(2.2, 2.4, 2.2)},
	]
	for lhc in lh_cfgs:
		var lh := Node3D.new()
		lh.position = lhc.pos
		lh.scale = lhc.scl
		var lhm := MeshInstance3D.new()
		lhm.mesh = load("res://assets/prop_lighthouse.obj")
		lhm.material_override = _toon(Color(0.97, 0.95, 0.92), {"rim_strength": 0.4})
		lh.add_child(lhm)
		# 灯室顶灯（夜里发光）
		var lamp := MeshInstance3D.new()
		var ls := SphereMesh.new()
		ls.radius = 1.4; ls.height = 2.8
		lamp.mesh = ls
		var lamp_mat := StandardMaterial3D.new()
		lamp_mat.albedo_color = Color(1.0, 0.95, 0.7)
		lamp_mat.emission_enabled = true
		lamp_mat.emission = Color(1.0, 0.92, 0.6)
		lamp_mat.emission_energy_multiplier = 0.0   # 夜晚由 night_f 点亮
		lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lamp.position = Vector3(0, 14.0, 0)
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lh.add_child(lamp)
		lh_lamps.append(lamp_mat)
		# 旋转光束（半透明锥体，绕塔扫海面）
		var beam_pivot := Node3D.new()
		beam_pivot.position = Vector3(0, 14.0, 0)
		var beam := MeshInstance3D.new()
		var bm2 := CylinderMesh.new()
		bm2.top_radius = 0.0
		bm2.bottom_radius = 4.5        # 7.0 → 4.5：光束更收束成"光柱"而非大楔
		bm2.height = 120.0             # 150 → 120：稍微收短，避免穿透太远
		beam.mesh = bm2
		var beam_mat := StandardMaterial3D.new()
		beam_mat.albedo_color = Color(1.0, 0.92, 0.65, 0.08)
		beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # 双面：更像体积光
		beam_mat.no_depth_test = false   # 关键：之前 true 让它穿透一切→ 盖成实心米黄楔；关掉后正常被遮挡
		beam.material_override = beam_mat
		beam.position = Vector3(0, 0, 60.0)
		beam.rotation.x = PI / 2.0   # 锥轴从 +Y 转到 +Z（从灯室向外伸出）
		beam_pivot.add_child(beam)
		lh.add_child(beam_pivot)
		lh_beam_pivots.append(beam_pivot)
		lh_beam_mats.append(beam_mat)
		backdrop.add_child(lh)

	# 天上飞鸟（更多、大小不一、双向飞、上下浮）
	for i in range(10):
		var bird := Node3D.new()
		var bscl := randf_range(0.6, 1.4)
		bird.scale = Vector3(bscl, bscl, bscl)
		for w in [-1.0, 1.0]:
			var bw := MeshInstance3D.new()
			var wb := BoxMesh.new()
			wb.size = Vector3(1.1, 0.03, 0.28)
			bw.mesh = wb
			bw.material_override = _toon(Color(0.15, 0.16, 0.22), {"rim_strength": 0.2})
			bw.position.x = w * 0.5
			bird.add_child(bw)
		var by := 34.0 + randf() * 44.0
		var dir := -1.0 if randf() < 0.5 else 1.0
		bird.position = Vector3((randf() - 0.5) * 320.0, by, -120.0 - randf() * 300.0)
		bird.set_meta("spd", 1.6 + randf() * 2.6)
		bird.set_meta("dir", dir)
		bird.set_meta("ph", randf() * TAU)
		bird.set_meta("by", by)
		backdrop.add_child(bird)
		birds.append(bird)

	# 远景小镇 / 城市剪影板：原先的 box 建筑与空白接景板已移除——
	# 海岸线小镇、山丘、灯塔、帆船现在统一由 AI 全景天空（sky_pano.png）绘制，
	# 既清晰又不会与绘画重复。夜晚"有人气"的暖光改由路面路灯 + 左侧灯塔顶灯承担。

# ============================================================ 玩家
func _build_player() -> void:
	player = RigidBody3D.new()
	player.mass = MASS
	player.gravity_scale = 1.0
	player.linear_damp = 0.04
	player.can_sleep = false
	var pm := PhysicsMaterial.new()
	pm.friction = 0.02
	pm.bounce = 0.0
	player.physics_material_override = pm
	player.axis_lock_angular_x = true
	player.axis_lock_angular_y = true
	player.axis_lock_angular_z = true
	player.position = Vector3(0, 0.75, 0)
	player.collision_layer = 2
	player.collision_mask = 1 | 8      # 1=地面 8=障碍
	player.contact_monitor = true       # 必须开启，body_entered 才会触发（否则撞车永远不判定）
	add_child(player)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	# 碰撞盒贴合 AI 骑行模型（车长沿 X，需转 -90° 才是前进方向）
	if ResourceLoader.exists("res://assets/ai/ai_rider.glb"):
		shape.size = Vector3(0.80, 1.60, 1.50)
	else:
		shape.size = Vector3(0.9, 1.24, 2.4)
	col.shape = shape
	player.add_child(col)

	ground_check = RayCast3D.new()
	# 必须伸到地面之下：AI 骑行模型碰撞盒半高 0.80，刚体原点停在 y≈0.80，
	# 若只探到 -0.78 则射线尖端在 y≈0.02（贴着地面上方）→ is_colliding() 恒为 false → 跳不起来
	ground_check.target_position = Vector3(0, -1.05, 0)
	ground_check.collision_mask = 1
	player.add_child(ground_check)

	player.body_entered.connect(_on_player_body_entered)

	# ---- 视觉装配（模型自带坐标：y=0 地面，前进 = -Z）----
	visual = Node3D.new()
	# 关键偏移：模型以 y=0 为地面烘焙，而刚体原点在离地 0.62m 处，
	# 少了这个偏移整个角色会悬空 62cm
	visual.position = Vector3(0.0, -0.62, 0.0)
	player.add_child(visual)

	var body_mi = _add_model("pelican_body", visual, Vector3.ZERO, _toon(Color(0.98, 0.985, 1.0), {"detail_tex": "feather", "detail_strength": 0.5, "rim_strength": 0.25}))
	pelican_parts.append(body_mi)
	var head_mi = _add_model("pelican_head", visual, Vector3.ZERO, _toon(Color(0.985, 0.99, 1.0), {"detail_tex": "feather", "detail_strength": 0.4, "rim_strength": 0.25}))
	pelican_parts.append(head_mi)
	var beak_mi = _add_model("pelican_beak", visual, Vector3.ZERO, _toon(Color(1.0, 0.72, 0.24), {"spec_strength": 0.55}))
	pelican_parts.append(beak_mi)
	var pouch_mi = _add_model("pelican_pouch", visual, Vector3.ZERO, _toon(Color(1.0, 0.80, 0.46), {"spec_strength": 0.4}))
	pelican_parts.append(pouch_mi)
	# 第一人称时这些部件会挡住视线 → 切换机位时隐藏
	fp_hide = [head_mi, beak_mi, pouch_mi]
	var tail_mi = _add_model("pelican_tail", visual, Vector3.ZERO, _toon(Color(0.96, 0.97, 1.0), {"detail_tex": "feather", "detail_strength": 0.5}))
	pelican_parts.append(tail_mi)
	# 红贝雷帽 + 红围巾（对齐参考图）
	var hat_mi := _add_model("pelican_hat", visual, Vector3.ZERO, _toon(Color(0.88, 0.15, 0.20), {"spec_strength": 0.35, "rim_color": Color(1.0, 0.72, 0.62)}))
	hat_mi.rotation = Vector3(0.06, 0, 0.09)   # 微微歪戴
	pelican_parts.append(hat_mi)
	fp_hide.append(hat_mi)
	pelican_parts.append(scarf)
	scarf = _pivot(visual, Vector3.ZERO)
	var scarf_mi := MeshInstance3D.new()
	scarf_mi.mesh = load("res://assets/pelican_scarf.obj")
	scarf_mi.material_override = _toon(Color(0.85, 0.13, 0.17), {"spec_strength": 0.3, "rim_color": Color(1.0, 0.68, 0.58)})
	_with_outline(scarf_mi, 0.008)
	scarf.add_child(scarf_mi)
	for sx in [-0.10, 0.10]:
		var eye_mi = _add_model("pelican_eye", visual, Vector3(sx, 1.78, -0.26), _toon(Color(0.10, 0.10, 0.14), {"rim_strength": 0.8, "spec_strength": 0.9, "roughness": 0.05}))
		fp_hide.append(eye_mi)
		pelican_parts.append(eye_mi)

	wing_l = _pivot(visual, Vector3(-0.28, 1.24, 0.04))
	wing_r = _pivot(visual, Vector3(0.28, 1.24, 0.04))
	pelican_parts.append(wing_l)
	pelican_parts.append(wing_r)
	var wing_mat := _toon(Color(0.97, 0.96, 0.98), {"detail_tex": "feather", "detail_strength": 0.45})
	var tip_mat := _toon(Color(0.17, 0.18, 0.24), {"rim_strength": 0.6, "rim_color": Color(1.0, 0.75, 0.6)})
	for pivot in [wing_l, wing_r]:
		var wl := MeshInstance3D.new()
		wl.mesh = load("res://assets/pelican_wing.obj")
		wl.material_override = wing_mat
		_with_outline(wl, 0.010)
		pivot.add_child(wl)
		var tip := MeshInstance3D.new()
		tip.mesh = load("res://assets/pelican_wingtip.obj")
		tip.material_override = tip_mat
		pivot.add_child(tip)

	leg_l = _pivot(visual, Vector3(-0.15, 0.94, 0.06))
	leg_r = _pivot(visual, Vector3(0.15, 0.94, 0.06))
	pelican_parts.append(leg_l)
	pelican_parts.append(leg_r)
	var leg_mat := _toon(Color(1.0, 0.66, 0.28), {"spec_strength": 0.4})
	for pivot in [leg_l, leg_r]:
		var lm := MeshInstance3D.new()
		lm.mesh = load("res://assets/pelican_leg.obj")
		lm.material_override = leg_mat
		_with_outline(lm, 0.008)
		pivot.add_child(lm)

	var tire_mat := _toon(Color(0.13, 0.13, 0.16), {"rim_color": Color(1.0, 0.8, 0.62), "rim_strength": 0.35, "spec_strength": 0.15})
	wheel_f = _pivot(visual, Vector3(0, 0.34, -0.58))
	wheel_b = _pivot(visual, Vector3(0, 0.34, 0.58))
	for pivot in [wheel_f, wheel_b]:
		var wm := MeshInstance3D.new()
		wm.mesh = load("res://assets/bike_wheel.obj")
		wm.material_override = tire_mat
		_with_outline(wm, 0.008)
		pivot.add_child(wm)
		# 白边胎（对齐参考图）
		var wall := MeshInstance3D.new()
		wall.mesh = load("res://assets/bike_whitewall.obj")
		wall.material_override = _toon(Color(0.96, 0.95, 0.90), {"spec_strength": 0.3})
		pivot.add_child(wall)
		# 辐条（金属色单独上材质，参考图能看见辐条）
		var sp := MeshInstance3D.new()
		sp.mesh = load("res://assets/bike_spokes.obj")
		sp.material_override = _toon(Color(0.82, 0.84, 0.88), {"spec_strength": 0.85, "rim_strength": 0.2, "metallic": 0.88, "roughness": 0.16})
		pivot.add_child(sp)
		if pivot == wheel_b:
			# 后飞轮（随后轮一起转）
			var cog := MeshInstance3D.new()
			cog.mesh = load("res://assets/bike_cog.obj")
			cog.material_override = _toon(Color(0.42, 0.45, 0.50), {"spec_strength": 0.7, "metallic": 0.80, "roughness": 0.28})
			pivot.add_child(cog)

	# 车筐（藤编纹理）+ 筐里的鱼（对齐参考图）
	var bk := MeshInstance3D.new()
	bk.mesh = load("res://assets/bike_basket.obj")
	var bkmat := StandardMaterial3D.new()
	bkmat.albedo_texture = load("res://assets/wicker.png")
	bkmat.roughness = 0.9
	bk.material_override = bkmat
	bk.position = Vector3(0, 0.98, -0.72)
	_with_outline(bk, 0.012)
	visual.add_child(bk)
	for i in range(2):
		var bf := MeshInstance3D.new()
		bf.mesh = load("res://assets/prop_fish.obj")
		bf.material_override = _toon(Color(0.35, 0.75, 0.95), {"rim_strength": 0.7})
		bf.scale = Vector3(0.7, 0.7, 0.7)
		bf.position = Vector3(-0.06 + i * 0.12, 1.14 + (i % 2) * 0.06, -0.70)
		bf.rotation = Vector3(-0.5 + i * 0.25, i * 1.3, 0)
		visual.add_child(bf)

	# 青绿色车架（对齐参考图）+ 橙色前叉 + 链轮
	_add_model("bike_frame", visual, Vector3.ZERO, _toon(Color(0.13, 0.55, 0.50), {"spec_strength": 0.6, "rim_color": Color(0.70, 1.0, 0.90), "metallic": 0.35, "roughness": 0.28}))
	_add_model("bike_fork", visual, Vector3.ZERO, _toon(Color(1.0, 0.58, 0.22), {"spec_strength": 0.5, "rim_color": Color(1.0, 0.8, 0.55), "metallic": 0.30, "roughness": 0.32}))
	_add_model("bike_chainring", visual, Vector3.ZERO, _toon(Color(0.35, 0.38, 0.42), {"spec_strength": 0.7, "metallic": 0.85, "roughness": 0.22}))
	_add_model("bike_chain", visual, Vector3.ZERO, _toon(Color(0.30, 0.33, 0.38), {"spec_strength": 0.7, "metallic": 0.90, "roughness": 0.30}))
	_add_model("bike_handlebar", visual, Vector3.ZERO, _toon(Color(0.55, 0.60, 0.70), {"spec_strength": 0.8, "rim_color": Color(0.85, 0.92, 1.0)}))
	_add_model("bike_seat", visual, Vector3.ZERO, _toon(Color(0.16, 0.15, 0.20), {"spec_strength": 0.5}))

	crank_a = _pivot(visual, Vector3(0, 0.30, 0.02))
	crank_b = _pivot(visual, Vector3(0, 0.30, 0.02))
	var crank_mat := _toon(Color(0.70, 0.74, 0.82), {"spec_strength": 0.8})
	var ca := MeshInstance3D.new()
	ca.mesh = load("res://assets/bike_crank.obj")
	ca.material_override = crank_mat
	_with_outline(ca, 0.006)
	crank_a.add_child(ca)
	var cb := ca.duplicate()
	crank_b.add_child(cb)
	crank_b.rotation = Vector3(PI, PI, 0)

	# ---- 轮后灰尘 ----
	dust = GPUParticles3D.new()
	dust.amount = 26
	dust.lifetime = 0.7
	dust.position = Vector3(0, 0.06, 0.72)
	var dpm := ParticleProcessMaterial.new()
	dpm.direction = Vector3(0, 0.45, 1.0)
	dpm.spread = 22.0
	dpm.initial_velocity_min = 1.2
	dpm.initial_velocity_max = 3.2
	dpm.gravity = Vector3(0, -1.5, 0)
	dpm.scale_min = 0.5
	dpm.scale_max = 1.4
	dpm.color = Color(0.88, 0.88, 0.94, 0.5)
	dust.process_material = dpm
	var dmesh := SphereMesh.new()
	dmesh.radius = 0.07
	dmesh.height = 0.14
	# 关键：必须给球体配半透明材质 + vertex_color_use_as_albedo，
	# 否则 process_material 的 color（半透明灰）不生效 → 渲染成不透明纯白小球撒一路（截图实测 bug）
	var dmat := StandardMaterial3D.new()
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.vertex_color_use_as_albedo = true
	dmat.albedo_color = Color(0.88, 0.88, 0.94, 0.42)
	dmat.roughness = 1.0
	dmesh.material = dmat
	dust.draw_pass_1 = dmesh
	visual.add_child(dust)

	# 车尾灯（夜晚发红光）+ 车头灯（对齐参考图夜景）
	tail_bulb = MeshInstance3D.new()
	var tb := SphereMesh.new()
	tb.radius = 0.05
	tb.height = 0.1
	tail_bulb.mesh = tb
	tail_mat = StandardMaterial3D.new()
	tail_mat.albedo_color = Color(0.9, 0.1, 0.08)
	tail_mat.emission_enabled = true
	tail_mat.emission = Color(1.0, 0.10, 0.05)
	tail_mat.emission_energy_multiplier = 0.3
	tail_bulb.material_override = tail_mat
	tail_bulb.position = Vector3(0, 0.95, 0.55)
	visual.add_child(tail_bulb)
	tail_light = OmniLight3D.new()
	tail_light.light_color = Color(1.0, 0.15, 0.10)
	tail_light.omni_range = 5.0
	tail_light.shadow_enabled = false
	tail_light.light_energy = 0.0
	tail_light.position = Vector3(0, 0.95, 0.62)
	visual.add_child(tail_light)
	head_light = SpotLight3D.new()
	head_light.light_color = Color(0.85, 0.90, 1.0)
	head_light.spot_range = 18.0
	head_light.spot_angle = 34.0
	head_light.shadow_enabled = false
	head_light.light_energy = 0.0
	head_light.position = Vector3(0, 1.05, -0.85)
	head_light.rotation = Vector3(deg_to_rad(-12.0), 0, 0)   # 灯束朝前下方
	visual.add_child(head_light)

	# 车头灯模型（夜晚发光，对齐参考图夜景）
	var lamp_mi := MeshInstance3D.new()
	lamp_mi.mesh = load("res://assets/bike_lamp.obj")
	bike_lamp_mat = StandardMaterial3D.new()
	bike_lamp_mat.albedo_color = Color(0.30, 0.32, 0.36)
	bike_lamp_mat.emission_enabled = true
	bike_lamp_mat.emission = Color(1.0, 0.92, 0.72)
	bike_lamp_mat.emission_energy_multiplier = 0.2
	lamp_mi.material_override = bike_lamp_mat
	lamp_mi.position = Vector3(0, 1.02, -0.80)
	visual.add_child(lamp_mi)

	# 夜间角色补光：让鹈鹕在夜里也可读（白天熄灭）
	char_fill = OmniLight3D.new()
	char_fill.light_color = Color(1.0, 0.82, 0.70)
	char_fill.omni_range = 7.0
	char_fill.shadow_enabled = false
	char_fill.light_energy = 0.0
	char_fill.position = Vector3(0, 1.6, 1.2)
	visual.add_child(char_fill)

	# --- AI 生成的 3D 鹈鹕（V109-C「脱胎换骨」：重建为带骨架蒙皮的可动角色）---
	# 旧路线：直接用 GLB 的焊死网格 → 头/翅/腿/尾全焊死，只能靠"整身颠"假装动。
	# 新路线：PelicanRig 在运行时把这块单连通网格重建为 Skeleton3D + Skin + 权重网格
	#         → 头可回看、翅可扇动、腿可蹬踏，且完整保留 AI 贴图/法线/UV。
	if USE_AI_PELICAN:
		ai_rig = PelicanRig.create("res://assets/ai/ai_pelican.glb")
		var inst: Node3D = ai_rig
		if ai_rig == null:
			# 兜底：骨架构建失败时退回原焊死网格（至少不会开天窗）
			if ResourceLoader.exists("res://assets/ai/ai_pelican.glb"):
				inst = (load("res://assets/ai/ai_pelican.glb") as PackedScene).instantiate() as Node3D
				push_warning("[AI] 骨架构建失败，退回静态网格")
		if inst != null:
			visual.add_child(inst)
			var bb: AABB = ai_rig.aabb if ai_rig != null else _node_aabb(inst)
			if bb.size.y > 0.01:
				var s := 1.30 / bb.size.y      # 归一化到骑坐高度约 1.3m
				inst.scale = Vector3(s, s, s)
				inst.position = Vector3(
					-s * bb.get_center().x,
					0.84 - s * bb.position.y,          # 底部稍沉入座垫(0.90) → "坐"而不是"站在座上"
					0.14 - s * bb.get_center().z)
				if ai_flip:
					inst.rotation.y = PI
				ai_pelican = inst
				# V108-C：记录基准变换，姿态动画只叠加偏移（不破坏原有对齐）
				ai_base_pos = inst.position
				ai_base_rot = inst.rotation
				for n in pelican_parts:
					if is_instance_valid(n):
						n.visible = false
				# AI 本体自带腿/翅膀（现已可独立动画）→ 必须藏掉程序化的腿/翅，
				# 否则出现"两套腿两对翅"的穿模 bug（V96 结论）
				for n in [leg_l, leg_r, wing_l, wing_r]:
					if is_instance_valid(n):
						n.visible = false
				if ai_rig != null:
					print("[AI] 鹈鹕骨架蒙皮已就绪  尺寸 ", bb.size, "  缩放 x%.2f  骨骼 %d 根"
						% [s, ai_rig.skeleton.get_bone_count()])
				else:
					print("[AI] 鹈鹕模型已加载（静态）  原始尺寸 ", bb.size, "  缩放 x%.2f" % s)

	# --- AI 生成的"鹈鹕骑自行车"整体模型（最高优先级：整组替换程序化角色+自行车）---
	if USE_AI_RIDER and ResourceLoader.exists("res://assets/ai/ai_rider.glb"):
		var ps2: PackedScene = load("res://assets/ai/ai_rider.glb")
		if ps2 != null:
			var inst2 := ps2.instantiate() as Node3D
			if inst2 != null:
				visual.add_child(inst2)
				var bb2 := _node_aabb(inst2)
				if bb2.size.y > 0.01:
					var s2 := 1.72 / bb2.size.y    # 整车+骑手总高约 1.72m
					inst2.scale = Vector3(s2, s2, s2)
					inst2.position = Vector3(
						-s2 * bb2.get_center().x,
						-s2 * bb2.position.y,              # 车轮贴地（visual y=0 即地面）
						-s2 * bb2.get_center().z)
					inst2.rotation.y = deg_to_rad(ai_rot)
					ai_rider = inst2
					# 隐藏程序化角色+自行车（保留头灯/尾灯/补光/尘土）
					for c in visual.get_children():
						if c == inst2 or c == char_fill or c == head_light or c == tail_light or c == dust:
							continue
						c.visible = false
					print("[AI] 骑行模型已加载  原始尺寸 ", bb2.size, "  缩放 x%.2f" % s2)

	camera = Camera3D.new()
	camera.fov = 58.0
	camera.far = 900.0
	# 电影级景深：远处轻微虚化（只虚化远景，不影响近处操作判断）
	var cattr := CameraAttributesPractical.new()
	cattr.dof_blur_far_enabled = true
	cattr.dof_blur_far_distance = 340.0   # 只虚化极远的海平线，中近景一律保持锐利（用户抱怨"模糊"）
	cattr.dof_blur_far_transition = 220.0
	cattr.dof_blur_near_enabled = false
	cattr.dof_blur_amount = 0.03
	cattr.exposure_sensitivity = 1.0
	camera.attributes = cattr
	add_child(camera)
	camera.global_position = Vector3(0, 3.2, 7.6)

	# 阳光眩光（面向太阳时的大光晕，参考图黄昏逆光）
	glare_node = MeshInstance3D.new()
	var gq := QuadMesh.new()
	gq.size = Vector2(90, 90)
	glare_node.mesh = gq
	glare_mat = StandardMaterial3D.new()
	glare_mat.albedo_texture = load("res://assets/glare.png")
	glare_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glare_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glare_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glare_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	glare_mat.no_depth_test = true
	glare_mat.albedo_color = Color(1, 1, 1, 0)
	glare_node.material_override = glare_mat
	glare_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glare_node.visible = true   # 重新启用：面向太阳时的暖光晕（用户要"阳光照射的感觉"）
	add_child(glare_node)

	# 高速风驰速度线（相机空间拉丝，对齐参考图速度感）
	speed_fx = GPUParticles3D.new()
	speed_fx.amount = 70
	speed_fx.lifetime = 0.26
	speed_fx.emitting = false
	var spm := ParticleProcessMaterial.new()
	spm.direction = Vector3(0, 0, 1)
	spm.spread = 10.0
	spm.initial_velocity_min = 16.0
	spm.initial_velocity_max = 26.0
	spm.gravity = Vector3.ZERO
	spm.scale_min = 0.6
	spm.scale_max = 1.4
	spm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	spm.emission_box_extents = Vector3(5, 3, 1)
	speed_fx.process_material = spm
	speed_fx.local_coords = true
	var smesh := BoxMesh.new()
	smesh.size = Vector3(0.02, 0.02, 0.8)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(1, 1, 1, 0.32)
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smesh.material = smat
	speed_fx.draw_pass_1 = smesh
	camera.add_child(speed_fx)
	speed_fx.position = Vector3(0, 0, -7)

# ============================================================ 工具
func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n

func _toon(c: Color, opts: Dictionary = {}) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/toon.gdshader")
	m.set_shader_parameter("base_color", c)
	m.set_shader_parameter("ramp_tex", load("res://assets/toon_ramp.png"))
	m.set_shader_parameter("rim_color", opts.get("rim_color", Color(1.0, 0.80, 0.62)))
	m.set_shader_parameter("rim_strength", opts.get("rim_strength", 0.55))
	m.set_shader_parameter("spec_strength", opts.get("spec_strength", 0.3))
	m.set_shader_parameter("detail_strength", opts.get("detail_strength", 0.0))
	# V98：可选覆盖粗糙度/金属度 —— 同一套 _toon() 也能表现出"金属/塑料/叶片/湿沥青"的差异，
	# 这是"每个物体都像同一种塑料"的关键。传 -1 表示沿用由 spec_strength 推导的默认值。
	m.set_shader_parameter("roughness_override", opts.get("roughness", -1.0))
	m.set_shader_parameter("metallic_override", opts.get("metallic", -1.0))
	if opts.has("detail_tex"):
		m.set_shader_parameter("detail_tex", load("res://assets/%s.png" % opts["detail_tex"]))
	if opts.has("stripe_v"):
		m.set_shader_parameter("stripe_v", opts["stripe_v"])
	if opts.has("translucency"):
		m.set_shader_parameter("translucency", opts["translucency"])
	return m

func _with_outline(mi: MeshInstance3D, thickness: float = 0.012) -> void:
	if outline_scale <= 0.01:
		return
	var o := MeshInstance3D.new()
	o.mesh = mi.mesh
	var om := ShaderMaterial.new()
	om.shader = load("res://shaders/outline.gdshader")
	om.set_shader_parameter("thickness", thickness * outline_scale)
	o.material_override = om
	o.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	o.visible = outline_on          # 默认隐藏，O 键可实时开
	o.set_meta("outline", true)     # 标记：_node_aabb 需跳过描边壳
	mi.add_child(o)
	outline_nodes.append(o)

# O 键：切换卡通描边（写实无描边 / 卡通勾边），画风交由玩家决定
func _toggle_outline() -> void:
	outline_on = not outline_on
	for i in range(outline_nodes.size() - 1, -1, -1):
		var n = outline_nodes[i]
		if not is_instance_valid(n):
			outline_nodes.remove_at(i)
			continue
		n.visible = outline_on
	print("[描边] ", "开" if outline_on else "关", "　节点数=", outline_nodes.size())

func _add_model(name: String, parent: Node3D, pos: Vector3, mat: ShaderMaterial, outline: float = 0.012) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = load("res://assets/%s.obj" % name)
	mi.material_override = mat
	mi.position = pos
	_with_outline(mi, outline)
	parent.add_child(mi)
	return mi

# ============================================================ 音频
func _build_audio() -> void:
	music = AudioStreamPlayer.new()
	var mstream: AudioStreamWAV = load("res://assets/music_loop.wav")
	mstream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	mstream.loop_begin = 0
	mstream.loop_end = mstream.data.size() / 2
	music.stream = mstream
	music.volume_db = -9.0
	add_child(music)
	music.play()

	wind = AudioStreamPlayer.new()
	var wstream: AudioStreamWAV = load("res://assets/wind_loop.wav")
	wstream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wstream.loop_begin = 0
	wstream.loop_end = wstream.data.size() / 2
	wind.stream = wstream
	wind.volume_db = -38.0
	add_child(wind)
	wind.play()

	sfx_jump = _sfx("sfx_jump.wav", -4.0)
	sfx_collect = _sfx("sfx_collect.wav", -2.0)
	sfx_crash = _sfx("sfx_crash.wav", 0.0)

func _sfx(fname: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load("res://assets/" + fname)
	p.volume_db = db
	add_child(p)
	return p

# ============================================================ UI（卡片式）
func _card_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 18
	sb.corner_radius_top_right = 18
	sb.corner_radius_bottom_left = 18
	sb.corner_radius_bottom_right = 18
	sb.border_width_left = 2
	sb.border_width_right = 2
	sb.border_width_top = 2
	sb.border_width_bottom = 2
	sb.border_color = border
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 12
	return sb

func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 统一描边式投影：在忙碌的 3D 背景上也能一眼看清（"界面整体都要最好"）
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.add_theme_constant_override("outline_size", 1)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	return l

func _make_button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	var sb := _card_style(Color(1.0, 0.45, 0.62), Color(1.0, 0.7, 0.85))
	sb.corner_radius_top_left = 999
	sb.corner_radius_top_right = 999
	sb.corner_radius_bottom_left = 999
	sb.corner_radius_bottom_right = 999
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	b.add_theme_stylebox_override("normal", sb)
	var hb := sb.duplicate()
	hb.bg_color = Color(1.0, 0.58, 0.72)
	b.add_theme_stylebox_override("hover", hb)
	var pb := sb.duplicate()
	pb.bg_color = Color(0.85, 0.32, 0.5)
	b.add_theme_stylebox_override("pressed", pb)
	b.add_theme_color_override("font_color", Color(1, 1, 1))
	return b

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 10        # HUD 置于最上层
	add_child(canvas)

	# 晕影
	var vig := ColorRect.new()
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vig.visible = true   # 已排除嫌疑：晕影不是过曝元凶
	var vm := ShaderMaterial.new()
	vm.shader = load("res://shaders/vignette.gdshader")
	vig.material = vm
	canvas.add_child(vig)

	# ---- V108-A：调试 HUD（左上角，默认隐藏；F3 切换 或 --debug 开启）----
	# 只在调试时显示，绝不进入正式开始界面（方案 §3.1 要求）
	debug_root = PanelContainer.new()
	debug_root.position = Vector2(16, 12)
	debug_root.add_theme_stylebox_override("panel", _card_style(Color(0.02, 0.03, 0.06, 0.76), Color(0.40, 0.90, 1.0, 0.38)))
	debug_label = _make_label("", 13, Color(0.80, 0.96, 1.0))
	debug_root.add_child(debug_label)
	debug_root.visible = _debug_hud
	canvas.add_child(debug_root)

	# ---- HUD ----
	hud_root = Control.new()
	hud_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_root.visible = false
	canvas.add_child(hud_root)

	# 左下：里程 / 最高速 / 电量（紧挨时速表，对齐参考图 HUD 布局）
	var card := PanelContainer.new()
	card.position = Vector2(168, 900.0 - 152.0)
	card.add_theme_stylebox_override("panel", _card_style(Color(0.10, 0.08, 0.16, 0.72), Color(1, 1, 1, 0.14)))
	var vbox := VBoxContainer.new()
	card.add_child(vbox)
	lbl_stats = _make_label("最高  0 km/h\n里程  0.00 km", 18, Color(0.92, 0.95, 1.0))
	vbox.add_child(lbl_stats)
	battery_bar = ProgressBar.new()
	battery_bar.min_value = 0
	battery_bar.max_value = 100
	battery_bar.value = 100
	battery_bar.show_percentage = false
	battery_bar.custom_minimum_size = Vector2(170, 12)
	var bbg := StyleBoxFlat.new()
	bbg.bg_color = Color(0.25, 0.22, 0.35)
	bbg.corner_radius_top_left = 6
	bbg.corner_radius_top_right = 6
	bbg.corner_radius_bottom_left = 6
	bbg.corner_radius_bottom_right = 6
	var bfill := bbg.duplicate()
	bfill.bg_color = Color(0.45, 0.90, 0.55)
	battery_bar.add_theme_stylebox_override("background", bbg)
	battery_bar.add_theme_stylebox_override("fill", bfill)
	vbox.add_child(battery_bar)
	hud_root.add_child(card)

	# 右上：积分 + 小鱼 + 连击（对齐参考图）
	var scard := PanelContainer.new()
	scard.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	scard.position = Vector2(-230, 20)
	scard.add_theme_stylebox_override("panel", _card_style(Color(0.10, 0.08, 0.16, 0.72), Color(1, 1, 1, 0.14)))
	var sv := VBoxContainer.new()
	scard.add_child(sv)
	lbl_score = _make_label("0", 40, Color(1, 1, 1))
	sv.add_child(lbl_score)
	lbl_fish = _make_label("小鱼 0", 18, Color(0.65, 0.9, 1.0))
	sv.add_child(lbl_fish)
	lbl_combo = _make_label("", 16, Color(1.0, 0.85, 0.4))
	sv.add_child(lbl_combo)
	# 连击窗口条：让"断连就清零"这条规则可见 —— 玩家能看到自己还剩多久可以续上
	var combo_bar := ProgressBar.new()
	combo_bar.min_value = 0.0
	combo_bar.max_value = COMBO_WINDOW
	combo_bar.value = 0.0
	combo_bar.show_percentage = false
	combo_bar.custom_minimum_size = Vector2(190, 6)
	combo_bar.visible = false
	var cbbg := StyleBoxFlat.new()
	cbbg.bg_color = Color(0, 0, 0, 0.35)
	cbbg.corner_radius_top_left = 3
	cbbg.corner_radius_top_right = 3
	cbbg.corner_radius_bottom_left = 3
	cbbg.corner_radius_bottom_right = 3
	var cbfill := cbbg.duplicate()
	cbfill.bg_color = Color(1.0, 0.80, 0.35)
	combo_bar.add_theme_stylebox_override("background", cbbg)
	combo_bar.add_theme_stylebox_override("fill", cbfill)
	sv.add_child(combo_bar)
	hud_root.add_child(scard)

	# 左下：圆形时速表（对齐参考图）
	speed_gauge = SpeedGauge.new()
	speed_gauge.position = Vector2(30, 900.0 - 148.0)
	hud_root.add_child(speed_gauge)

	# 底部中央：按键提示栏（对齐参考图）
	var hint := PanelContainer.new()
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.add_theme_stylebox_override("panel", _card_style(Color(0.10, 0.08, 0.16, 0.60), Color(1, 1, 1, 0.10)))
	hint.add_child(_make_label("V109　空格 / ↑ = 跳跃　·　A / D = 转向　·　C = 视角　·　Q = 画质　·　F3 = 调试　·　O = 描边　·　P = 截图　·　Esc = 暂停　·　M = 静音　·　R = 重来", 14, Color(1, 1, 1, 0.85)))
	hud_root.add_child(hint)

	# ---- 开始界面 ----
	start_root = Control.new()
	start_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(start_root)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.10, 0.04, 0.10, 0.30)
	start_root.add_child(dim)
	var scenter := CenterContainer.new()
	scenter.set_anchors_preset(Control.PRESET_FULL_RECT)
	start_root.add_child(scenter)
	var spanel := PanelContainer.new()
	spanel.add_theme_stylebox_override("panel", _card_style(Color(0.13, 0.10, 0.22, 0.92), Color(1.0, 0.6, 0.8, 0.5)))
	scenter.add_child(spanel)
	var sv2 := VBoxContainer.new()
	sv2.add_theme_constant_override("separation", 10)
	spanel.add_child(sv2)
	sv2.add_child(_make_label("🚲 鹈鹕骑单车", 76, Color(1.0, 0.80, 0.58)))
	sv2.add_child(_make_label("Pelican Rider 3D", 20, Color(0.85, 0.88, 1.0)))
	sv2.add_child(_make_label("黄昏海岸线 · 一只骑自行车的鹈鹕的旅途\n躲开路障 · 收集小鱼 · 看遍日夜", 17, Color(0.92, 0.9, 0.92)))
	start_best = _make_label("", 16, Color(1.0, 0.85, 0.4))
	sv2.add_child(start_best)
	var sbtn := _make_button("开 始 骑 行", 26)
	sbtn.pressed.connect(_start_game)
	sv2.add_child(sbtn)
	sv2.add_child(_make_label("空格 = 跳跃　A/D 或 ←/→ = 转向", 15, Color(0.75, 0.78, 0.9)))
	# 版本号：用于确认玩家看到的是哪一次构建（Godot 运行中改脚本不会热重载，必须关掉重开）
	sv2.add_child(_make_label("V109 · 角色骨架蒙皮（头/翅/腿/尾 真正独立运动：蹬踏/扇翅/回看）+ 状态机 + 姿态层 + 三档画质 MSAA + 调试 HUD（F3）+ 性能基线", 13, Color(0.72, 0.74, 0.88)))
	_update_start_best()

	# ---- 结束界面 ----
	over_root = Control.new()
	over_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_root.visible = false
	canvas.add_child(over_root)
	var dim2 := ColorRect.new()
	dim2.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim2.color = Color(0.10, 0.02, 0.06, 0.5)
	over_root.add_child(dim2)
	var ocenter := CenterContainer.new()
	ocenter.set_anchors_preset(Control.PRESET_FULL_RECT)
	over_root.add_child(ocenter)
	var opanel := PanelContainer.new()
	opanel.add_theme_stylebox_override("panel", _card_style(Color(0.16, 0.08, 0.14, 0.94), Color(1.0, 0.4, 0.5, 0.6)))
	ocenter.add_child(opanel)
	var ov := VBoxContainer.new()
	ov.add_theme_constant_override("separation", 10)
	opanel.add_child(ov)
	ov.add_child(_make_label("翻车了！", 52, Color(1.0, 0.45, 0.5)))
	over_stats = _make_label("", 22, Color(1, 1, 1))
	ov.add_child(over_stats)
	var obtn := _make_button("再 来 一 次", 24)
	obtn.pressed.connect(func():
		Engine.time_scale = 1.0
		get_tree().reload_current_scene())
	ov.add_child(obtn)
	ov.add_child(_make_label("按 R 或 空格 也可以重来", 14, Color(0.8, 0.8, 0.9)))

	# ---- 暂停界面 ----
	pause_root = Control.new()
	pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.visible = false
	canvas.add_child(pause_root)
	var pdim := ColorRect.new()
	pdim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pdim.color = Color(0.05, 0.04, 0.12, 0.55)
	pause_root.add_child(pdim)
	var pc := CenterContainer.new()
	pc.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_root.add_child(pc)
	var pp := PanelContainer.new()
	pp.add_theme_stylebox_override("panel", _card_style(Color(0.12, 0.10, 0.20, 0.94), Color(1.0, 0.7, 0.5, 0.5)))
	pc.add_child(pp)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 12)
	pp.add_child(pv)
	pv.add_child(_make_label("⏸  暂 停", 46, Color(1.0, 0.85, 0.6)))
	var resume_btn := _make_button("继 续", 22)
	resume_btn.pressed.connect(_toggle_pause)
	pv.add_child(resume_btn)
	var again_btn := _make_button("重新开始", 20)
	again_btn.pressed.connect(func():
		get_tree().paused = false
		Engine.time_scale = 1.0
		get_tree().reload_current_scene())
	pv.add_child(again_btn)
	pv.add_child(_make_label("Esc 继续　·　M 静音", 14, Color(0.85, 0.85, 0.9)))

func _update_start_best() -> void:
	if best > 0.0:
		start_best.text = "最高纪录  %.0f m" % best

# ============================================================ 流程
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# 暂停 / 静音（暂停时 _input 仍会触发）
	if event.keycode == KEY_ESCAPE:
		_toggle_pause()
	elif event.keycode == KEY_M:
		muted = not muted
		AudioServer.set_bus_mute(0, muted or get_tree().paused)
	elif event.keycode == KEY_Q:
		# 画质三档：AI 高模 + 超采样很吃 GPU，一键降档保帧率
		quality_mode = (quality_mode + 1) % 3
		_apply_quality()
	elif event.keycode == KEY_O:
		_toggle_outline()
	elif event.keycode == KEY_P:
		# 一键截图：窗口模式把当前帧存到桌面，发给我就能精准修画质（headless 下纹理为 null 自动跳过）
		_save_screenshot()
	elif event.keycode == KEY_F3:
		# V108-A：调试 HUD 开关（FPS / 帧时间 / 节点数 / 距离 / 速度 / 时段）
		_debug_hud = not _debug_hud
		if debug_root != null:
			debug_root.visible = _debug_hud
		if _debug_hud and debug_label != null:
			_update_debug_hud()

# 画质三档（Q 键循环）：0=高 1=中 2=低
func _apply_quality() -> void:
	if env_ref == null:
		return
	var vp := get_viewport()
	# ⚠️ V99 教训（历史）：当年"高画质 1.5x"出糊，根因是 project.godot 里有 0.66x 缩水链被
	# 运行时覆盖掩盖 —— 那条链已在 V99 拆除，1.0 基准干净。
	# V105：高档重启 1.5x 超采样（内部 1620p 降采样到 1080p）= 细节密度×2.25 + 免费降采样 AA。
	# 与 anisotropic 过滤（V105）配合解决"画质粗糙"：贴图斜视角细节 + 像素密度双管齐下。
	match quality_mode:
		0:
			if vp != null:
				vp.set("scaling_3d_scale", 1.5)
				vp.set("msaa_3d", 3)      # V108-A：8x MSAA（方案 §3.1 高画质）
			env_ref.ssao_enabled = true
			env_ref.ssil_enabled = true   # V102 A/B 证实蓝调非 SSIL 所致（是天空环境光），恢复
			env_ref.ssr_enabled = true
			env_ref.glow_intensity = 0.55
			env_ref.volumetric_fog_enabled = true   # 体积光/god rays 只在最高画质开
			_apply_shadow_quality(3)                # 4 级 CSM 阴影
			print("[画质] 高：1.5x 超采样 + 8xMSAA + 各向异性 + SSAO/SSIL/SSR + 体积光 + 4级CSM阴影")
		1:
			if vp != null:
				vp.set("scaling_3d_scale", 1.0)
				vp.set("msaa_3d", 2)      # V108-A：4x MSAA（方案 §3.1 中画质）
			env_ref.ssao_enabled = true
			env_ref.ssil_enabled = false
			env_ref.ssr_enabled = false
			env_ref.glow_intensity = 0.45
			env_ref.volumetric_fog_enabled = false
			_apply_shadow_quality(2)
			print("[画质] 中：1.0x 原生 + 4xMSAA + SSAO（关 SSIL/SSR/体积光）+ 2级CSM阴影")
		2:
			if vp != null:
				vp.set("scaling_3d_scale", 0.8)
				vp.set("msaa_3d", 1)      # V108-A：2x MSAA（方案 §3.1 低画质，优先帧率）
			env_ref.ssao_enabled = false
			env_ref.ssil_enabled = false
			env_ref.ssr_enabled = false
			env_ref.glow_intensity = 0.35
			env_ref.volumetric_fog_enabled = false
			_apply_shadow_quality(1)
			print("[画质] 低：0.8x + 2xMSAA，关 SSAO/SSIL/SSR/体积光（优先帧率）+ 单级阴影")

# 按画质档调整太阳阴影级数（近处锐利度 vs 帧率的取舍）
func _apply_shadow_quality(levels: int) -> void:
	if sun == null:
		return
	match levels:
		3:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		2:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		_:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL

var _diag_done: Dictionary = {}   # 自检模式下每种资产只诊断一次

# 自检诊断：打印 AI 模型的局部包围盒与节点位置，用于发现"浮空 / 陷地 / 尺寸离谱"
func _diag_aabb(tag: String, node: Node3D) -> void:
	if not (_verify or _fulltest or _stress):
		return
	if _diag_done.has(tag):
		return
	_diag_done[tag] = true
	var a := _node_aabb(node)
	print("[DIAG-", tag, "] 局部AABB位置=", a.position, " 尺寸=", a.size,
		" 节点位置=", node.position, " → 世界底部y=", snappedf(a.position.y + node.position.y, 0.01))

# 隐藏 AI 模型自带的方形底座（混元 3D 常见：很扁的大面积 mesh 垫在脚下，放路上会露方块边）
func _hide_base_mesh(root: Node3D) -> void:
	var meshes: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and n.mesh != null:
			meshes.append(n)
	if meshes.size() < 2:
		return
	var main_y := 0.0
	for m in meshes:
		var ab: AABB = m.mesh.get_aabb()
		main_y = maxf(main_y, ab.size.y)
	for m in meshes:
		var ab: AABB = m.mesh.get_aabb()
		# 扁（y < 主体 1/4）且宽（x/z > 主体高 0.8）→ 判定为底座
		if ab.size.y < main_y * 0.25 and maxf(ab.size.x, ab.size.z) > main_y * 0.8:
			m.visible = false

# V101：登记 AI 模型（棕榈/灌木）自带材质 → {材质: 原始 albedo}。
# GLB 实例间共享材质资源，登记一次即可；夜里在 _update_day 统一乘暗（否则叶片亮绿像发光纸板）
func _collect_ai_mats(root: Node3D) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and n.mesh != null:
			for si in range(n.mesh.get_surface_count()):
				var am: Material = n.get_active_material(si)
				if am is StandardMaterial3D and not ai_night_orig.has(am):
					ai_night_orig[am] = (am as StandardMaterial3D).albedo_color

# V106：把 AI GLB 自带的平涂 PBR 材质**升级**为 foliage shader（保留原 albedo 贴图）。
# 为什么：AI 模型占画面 40%+ 面积却是一片死平（叶簇无斑纹、无风、无透光），
# 是"远景廉价感"的最大来源。升级后同一张贴图会被叠上叶片斑纹 / 风摆 / 次表面透光。
# 注意：材质在 GLB 实例间**共享** → 用 _foliage_cache 去重，避免每株棕榈都新建 shader 材质。
var _foliage_cache: Dictionary = {}   # 原材质 → 转换后的 ShaderMaterial

func _to_foliage_mat(orig: StandardMaterial3D, sway_phase: float) -> ShaderMaterial:
	if _foliage_cache.has(orig):
		return _foliage_cache[orig]
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	# 保留原贴图（AI 生成的叶片 albedo）；乘上原 albedo_color 作为 tint
	if orig.albedo_texture != null:
		m.set_shader_parameter("albedo_tex", orig.albedo_texture)
	else:
		m.set_shader_parameter("albedo_tex", load("res://assets/grass_hd.png" if ResourceLoader.exists("res://assets/grass_hd.png") else "res://assets/grass.png"))
	m.set_shader_parameter("tint", orig.albedo_color)
	m.set_shader_parameter("detail_strength", 0.62)
	m.set_shader_parameter("wind_strength", 1.0)
	m.set_shader_parameter("translucency", 0.30)
	m.set_shader_parameter("hue_var", 0.45)
	m.set_shader_parameter("sway_phase", sway_phase)
	m.set_shader_parameter("night_f", 0.0)
	_foliage_cache[orig] = m
	return m

func _apply_foliage_shader(root: Node3D, sway_phase: float = -1.0) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and n.mesh != null:
			var ph: float = sway_phase if sway_phase >= 0.0 else randf() * TAU
			for si in range(n.mesh.get_surface_count()):
				var am: Material = n.get_active_material(si)
				if am is StandardMaterial3D:
					n.set_surface_override_material(si, _to_foliage_mat(am, ph))

func _node_aabb(node: Node3D) -> AABB:
	# 汇总子树内所有网格的包围盒（node 父坐标系）。
	# 关键修复：必须**累乘父级变换**（acc * n.transform）。
	# 旧实现只用节点自身的局部变换，忽略中间层级（GLB 根节点常带单位缩放），
	# 算出的尺寸与实际差好几倍 → 所有 AI 模型归一化尺寸全错（小屋 3m 变成 0.9m、灌木变成 0.5m）。
	var result := AABB(Vector3.ZERO, Vector3.ZERO)
	var first := true
	var stack: Array = [[node, node.transform]]
	while not stack.is_empty():
		var item = stack.pop_back()
		var n = item[0]
		var acc: Transform3D = item[1]
		for c in n.get_children():
			stack.append([c, acc * c.transform])
		if n is MeshInstance3D and n.mesh != null:
			# 跳过隐藏节点（被 _hide_base_mesh 藏掉的底座）与描边壳（否则描边会撑大包围盒）
			if not n.visible or bool(n.get_meta("outline", false)):
				continue
			var ab: AABB = acc * n.mesh.get_aabb()
			if first:
				result = ab
				first = false
			else:
				result = result.merge(ab)
	return result

func _apply_camera_mode() -> void:
	# 第一人称：隐藏整个 AI 模型（否则相机会怼进模型里）
	if ai_rider != null:
		if is_instance_valid(ai_rider):
			ai_rider.visible = (cam_mode != 3)
		return
	if ai_pelican != null:
		if is_instance_valid(ai_pelican):
			ai_pelican.visible = (cam_mode != 3)   # FP 模式整体隐藏 AI 鹈鹕
		return
	for m in fp_hide:
		if is_instance_valid(m):
			m.visible = (cam_mode != 3)

func _toggle_pause() -> void:
	if not started or game_over:
		return
	get_tree().paused = not get_tree().paused
	var pz := get_tree().paused
	pause_root.visible = pz
	AudioServer.set_bus_mute(0, muted or pz)   # 暂停时静音

# 一键截图：窗口模式下把当前渲染帧存到桌面，文件名带时间戳，方便用户发给我精准修画质。
# headless 下 Viewport 纹理为 null，自动跳过（不会弹窗、不影响自测）。
func _save_screenshot() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var tex := vp.get_texture()
	if tex == null:
		_pop_text("截图不可用（无渲染帧）", Color(1.0, 0.6, 0.5))
		return
	var img := tex.get_image()
	if img == null:
		_pop_text("截图不可用（帧为空）", Color(1.0, 0.6, 0.5))
		return
	# 注意：Godot 4.7 已移除 OS.get_datetime()，日期时间改用 Time 单例
	var stamp := Time.get_datetime_string_from_system(false)   # 形如 2026-10-02_16-03-47（文件名安全）
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	var path := dir.path_join("pelican_shot_%s.png" % stamp)
	var err := img.save_png(path)
	if err == OK:
		_pop_text("已存截图: " + path.get_file(), Color(0.6, 1.0, 0.7))
		print("[截图] 已保存 ", path)
	else:
		_pop_text("截图保存失败", Color(1.0, 0.6, 0.5))
		print("[截图] 保存失败 err=", err)

func _notification(what: int) -> void:
	# 切出窗口自动暂停
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and started and not game_over and not get_tree().paused:
		_toggle_pause()
	# 节点即将销毁（reload_current_scene 解绑阶段）：立刻停掉所有逐帧逻辑，
	# 否则 sun.look_at / global_transform 会在"已脱离树但尚未释放"的窗口里报错
	if what == NOTIFICATION_PREDELETE:
		_reloading = true

# ============================================================ 自动化全场景回归测试
func _fulltest_step() -> void:
	match _frames:
		40:
			cam_mode = 1
			_apply_camera_mode()
			print("[FT] 机位1(低角度) ok")
		70:
			cam_mode = 2
			_apply_camera_mode()
			print("[FT] 机位2(侧面) ok")
		100:
			cam_mode = 3
			_apply_camera_mode()
			print("[FT] 机位3(第一人称) ok  角色可见=", (is_instance_valid(ai_rider) and ai_rider.visible),
				" 着地=", ground_check.is_colliding())
		130:
			cam_mode = 0
			_apply_camera_mode()
			print("[FT] 机位0(追尾) ok")
		170:
			# 连续跳跃（测空中态与落地）
			for i in 3:
				player.apply_central_impulse(Vector3(0, MASS * JUMP_SPEED, 0))
			print("[FT] 三连跳 施加冲量")
		200:
			# 强制吃鱼
			if fishes.size() > 0:
				player.global_position = fishes[0].global_position + Vector3(0, 0.5, 0)
		215:
			print("[FT] 吃鱼后 小鱼=", fish_count, " 电量=", roundf(battery), " 分数=", roundf(score))
		250:
			# 强制撞车
			if obstacles.size() > 0:
				player.global_position = obstacles[0].global_position + Vector3(0, 0.45, 0)
		265:
			print("[FT] 撞车后 game_over=", game_over, " time_scale=", Engine.time_scale,
				" 结算面板=", (over_root.visible if over_root else "null"))
		300:
			# 切夜间（直接改时间轴：0.75 = 深夜）
			day_time = 0.78
		320:
			print("[FT] 强制夜晚 day_time=", roundf(day_time), " 当前夜色=", roundf(cur_night_f),
				" 车头灯能=", roundf(head_light.light_energy), " 窗户数=", night_windows.size())
		330:
			# 电量耗尽
			battery = 0.05
		345:
			print("[FT] 电量耗尽后 game_over=", game_over)
		140:
			# 真实跳跃链路验证：模拟按下 ui_accept（依赖 ground_check 命中才起跳）
			_jump_before_y = player.global_position.y
			Input.action_press("ui_accept")
		155:
			Input.action_release("ui_accept")
			print("[FT] 真实跳跃 ground_check=", ground_check.is_colliding(),
				" vy=", snappedf(player.linear_velocity.y, 0.1),
				" 离地=", (player.global_position.y > _jump_before_y + 0.05))
		380:
			print("[FT] 阶段测试全部通过，开始重开验证…")
			var f := FileAccess.open("user://ft_done", FileAccess.WRITE)
			f.store_string("1")
			f.close()
			Engine.time_scale = 1.0
			_reloading = true
			get_tree().call_deferred("reload_current_scene")
		400:
			print("[FT] 兜底退出")
			get_tree().quit()

# ============================================================ V108-B 角色状态机
# 目标（方案 §3.2）：动画 / 声音 / 镜头 / 粒子统一监听同一个状态，
# 消除"撞车时仍在跳跃""重开后旧音效""落地和起跳同时触发"。
func _set_pstate(s: int) -> void:
	if pstate == s:
		return
	pstate_prev = pstate
	pstate = s
	pstate_time = 0.0

# 可重触发状态（吃鱼 / 擦身）：即使已在同状态也重置计时，保证每次反馈时长完整
func _kick_pstate(s: int) -> void:
	if pstate != s:
		pstate_prev = pstate
		pstate = s
	pstate_time = 0.0

func _pstate_name() -> String:
	return ["RIDING", "STEERING", "JUMP_START", "AIRBORNE", "LANDING",
		"COLLECTING", "NEAR_MISS", "HIT", "GAME_OVER", "RESPAWN"][pstate]

# 每帧推进：一次性状态超时回落，持续性状态按条件切换
func _update_pstate(delta: float, grounded: bool, steer: float) -> void:
	pstate_time += delta
	match pstate:
		PState.HIT, PState.GAME_OVER, PState.RESPAWN:
			return   # 终态 / 过渡态由 _crash 与重开流程显式切换，不由条件推断
		PState.JUMP_START:
			if pstate_time >= 0.16:
				_set_pstate(PState.AIRBORNE)
		PState.AIRBORNE:
			if grounded:
				_set_pstate(PState.LANDING)
		PState.LANDING:
			if pstate_time >= 0.22:
				_set_pstate(PState.STEERING if absf(steer) > 0.05 else PState.RIDING)
		PState.COLLECTING:
			if pstate_time >= 0.35:
				_set_pstate(PState.STEERING if absf(steer) > 0.05 else PState.RIDING)
		PState.NEAR_MISS:
			if pstate_time >= 0.40:
				_set_pstate(PState.STEERING if absf(steer) > 0.05 else PState.RIDING)
		PState.STEERING:
			if absf(steer) <= 0.05 and grounded:
				_set_pstate(PState.RIDING)
		PState.RIDING:
			if not grounded:
				_set_pstate(PState.AIRBORNE)
			elif absf(steer) > 0.05:
				_set_pstate(PState.STEERING)

# V108-C：角色姿态动画 —— 用状态 + 速度驱动 AI 鹈鹕身体相对车架的运动。
# 原则（方案 §3.3）：平滑插值不瞬移角度 / 不影响碰撞体（只动视觉节点）/
# 幅度随速度与状态变化 / 相位由 game_time 决定（重开可复现）。
func _update_body_pose(spd: float) -> void:
	if ai_pelican == null or not is_instance_valid(ai_pelican):
		return
	var cadence := clampf(spd / MAX_SPEED, 0.0, 1.0)
	var t_pitch := deg_to_rad(4.5) * cadence          # 加速前倾：越快越俯身
	var t_roll := -steer_sm * deg_to_rad(7.0)         # 转向侧倾（与车身同向）
	var t_lift := 0.0
	# 蹬踏起伏：身体随曲柄节奏轻微上下（相位与曲柄一致）
	t_lift += sin(game_time * maxf(spd * 0.32, 4.0) * 2.0) * 0.012 * (0.4 + 0.6 * cadence)
	match pstate:
		PState.JUMP_START:
			# 起跳：先压身、再弹起（半个正弦包络）
			var k := clampf(pstate_time / 0.16, 0.0, 1.0)
			t_pitch -= deg_to_rad(7.0) * sin(k * PI)
			t_lift += 0.055 * sin(k * PI)
		PState.AIRBORNE:
			t_pitch -= deg_to_rad(9.0)      # 空中后仰挺胸
			t_lift += 0.020
		PState.LANDING:
			var k2 := clampf(pstate_time / 0.22, 0.0, 1.0)
			t_pitch += deg_to_rad(6.0) * (1.0 - k2)
			t_lift -= 0.050 * (1.0 - k2)    # 落地压缩
		PState.COLLECTING:
			var k3 := clampf(pstate_time / 0.35, 0.0, 1.0)
			t_pitch += deg_to_rad(10.0) * sin(k3 * PI)   # 吃鱼前探啄食
		PState.NEAR_MISS:
			var k4 := clampf(pstate_time / 0.40, 0.0, 1.0)
			t_roll += deg_to_rad(9.0) * sin(k4 * PI * 3.0) * (1.0 - k4)   # 受惊抖动
		PState.HIT:
			t_pitch += deg_to_rad(14.0)     # 撞击前扑
			t_lift += 0.030
	# 快反馈收敛更快，慢状态柔和收敛（避免动作"跳"）
	var rate := 0.16 if pstate in [PState.NEAR_MISS, PState.COLLECTING, PState.HIT, PState.LANDING] else 0.10
	body_pitch = lerpf(body_pitch, t_pitch, rate)
	body_roll = lerpf(body_roll, t_roll, rate)
	body_lift = lerpf(body_lift, t_lift, rate)
	ai_pelican.position = ai_base_pos + Vector3(0.0, body_lift, 0.0)
	ai_pelican.rotation = Vector3(ai_base_rot.x + body_pitch, ai_base_rot.y, ai_base_rot.z + body_roll)

func _start_game() -> void:
	started = true
	_set_pstate(PState.RIDING)   # V108-B：离开 RESPAWN，进入骑行
	start_root.visible = false
	hud_root.visible = true
	# 入场运镜：从高空缓缓俯冲到追尾机位
	camera.global_position = player.global_position + Vector3(6.0, 16.0, 24.0)
	_pop_text("出 发 !", Color(1.0, 0.92, 0.62))

func _load_best() -> void:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) == OK:
		best = float(cf.get_value("rider", "best", 0.0))

func _save_best() -> void:
	var cf := ConfigFile.new()
	cf.set_value("rider", "best", best)
	cf.save(SAVE_PATH)

# ============================================================ 世界跟随 / 生成
func _follow_world() -> void:
	var pz := player.global_position.z
	if grass:
		grass.position.z = pz
	if backdrop:
		backdrop.position.z = pz
	if road_group:
		road_group.position.z = pz   # 路面三件套随玩家一起 treadmill，长直路永远跑不到尽头
		# V104：两处滚动让"路真的在动"——
		#   1) 路面贴图 UV 滚动（9m 一周期）：纹理相对世界静止 → 骑行时向后掠过，不再是冻结传送带
		if road_shader_mat != null:
			road_shader_mat.set_shader_parameter("scroll", _scroll_test if _scroll_test >= 0.0 else -pz / 9.0)
		#   2) 中央虚线循环位移（虚线周期 9.0m = 3.2 线 + 5.8 空）：世界坐标静止 → 相对玩家向后飞
		#      fmod 跳变时恰好转过一个周期，图案无缝衔接，肉眼不可见
		if dashes_node != null:
			dashes_node.position.z = fmod(-pz, 9.0)
	# 玩家别跑出路面
	if absf(player.global_position.x) > ROAD_HALF - 0.5:
		var lv := player.linear_velocity
		lv.x = lerpf(lv.x, 0.0, 0.35)
		player.linear_velocity = lv
		player.global_position.x = clampf(player.global_position.x, -(ROAD_HALF - 0.5), ROAD_HALF - 0.5)

func _fade_in(node: Node3D) -> void:
	# 让路边道具从地面"长出来"，避免 200m 外突然弹现（弹现 = 粗糙感主因之一）
	var ts := node.scale
	if ts == Vector3.ZERO:
		return
	node.scale = ts * 0.32          # 从 32% 尺寸起步
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_QUART)
	tw.set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", ts, 0.5)   # 0.5s 平滑长到目标尺寸

func _spawn_logic(delta: float) -> void:
	var pz := player.global_position.z

	# 前方 200m 内持续铺满：障碍、小鱼、树木灌木、护栏、路灯
	while obstacle_cursor > pz - AHEAD:
		_spawn_obstacle(obstacle_cursor)
		# 骑得越远，障碍越密（难度递增）
		var gap_lo := maxf(16.0, 26.0 - max_dist * 0.006)
		var gap_hi := maxf(24.0, 44.0 - max_dist * 0.009)
		obstacle_cursor -= randf_range(gap_lo, gap_hi)
	while fish_cursor > pz - AHEAD:
		_spawn_fish(fish_cursor)
		fish_cursor -= randf_range(28.0, 58.0)
	while scenery_cursor > pz - AHEAD:
		_spawn_scenery(scenery_cursor)
		scenery_cursor -= randf_range(11.0, 18.0)
	while rail_cursor > pz - AHEAD:
		_spawn_rail(rail_cursor)
		rail_cursor -= 8.0
	while lamp_cursor > pz - AHEAD:
		_spawn_lamp(lamp_cursor)
		lamp_cursor -= 48.0
	while decal_cursor > pz - AHEAD:
		_spawn_decal(decal_cursor)
		decal_cursor -= randf_range(75.0, 115.0)
	while sign_cursor > pz - AHEAD:
		_spawn_sign(sign_cursor)
		sign_cursor -= randf_range(80.0, 120.0)
	while umbrella_cursor > pz - AHEAD:
		_spawn_umbrella(umbrella_cursor)
		umbrella_cursor -= randf_range(50.0, 80.0)
	while hut_cursor > pz - AHEAD:
		_spawn_hut(hut_cursor)
		hut_cursor -= randf_range(65.0, 105.0)   # 更密：右侧是"海边村落"，不是空草地
	while verge_cursor > pz - AHEAD:
		_spawn_verge(verge_cursor)
		verge_cursor -= randf_range(1.6, 3.0)   # 更密的草丛/碎石（细腻度）

	# 擦身而过奖励（障碍从身边掠过且没撞上）
	for o in obstacles:
		if not is_instance_valid(o):
			continue
		var oz: float = o.global_position.z
		var prev: float = o.get_meta("pz", oz)
		if prev <= pz and oz > pz and absf(o.global_position.x - player.global_position.x) < 1.45:
			bonus_score += NEAR_MISS_BONUS
			_pop_text("+3 擦身!", Color(0.80, 1.0, 0.85))
			_kick_pstate(PState.NEAR_MISS)   # V108-B：擦身反馈状态（受惊回看）
		o.set_meta("pz", oz)

	# 小鱼浮动 + 旋转
	for f in fishes:
		if is_instance_valid(f):
			f.position.y = f.get_meta("by", 2.0) + sin(game_time * 3.0 + f.position.z) * 0.16
			f.rotate_y(delta * 2.6)

	for i in range(obstacles.size() - 1, -1, -1):
		if not is_instance_valid(obstacles[i]) or obstacles[i].global_position.z > pz + 30.0:
			if is_instance_valid(obstacles[i]):
				obstacles[i].queue_free()
			obstacles.remove_at(i)
	for i in range(fishes.size() - 1, -1, -1):
		if not is_instance_valid(fishes[i]) or fishes[i].global_position.z > pz + 30.0:
			if is_instance_valid(fishes[i]):
				fishes[i].queue_free()
			fishes.remove_at(i)
	for i in range(scenery.size() - 1, -1, -1):
		if not is_instance_valid(scenery[i]) or scenery[i].global_position.z > pz + 40.0:
			if is_instance_valid(scenery[i]):
				scenery[i].queue_free()
			palms.erase(scenery[i])
			swayables.erase(scenery[i])
			scenery.remove_at(i)

func _spawn_obstacle(z: float) -> void:
	var kind := randi() % 5        # 0路障锥 1油桶 2石头 3轮胎堆 4水马
	_spawn_obstacle_at(z, kind, randf_range(-ROAD_HALF + 0.9, ROAD_HALF - 0.9))
	# 路障偶尔成排出现（对齐参考图的路障簇）
	if kind == 0 and randf() < 0.22:
		var x0 := randf_range(-2.4, 2.4)
		_spawn_obstacle_at(z, 0, clampf(x0 - 1.35, -ROAD_HALF + 0.9, ROAD_HALF - 0.9))
		_spawn_obstacle_at(z, 0, clampf(x0 + 1.35, -ROAD_HALF + 0.9, ROAD_HALF - 0.9))

func _spawn_obstacle_at(z: float, kind: int, x: float) -> void:
	var body := RigidBody3D.new()
	body.mass = 24.0
	body.position = Vector3(x, 1.0, z)
	# 障碍放在 layer 8：玩家仍能撞到，但"落地检测"射线只认地面(layer 1)，
	# 避免站在障碍物上还能二段跳
	body.collision_layer = 8
	body.collision_mask = 1 | 2
	body.set_meta("kind", kind)

	var shape := CollisionShape3D.new()
	var mi := MeshInstance3D.new()
	if kind == 3:
		mi.mesh = load("res://assets/prop_tires.obj")
		mi.material_override = _toon(Color(0.16, 0.16, 0.18), {"spec_strength": 0.25, "rim_strength": 0.3})
		var cs := CylinderShape3D.new(); cs.radius = 0.40; cs.height = 0.70
		shape.shape = cs; shape.position.y = 0.35
	elif kind == 4:
		mi.mesh = load("res://assets/prop_barrier.obj")
		mi.material_override = _toon(Color(0.95, 0.55, 0.12), {"spec_strength": 0.35, "rim_color": Color(1.0, 0.85, 0.6)})
		var bs := BoxShape3D.new(); bs.size = Vector3(1.30, 0.90, 0.48)
		shape.shape = bs; shape.position.y = 0.45
	elif kind == 0:
		mi.mesh = load("res://assets/prop_cone.obj")
		mi.material_override = _toon(Color(1.0, 0.45, 0.14), {"stripe_v": 0.42, "spec_strength": 0.4})
		var cs := CylinderShape3D.new(); cs.radius = 0.28; cs.height = 1.15
		shape.shape = cs; shape.position.y = 0.575
	elif kind == 1:
		mi.mesh = load("res://assets/prop_barrel.obj")
		mi.material_override = _toon(Color(0.85, 0.24, 0.42), {"spec_strength": 0.55, "rim_color": Color(1.0, 0.8, 0.9)})
		var cs2 := CylinderShape3D.new(); cs2.radius = 0.38; cs2.height = 1.05
		shape.shape = cs2; shape.position.y = 0.525
	else:
		mi.mesh = load("res://assets/prop_rock.obj")
		mi.material_override = _toon(Color(0.55, 0.58, 0.68), {"spec_strength": 0.2})
		var cs3 := SphereShape3D.new(); cs3.radius = 0.42
		shape.shape = cs3; shape.position.y = 0.3
	_with_outline(mi, 0.010)
	body.add_child(mi)
	body.add_child(shape)
	add_child(body)
	obstacles.append(body)

func _spawn_fish(z: float) -> void:
	# 小鱼成群出现（三只排成一道弧线，对齐参考图的收集节奏）
	var base_x := randf_range(-ROAD_HALF + 1.4, ROAD_HALF - 1.4)
	var base_y := randf_range(1.5, 3.0)
	for k in range(3):
		_spawn_fish_at(z, base_x + (k - 1) * 0.85, base_y + (1 - abs(k - 1)) * 0.38)

func _spawn_fish_at(z: float, bx: float, by: float) -> void:
	var area := Area3D.new()
	area.position = Vector3(bx, by, z)
	area.collision_layer = 4
	area.collision_mask = 2
	var mi := MeshInstance3D.new()
	mi.mesh = load("res://assets/prop_fish.obj")
	mi.material_override = _toon(Color(0.30, 0.78, 1.0), {"rim_color": Color(0.8, 0.95, 1.0), "rim_strength": 0.9, "spec_strength": 0.7})
	mi.scale = Vector3(1.15, 1.15, 1.15)
	_with_outline(mi, 0.008)
	area.add_child(mi)
	var col := CollisionShape3D.new()
	var ss := SphereShape3D.new(); ss.radius = 0.55
	col.shape = ss
	area.add_child(col)
	area.set_meta("by", by)
	area.body_entered.connect(func(_b): _collect_fish(area))
	add_child(area)
	fishes.append(area)

func _collect_fish(area: Area3D) -> void:
	if game_over or not is_instance_valid(area):
		return
	fish_count += 1
	combo += 1
	combo_timer = COMBO_WINDOW   # 每次吃鱼刷新连击窗口
	best_combo = maxi(best_combo, combo)
	battery = minf(battery + 6.0, 100.0)
	var gain := FISH_BASE
	if combo % COMBO_STEP == 0:
		gain += 10.0
	bonus_score += gain
	_spawn_sparkle(area.global_position)
	_pop_text("+%d" % int(gain), Color(0.55, 0.95, 1.0))
	_kick_pstate(PState.COLLECTING)   # V108-B：吃鱼反馈状态（头部前探）
	if combo % COMBO_STEP == 0:
		_pop_text("连击 x%d !" % combo, Color(1.0, 0.85, 0.35))
	sfx_collect.pitch_scale = 1.0 + minf(combo * 0.06, 0.8)   # 连击越高音调越高
	sfx_collect.play()
	area.queue_free()
	fishes.erase(area)

func _spawn_decal(z: float) -> void:
	# 路面自行车道标志喷绘（对齐参考图）；共享材质，夜间自发光
	var d := MeshInstance3D.new()
	var quad := PlaneMesh.new()
	quad.size = Vector2(2.6, 2.6)
	d.mesh = quad
	if decal_mat == null:
		decal_mat = StandardMaterial3D.new()
		decal_mat.albedo_texture = load("res://assets/bike_symbol.png")
		decal_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		decal_mat.roughness = 0.85
		decal_mat.emission_enabled = true
		decal_mat.emission = Color(0.85, 0.88, 0.95)
		decal_mat.emission_energy_multiplier = 0.15
	d.material_override = decal_mat
	d.position = Vector3(randf_range(-2.8, 2.8), 0.015, z)
	d.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(d)
	scenery.append(d)

func _spawn_verge(z: float) -> void:
	# 路肩草丛与碎石：让地面不再是光板（对齐参考图的路边植被）
	for side in [-1.0, 1.0]:
		if randf() < 0.18:
			continue
		var x: float = side * (ROAD_HALF + 1.0 + randf() * 5.5)
		var zz := z + randf_range(-3.0, 3.0)
		# 路肩花丛（五颜六色的小花球，让路边有颜色）——只长右侧草地；
		# 左侧是沙滩，彩花长在沙地上像一坨坨垃圾（截图实测），沙滩只留沙草/碎石
		if side > 0.0 and randf() < 0.45:
			var fl := MeshInstance3D.new()
			fl.mesh = load("res://assets/prop_tuft.obj")
			var fc: Color = [Color(0.95, 0.35, 0.55), Color(0.98, 0.82, 0.25),
							 Color(0.75, 0.45, 0.95), Color(1.0, 0.55, 0.30),
							 Color(0.40, 0.85, 0.95), Color(1.0, 0.80, 0.30)][randi() % 6]
			fl.material_override = _toon(fc, {"rim_color": Color(1, 0.9, 0.95), "rim_strength": 0.3, "spec_strength": 0.1})
			var fsc := randf_range(0.28, 0.45)
			fl.scale = Vector3(fsc, fsc * 0.8, fsc)
			fl.position = Vector3(x, 0.34, zz)
			fl.rotation = Vector3(0, randf() * TAU, 0)
			add_child(fl)
			scenery.append(fl)
			_fade_in(fl)
		elif randf() < 0.72:
			var t := MeshInstance3D.new()
			t.mesh = load("res://assets/prop_tuft.obj")
			t.material_override = _toon(Color(0.34, 0.66, 0.32), {"rim_color": Color(0.85, 1.0, 0.80), "spec_strength": 0.1})
			var s := randf_range(0.7, 1.15)
			t.scale = Vector3(s, s * randf_range(0.85, 1.35), s)
			t.position = Vector3(x, 0.0, zz)
			t.rotation = Vector3(0, randf() * TAU, 0)
			add_child(t)
			scenery.append(t)
			_fade_in(t)
		else:
			var rk := MeshInstance3D.new()
			rk.mesh = load("res://assets/prop_rock.obj")
			rk.material_override = _toon(Color(0.55, 0.56, 0.62), {"spec_strength": 0.15})
			var rs := randf_range(0.16, 0.34)
			rk.scale = Vector3(rs, rs, rs)
			rk.position = Vector3(x, 0.0, zz)
			rk.rotation = Vector3(0, randf() * TAU, 0)
			add_child(rk)
			scenery.append(rk)
			_fade_in(rk)

func _spawn_sign(z: float) -> void:
	var side := -1.0 if randf() < 0.5 else 1.0
	var node := Node3D.new()
	node.position = Vector3(side * (ROAD_HALF + 1.1), 0.0, z)
	var mi := MeshInstance3D.new()
	mi.mesh = load("res://assets/prop_sign.obj")
	mi.material_override = _toon(Color(0.95, 0.78, 0.20), {"spec_strength": 0.3})
	_with_outline(mi, 0.010)
	node.add_child(mi)
	add_child(node)
	scenery.append(node)
	_fade_in(node)

func _spawn_umbrella(z: float) -> void:
	# 沙滩遮阳伞（成簇摆放，必须锁在沙滩带内，避免插进海里/水际线上穿帮）
	# 沙滩带：中心 -(ROAD_HALF+3.5)=-8.0、半宽 3.5 → x ∈ [-11.5, -4.5]
	var beach_c := -(ROAD_HALF + 3.5)
	for k in range(3):
		var u := Node3D.new()
		var ux := clampf(beach_c + randf_range(-2.8, 2.8) + k * 0.7, -11.2, -4.8)
		u.position = Vector3(ux, 0.0,
			z + randf_range(-2.0, 2.0) + k * randf_range(1.2, 2.6))
		u.rotation = Vector3(0, randf() * TAU, 0)
		var us := randf_range(0.9, 1.2)
		u.scale = Vector3(us, us, us)
		var mi := MeshInstance3D.new()
		mi.mesh = load("res://assets/prop_umbrella.obj")
		mi.material_override = _toon(Color(0.88, 0.22, 0.28) if k % 2 == 0 else Color(0.95, 0.65, 0.30),
			{"spec_strength": 0.3, "rim_color": Color(1.0, 0.8, 0.7)})
		_with_outline(mi, 0.012)
		u.add_child(mi)
		add_child(u)
		scenery.append(u)
		_fade_in(u)
		u.set_meta("sway_amp", 0.018)
		u.set_meta("sway_ph", randf() * TAU)
		swayables.append(u)

func _spawn_scenery(z: float) -> void:
	# 左侧沙滩：棕榈树（成丛散布，避免等距单排的"复制粘贴"感）
	if randf() > 0.15:
		var lcl := 1 + (1 if randf() < 0.45 else 0) + (1 if randf() < 0.22 else 0)
		var lbx := -(ROAD_HALF + 2.2 + randf() * 2.6)
		var lbz := z + randf_range(-3.0, 3.0)
		for c in range(lcl):
			var palm_l := _make_palm(lbx + randf_range(-2.4, 2.4), lbz + randf_range(-3.5, 3.5))
			add_child(palm_l)
			scenery.append(palm_l)
			_fade_in(palm_l)
	# 右侧草地：棕榈/普通树 / 灌木（也加密，避免"只有一边有树"的空旷感）
	if randf() > 0.30:
		var rcl := 1 + (1 if randf() < 0.40 else 0)
		var rbx := ROAD_HALF + 2.5 + randf() * 2.4
		var rbz := z + randf_range(-3.0, 3.0)
		for c in range(rcl):
			var palm_r := _make_palm(rbx + randf_range(-2.0, 2.0), rbz + randf_range(-3.0, 3.0))
			add_child(palm_r)
			scenery.append(palm_r)
			_fade_in(palm_r)
	elif randf() < 0.92:
		var bush: bool = randf() < 0.45
		var x: float = ROAD_HALF * ((1.0 + randf() * 2.2) if bush else (3.0 + randf() * 13.0))
		var node := Node3D.new()
		node.position = Vector3(x, 0.0, z + randf_range(-4.0, 4.0))
		var s := randf_range(0.85, 1.35)
		node.scale = Vector3(s, s, s)
		node.rotation = Vector3(0, randf() * TAU, 0)
		if bush:
			if bush_scene != null:
				# AI 高保真灌木（PBR 自带叶片细节，高度归一到 ~1.3m）
				var binst := bush_scene.instantiate() as Node3D
				if binst != null:
					_hide_base_mesh(binst)   # 藏掉自带的方形沙地底座
					_collect_ai_mats(binst)   # V101：登记自带材质，夜里统一压暗
					_apply_foliage_shader(binst, randf() * TAU)   # V106：灌木叶片细节
					var bbb := _node_aabb(binst)
					var bs2 := 1.3 / maxf(bbb.size.y, 0.01)
					binst.scale = Vector3(bs2, bs2, bs2)
					binst.position = Vector3(-bs2 * bbb.get_center().x, -bs2 * bbb.position.y, -bs2 * bbb.get_center().z)
					binst.rotation.y = randf() * TAU
					node.add_child(binst)
					_diag_aabb("BUSH", node)
			else:
				var bm := MeshInstance3D.new()
				bm.mesh = load("res://assets/prop_bush.obj")
				bm.material_override = _toon(Color(0.30, 0.66, 0.34), {"rim_color": Color(0.85, 1.0, 0.85), "spec_strength": 0.15, "translucency": 0.8})
				_with_outline(bm, 0.014)
				node.add_child(bm)
		else:
			var trunk := MeshInstance3D.new()
			trunk.mesh = load("res://assets/tree_trunk.obj")
			trunk.material_override = _toon(Color(0.44, 0.29, 0.18), {"spec_strength": 0.1})
			node.add_child(trunk)
			var leaves := MeshInstance3D.new()
			leaves.mesh = load("res://assets/tree_leaves.obj")
			leaves.material_override = _toon(Color(0.22, 0.60, 0.36), {"rim_color": Color(0.8, 1.0, 0.85), "spec_strength": 0.15, "translucency": 0.9})
			_with_outline(leaves, 0.02)
			node.add_child(leaves)
		add_child(node)
		scenery.append(node)
		_fade_in(node)
		node.set_meta("sway_amp", randf_range(0.012, 0.026))
		node.set_meta("sway_ph", randf() * TAU)
		swayables.append(node)
	# V103：右侧电线杆节奏线（路边"有人烟"的纵深元素；稀疏分布，木杆+单横担）
	if randf() < 0.18:
		var pole := Node3D.new()
		pole.position = Vector3(ROAD_HALF + 1.35 + randf_range(-0.15, 0.15), 0.0, z + randf_range(-2.0, 2.0))
		pole.rotation.z = randf_range(-0.02, 0.02)
		var wood := _toon(Color(0.36, 0.29, 0.23), {"roughness": 0.95, "spec_strength": 0.04})
		var pshaft := MeshInstance3D.new()
		var pcm := CylinderMesh.new()
		pcm.top_radius = 0.07
		pcm.bottom_radius = 0.11
		pcm.height = 7.0
		pshaft.mesh = pcm
		pshaft.position.y = 3.5
		pshaft.material_override = wood
		pole.add_child(pshaft)
		var parm := MeshInstance3D.new()
		var pbm := BoxMesh.new()
		pbm.size = Vector3(1.6, 0.09, 0.09)
		parm.mesh = pbm
		parm.position.y = 6.55
		parm.material_override = wood
		pole.add_child(parm)
		add_child(pole)
		scenery.append(pole)
		_fade_in(pole)

func _make_palm(x: float, z: float) -> Node3D:
	# 优先用 AI 生成的高保真棕榈（画风与 AI 鹈鹕一致）
	if palm_scene != null:
		var inst := palm_scene.instantiate() as Node3D
		if inst != null:
			_collect_ai_mats(inst)   # V101：登记自带材质，夜里统一压暗（否则叶片夜里亮绿）
			_apply_foliage_shader(inst, randf() * TAU)   # V106：平涂 PBR → 叶片斑纹/风摆/透光
			var bb := _node_aabb(inst)
			var target := randf_range(6.5, 9.5)          # 树高 6.5~9.5m
			var s := target / maxf(bb.size.y, 0.01)
			inst.scale = Vector3(s, s, s)
			inst.position = Vector3(x, -s * bb.position.y, z)
			inst.rotation.y = randf() * TAU
			inst.set_meta("sway_ph", randf() * TAU)
			palms.append(inst)
			return inst
	var palm := Node3D.new()
	palm.position = Vector3(x, 0.0, z)
	var ps := randf_range(0.85, 1.25)
	palm.scale = Vector3(ps, ps, ps)
	palm.rotation = Vector3(0, randf() * TAU, 0)
	var ptr := MeshInstance3D.new()
	ptr.mesh = load("res://assets/palm_trunk.obj")
	ptr.material_override = _toon(Color(0.52, 0.38, 0.24), {"spec_strength": 0.15})
	palm.add_child(ptr)
	var fr := MeshInstance3D.new()
	fr.mesh = load("res://assets/palm_fronds.obj")
	fr.material_override = _toon(Color(0.20, 0.58, 0.34), {"rim_color": Color(1.0, 0.80, 0.60), "spec_strength": 0.2, "translucency": 0.9})
	_with_outline(fr, 0.02)
	palm.add_child(fr)
	palm.set_meta("sway_ph", randf() * TAU)
	palms.append(palm)
	return palm

func _spawn_rail(z: float) -> void:
	# 白色栏杆桥（对齐参考图：连续白栏杆 + 双横梁）
	for side in [-1.0, 1.0]:
		if randf() < 0.06:
			continue   # 偶尔断口，打破"无限复制粘贴"的栏杆
		var r := MeshInstance3D.new()
		r.mesh = load("res://assets/rail_white.obj")
		r.material_override = _toon(Color(0.84, 0.84, 0.81), {"spec_strength": 0.2, "rim_strength": 0.12, "roughness": 0.55})
		r.position = Vector3(side * (ROAD_HALF + 0.45) + randf_range(-0.12, 0.12), randf_range(-0.02, 0.02), z)
		r.rotation = Vector3(randf_range(-0.012, 0.012), PI * 0.5 + randf_range(-0.05, 0.05), randf_range(-0.012, 0.012))
		add_child(r)
		scenery.append(r)
		# 栏杆上偶尔停一只海鸥（参考图海滨细节）
		if randf() < 0.30:
			var pb := MeshInstance3D.new()
			pb.mesh = load("res://assets/prop_bird_perched.obj")
			pb.material_override = _toon(Color(0.96, 0.96, 0.98), {"rim_strength": 0.4, "spec_strength": 0.2})
			pb.position = Vector3(randf_range(1.0, 7.0), 0.92, 0.0)
			pb.rotation = Vector3(0, randf_range(-0.6, 0.6), 0)
			_with_outline(pb, 0.006)
			r.add_child(pb)

func _spawn_hut(z: float) -> void:
	var hut := Node3D.new()
	hut.position = Vector3(ROAD_HALF + 6.0 + randf() * 5.0, 0.0, z)
	hut.rotation = Vector3(0, randf_range(-0.6, 0.6), 0)
	var hs := randf_range(0.9, 1.2)
	hut.scale = Vector3(hs, hs, hs)
	if hut_scene != null:
		# AI 高保真小屋（PBR 贴图自带窗户/木纹/茅草细节，无需程序化夜窗贴片）
		var inst := hut_scene.instantiate() as Node3D
		if inst != null:
			var bb := _node_aabb(inst)
			var s := 3.0 / maxf(bb.size.y, 0.01)      # 目标总高约 3m
			inst.scale = Vector3(s, s, s)
			inst.position = Vector3(-s * bb.get_center().x, -s * bb.position.y, -s * bb.get_center().z)
			hut.add_child(inst)
			_diag_aabb("HUT", hut)
			# 门廊暖灯：AI 模型自带窗户贴图（夜窗贴片会穿模），改用门口的暖光灯提供夜间人气
			if hut_glow_mat == null:
				hut_glow_mat = StandardMaterial3D.new()
				hut_glow_mat.albedo_color = Color(1.0, 0.88, 0.62)
				hut_glow_mat.emission_enabled = true
				hut_glow_mat.emission = Color(1.0, 0.78, 0.42)
				hut_glow_mat.emission_energy_multiplier = 0.0
				hut_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			var pglow := MeshInstance3D.new()
			var pgs := SphereMesh.new()
			pgs.radius = 0.13; pgs.height = 0.26
			pglow.mesh = pgs
			pglow.material_override = hut_glow_mat
			pglow.position = Vector3(-1.05, 2.05, 0.35)   # 门口上方（朝路一侧）
			hut.add_child(pglow)
			var pl := OmniLight3D.new()
			pl.light_color = Color(1.0, 0.72, 0.40)
			pl.omni_range = 7.0
			pl.shadow_enabled = false
			pl.light_energy = 0.0
			pl.position = Vector3(-1.15, 2.0, 0.35)
			hut.add_child(pl)
			lamp_lights.append(pl)   # 复用路灯的夜间点亮逻辑（按距离衰减）
	else:
		var body := MeshInstance3D.new()
		body.mesh = load("res://assets/prop_hut.obj")
		body.material_override = _toon(Color(0.92, 0.86, 0.74), {"spec_strength": 0.15, "rim_color": Color(1.0, 0.85, 0.7)})
		_with_outline(body, 0.014)
		hut.add_child(body)
		# 夜间发光窗（并入 night_windows，夜里淡入暖光，让海边村落"有人气"）
		var win := MeshInstance3D.new()
		var wq := QuadMesh.new()
		wq.size = Vector2(0.62 * hs, 0.5 * hs)
		win.mesh = wq
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(1.0, 0.88, 0.60)
		wm.emission_enabled = true
		wm.emission = Color(1.0, 0.86, 0.55)
		wm.emission_energy_multiplier = 0.0
		wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		win.material_override = wm
		win.position = Vector3(-0.45 * hs, 1.15 * hs, 0.55 * hs)   # 朝路一侧（-x）的小窗
		win.rotation = Vector3(0, -PI * 0.5, 0)
		hut.add_child(win)
		night_windows.append(wm)
	add_child(hut)
	scenery.append(hut)
	_fade_in(hut)

func _spawn_lamp(z: float) -> void:
	var side := -1.0 if randf() < 0.5 else 1.0
	var lamp := Node3D.new()
	lamp.position = Vector3(side * (ROAD_HALF + 1.3), 0.0, z)
	if side > 0.0:
		lamp.rotation = Vector3(0, PI, 0)
	if lamp_scene != null:
		# AI 生成的高精度路灯（灯头位置按模型归一化后重算）
		var inst := lamp_scene.instantiate() as Node3D
		if inst != null:
			var bb := _node_aabb(inst)
			var s := 4.6 / maxf(bb.size.y, 0.01)      # 总高 4.6m
			inst.scale = Vector3(s, s, s)
			inst.position = Vector3(-s * bb.get_center().x, -s * bb.position.y, -s * bb.get_center().z)
			inst.rotation.y = PI * 0.5                 # 灯臂朝向路面
			lamp.add_child(inst)
	else:
		var pole := MeshInstance3D.new()
		pole.mesh = load("res://assets/prop_lamp.obj")
		pole.material_override = _toon(Color(0.42, 0.45, 0.52), {"spec_strength": 0.5})
		_with_outline(pole, 0.012)
		lamp.add_child(pole)
	if lamp_glow_mat == null:
		lamp_glow_mat = StandardMaterial3D.new()
		lamp_glow_mat.albedo_color = Color(1.0, 0.9, 0.65)
		lamp_glow_mat.emission_enabled = true
		lamp_glow_mat.emission = Color(1.0, 0.78, 0.45)
		lamp_glow_mat.emission_energy_multiplier = 0.3
	var glow := MeshInstance3D.new()
	var gs := SphereMesh.new()
	gs.radius = 0.14
	gs.height = 0.28
	glow.mesh = gs
	glow.material_override = lamp_glow_mat
	glow.position = Vector3(0.58, 3.96, 0.0)
	lamp.add_child(glow)
	# 夜晚路灯点光源（V99 大改：原来 range 11 + 不投影 = 夜路"没有光池"，路灯像装饰）
	var ol := OmniLight3D.new()
	ol.light_color = Color(1.0, 0.73, 0.42)   # 暖钠灯色（略偏橙，比纯黄更像真实路灯）
	ol.light_energy = 0.0
	ol.omni_range = 17.0            # 11→17：真正照亮路面与路肩，形成可读的光池
	ol.omni_attenuation = 1.35      # <1 让光心更亮、边缘更快衰减 → 路面上一圈亮斑
	ol.omni_shadow_mode = OmniLight3D.SHADOW_CUBE      # 立方阴影贴图（点光源唯一可用模式）
	ol.shadow_enabled = true   # ⚠️ 属性名是 shadow_enabled，**没有** omni_shadow_enabled（后者不存在，写了会每帧报错）
	ol.shadow_bias = 0.06
	ol.shadow_normal_bias = 0.5
	ol.position = Vector3(0.58, 3.85, 0.0)
	lamp.add_child(ol)
	lamp_lights.append(ol)
	# 灯下光锥：黄昏/夜晚可见的柔和光柱（钠灯下的湿气/雾感），是"路灯灯光照射"最有氛围的一笔
	# V105b：ShaderMaterial 软光锥 —— 旧 StandardMaterial3D 均匀 alpha 渲出来是"实心黄三角"（硬边+上下等亮，最廉价）。
	# 新 shader 三层体积感：灯口亮→地面暗的垂直渐变 + 视线掠射软边 + 锥底渐隐衔接地面光池。
	var cone_mat := ShaderMaterial.new()
	cone_mat.shader = load("res://shaders/light_cone.gdshader")
	cone_mat.set_shader_parameter("cone_color", Color(1.0, 0.80, 0.50))
	cone_mat.set_shader_parameter("fade", 0.0)
	var cone := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.22
	cm.bottom_radius = 3.1        # 向下张开的锥体（灯罩 → 地面光斑）
	cm.height = 3.7
	cm.radial_segments = 20
	cm.rings = 1
	cone.mesh = cm
	cone.material_override = cone_mat
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cone.position = Vector3(0.58, 2.05, 0.0)
	cone.set_meta("is_lightcone", true)
	lamp.add_child(cone)
	lamp_cone_mats.append(cone_mat)
	add_child(lamp)
	scenery.append(lamp)
	_fade_in(lamp)

# ============================================================ 反馈
func _spawn_sparkle(pos: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 18
	p.lifetime = 0.55
	p.one_shot = true
	p.explosiveness = 1.0
	p.position = pos
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 2.5
	pm.initial_velocity_max = 5.5
	pm.gravity = Vector3(0, -5, 0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pm.color = Color(1.0, 0.9, 0.45)
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.05
	mesh.height = 0.1
	p.draw_pass_1 = mesh
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)

func _spawn_feathers(pos: Vector3) -> void:
	var p := GPUParticles3D.new()
	p.amount = 26
	p.lifetime = 1.1
	p.one_shot = true
	p.explosiveness = 1.0
	p.position = pos
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 3.0
	pm.initial_velocity_max = 7.0
	pm.gravity = Vector3(0, -7, 0)
	pm.scale_min = 0.8
	pm.scale_max = 1.6
	pm.color = Color(0.98, 0.98, 1.0)
	p.process_material = pm
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.09, 0.02, 0.14)
	p.draw_pass_1 = mesh
	add_child(p)
	p.emitting = true
	p.finished.connect(p.queue_free)

func _on_player_body_entered(body: Node3D) -> void:
	if game_over or not started:
		return
	if body is RigidBody3D and obstacles.has(body):
		_crash(int(body.get_meta("kind", 0)))

func _crash(kind: int = 0) -> void:
	const OBSTACLE_NAMES := ["路障锥", "油桶", "石头", "轮胎堆", "水马护栏"]
	var hit_name: String
	if kind < 0:
		hit_name = "电量耗尽"
	else:
		hit_name = OBSTACLE_NAMES[clampi(kind, 0, 4)]
	_set_pstate(PState.HIT)   # V108-B：撞击瞬间（保留 0.30s 表现期后再转 GAME_OVER）
	game_over = true
	combo = 0
	dust.emitting = false
	speed_fx.emitting = false
	Engine.time_scale = 0.35
	sfx_crash.play()
	shake = 1.0
	player.apply_central_impulse(Vector3(randf_range(-2200, 2200), 1900, 1500))
	player.axis_lock_angular_x = false
	player.axis_lock_angular_z = false
	player.apply_torque_impulse(Vector3(randf_range(-4000, 4000), 0, randf_range(-3000, 3000)))
	_spawn_feathers(player.global_position + Vector3(0, 0.8, 0))
	if score > best:
		best = score
		_save_best()
	over_stats.text = ("距离  %.0f m\n小鱼  %d\n最高连击  x%d\n用时  %.0f 秒\n最高纪录  %.0f m"
		% [score, fish_count, best_combo, game_time, best])
	if kind < 0:
		_pop_text("电量耗尽!", Color(0.65, 0.85, 1.0))
	else:
		_pop_text("撞上了 " + hit_name + " !", Color(1.0, 0.42, 0.36))
	# 保留 HUD（还能看到时速表与里程），只叠加结算面板
	over_root.visible = true

# ============================================================ 相机 / HUD
func _camera_update(delta: float) -> void:
	var p := player.global_position
	# 撞车后：环绕运镜（电影感慢镜头）
	if game_over:
		crash_orbit += delta * 0.55
		camera.global_position = camera.global_position.lerp(
			p + Vector3(sin(crash_orbit) * 5.5, 2.6, cos(crash_orbit) * 5.5), 0.06)
		camera.look_at(p + Vector3(0, 1.0, 0))
		return
	var target_pos: Vector3
	var look_pos: Vector3
	var fov_base := 60.0
	match cam_mode:
		0:
			# 3/4 后侧追逐：降低机位 + 更贴，更有电影感与速度冲击；正后方(x=0)把车压成细线已规避
			target_pos = p + Vector3(1.45, 2.15, 4.5)
			look_pos = p + Vector3(-0.15, 1.15, -2.6)   # 看向前方 2.6m：速度感 + 纵深
			fov_base = 60.0
		1:
			target_pos = p + Vector3(0, 0.95, 4.6)      # 低角度贴地（更有贴地飞驰感）
			look_pos = p + Vector3(0, 1.05, -5.0)
			fov_base = 62.0
		2:
			target_pos = p + Vector3(3.2, 1.8, 3.2)    # 侧面
			look_pos = p + Vector3(0, 1.15, -1.5)
			fov_base = 58.0
		3:
			# 第一人称：骑手视高，越过车把看到前方与车筐
			target_pos = p + Vector3(0, 1.70, 0.12)
			look_pos = p + Vector3(0, 1.45, -8.0)
			fov_base = 72.0
	var speed_norm := clampf(-player.linear_velocity.z / MAX_SPEED, 0.0, 1.0)
	# 转向时相机轻微朝转向侧偏移，增强操控反馈
	target_pos.x += steer_sm * 1.6
	if cam_mode == 2:
		target_pos.x = p.x + 3.8 * (1.0 if steer_sm >= 0.0 else -1.0)
	# 镜头生命感：手持式微抖（双频有机浮动 + 慢速横/纵漂移），让镜头"活着"而不是死贴三脚架
	target_pos.y += sin(game_time * 9.0) * 0.05 + sin(game_time * 5.3) * 0.03
	target_pos.x += sin(game_time * 1.3) * 0.06
	target_pos.z += sin(game_time * 0.9) * 0.04
	# 第一人称需要即时贴合，其余平滑跟随
	var blend := 1.0 - pow(0.000001 if cam_mode == 3 else 0.0025, delta)
	camera.global_position = camera.global_position.lerp(target_pos, blend)
	camera.look_at(look_pos)
	# 转向时镜头轻微侧倾（banking），强化过弯速度感（每帧 look_at 重置朝向后叠一次纯滚转）
	if cam_mode != 3:
		camera.rotate_object_local(Vector3(0, 0, 1), -steer_sm * 0.05)
		# 慢速手持滚转摇摆：画面有呼吸，不僵直
		camera.rotate_object_local(Vector3(0, 0, 1), sin(game_time * 1.7) * 0.012)
	camera.fov = lerpf(camera.fov, fov_base + speed_norm * 14.0 + sin(game_time * 2.0) * 0.6, 0.05)   # 高速拉 FOV + 轻微呼吸
	if shake > 0.0:
		shake = maxf(shake - delta * 1.8, 0.0)
		camera.h_offset = randf_range(-0.18, 0.18) * shake
		camera.v_offset = randf_range(-0.14, 0.14) * shake
	else:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	# 太阳眩光强度 = 相机朝向太阳的程度 × 白天/黄昏
	if glare_node:
		var cam_fwd := -camera.global_transform.basis.z
		var face := clampf(cam_fwd.dot(cur_sun_dir), 0.0, 1.0)
		glare_node.global_position = camera.global_position + cur_sun_dir * 260.0
		glare_mat.albedo_color.a = pow(face, 3.0) * (1.0 - cur_night_f) * 0.30

# V108-A：调试 HUD 刷新（性能 / 状态一览；只在 F3 或 --debug 下调用）
func _update_debug_hud() -> void:
	if debug_label == null:
		return
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var cpu_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var draws := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var spd := 0.0
	if is_instance_valid(player):
		spd = -player.linear_velocity.z
	debug_label.text = "\n".join([
		"FPS %.1f   帧 %.2f ms" % [fps, 1000.0 / maxf(fps, 0.001)],
		"CPU %.2f ms   物理 %.2f ms" % [cpu_ms, phys_ms],
		"画质 %s   节点 %d   DrawCall %d   图元 %d" % [["高", "中", "低"][quality_mode], nodes, draws, prims],
		"距离 %.0f m   速度 %.1f m/s   障碍 %d   鱼 %d" % [max_dist, spd, obstacles.size(), fishes.size()],
		"场景 %d   路灯 %d   day_time %.3f (%s)" % [scenery.size(), lamp_lights.size(), day_time, _phase_name()],
		"状态 %s  (%.2fs)" % [_pstate_name(), pstate_time],
	])

func _phase_name() -> String:
	var t := day_time
	if t < 0.12: return "清晨"
	elif t < 0.32: return "上午"
	elif t < 0.45: return "正午"
	elif t < 0.55: return "黄昏"
	elif t < 0.72: return "入夜"
	elif t < 0.88: return "深夜"
	return "黎明"

func _pop_text(txt: String, col: Color) -> void:
	# HUD 飘字反馈（吃鱼 / 擦身 / 连击）
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 26)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.65))
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.position = Vector2(700, 690)
	hud_root.add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "position", Vector2(700, 630), 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate:a", 0.0, 0.55)
	tw.tween_callback(l.queue_free)

func _max_speed() -> float:
	# 电量耗尽进入"乏力"状态：上限降到 62%（让电量有玩法意义）
	var cap := MAX_SPEED * (0.62 if battery <= 0.0 else 1.0)
	return minf(START_SPEED + max_dist * 0.018, cap)

# 圆形时速表（自绘表盘）
class SpeedGauge extends Control:
	var value := 0.0
	var max_value := 26.0
	var lbl: Label

	func _ready() -> void:
		custom_minimum_size = Vector2(150, 150)
		lbl = Label.new()
		lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.text = "0"
		lbl.add_theme_font_size_override("font_size", 38)
		lbl.add_theme_color_override("font_color", Color(1, 1, 1))
		lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
		add_child(lbl)
		var unit := Label.new()
		unit.text = "km/h"
		unit.set_anchors_preset(Control.PRESET_FULL_RECT)
		unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		unit.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		unit.position = Vector2(0, 34)
		unit.add_theme_font_size_override("font_size", 14)
		unit.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0, 0.9))
		add_child(unit)

	func set_speed(v: float) -> void:
		value = v
		if lbl:
			lbl.text = str(int(round(v * 3.6)))
		queue_redraw()

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.42
		var a0 := PI * 0.75
		var a1 := PI * 2.25
		# 背板圆环（暗底 + 外微光）
		draw_arc(c, r, a0, a1, 64, Color(0.04, 0.06, 0.12, 0.5), 12.0)
		draw_arc(c, r, a0, a1, 64, Color(1.0, 0.9, 0.7, 0.10), 16.0)
		# 刻度（每 10% 一根，整五更长）
		for i in range(0, 11):
			var ang := a0 + (a1 - a0) * (float(i) / 10.0)
			var d := Vector2(cos(ang), sin(ang))
			var p1 := c + d * (r - 8.0)
			var p2 := c + d * (r - (17.0 if i % 5 == 0 else 12.0))
			draw_line(p1, p2, Color(1.0, 1.0, 1.0, 0.30), 2.5 if i % 5 == 0 else 1.5)
		# 进度弧（暖橙 → 红渐变，速度越高越红）
		var f := clampf(value / max_value, 0.0, 1.0)
		if f > 0.004:
			var col := Color(1.0, 0.72, 0.40).lerp(Color(1.0, 0.22, 0.22), f)
			draw_arc(c, r, a0, a0 + (a1 - a0) * f, 64, col, 9.0)
