shader_type spatial;

// V104 路面着色器（彻底重做版）：把"贴图平铺的均匀灰布"变成有岁月痕迹的真实沥青。
// 三层细节体系：
//   MACRO  大尺度（几十米）：老化色斑 + 色温漂移 + 大尺度凹凸法线 → 光影会"流动"，打破死板
//   MESO   中尺度（米级）：轮迹磨光带 / 低洼积水斑 / 油渍滴漏 / 蜿蜒裂缝 / 修补沥青条 / 路缘土污
//   MICRO  高频（厘米级）：程序化颗粒补足贴图分辨率，近看不糊
// 所有程序化图案绑定滚动后的贴图空间（uv.y 每帧按玩家位移流动）→ 路面真正"动"起来，
// 且车辙/坑洼等图案跟路面一体平移，永不穿帮。
// OBJ 的 UV：u∈[0,1] 横向(x -4.5→4.5)，v 每 1 单位 = 9m（贴图周期）。

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 tint : source_color = vec4(0.78, 0.78, 0.78, 1.0);
uniform float scroll = 0.0;                 // 主脚本每帧传 -player_z / 9.0
uniform float specular_amt = 0.62;

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

void fragment() {
	// ⚠️ V104c 关键坑：Godot 的 OBJ 导入器会翻转 vt.y（OBJ 的 V 轴向上、Godot 的 UV 向下），
	//    所以采样点要【减】scroll 才能让图案向玩家身后（画面下方）流动——
	//    若用加号，路面纹理会向前跑，与虚线（几何位移、天然向后）反向，出现"路自己在前进"的精神分裂感。
	vec2 uv = UV - vec2(0.0, scroll);
	float x_m = (UV.x - 0.5) * 9.0;      // 横向米坐标（-4.5 ~ +4.5）
	float y_m = uv.y * 9.0;              // 纵向米坐标（随路面滚动）

	vec4 tex = texture(albedo_tex, uv);
	vec3 alb = tex.rgb * tint.rgb;

	// ================= MACRO：大尺度老化 =================
	float mac1 = vnoise(vec2(x_m * 0.10, y_m * 0.028) + 2.2);
	float mac2 = vnoise(vec2(x_m * 0.23, y_m * 0.060) + 15.8);
	float macro = mac1 * 0.65 + mac2 * 0.35;
	// 老沥青色温不均匀：有的区域偏灰褐（车流油污渗色），有的偏冷灰
	vec3 aged_tint = mix(vec3(0.90, 0.855, 0.80), vec3(1.05, 1.045, 1.06), macro);
	alb *= aged_tint;
	alb *= 0.90 + 0.20 * macro;          // 明度大尺度起伏（云影残留/老化差异）

	// 大尺度凹凸：中心差分取 macro 场梯度 → 叠进法线，树影/天光反射会在上面"流动"
	vec2 bp = vec2(x_m * 0.42, y_m * 0.095);
	float b0 = vnoise(bp + 1.7);
	float bx = vnoise(bp + vec2(0.34, 0.0) + 1.7) - b0;
	float by = vnoise(bp + vec2(0.0, 0.34) + 1.7) - b0;
	vec2 bump_grad = vec2(bx, by) / 0.34;

	// ================= MESO：道路痕迹 =================
	// 轮迹磨光带：主车辙 |x|≈1.7（行车轮迹），次车辙 |x|≈2.95；磨损深浅沿路起伏
	float rut1 = exp(-pow((abs(x_m) - 1.7) / 0.34, 2.0));
	float rut2 = exp(-pow((abs(x_m) - 2.95) / 0.26, 2.0));
	float rut_var = 0.70 + 0.30 * vnoise(vec2(y_m * 0.33, 7.31));
	float rut = clamp(rut1 + rut2 * 0.45, 0.0, 1.0) * rut_var;

	// 低洼积水斑：低频找洼 + 高频碎边；轮迹内加倍（反复碾压压实成洼）
	float pn = vnoise(vec2(x_m * 1.6, y_m * 0.42) + vec2(3.7, 1.9));
	float pd = vnoise(vec2(x_m * 4.5, y_m * 1.2) - vec2(8.1, 4.4));
	float puddle = smoothstep(0.665, 0.795, pn * 0.72 + pd * 0.28);
	puddle = clamp(puddle * (0.30 + 0.85 * rut1) + puddle * 0.18, 0.0, 0.50);   // V104b：0.55→0.50 收一点面积

	// 油渍滴漏：行车道中央区的高频深色斑，边缘发暗圈
	float oil_n = vnoise(vec2(x_m * 2.2, y_m * 0.55) + vec2(21.7, 13.1));
	float oil = smoothstep(0.74, 0.88, oil_n) * smoothstep(2.8, 1.3, abs(x_m));
	float oil_ring = oil * smoothstep(0.88, 0.78, oil_n);   // 边缘一圈更黑

	// 蜿蜒裂缝：两个噪声场零等值线 = 天然不规则路径；按路段稀疏出现，绝不连成蜘蛛网
	float c1 = vnoise(vec2(x_m * 0.55, y_m * 0.11) + 11.3);
	float c2 = vnoise(vec2(x_m * 0.50 + 7.7, y_m * 0.10) + 4.2);
	float crack_gate = step(0.66, vnoise(vec2(y_m * 0.045, 9.4)));
	float crack = smoothstep(0.028, 0.006, abs(c1 - c2)) * crack_gate;

	// 修补沥青条：x≈+0.75 的深色新沥青（更哑更黑），沿路一段一段
	float patch_gate = smoothstep(0.52, 0.74, vnoise(vec2(y_m * 0.21, 4.2)));
	float patch = exp(-pow((x_m - 0.75) / 0.17, 2.0)) * patch_gate;

	// 路缘土污：两侧 0.9m 渐变泥土色（落叶尘土从路肩吹上路面）
	float edge = smoothstep(3.55, 4.45, abs(x_m));
	float edge_var = 0.45 + 0.40 * vnoise(vec2(y_m * 0.8, 3.3));

	// ================= 合成反照率 =================
	alb *= mix(1.0, 0.80, rut);                    // 轮迹磨光压暗
	alb *= mix(1.0, 0.76, puddle);                 // 积水吃光（V104b：0.70→0.76，白斑没那么突兀）
	alb *= mix(1.0, 0.52, oil * 0.75);             // 油渍深斑
	alb *= mix(1.0, 0.42, oil_ring * 0.6);         // 油渍边缘黑圈
	alb *= mix(1.0, 0.42, crack);                  // 裂缝缝隙近黑
	alb *= mix(1.0, 0.60, patch);                  // 新补沥青最黑
	alb = mix(alb, alb * vec3(0.74, 0.68, 0.57), edge * edge_var);   // 路缘土色

	// MICRO：厘米级颗粒（补足贴图分辨率，近景不再糊）
	// V105b：单层→双层。88/m 的粗骨料 + 210/m 的细砂 —— 单层在近景（脚边 3m 内）会被撑成"糊斑"，
	// 双层频率差 2.4 倍形成砂粒尺度堆叠，近看是"沥青骨料"而不是一团糊。
	float micro = vnoise(vec2(x_m * 88.0, y_m * 88.0));
	float micro2 = vnoise(vec2(x_m * 210.0, y_m * 210.0) + 11.3);
	alb *= 0.955 + 0.09 * micro;
	alb *= 0.975 + 0.055 * micro2;
	// 骨料亮粒：少数石子反光偏亮（真实沥青里石英颗粒的点点反光）
	float grit = step(0.965, vnoise(vec2(x_m * 160.0, y_m * 160.0) + 5.5));
	alb += vec3(0.055, 0.053, 0.050) * grit;

	ALBEDO = alb;

	// ================= 粗糙度分区 =================
	float rough = 0.86;
	rough = mix(rough, 0.70, rut);                 // 磨光轮迹更光滑
	rough = mix(rough, 0.46, puddle);              // 积水反光（V104b：0.30 白天把天空镜面反射成大白斑，0.46 收敛成"湿润"而不是"水坑镜"）
	rough = mix(rough, 0.38, oil * 0.8);           // 油渍反光
	rough = mix(rough, 0.95, crack);               // 裂缝粗糙吸光
	rough = mix(rough, 0.94, patch);               // 新沥青哑光
	rough = mix(rough, 0.97, edge * 0.6);          // 土污粗糙
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	METALLIC = 0.0;
	SPECULAR = specular_amt;

	// ================= 法线：贴图颗粒 + 大尺度凹凸合成 =================
	vec3 nmap = texture(normal_tex, uv).rgb;
	vec3 nd = nmap * 2.0 - 1.0;
	nd.xy += bump_grad * 0.055;                    // 大尺度起伏叠加（幅度克制防穿帮感）
	// V105b：骨料凸起法线扰动 —— 程序化微法线（对 micro 噪声做梯度差分），
	// 让近景沥青在斜射光下有"一粒粒"的明暗起伏，而不是一张平贴纸（"死板"的最后来源）。
	// 幅度随 MICRO 频率走（88/m 对应 1.1cm 尺度），只扰动 nd.xy 不入 albedo → 只改光不减色。
	float mE = 0.055;
	float micro_c = vnoise(vec2(x_m * 88.0, y_m * 88.0) + 21.5);
	float micro_x = vnoise(vec2((x_m + mE) * 88.0, y_m * 88.0) + 21.5);
	float micro_y = vnoise(vec2(x_m * 88.0, (y_m + mE) * 88.0) + 21.5);
	nd.xy += vec2(micro_x - micro_c, micro_y - micro_c) * 3.2;
	// 磨光/积水区颗粒感减弱（胎面把骨料磨平了）
	NORMAL_MAP_DEPTH = mix(1.0, 0.40, max(rut, puddle));
	NORMAL_MAP = normalize(clamp(nd, -1.0, 1.0)) * 0.5 + 0.5;
}
