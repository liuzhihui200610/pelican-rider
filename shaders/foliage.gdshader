shader_type spatial;

// V106 通用植被材质（棕榈 / 灌木 / 普通树 / 草丛）：替换 AI GLB 自带的"平涂 PBR"。
//
// 为什么需要它：AI 生成的 GLB 只带基础 PBR（一张 albedo + 粗糙度），
// 在开阔场景里占了画面 40%+ 面积却是一片死平 —— 这是"远景廉价感"的最大来源。
// 本 shader 在**保留原贴图**的前提下，叠加四层程序化生命力：
//   1) 叶片斑纹：双频噪声调制 albedo（叶脉明暗 / 老叶新叶色差）
//   2) 风摆：顶点位移（越靠叶梢幅度越大）+ 法线微摆 → 整片植被"活着"
//   3) 次表面透光：背光时叶片透出暖绿（阳光穿透叶片的经典特征）
//   4) 夜暗内置：替代 main.gd 每帧乘暗（保留但统一到 shader 里）

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float detail_strength : hint_range(0.0, 1.0) = 0.5;
uniform float wind_strength : hint_range(0.0, 2.0) = 1.0;
uniform float translucency : hint_range(0.0, 1.0) = 0.25;
uniform float night_f : hint_range(0.0, 1.0) = 0.0;
uniform float hue_var : hint_range(0.0, 1.0) = 0.5;   // 每株的色相偏移（打散"复制粘贴"感）
uniform float sway_phase = 0.0;                        // 每株相位偏移（错开摆动，避免整齐划一）

varying vec3 wpos;
varying float v_wind;

float hash21(vec2 p) {
	p = mod(p, 512.0);   // 输入安全域：世界坐标随里程无限增长，float32 hash 会崩（铁律，别删）
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
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 风摆：双频阵风沿 -z 流动，与草地同向（顺风）
	float w1 = vnoise(vec2(wp.x * 0.20, wp.z * 0.13 - TIME * 1.6) + 3.1 + sway_phase);
	float w2 = vnoise(vec2(wp.x * 0.62, wp.z * 0.40 - TIME * 2.7) + 9.4 + sway_phase);
	float gust = w1 * 0.65 + w2 * 0.35;
	v_wind = gust;
	// 只在**局部高处**（叶梢）位移，树干/根部不动 —— 用局部 y 相对高度做权重
	float leaf_w = clamp(VERTEX.y * 0.55 + 0.35, 0.0, 1.4);
	VERTEX.x += (gust - 0.5) * 0.16 * wind_strength * leaf_w;
	VERTEX.z += (gust - 0.5) * 0.07 * wind_strength * leaf_w;
	wpos = wp;
}

void fragment() {
	vec3 alb = texture(albedo_tex, UV).rgb * tint.rgb;

	// ---- 1) 叶片斑纹：双频噪声（1.5m 大叶簇 + 0.18m 单片叶的明暗） ----
	// 用世界坐标 → 相邻两株不会出现完全相同的斑纹（避免"复制粘贴"）
	float pat1 = vnoise(wpos.xz * 0.66 + 2.2);
	float pat2 = vnoise(wpos.xz * 5.4 + 17.6);
	float leaf_pat = pat1 * 0.62 + pat2 * 0.38;
	// 老叶偏黄、新叶偏深的绿：用色相偏移模拟
	alb *= mix(vec3(1.20, 1.04, 0.74), vec3(0.72, 0.94, 0.86), leaf_pat);
	alb *= 0.88 + 0.24 * leaf_pat;
	// 高频叶脉颗粒（只有近处看得见）
	float vein = vnoise(wpos.xz * 22.0);
	alb *= 0.94 + 0.12 * vein;

	// ---- 每株色相微偏：让一丛棕榈不是同一桶绿漆刷出来的 ----
	float hv = (hash21(vec2(sway_phase * 7.3, sway_phase * 3.1)) - 0.5) * hue_var;
	alb = mix(alb, alb.gbr, max(hv, 0.0) * 0.55);

	// ---- 4) 夜暗内置（V106c：仅调 ALBEDO 不够 —— 实拍夜景叶片仍发绿，
	// 因为环境光/间接光在 PBR 里会独立给叶片补光。最彻底的做法是直接乘 AO_LIGHT_AFFECT / SPECULAR 一起压，
	// 同时把 albedo 压到近乎无彩的暗灰绿（真实夜景植被几乎不可辨色）----
	alb = mix(alb, alb * vec3(0.16, 0.20, 0.18), night_f);

	ALBEDO = alb;
	ROUGHNESS = mix(0.55, 0.92, leaf_pat);   // 叶面有蜡质微光 ↔ 粗糙
	SPECULAR = 0.32 * (1.0 - night_f * 0.75);
	// V106c 关键：植被 PBR 走完整光照管线，Sky 环境光会独立给叶片补绿光 →
	// 仅压 ALBEDO 治不了"夜里亮绿"。AO_LIGHT_AFFECT 直接削弱环境光贡献，
	// 夜里把间接光砍到 15%（叶片回归暗剪影），白天保持 1.0 不受影响。
	AO_LIGHT_AFFECT = 1.0 - night_f * 0.85;

	// ---- 3) 次表面透光：叶背透光（用视线与法线关系近似背光）----
	// 背光时叶尖透出暖绿 — 正午阳光穿过棕榈叶的经典观感
	float back = clamp(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	BACKLIGHT = vec3(0.36, 0.62, 0.24) * back * translucency * detail_strength * (1.0 - night_f);
	// V106b：夜间叶片受月光 → 冷蓝边缘（否则纯压暗后植物像剪影贴纸）
	BACKLIGHT += vec3(0.10, 0.16, 0.30) * back * night_f * 0.35;
}
