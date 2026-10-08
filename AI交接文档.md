# 鹈鹕骑手 3D（Pelican Rider）· AI 交接文档

> **给下一个接手的人／AI**：读完这一份，你就能直接接着干，不用翻聊天记录。
> 最后更新：2026-10-03 18:00 · 当前版本 **V107** · 代码状态：**全部测试通过、可正常渲染、画质二轮升级（2048 去水印贴图 / 程序化天空云层 / 植被细节 shader / mipmap 各向异性修复）已完成**

---

## 0. 三十秒速览

| 项 | 值 |
|---|---|
| 是什么 | Godot **4.7.2** 写的 3D  endless runner（跑酷）游戏 |
| 玩家角色 | 一只骑自行车的白色鹈鹕，海岸公路上躲障碍、吃小鱼、扛电量 |
| 主控脚本 | `scripts/main.gd`（**2970+ 行，全部逻辑都在这一个文件里**） |
| 着色器 | `shaders/` 共 11 个（sky / ocean / toon / cloud / outline / vignette / road / road_paint / grass / light_cone / **foliage**） |
| 当前版本 | **V107**（版本号出现在 HUD 底部提示条 + 开始界面） |
| 测试状态 | headless fulltest / stress×2 **五项错误全 0**，功能自验全绿 |
| 怎么跑 | 双击 `Play-PelicanRider.bat`（**不要**用 Godot 编辑器打开） |
| 硬件 | Windows 11 + RTX 4060 笔记本（i7-13650HX / 24GB） |
| **接手者能力** | **V100 起的 AI 可以正常读图**（`Read` PNG 可用）——审计帧亲眼看，画面判断不必再纯靠数值推断 |

---

## 1. ⚠️ 先读这一节：三个会让接手者栽跟头的核心事实

### ① 我看不到图片（最重要的限制）

上一个 AI 在**整个会话后期才发现**这件事（V96 之后）。`Read` 一张 PNG 会返回：

```
System reminder: the current model does not support images. Content filtered.
```

**后果**：所有"哪里不好看 / 不真实 / 不细腻"的判断，都**不是**看图得出的，而是靠：
- 读代码找结构性问题
- 用 Python（`tools/analyze_v*.py`）做**像素数值体检**（亮度/过曝/死黑/饱和度/天空地面 RGB/噪点）
- 渲染经验推断

**交接后请务必告诉用户这一点**，并请他们描述具体问题或直接发图给你（如果你的模型能看图那就更好）。

### ② `EXIT=0` 是假绿，必须 grep 错误

Godot 即使脚本加载失败也可能返回 `raw_exit=0`。**唯一可信的验证**是 grep 日志：

```bash
grep -c "SCRIPT ERROR"   log   # 脚本错误
grep -c "Parse Error"    log   # 语法/缩进错误
grep -c "Failed to load script" log
grep -c "SHADER ERROR"   log   # 着色器编译错误
grep -c "RUNTIME ERROR"  log
```

⚠️ **特别注意**：`SHADER_ERROR` 不会让功能自验失败——功能自验照样全绿。只能靠数它才发现（V98 就这样漏掉过 2 个着色器编译错误）。

### ③ 引擎属性必须先内省验证，别凭记忆写

V94 踩过：把 Godot3 的 `shadow_filter` 写进 Godot4 → **382 条报错、整工程加载失败**。
V99 踩过：OmniLight3D 写 `omni_shadow_enabled` → **每帧刷 5 条 SCRIPT ERROR**（正确是 `shadow_enabled`）。

**正确做法**（写任何引擎属性前先跑）：

```bash
cat > probe.gd <<'EOF'
extends SceneTree
func _init():
	var o := OmniLight3D.new()
	var have := {}
	for p in o.get_property_list(): have[p["name"]] = true
	for w in ["shadow_enabled","omni_shadow_enabled","omni_range"]:
		print("PROP ", w, " = ", have.has(w))
	quit()
EOF
# 放到项目根目录，然后：
godot_console --headless --path <项目> --script res://probe.gd 2>&1 | grep PROP
rm probe.gd
```

已内省确认**不存在**的属性（别再写）：`directional_shadow_fade_end`、`OmniLight3D.omni_shadow_enabled`、`OmniLight3D.omni_bake_mode`。

---

## 2. 项目结构与文件

