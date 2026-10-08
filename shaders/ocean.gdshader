shader_type spatial;

// 海面：在片段着色器里解析算法线（不靠几何体分段），做出太阳闪光 / 菲涅尔天空反射 / 深浅渐变。
// 原实现是纯色平板（PlaneMesh 默认 1 分段，顶点波无效），看起来很糙；现在逐像素扰动法线，
// 阳光打在起伏水面上会出现"碎金"闪光，海面立刻变细腻、有晒太阳的波光感。
uniform vec4 deep_color : source_color = vec4(0.015, 0.10, 0.27, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.06, 0.40, 0.54, 1.0);
uniform float wave_height : hint_range(0.0, 2.0) = 0.5;
uniform float wave_speed : hint_range(0.0, 4.0) = 1.1;
uniform float wave_scale : hint_range(0.05, 3.0) = 0.35;
uniform float day_f : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_dir = vec3(0.4, 0.6, 0.5);   // 世界空间太阳方向（由主脚本每帧传入；勿加 source_color 提示，否则会被夹到 [0,1]）
uniform float sun_strength : hint_range(0.0, 6.0) = 3.4;
uniform float sun_shininess : hint_range(1.0, 400.0) = 60.0;
uniform float night_f : hint_range(0.0, 1.0) = 0.0;

varying vec3 wpos;

