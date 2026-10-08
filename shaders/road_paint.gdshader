shader_type spatial;

// V104 标线（虚线/边线）着色器：替代原恒定色 toon 材质。
// 真实道路标线的质感来自"磨损"：漆面斑驳剥落露出沥青底色、新旧程度沿路不均。
// 磨损图案用 mesh 局部坐标（VERTEX.xz）计算 → 斑驳"长"在标线上，
// treadmill 滚动 / 虚线循环位移时磨损纹样跟着虚线走，永不漂移。
// 另有夜里 5% 的微发光近似"玻璃珠回反射"——月光/路灯光下标线隐约可辨。

uniform vec4 paint_col : source_color = vec4(0.93, 0.93, 0.88, 1.0);
uniform float night_f : hint_range(0.0, 1.0) = 0.0;

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

varying vec2 lpos;   // mesh 局部 xz（米）

void vertex() {
	lpos = VERTEX.xz;
}

void fragment() {
	// 两层磨损：低频决定"哪一段掉漆严重"，高频决定剥落的碎斑形状
	// V105b：整体磨损收敛（smoothstep 区间上移 + 封顶 0.80）—— 白天实拍虚线存在感太弱，
	// 真实道路上主干道的标线虽然旧但仍然是"白色可辨"的，磨损不该把它吃到和沥青一个亮度。
	float w1 = vnoise(lpos * vec2(2.6, 0.30) + 5.2);
	float w2 = vnoise(lpos * vec2(9.0, 1.10) + 17.3);
	float w3 = vnoise(lpos * vec2(26.0, 3.4) + 31.7);
	float wear = smoothstep(0.47, 0.78, w1 * 0.50 + w2 * 0.34 + w3 * 0.16);
	wear = clamp(wear * 0.85, 0.0, 0.80);         // 封顶：总有漆面残留，不剥成断线

	vec3 asphalt_under = vec3(0.285, 0.275, 0.265);   // 底下是脏沥青
	vec3 alb = mix(paint_col.rgb, asphalt_under, wear);

	ALBEDO = alb;
	ROUGHNESS = mix(0.74, 0.96, wear);            // V105b：完好处是新漆的釉面反光（0.86→0.74），剥落处粗糙吸光
	SPECULAR = 0.42;

	// 夜间回反射（标线玻璃珠效应）：车灯/路灯下标线是路上最亮的引导元素
	// V105b：0.055→0.10 —— 夜帧实拍虚线存在感不足，真实玻璃珠的回反射在灯下非常醒目
	EMISSION = paint_col.rgb * (1.0 - wear) * 0.10 * night_f;
}