```
PelicanRider-Godot/
├── project.godot            # 渲染配置（V98/V99 改过分辨率与抗锯齿）
├── scripts/main.gd          # ★ 全部游戏逻辑，2948 行
├── shaders/
│   ├── sky.gdshader         # 天空：昼/夕/夜 + 太阳眩光 + 银河星空（V99 重做）
│   ├── ocean.gdshader       # 海面：程序化波法线 + 天空反射 + 碎金/月光
│   ├── toon.gdshader        # ★ 角色/道具材质（V98 重写为标准 PBR）
│   ├── cloud.gdshader       # 程序化积云
│   ├── outline.gdshader     # 卡通描边（V84 起默认关闭，O 键可开）
│   ├── road.gdshader        # ★ 路面三层细节（V104）+ 骨料微法线（V105c）
│   ├── road_paint.gdshader  # ★ 标线磨损剥落 + 夜间玻璃珠回反射（V104/V105b）
│   ├── grass.gdshader       # ★ 草地风浪 + 中频斑纹 + 野花（V104/V105b）
│   ├── light_cone.gdshader  # ★ 路灯光锥体积光（V105b，替代实心黄三角）
│   ├── foliage.gdshader     # ★ 植被细节（V106：叶片斑纹/风摆/透光/夜暗剪影）
│   └── vignette.gdshader    # 暗角
├── scenes/Main.tscn         # 只有一个空 Node3D + 挂 main.gd（几乎所有东西代码里建）
├── assets/
│   ├── ai/                  # AI 生成的 GLB 模型 + PBR 贴图（鹈鹕/棕榈/路灯/小屋/灌木/帆船）
│   ├── *.png                # 程序化贴图（沥青/草/沙/全景天空/toon ramp/眩光…）
│   └── *.obj                # 程序化低模（自行车零件/路障/栏杆/伞/草丛…）
├── tools/
│   ├── parsecheck.sh        # ★★ 秒级语法+着色器体检（改完代码先跑这个）
│   ├── analyze_v97.py       # V96 vs V97 像素对比
│   ├── analyze_v95.py       # 三时段像素体检
│   └── run_headless_tests.sh
├── Play-PelicanRider.bat    # ★ 玩家用这个启动
├── Diagnostics.bat          # 排查 Godot 路径
├── Play-Debug.bat           # 前台运行看报错
├── CHANGELOG.md             # ★ 99 个版本的完整历史（V1~V99），必读
└── v9x_*.png                # 历次审计帧
```

**代码规模**：`main.gd` 2948 行 + 6 个着色器共 386 行。

---

## 3. 怎么跑 / 怎么验证（接手者必读）

### 启动游戏（给用户）
```
双击 Play-PelicanRider.bat
```

### Godot 二进制路径
```
GUI 版（真渲染，会弹窗口）：
C:\Users\26483\AppData\Local\Microsoft\WinGet\Packages\
  GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64.exe

Console 版（headless，抓脚本/着色器错误）：
同上但文件名结尾是 _console.exe
```

### 🔴 铁律：验证绝不能弹桌面窗口
用户明确要求过：**"你背后做测试不要搞我界面上影响我操作电脑"**。

- headless 测试：用 `_console.exe --headless`，**安全**
- 要真渲染抓帧：用 GUI 版 + `Start-Process -WindowStyle Minimized`（PowerShell），**最小化不抢焦点**
- ⚠️ **GUI 多实例必须每帧作为独立后台任务单独启动**（golden/dusk/night 各跑一次），不要在一个循环里顺序起多个 → 会 GPU 初始化挂死

### 验证流程（严格按这个顺序）
```bash
cd "C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"

# 第 1 步：秒级体检（语法 + 着色器）—— 改完代码立刻跑
bash tools/parsecheck.sh

# 第 2 步：完整功能测试（约 4~5 分钟）
godot_console --headless --path . --fulltest > ft.log 2>&1
# 然后 grep 五个错误（见 §1②）
```

### 抓审计帧（GUI 真渲染）
```powershell
$exe="C:\...\Godot_v4.7.2-stable_win64.exe"
$proj="C:\Users\26483\WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot"
# 关键：必须 dangerouslyDisableSandbox，否则 Godot 写 Vulkan 缓存会被沙箱拦截 → 静默失败无 PNG
Start-Process -FilePath $exe -ArgumentList `
  "--path","$proj","--autoshot","--autocam=0","--autoday=0.47","--shotname=v99_sunset" `
  -WindowStyle Minimized -PassThru -Wait
```

**autoshot 参数**：`--autoshot`（240 帧抓图后自动退出）· `--autocam=N`（0追尾/1低角/2侧面/3第一人称）· `--autoday=F`（0~1 时间轴，0.25=正午 0.47=夕阳 0.80=深夜）· `--shotname=X`（存 `res://X.png`）

⚠️ **沙箱坑**：GUI 渲染时 Godot 要写 `app_userdata/.../vulkan/pipelines.*.cache`，被沙箱拦截会**静默失败**（exit=0 但没有 PNG）。**判断依据：无 PNG 就是被拦了**，必须加 `dangerouslyDisableSandbox=true` 重跑。

