shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

// V105b 路灯光锥：替代原 CylinderMesh + 均匀 alpha 的"黄塑料三角"。
// 旧方案是整个锥面同一个 alpha 加性叠加 → 夜里一块实心黄色三角，边缘锐利、最廉价的一笔。
// 体积光真实感三要素（shader 内全部解决）：
//   1) 垂直渐变：灯口最亮 → 落到地面渐隐（光被空气稀释 + 漫射）
//   2) 视角软边：视线正对锥心时亮、掠过侧壁时暗（体积光沿着观察路径积分的自然衰减）
//      —— cull_disabled 下前后两个侧面都会画，加性混合自动叠出"锥心更浓"的效果
//   3) fade 总闸：随 lamp_f 昼夜渐显（main.gd 每帧驱动）

uniform vec3 cone_color : source_color = vec3(1.0, 0.80, 0.50);
uniform float fade : hint_range(0.0, 1.0) = 0.0;
uniform float cone_height = 3.7;   // 与 CylinderMesh.height 一致

varying float v_h;   // 0 = 灯口（顶）, 1 = 落到地面（底）

void vertex() {
	// 用 mesh 局部 y 而不是 UV.y：不赌 Godot 圆柱 UV 约定，物理上永远正确
	// VERTEX.y ∈ [-h/2, +h/2]，顶 +h/2 是灯口
	v_h = 0.5 - VERTEX.y / cone_height;
}

void fragment() {
	// 1) 垂直渐变：灯口 1.0 → 地面趋 0（指数曲线比线性更接近光在雾里的衰减）
	float vert = pow(clamp(v_h, 0.0, 1.0), 1.6);

	// 2) 视角软边：NORMAL/VIEW 都是 view space。正对锥壁（dot→1）亮，
	//    视线掠过侧壁（dot→0）暗 → 硬三角边被抹成柔光壳
	float rim = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float soft = pow(clamp(rim, 0.0, 1.0), 2.3);

	// 3) 底部光斑渐隐与地面光池衔接（避免锥底截断面出现一条亮缝）
	float base_fade = smoothstep(1.0, 0.82, v_h);

	ALBEDO = cone_color * vert * soft * base_fade * fade;
}
