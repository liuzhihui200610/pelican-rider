shader_type spatial;

// V104 草地着色器：替代原 StandardMaterial3D（+ 几何顶点色斑驳保留）。
// 新增四层生命力：
//   1) 风扫草浪：两组噪声域沿 -z 流动（顺风向），albedo 明暗波 + 法线微摆 → 光影在草面上"跑"
//   2) 大尺度草皮色差：黄绿（晒干）↔ 深绿（湿润）的大块patch，弥补顶点色 8m 网格的粗糙
//   3) 近路枯草带：路缘侧 1.2m 草色转黄褐（踩踏/尾气），过渡自然
//   4) 夜晚压暗内置（替代原 main.gd 每帧 lerp albedo_color 的做法）
// 几何层的顶点色斑驳（COLOR）继续生效：两者相乘，层次互补。

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(0.50, 0.62, 0.44, 1.0);
uniform vec2 uv_scale = vec2(26.0, 120.0);
uniform float night_f : hint_range(0.0, 1.0) = 0.0;
uniform float wind_strength : hint_range(0.0, 1.0) = 0.55;

varying vec3 wpos;

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

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = UV * uv_scale;
	vec4 tex = texture(albedo_tex, uv);
	vec3 alb = tex.rgb * tint.rgb * COLOR.rgb;   // 顶点色斑驳继续生效

	// ---- 大尺度草皮色差：晒干黄绿 ↔ 湿润深绿（V105b：加中频层 + 对比再拉大）----
	// 40m 级 macro 在远处被雾和透视压成"一整片同色"，加入 7m 级中频 patch 让远景也有可见的斑纹节奏
	float macro1 = vnoise(wpos.xz * 0.024 + 3.7);
	float macro2 = vnoise(wpos.xz * 0.062 + 12.9);
	float macro3 = vnoise(wpos.xz * 0.14 + 7.7);          // V105b 中频：7m 级 patch
	float macro = macro1 * 0.42 + macro2 * 0.28 + macro3 * 0.30;
	alb *= mix(vec3(1.25, 1.02, 0.62), vec3(0.72, 0.92, 1.10), macro);   // 暖金干草 ↔ 冷湿深绿（V105b 反差 36%→52%）
	alb *= 0.86 + 0.26 * macro;

	// ---- 野花点缀（V105b）：cell hash 撒锐利花点（白/黄/紫三色），近处是几像素的小亮点，远处自然消隐 ----
	// 不用插值噪声阈值法（那出的是模糊斑块），cell hash + cell 内随机位置才能出"一朵一朵"的锐点
	vec2 fcell = floor(wpos.xz * 1.6);
	float fh = hash21(fcell * 1.7 + 5.0);
	float flower_on = step(0.955, fh);                    // 每 0.625m 格 4.5% 概率出花（V105b 首版 3.2% 太稀，草丛里几乎找不到）
	vec2 fpos = vec2(hash21(fcell + 1.3), hash21(fcell + 7.7)) * 0.7 + 0.15;
	float fd = length(fract(wpos.xz * 1.6) - fpos);
	float flower = flower_on * smoothstep(0.085, 0.035, fd);
	float fh2 = hash21(fcell + 23.1);
	vec3 fcol = vec3(0.96, 0.94, 0.88);                   // 白花为主
	fcol = mix(fcol, vec3(0.97, 0.84, 0.28), step(0.62, fh2));   // 黄花
	fcol = mix(fcol, vec3(0.84, 0.62, 0.92), step(0.86, fh2));   // 紫花少量
	alb = mix(alb, fcol, flower * (1.0 - night_f * 1.1));         // 夜里花自然隐没

	// ---- 风扫草浪：阵风波沿 -z 流动（与骑行同向 = 顺风），两层叠加有"一阵一阵"的节奏 ----
	float w1 = vnoise(vec2(wpos.x * 0.32, wpos.z * 0.20 - TIME * 2.1) + 3.3);
	float w2 = vnoise(vec2(wpos.x * 0.85, wpos.z * 0.52 - TIME * 3.3) + 8.8);
	float gust = w1 * 0.68 + w2 * 0.32;
	alb *= 1.0 + wind_strength * (gust - 0.5) * 0.42;

	// ---- 近路枯草带：世界 x ∈ [-4.5, -3.3] 渐变黄褐 ----
	float road_side = smoothstep(-3.3, -4.45, wpos.x);
	vec3 dry = vec3(0.80, 0.70, 0.45);
	alb = mix(alb, alb * dry, road_side * (0.55 + 0.30 * vnoise(wpos.xz * vec2(0.9, 0.35))));

	// ---- 高频颗粒：草叶碎影 ----
	float micro = vnoise(wpos.xz * 7.0);
	alb *= 0.96 + 0.08 * micro;

	// ---- 夜晚压暗（深绿灰，不再发蓝）----
	alb = mix(alb, alb * vec3(0.30, 0.38, 0.34), night_f);

	ALBEDO = alb;

	// ---- 法线：贴图草叶起伏 + 风的轻摆（光影波动）----
	vec3 nmap = texture(normal_tex, uv).rgb;
	vec3 nd = nmap * 2.0 - 1.0;
	float sway = vnoise(vec2(wpos.x * 0.5, wpos.z * 0.3 - TIME * 2.6) + 5.1);
	nd.x += (sway - 0.5) * 0.30 * wind_strength;
	nd = normalize(clamp(nd, -1.0, 1.0));
	NORMAL_MAP = nd * 0.5 + 0.5;
	ROUGHNESS = 0.95;
	SPECULAR = 0.25;
}