### 其他测试模式
| 命令 | 作用 |
|---|---|
| `--fulltest` | 完整功能自验（跳跃/吃鱼/撞车/夜晚/电量/重开/四机位） |
| `--stress` | 长局压测，无敌，跑到帧 1000+，覆盖昼夜 + 海量生成回收 |
| `--stress --nogod` | 压测撞车与重开路径 |
| `--bare` | 极简环境（只建场景，秒级，用于快速验证着色器） |
| `--verify` | 打印位置/分数/障碍数等 |
| `--shot --shot_frame=N` | 指定帧数抓图 |

---

## 4. 游戏设计现状

### 核心循环
骑车前进 → 躲障碍（5 种）→ 吃小鱼（加分+回电）→ 攒里程 → 里程换电量 → 电量耗尽/撞车则结束。

### 关键常量（`main.gd` 第 8~18 行）
```gdscript
const ROAD_HALF := 4.5      # 路面半宽（总宽 9m）
const START_SPEED := 11.0
const MAX_SPEED := 26.0
const ACCEL := 8.0
const JUMP_SPEED := 9.0     # 滞空约 1.6s
const MASS := 80.0
const STEER_SPEED := 5.2
const FISH_BASE := 5.0
const NEAR_MISS_BONUS := 3.0 # 擦身而过奖励
const COMBO_STEP := 5
const AHEAD := 200.0        # 前方预生成距离（米）
const COMBO_WINDOW := 4.0   # 连击窗口（V98 新增）
```

### 玩法系统
- **电量**：持续下降（`0.30 + 速度*0.02`/秒），吃鱼 +6%，每 250m 里程碑 +22%；耗尽 → 强制结束。上限降到 62% 速度
- **连击**（V98 重做）：吃鱼累积，**4 秒窗口**内没吃下一条就清零；有可见进度条
- **难度曲线**：障碍间距随 `max_dist` 收紧（`26 - dist*0.006` ~ `44 - dist*0.009`）
- **镜头**：C 键四档（0追尾 / 1低角 / 2侧面 / 3第一人称）
- **其它按键**：Q 画质三档 · O 描边 · P 截图 · Esc 暂停 · M 静音 · R 重来 · 空格/↑ 跳跃 · A/D 或 ←/→ 转向

### 昼夜循环
`day_time` 0→1 循环，`DAY_LENGTH` 一天real时长。太阳高度用**非对称曲线**（V99）：升段振幅 0.62（正午 el≈0.72 ≈46°），降段 0.40（下落慢 → 夕阳停留久）。
派生量：`day_f` / `night_f` / `dusk_f` / `golden`（黄金时刻权重）/ `lamp_f`（路灯提前亮）。

---

## 5. 资产现状

### AI 生成（`assets/ai/`，混元 3D 管线，每个都有 GLB + preview + PBR 三图）
`ai_pelican.glb`（**当前主角**：站姿鹈鹕，骑程序化自行车）· `ai_rider.glb`（整组"鹈鹕骑自行车"合并网格，**当前关闭**）·
`ai_palm.glb`（棕榈）· `ai_lamp.glb`（路灯）· `ai_hut.glb`（小屋）· `ai_bush.glb`（灌木）· `ai_boat.glb`（帆船）

### ⚠️ 资产限制与 V109 的解法（**重要，别再踩**）
**所有 AI GLB 都是单一合并网格**（`ai_pelican.glb` 经二进制解析 = 1 node / 1 mesh / 1 primitive / **无 skin**），
且经连通分量分析确认是**单连通壳**（19987 唯一顶点全连通）→ **既不能单独转肢体，也不能"切部件"（切了会裂）**。

**V109-C 的解法（已落地，见 `scripts/pelican_rig.gd`）**：
运行时把这块焊死网格重建为 **Skeleton3D + Skin + 带顶点权重的 ArrayMesh**（8 根骨：root/spine/head/wing_l/wing_r/tail/leg_l/leg_r）。
顶点不动、只加权重 → 形变连续无裂缝，完整保留 AI 贴图/法线/UV。
现在**头可回看、翅可扇动、腿可蹬踏、尾可摆动**。

关键实现要点（血泪，照着做）：
1. **Skin 必须用 `Skeleton3D.create_skin_from_rest_transforms()` + `register_skin()`**；
   手工 `Skin.add_bind()` 拼的 Skin 在渲染端不生效（网格会被整体放大 1.27² 并上移）。
2. **`mesh_inst.skeleton` / `mesh_inst.skin` 必须在节点进入场景树后（`_ready()`）才赋值**，
   树外赋值会让渲染端拿到无效绑定。
