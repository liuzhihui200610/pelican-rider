shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// 写实 PBR 材质：不再用自定义 light() 覆盖光照管线。
// V98 关键修复 —— 旧版用自定义 light() 只累加 DIFFUSE_LIGHT，导致：
//   1) METALLIC / ROUGHNESS 写进 ALBEDO 但完全没被 BRDF 消费 → 所有物体像"塑料片"贴上去，没有真实材质反应；
//   2) 自定义 light() 覆盖后，SSAO / SSIL / SDFGI / 阴影贴图 / 反射探针 **不参与** → 物体与场景"脱层"、没有接地感；
//   3) 边缘光靠 EMISSION 硬叠 → 夜里像发光体。
// 现在：走标准 PBR（能量守恒 GGX + 菲涅尔 + 各类环境光/遮蔽/反射），
// 额外把"边缘光/透光"作为**加性项**注入（保留电影感，但不取代真实光照）。

uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D ramp_tex : source_color, filter_nearest;
uniform sampler2D detail_tex : source_color, hint_default_white;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.55;
uniform vec4 rim_color : source_color = vec4(1.0, 0.88, 0.96, 1.0);
uniform float spec_strength : hint_range(0.0, 2.0) = 0.3;
uniform float roughness_override : hint_range(-1.0, 1.0) = -1.0;
uniform float metallic_override : hint_range(-1.0, 1.0) = -1.0;
// >0 时在 UV.v 附近画一条白带（路障锥的反光条）
uniform float stripe_v : hint_range(-1.0, 1.0) = -1.0;
// 叶片被光从背后照透发暖光（植被 SSS-lite）
uniform float translucency : hint_range(0.0, 2.0) = 0.0;

// 全局夜晚系数（0=白天 1=深夜）
global uniform float night_dim;

varying vec3 v_ws_normal;
varying vec3 v_ws_pos;
varying vec2 v_uv;

void vertex() {
	v_ws_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_ws_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_uv = UV;
}

void fragment() {
	vec3 col = base_color.rgb;
	col *= mix(vec3(1.0), texture(detail_tex, v_uv * 3.0).rgb, detail_strength);
	if (stripe_v > 0.0 && abs(v_uv.y - stripe_v) < 0.07) {
		col = vec3(1.0);
	}
	ALBEDO = col;
	// 真实感：不再是"什么都 0.58 磨砂"。按材质给不同粗糙度，金属/塑料/树叶各自的高光形状才不一样。
	ROUGHNESS = (roughness_override >= 0.0) ? roughness_override : clamp(0.62 - spec_strength * 0.35, 0.05, 0.98);
	METALLIC = (metallic_override >= 0.0) ? metallic_override : clamp(spec_strength * 0.22, 0.0, 0.65);
	// V102：SPECULAR 恒定 0.5 让"哑光"材质在掠射角仍把整片蓝天映进去（路面标线发蓝的真凶）。
	// 镜面强度随粗糙度衰减（近似 Disney/GGX 习惯），粗糙 0.9 的漆面几乎不再镜像天空。
	SPECULAR = 0.5 * clamp(1.25 - ROUGHNESS, 0.12, 1.0);

	vec3 N = normalize(v_ws_normal);
	vec3 V = normalize(CAMERA_POSITION_WORLD - v_ws_pos);
	float fres = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 3.4);

	// 边缘光/透光：作为加性项叠加在**已包含 PBR + SSAO/SSIL/反射**的输出之上，
	// 不再自己算一套光照（这是旧版"物体像贴纸"的根源）。
	float rim = fres * rim_strength * 0.20 * (1.0 - night_dim * 0.8);
	EMISSION = rim_color.rgb * rim;
}

// 透光（植被 SSS-lite）：阳光从叶片背后照来时叶片发暖光。
// 注意：Godot 4 的 light() 里【不能写 EMISSION】（只能 DIFFUSE_LIGHT / SPECULAR_LIGHT / ATTENUATION），
// 写 EMISSION 会编译失败 "Unknown identifier in expression: 'EMISSION'"。
// 所以透射项追加到 DIFFUSE_LIGHT 上（作为"从背面透过来的那部分光"），而不是 EMISSION。
void light() {
	if (translucency > 0.0) {
		vec3 Nw = normalize(v_ws_normal);
		float back = clamp(max(dot(-NORMAL, LIGHT), dot(-Nw, LIGHT)), 0.0, 1.0);
		float t = pow(back, 3.0) * translucency;
		// 追加而非覆盖：DIFFUSE_LIGHT 此时已含引擎算好的 PBR 漫反射，我们只"加"透射
		DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION * t * 0.55 * (1.0 - night_dim * 0.6);
	}
}