// --- 2D value noise：岸线泡沫碎化用 ---
float hash21(vec2 p) {
	p = mod(p, 512.0);   // V104b：输入安全域 —— 世界坐标/时间随里程无限增长，float32 hash 会精度崩坏（长玩后图案闪烁）；mod 512 让噪声平铺化，周期从千米级到分钟级均不可感
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 多频正弦叠加的波高（用于法线梯度与深浅微调）
float wave_h(vec2 p, float t) {
	// 后两个分量用旋转域向量 + 各自相速 → 打破"沿路平行条纹"的刷痕感
	vec2 q = vec2(p.x * 0.8 - p.y * 0.6, p.x * 0.6 + p.y * 0.8);
	return sin(p.x * wave_scale + t) * 0.55
	     + sin(q.y * wave_scale * 0.9 + t * 0.73) * 0.42
	     + sin((q.x + p.y) * wave_scale * 1.6 + t * 1.52) * 0.28;
}

// 程序化天空反射：给定反射射线方向，返回与 sky.gdshader 同梯度的天空色 + 日月倒影高光，
// 让海面真正"镜像"天空与太阳/月亮（顶级水面质感的关键，替代原来固定淡天色）
vec3 sky_reflect(vec3 dir) {
	float h = dir.y;
	vec3 day_top   = vec3(0.10, 0.32, 0.86);
	vec3 day_hor   = vec3(0.36, 0.58, 0.88);   // V100：反射源天空同步加深 —— 海面镜像的是"蓝"天而不是白天那条白亮地平线
	vec3 dusk_top  = vec3(0.25, 0.28, 0.52);
	vec3 dusk_hor  = vec3(1.00, 0.60, 0.42);
	vec3 night_top = vec3(0.015, 0.025, 0.07);
	vec3 night_hor = vec3(0.07, 0.09, 0.18);
	vec3 top = mix(mix(dusk_top, day_top, day_f), night_top, night_f);
	vec3 hor = mix(mix(dusk_hor, day_hor, day_f), night_hor, night_f);
	vec3 c = mix(hor, top, pow(clamp(h, 0.0, 1.0), 0.38));
	// 太阳 / 月亮倒影高光
	vec3 sd = normalize(sun_dir);
	float s = clamp(dot(dir, sd), 0.0, 1.0);
	vec3 glow_col = mix(vec3(1.0, 0.55, 0.32), vec3(1.0, 0.92, 0.70), day_f);
	c += glow_col * pow(s, 200.0) * 1.6 * (1.0 - night_f);   // 紧贴日轮倒影
	c += glow_col * pow(s, 14.0) * (0.10 + day_f * 0.10) * (1.0 - night_f);  // 日冕晕
	vec3 md = normalize(-sd);
	float m = clamp(dot(dir, md), 0.0, 1.0);
	c += vec3(0.90, 0.93, 1.0) * pow(m, 300.0) * night_f;    // 月亮倒影
	return c;
}

void vertex() {
	// 平面只有 1 分段，但平面是平的 → 插值出的世界 XZ 逐像素依然精确，足以驱动逐像素波函数
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME * wave_speed;
	vec2 p = wpos.xz;

	// 波高解析梯度（中心差分），得到水面坡度
	float e = 0.05;
	float hx = (wave_h(p + vec2(e, 0.0), t) - wave_h(p - vec2(e, 0.0), t)) / (2.0 * e);
	float hz = (wave_h(p + vec2(0.0, e), t) - wave_h(p - vec2(0.0, e), t)) / (2.0 * e);

	// 世界空间法线：以几何法线（+Y）为基，叠加坡度扰动
	vec3 nView = normalize(NORMAL);
	vec3 nWorld = normalize((INV_VIEW_MATRIX * vec4(nView, 0.0)).xyz);
	nWorld = normalize(nWorld + vec3(-hx, 0.0, -hz) * wave_height * 5.0);

	// V98：细浪/毛细波 —— 之前只有大尺度涌浪，海面在近处显得"匀"、像一块布。
	// 叠一层高频小波（三个不同方向/相速），让近景海面有真实的细碎质感与 sparkle。
	float e2 = 0.012;
	float t2 = t * 1.9;
	float fx = (wave_h(p * 5.7 + vec2(0.3, -0.2), t2) - wave_h(p * 5.7 - vec2(0.3, -0.2), t2)) / (0.6);
	float fz = (wave_h(p * 5.7 + vec2(-0.2, 0.3), t2) - wave_h(p * 5.7 + vec2(0.2, -0.3), t2)) / (0.6);
	nWorld = normalize(nWorld + vec3(-fx, 0.0, -fz) * 0.16 * (0.35 + 0.65 * day_f));
	// 把扰动后的世界法线写回视图空间，让 Godot 自带光照（太阳/补光/阴影）也跟着起伏
	NORMAL = normalize((VIEW_MATRIX * vec4(nWorld, 0.0)).xyz);

	vec3 Vworld = normalize(CAMERA_POSITION_WORLD - wpos);

	// 深浅颜色随波高微调 + 白天/夜晚
	float wh = wave_h(p, t);
	vec3 deep = mix(vec3(0.015, 0.05, 0.13), deep_color.rgb, day_f);
	vec3 shal = mix(vec3(0.04, 0.10, 0.20), shallow_color.rgb, day_f);
	vec3 base = mix(deep, shal, clamp(wh * 0.5 + 0.5, 0.0, 1.0));

	// V104：近岸浅滩分层 —— 海面右缘 x=-11.4 是岸线，向 -x 逐渐变深。
	// 浅水透沙底呈青绿色、反射压低（能"看进"水里），13m 过渡到远海深蓝。
	float shore_d = max(-11.4 - wpos.x, 0.0);
	float depth_f = clamp(shore_d / 13.0, 0.0, 1.0);
	float lago_wave = clamp(wh * 0.5 + 0.5, 0.0, 1.0);
	vec3 lagoon = mix(vec3(0.03, 0.09, 0.13), vec3(0.24, 0.63, 0.58), day_f);   // V105：浅滩更碧绿（热带近岸水质感）
	lagoon *= 0.85 + 0.30 * lago_wave;                                          // 保留波纹明暗
	base = mix(lagoon, base, smoothstep(0.0, 1.0, depth_f));

	// V104：洋流色斑 —— 80m 级的大块水色差异（浮游生物/深浅洋流），打破"一桶蓝漆倒出来"的均匀感
	base *= 0.93 + 0.14 * vnoise(wpos.xz * 0.012 + 7.7);

	// 菲涅尔驱动的"真·天空反射"：用视线反射射线去程序化天空（与天空着色器同梯度 + 日月倒影），
	// 海面真正镜像天空与太阳/月亮 —— 顶级水面质感的关键
	vec3 R = reflect(-Vworld, nWorld);
	vec3 skyref = sky_reflect(R);
	float fres = pow(1.0 - max(dot(nWorld, Vworld), 0.0), 5.0);
	fres *= mix(0.45, 1.0, depth_f);   // V104：浅水反射压低 —— 近岸看进水里而不是看天
	base = mix(base, skyref, clamp(fres * 0.75, 0.0, 0.55));   // V100c：0.80/0.68 仍偏银；0.75/0.55 + 降镜面粗糙度，海色成为主角

	ALBEDO = base;

	// V104：远海大气透视 —— 距相机 220m 外海面渐渐融入低空天色（远处不再是一块死板贴图，
	// 海天交界"融"进空气里，这是海岸航拍质感的收笔）。碎金波光同步衰减（远处看不见波光）。
	float cam_d = distance(CAMERA_POSITION_WORLD, wpos);
	float haze = smoothstep(220.0, 950.0, cam_d);
	vec3 haze_col = mix(sky_reflect(normalize(vec3(Vworld.x, 0.06, Vworld.z))),
	                    vec3(0.56, 0.63, 0.76), 0.35 * (1.0 - night_f));
	ALBEDO = mix(ALBEDO, haze_col, haze * (0.30 + 0.30 * (1.0 - day_f)));
	ROUGHNESS = mix(0.26, 0.14, day_f);   // V100c：白天 0.08 太镜面 → 整块天空（含太阳眩光）被反射成银海；0.14 保住倒影但收敛发白
	METALLIC = 0.0;

	// 太阳闪光（Blinn-Phong，叠加发光，不受反照率压暗 → 海面碎金波光）
	vec3 H = normalize(normalize(sun_dir) + Vworld);
	float spec = pow(max(dot(nWorld, H), 0.0), sun_shininess) * sun_strength;
	EMISSION = base * 0.03 + vec3(1.0, 0.95, 0.80) * spec * (0.35 + day_f * 0.65);

	// 朝光"波光带"：宽瓣高光把反光拉成从脚下伸向太阳的一条金色光路（海面最有感染力的元素）
	float broad = pow(max(dot(nWorld, H), 0.0), 8.0) * 0.25;   // V100c：0.34 仍把半片海刷白；0.25 只留一条金色光路
	EMISSION += vec3(1.0, 0.90, 0.70) * broad * (0.30 + day_f * 0.70);

	// 月光在夜海上的冷色反光（只在夜晚）：像太阳碎金一样留出一条冷色波光带，解决"夜海没有月光倒影"
	vec3 moon_dir = -normalize(sun_dir);
	vec3 Hm = normalize(moon_dir + Vworld);
	float mspec = pow(max(dot(nWorld, Hm), 0.0), sun_shininess * 0.6) * 2.4;
	EMISSION += vec3(0.55, 0.68, 0.95) * mspec * night_f;
	// 月光也拉一条宽的银蓝色光路（夜海最出画面的一笔）
	float mbroad = pow(max(dot(nWorld, Hm), 0.0), 7.0) * 0.45;
	EMISSION += vec3(0.60, 0.72, 0.98) * mbroad * night_f;

	// 浪尖白沫：波峰处叠加细碎白沫，海面更有"拍打/呼吸"的生命感（视觉冲击力）
	float crest = smoothstep(0.62, 1.05, wh);
	vec3 foam_col = vec3(0.92, 0.96, 1.0);
	ALBEDO = mix(ALBEDO, foam_col, crest * (0.16 + 0.22 * day_f));
	EMISSION += foam_col * crest * (0.03 + 0.10 * day_f);

	// ---- V104：近岸冲刷泡沫（只算岸线旁 10m，远海零开销）----
	// 两层结构：
	//   1) 岸线白沫带：贴着岸线 0~1.7m，前后摆动（两个不同频率的 z 向波叠加 → 岸线不是直尺）
	//   2) 周期冲刷浪：一条浪头从离岸 4.6m 周期性推上岸再退回（拍岸节奏），强度随相位淡入淡出
	// 泡沫用双层噪声打碎 → 是"碎沫花边"而不是一坨死白。
	if (shore_d < 10.0) {
		// V105b：摆动幅度 0.9→1.5、加第三层高频 z 波 —— 实拍岸线白沫带仍太直，真实岸线呈犬牙交错的弯月形
		float osc = sin(wpos.z * 0.55 + t * 1.25) * 0.55 + sin(wpos.z * 0.21 - t * 0.60) * 0.45 + sin(wpos.z * 1.30 + t * 2.10) * 0.22;
		float shore_foam = smoothstep(1.7 + osc * 1.5, 0.05, shore_d);
		float ph = fract(t * 0.11 + wpos.z * 0.0016);
		float front = 4.6 - ph * 5.2;                     // 浪头位置：4.6m → -0.6m（冲上岸）
		float wash = exp(-pow((shore_d - front) / 0.75, 2.0))
		           * smoothstep(0.0, 0.12, ph) * (0.35 + 0.65 * (1.0 - ph));
		float brk = 0.45 + 0.55 * vnoise(vec2(wpos.z * 1.9, wpos.x * 2.6) + vec2(t * 0.35, 0.0));
		brk *= 0.75 + 0.25 * vnoise(vec2(wpos.z * 6.0, wpos.x * 8.0) - vec2(t * 0.8, 0.0));
		float sfoam = clamp(shore_foam + wash * 0.85, 0.0, 1.0) * brk;
		vec3 sf_col = mix(vec3(0.52, 0.60, 0.70), vec3(0.93, 0.97, 1.0), day_f);
		ALBEDO = mix(ALBEDO, sf_col, sfoam * (0.55 + 0.30 * day_f));
		EMISSION += sf_col * sfoam * (0.02 + 0.06 * day_f);
	}

	// 远处波光/碎金随大气透视一起衰减（否则远海一片亮斑喧宾夺主）
	EMISSION *= 1.0 - haze * 0.55;
}