3. 骨骼局部偏移要减**父骨的全局位置**（不是父骨的局部偏移），否则逐级累加。
4. `get_bone_global_pose()` 是**骨架局部空间**坐标，且无帧循环时读回是陈旧缓存。
5. 权重分区的硬约束（**改权重函数会立刻被自检抓到**）：翼骨主导顶点必须 `|Z|≥0.19`（否则抬翅会拖胖躯干）、腿骨主导顶点必须 `Y<0.42`。

**回归测试（改 `pelican_rig.gd` 后必跑）**：
```
godot --headless --path . --script tools/rig_selftest.gd   # 14 项断言，覆盖三大坑 + 权重分区
```

**调试开关**：`--rigfrozen`（冻结骨骼）· `--rigprobe`（并排放未蒙皮对照网格）· `--rigdemo=骨名:degX,degY,degZ`（固定极端姿态，`;` 分隔多骨）。

**⚠️ 别用截图对比来断言形变**：非受控渲染（相机/云层会动）像素差可达 27%，肉眼对比毫无意义。
要么用上面的权重断言，要么用 `--rigfrozen` / 同机位同光照的受控截图。

**性能基线**（V109 起有效）：`logs/V109/perf-baseline-20261005-0531.txt`（高档 ~80 FPS / 中低档 ~135 FPS）。
⚠️ `logs/V108/` 下那份**作废**（`--autoday/--autocam` 未生效），已移入 `_archive/V108-stale-perf/`。

### 程序化贴图（`assets/*.png`）
`asphalt.png` + `asphalt_normal.png` · `grass.png` + `grass_normal.png` · `sand.png` + `sand_normal.png` · `sky_pano.png`（AI 全景黄昏海岸，**只在黄昏时段使用**）· `toon_ramp.png` · `glare.png`（眩光 sprite）· `feather.png` · `wicker.png`

### 程序化低模（`assets/*.obj`，`tools/build_assets.py` 生成）
自行车零件（frame/fork/chainring/chain/saddle/crankset…）· 路障（锥/桶/石/轮胎堆/水马）· 栏杆 · 遮阳伞 · 草丛 · 石头 · 树 · 路灯 · 招牌 · 小屋 · 海鸥

---

## 6. 会话历史摘要（V93~V99，重点是思路演变）

> 完整细节在 `CHANGELOG.md`（99 个版本）。这里只讲**思路是怎么演变的**，因为这才是交接后最需要的。

### 阶段 A：V93~V96 —— "堆料"阶段（方向错了但有价值）
- **V93/V94**：综合提升、UI 描边、时速表、阴影升级。修了 `shadow_filter` 那个 382 条报错的坑
- **V95**：**顶级电影感五维** —— 体积光 god rays、海面真反射天空、银河星空、植被背光透光、电影泛光调校
- **V96**：**去僵硬** —— 诊断出根因是"AI 模型焊死 + 程序化腿翅被隐藏"，用双谐波颠+泵动+蛇形+相机手持感让整组"活起来"

### 阶段 B：V97 —— "抠细节"（用户仍不满意）
用户："不够细节真实" + "场景不到位"。做了：压太阳过曝、路面轮胎磨痕、路灯黄昏亮、栏杆/棕榈打破重复、草丛加密、遮阳伞不再插进海里。

**结果：用户还是说不行。** 事后看，这 6 项全是"调参数/加摆件"，治不了根本。

### 阶段 C：V98 —— 挖到真正的病根（转折点）
用户："还是不行，bug多，画质垃圾"。**先自查：V97 清单 100% 完成、没遗漏，但方向错了。**

挖出三个结构性元凶：
1. **`scaling_3d/scale=1.5` → 3D 只渲染 66% 分辨率再放大** = 全画面糊
2. **`toon.gdshader` 用自定义 `light()` 只累加 DIFFUSE_LIGHT** → ①METALLIC/ROUGHNESS 从未被 BRDF 消费（万物塑料片）②**SSAO/SSIL/阴影/反射探针全部不参与**（物体与场景脱层）③边缘光靠 EMISSION 硬叠（夜里像发光体）
3. SSR 被之前错误地关掉了（理由是"材质是假光照，开了会拖影发糊"）

同时修了两个真 bug：**连击系统完全失效**（`combo` 只在结算归零，游戏中只增不减 → 玩久奖励白拿）、`:=` 遮蔽成员变量。

### 阶段 D：V99 —— 光影专项 + 发现 V98 的漏点
用户点名五个元素："阳光照射夏日感，影子，夕阳，晚上，星空，路灯灯光照射"。

**⭐ 又发现一个重大漏点**：`_apply_quality()` 里"高画质"档写着 `vp.set("scaling_3d_scale", 1.5)`，**在运行时覆盖了 project.godot 的 1.0** —— 这就是"V98 改了配置却依然显糊"的真正原因。

教训（已写入记忆）：**改渲染参数必须 grep 代码里所有赋值点，只改配置文件会白改。**

---

## 7. V98 & V99 具体改了什么（最近的成果，接手者的起点）

### V98：渲染管线返工
| 项 | 改动 |
|---|---|
| 分辨率 | `scaling_3d/scale 1.5 → 1.0`（原生 1080p） |
| 抗锯齿 | `msaa_3d 2→3`（8x MSAA）+ **新增 TAA**（`use_taa=true`, `taa_samples=16`） |
| 材质 | `toon.gdshader` **重写为标准 PBR**（`diffuse_burley` + `specular_schlick_ggx`），移除自定义漫反射，边缘光/透光降为加性项 |
| 材质身份 | `_toon()` 新增 `roughness`/`metallic` 覆盖参数；车架=烤漆金属、牙盘链条=钢、眼睛=玻璃、沥青 r0.86、标线 r0.72、栏杆 r0.55 |
| SSR | **重新开启**（PBR 正确后）+ 沥青 `metallic_specular 0.62` |
| SSAO | `intensity 1.35→1.55`、`power 1.6→1.8`、**新增 `ssao_detail 0.6`** |
| SSIL | `radius 3→4`、**新增 `ssil_normal_rejection 1.0`** |
| 海面 | 新增高频细浪/毛细波（三方向三相速） |
| bug | 连击系统重做（4 秒窗口 + 可见进度条） |
| 玩法 | 里程碑每 250m 回电 +22% + 奖励分 +30 |

### V99：光影专项（五个元素）
| 元素 | 改动 |
|---|---|
| **夏日** | 太阳高度改**非对称曲线**（正午 el 0.46→0.72 ≈46°）；太阳色改用 `golden` 权重独立控制（夏日暖白 5500K ↔ 低角度火红橙） |
| **影子** | **4 级 CSM**（`SHADOW_PARALLEL_4_SPLITS`）分割 12/45/110；`max_distance 130→260`；`blend_splits`；`shadow_blur 2.0→1.35`；bias 三件套；`shadow_opacity 0.92`；`light_angular_distance 0.6`；新增 `_apply_shadow_quality()` 随画质降级 |
| **夕阳** | 天空加**夕阳专属三段垂直渐变**（地平线火红→中层橙粉→天顶紫蓝）；`dusk_hor` 更火红 |
| **夜晚** | 月光 0.85→1.05 且更蓝；月影 2 级 CSM + `shadow_opacity 0.75`；**环境光夜间底子 0.50→0.16**（夜空发灰的元凶） |
| **星空** | 重做：①银河带多层带状噪声+云絮明暗+银心更亮更暖 ②**暗尘带**（黑色尘埃裂缝，真实感关键）③恒星三层各带独立闪烁+**色温变化**+银心方向星更密 |
| **路灯** | `omni_range 11→17`、`omni_attenuation 1.35`、`light_energy 2.6→4.2`、开**立方阴影**（性能保护：只让最近一盏 d<26m 投影）、**新增灯下光锥**（加性混合锥体，随 `lamp_f` 渐显） |

### 客观像素验证结果（V99 三帧）
| 时段 | 亮度 | 过曝 | 死黑 | 天空 RGB | 判读 |
|---|---|---|---|---|---|
| 夏日 | 0.651 | 0.14% | 0.01% | 0.63/0.70/**0.74** | B 最高 = 真夏日蓝天 ✅ |
| 夕阳 | 0.622 | 0.78% | 0.01% | **0.75**/0.68/0.62 | R>G>B = 火红晚霞 ✅ |
| 夜晚 | 0.246 | 0.03% | 2.23% | 0.26/0.29/0.33 | 亮度 0.284→0.246，夜空真深了 ✅ |

---

## 8. 踩过的坑（血泪教训，别重复）

### 缩进 bug —— **踩了 5 次**（V83/V92/V95/V98 + 这次会话）
GDScript 缩进错误 → `Parse Error` → **整工程加载失败** → 完整测试挂死（跑满 7 分钟被 timeout 杀）。

**正确做法**：
```bash
# 1. 改完立刻秒级体检（这是 V98 新建的工具，专治这个坑）
bash tools/parsecheck.sh
# 2. 检查有没有空格缩进（Godot 风格必须用 Tab）
grep -n "^ \+[^ *]" scripts/main.gd    # 应该无输出
```
最常见的错：改 for 循环体内的行时多塞了一个 Tab。

### 其它坑
| 坑 | 后果 | 教训 |
|---|---|---|
| `EXIT=0` 假绿 | 以为测试通过 | 必须 grep 五项错误 |
| `light()` 里写 `EMISSION` | 着色器编译失败，但**功能自验照样全绿** | Godot4 `light()` 只允许 `DIFFUSE_LIGHT`/`SPECULAR_LIGHT`/`ATTENUATION` |
| 凭记忆写引擎属性 | V94: 382 条报错；V99: 每帧 5 条报错 | 写前先 `get_property_list()` 内省 |
| `:=` 遮蔽成员变量 | HUD 引用失效但不报错 | 新增局部变量用 `var x :=` |
| 在 `light()` 里覆盖全部光照 | SSAO/SSIL/阴影/反射全失效（V98 最大的坑，耗时最久才找到） | 优先用标准 PBR，把特效降级为加性项 |
| 只改配置文件不改运行时赋值 | V98 白改一轮 | 改渲染参数要 grep 代码里所有赋值点 |
| GUI 多实例顺序启动 | GPU 初始化挂死 | 每帧独立后台任务 |
| Godot 写 Vulkan 缓存被沙箱拦 | exit=0 但无 PNG，静默失败 | 无 PNG 就是被拦了，加 `dangerouslyDisableSandbox` |
| **`--stress` 模式曾漏在启动条件外** | 压测一直在空转（障碍/鱼恒为 0），完全没覆盖真实逻辑 | V76 修好；新增测试模式记得加进 `_ready` 的启动判断 |
| 锐度指标 `lap_var` 误导 | V98 数值下降，看着像变糊 | `lap_var` 把**噪点和锯齿当细节**；必须配合 speckle（孤立极值点占比）分离。V98 的噪点 1.03%→0.44% 说明 TAA 起作用了 |
| **Godot OBJ 导入器翻转 vt.y** | 按"未翻转"推导滚动公式 → 地面往前冲（V104c 用户实测 bug） | 源码铁证 `resource_importer_obj.cpp:314`：`uv.y = 1.0 - y`。**任何按 OBJ UV 推导的滚动/偏移公式必须按翻转后坐标算** |
| **TAA 与 treadmill 滚动不兼容** | 所有地面像素每帧都在动 → TAA 当相机抖动累积 → 近景虚线糊成白带、颗粒全失（V104c） | `use_taa=false` 永久关闭（MSAA 8x 兜底）。**无尽跑酷的滚动地面不能用 TAA** |
| **程序化噪声输入随里程无限增长** | float32 `hash(fract(p*234.34))` 精度崩坏 → 长玩后图案闪烁（V104 预防性修复） | 所有 shader 的 `hash21` 入口加 `p = mod(p, 512.0)`。**千万别删** |
| **1.5x 超采样 ≠ 梯度锐度提升** | V105 量化指标几乎无变化，误判"超采样没生效" | `get_viewport().get_texture()` 拿的是**视口最终呈现尺寸**，超采样收益体现在"降采样抗锯齿"，梯度锐度是**应该降低**的。判断超采样要看边缘洁净度/颗粒细腻度，不能用锐度指标 |
| **`scaling_3d/mode=1`(FSR) 配超采样** | 每次启动报 `FSR... not designed for downsampling. Falling back to bilinear` | 超采样（scale>1）时用 `mode=0`（bilinear）显式声明，别依赖 fallback |
| **多层均匀 alpha 的"光柱/光锥"= 廉价感** | 路灯写真空黄三角（V105b 夜帧最大丑点） | 体积光必须做**垂直渐变 + 视线掠射软边**两层；用 `VERTEX.y` 求高度而非赌 UV 约定 |
| **贴图 `mipmaps/generate=false` → 各向异性过滤静默失效** | V105 加的 anisotropic hint 完全没生效，掠射视角细节全丢（V107 才发现） | 凡是要用 `filter_linear_mipmap_anisotropic` 的贴图，**必须先在 .import 里开 `mipmaps/generate=true`**。改完要跑一次 `--editor --quit` 重新导入 |
| **AI 生成贴图带「AI生成 WORKBUDDY」水印** | 夜灯下路面隐约显形"AI生"字样（长期瑕疵） | ⚠️ "取块时绕开"**会失败**（窗口边界算紧一点就漏进去，踩过 2 次）。正解：先定位水印矩形（归一化 y 0.40-0.53 / x 0.32-0.55）→ **inpaint 覆盖** → 再自由取块。验收用模板互相关（原图 0.695 → HD 0.38） |
| **AI 植被夜里亮绿压不下去** | 只压 ALBEDO 无效 —— PBR 的 Sky 环境光**独立**给叶片补绿光 | 必须同时设 **`AO_LIGHT_AFFECT = 1.0 - night_f*0.85`** 削弱间接光。另：换过材质后要保证每帧驱动 `night_f`（否则夜暗直接失效） |
| **程序化云用平面投影** | 直接在 sky() 里按 EYEDIR 画噪声没有透视感 | 用 `EYEDIR.xz / EYEDIR.y` 投影到高空平面再采样噪声 → 天然获得正确的透视收缩 |

---

## 9. 「看不见图」时怎么迭代（方法论，重要）

既然无法看图，就必须靠**客观数据 + 用户反馈**闭环。上一轮摸索出的有效流程：

### 有效的诊断手段
| 手段 | 怎么做 | 能回答什么 |
|---|---|---|
| **像素体检** | `tools/analyze_v97.py`（可改文件名复用）统计亮度/过曝/死黑/饱和度/天空地面RGB/噪点 | 时序亮度是否正确、过曝是否受控、夜空是否死黑、颜色倾向是否合理 |
| **噪点分离** | 比较 `lap_var`（拉普拉斯方差）与 speckle（`abs(lap)>60` 的像素占比） | 区分"真细节"与"锯齿噪点"——**只看 lap_var 会被误导** |
| **每帧数值验证** | headless `--autoshot` 跑 N 帧打印目标 transform/数值 | 客观证明"动没动"、"值不对"，比看静态图可靠（V96 用这招验证动画） |
| **代码审计** | 读材质/光照/配置，找**结构性**问题 | 真正的病根往往在这（V98 的三个元凶都是这么找到的） |
| **引擎内省** | `get_property_list()` 确认属性存在 | 避免硬写不存在属性导致整工程失败 |

### 迭代节奏（照做，别乱改）
```
1. 用户给反馈（"不真实"/"不细腻"这类主观描述）
2. 先审计代码找结构性原因 ← 优先级最高，不要先调参数
3. 改完立刻 bash tools/parsecheck.sh
4. headless fulltest + grep 五项错误
5. 渲染三帧审计图，跑像素体检对比数字
6. 把改动与客观数字一起汇报给用户，请他看图确认
```

### ⚠️ 最重要的一条教训
**V97 是"调参数/加摆件"治"不真实"，全部做完用户还是说不行。** 因为病根在渲染管线本身（分辨率、材质光照模型）。

**所以：用户抱怨"画质差/不真实/不细腻"时，先怀疑架构与管线，再怀疑参数。** 别急着加细节、加装饰、调数值。

---

## 10. 接手时建议的优先事项

### 🔴 先做（成本低、收益高）
1. **让用户描述具体问题**（因为 AI 看不见图时可问）："画面里最刺眼/最假的是哪一块？"（AI 现在能读图，优先自己看）
2. ~~**确认性能**~~ ✅ **已做（V109）**：高档 ~80 FPS / 中低档 ~135 FPS，见 `logs/V109/perf-baseline-20261005-0531.txt`。瓶颈在超采样 + MSAA
3. ~~**清理项目根目录**~~ ✅ **已做（V108/V109）**：历史诊断图与日志全部归档到 `_archive/`，根目录 **0 散落文件**

### 🟡 可以做
4. ~~**真·骨骼动画**~~ ✅ **已做（V109-C）**：不换模型，改为**运行时重建骨架**（`scripts/pelican_rig.gd`）。腿/翅/头/尾已可独立运动
5. **玩法深度**：目前只有"躲障碍+吃鱼+没电"。可加：技能系统、场景事件（隧道/弯道/跳台）、难度层级、收集图鉴
6. **物件穿插检查**：V97 修过遮阳伞插进海里（沙滩带 x∈[-11.5,-4.5]，伞原本跑到 -13.5）。类似穿帮可能还有别的位置

### 🟢 长期
7. 把 `main.gd` **3353 行**拆分（世界构建 / 玩家 / 场景生成 / UI / 昼夜 各一个文件）。本轮已把"角色骨骼"拆成独立脚本（`pelican_rig.gd`），可照此模式继续
8. 加单元测试（现在只有 headless 自验脚本）

---

## 11. 关键文件速查

| 想改什么 | 去哪个文件/行 |
|---|---|
| 游戏常量（速度/跳跃/得分） | `scripts/main.gd` 8~18 |
| 昼夜循环、太阳月亮、灯光时序 | `scripts/main.gd` ~296~360 |
| 环境（Environment/雾/泛光/调色） | `scripts/main.gd` ~700~760 |
| 阴影质量分档 | `scripts/main.gd` `_apply_shadow_quality()` |
| 画质三档 | `scripts/main.gd` `_apply_quality()` ⚠️ **这里覆盖 project.godot 的分辨率** |
| 相机 | `scripts/main.gd` `_camera_update()` ~2750 |
| 场景生成（路障/鱼/树/栏杆/伞/灯） | `scripts/main.gd` 2100~2450 |
| 路面/草地/沙地材质 | `scripts/main.gd` ~925~990 |
| 天空（昼/夕/夜/太阳/银河） | `shaders/sky.gdshader` |
| 海面 | `shaders/ocean.gdshader` |
| 角色/道具材质 | `shaders/toon.gdshader` + `_toon()` ~1490 |
| UI/HUD | `scripts/main.gd` ~1650~1850 |
| 完整版本历史 | `CHANGELOG.md`（99 节，**强烈建议先读 V95~V99**） |

---

## 12. 验证命令速查（复制粘贴用）

```bash
PROJ="C:/Users/26483/WorkBuddy/2026-09-29-21-13-37/PelicanRider-Godot"
GODOT="C:/Users/26483/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe"
UDIR="C:/Users/26483/AppData/Roaming/Godot/app_userdata/鹈鹕骑手 3D (Pelican Rider)"

# 秒级体检（改完代码立刻跑）
bash "$PROJ/tools/parsecheck.sh"

# 完整功能测试
rm -f "$UDIR/ft_done"
timeout 400 "$GODOT" --headless --path "$PROJ" --fulltest > "$PROJ/ft.log" 2>&1
for k in "SCRIPT ERROR" "Parse Error" "Failed to load script" "SHADER ERROR" "RUNTIME ERROR"; do
  echo "$k = $(grep -c "$k" "$PROJ/ft.log")"
done

# 压测
timeout 400 "$GODOT" --headless --path "$PROJ" --stress > "$PROJ/stress.log" 2>&1
timeout 400 "$GODOT" --headless --path "$PROJ" --stress --nogod > "$PROJ/stress_ng.log" 2>&1
```

---

## 13. 最后的话

**给接手者**：这个项目最大的资产是 `CHANGELOG.md` 里 100+ 个版本的血泪记录——很多"看起来很简单"的问题（模型朝向、轮子装歪、颜色不对、模型尺寸全错、CSM 比例）都是前人花大量时间定位的。**动手前先搜 CHANGELOG，别重复劳动。**

**给用户**：项目已迭代到 **V109**。V100 起接手 AI 能读图，画面已亲眼审计过五轮（夏日/黄昏/夜晚），"零阴影""白纱""银海""夜植发光"四个大顽疾已全部修复；V104 把路面/海面/草地三大材质全部换成程序化多层 shader；**V108** 加了角色状态机 / 调试 HUD / 性能采样；**V109 完成"脱胎换骨"——运行时重建骨架，主角首次能真蹬腿 / 扇翅 / 回头**。测试全绿，性能实测高档 ~80 FPS。

已知的主要未解问题：
1. ~~**AI 鹈鹕模型焊死**，没有真正的蹬腿/扇翅动画~~ ✅ **V109-C 已解决**（运行时骨架蒙皮，8 根骨）。**残余**：线性混合蒙皮在大角度下有轻微体积收缩（翼尖可见拉伸），彻底解决需双骨权重 + 辅助骨
2. ~~**性能开销大**，尚未实测帧率~~ ✅ **V109 已实测**：高档 ~80 FPS（1.5× 超采样 + 8× MSAA 全开）/ 中低档 ~135 FPS。瓶颈在超采样 + MSAA。⚠️ 高档 `min FPS` 偶见 32（疑似偶发卡顿，未定位）
3. ~~项目根目录堆满历史诊断文件~~ ✅ **已整理**（`_archive/`，根目录 0 散落）
4. 路面标线在正午仍带轻微蓝调（天空环境光物理所致，已有配平；再调会牺牲自然感）
5. **程序化噪声已做 mod 512 平铺化**：路面车辙/坑洼图案周期约 465~1219m、高频颗粒 5.8m——理论上长骑会撞见重复，实际不可感；若未来有人"优化"掉 mod 512 会复活长时游玩精度崩坏 bug（图案闪烁），千万别删
6. **V104c 两大铁律（踩过坑的）**：① Godot OBJ 导入器**翻转 vt.y**（源码 `1.0 - y`），任何按 OBJ UV 推导的滚动公式必须按翻转后坐标算，符号反了地面就"向前跑"；② **TAA 必须保持关闭**（`use_taa=false`）——treadmill 滚动让所有地面像素每帧都在动，TAA 会把近景虚线糊成白带、路面颗粒抹掉。MSAA 8x 已兜底抗锯齿。
7. **⚠️ 项目仍在 WorkBuddy 会话目录**（`WorkBuddy\2026-09-29-21-13-37\PelicanRider-Godot\`）——有被清理误伤的风险，建议迁到稳定代码目录
7. 调试参数：`--scrollat=X` 固定路面滚动值（视觉 A/B 验滚动方向）；`--hide=scenery,obstacles,fishes,player,backdrop` 隐藏元素（V104c 起对后 spawn 的节点也生效）。
