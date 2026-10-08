shader_type sky;

// 昼夜循环天空：白天 → 黄昏 → 夜晚（星星 + 月亮），由太阳高度自动混合
uniform vec3 sun_dir = vec3(0.35, 1.0, 0.0);

// ---- V106 程序化云层 ----
// 为什么加：白天用的是本 shader（不是 AI 全景贴图），而原先白天只有纯渐变 + 3D 球状云（太远看不见）
// → 天空细节能量仅 3.8（全画面最弱环节）。程序化云层让天空自己就有层次。
float h21(vec2 p) {
    p = mod(p, 512.0);
    p = fract(p * vec2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}
float vn(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1,0)), u.x),
               mix(h21(i + vec2(0,1)), h21(i + vec2(1,1)), u.x), u.y);
}
// FBM：5 层，云絮的主体结构
float fbm_cloud(vec2 p) {
    float o = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        o += vn(p) * a;
        p *= 2.03;
        a *= 0.5;
    }
    return o;
}

void sky() {
    vec3 sd = normalize(sun_dir);
    float el = sd.y;
    float day_f = smoothstep(0.05, 0.35, el);
    float night_f = smoothstep(-0.02, -0.28, el);
    float dusk_f = clamp(1.0 - day_f - night_f, 0.0, 1.0);

    vec3 day_top = vec3(0.09, 0.31, 0.86);   // V100：夏日正午深蓝（0.13/0.38/0.90 偏淡青，0.09/0.31/0.86 才是晒出来的蓝天）
    vec3 day_hor = vec3(0.42, 0.64, 0.92);   // V100：地平线淡蓝收白（0.55/0.76/0.96 太白 → 整个天发灰）
    vec3 dusk_top = vec3(0.20, 0.24, 0.50);
    vec3 dusk_hor = vec3(1.0, 0.52, 0.30);   // 夕阳地平线：火红橙（V99 加深，之前 0.60 偏粉橙、不够"夕阳"）
    vec3 night_top = vec3(0.010, 0.018, 0.055);
    vec3 night_hor = vec3(0.055, 0.075, 0.16);

    vec3 top = mix(mix(dusk_top, day_top, day_f), night_top, night_f);
    vec3 hor = mix(mix(dusk_hor, day_hor, day_f), night_hor, night_f);

    float h = EYEDIR.y;
    vec3 col;
    if (h >= 0.0) {
        // 夕阳专属：地平线火红 → 中层橙粉 → 天顶紫蓝 的三段渐变（真实晚霞的垂直色序）
        if (dusk_f > 0.001) {
            vec3 mid_dusk = mix(vec3(0.62, 0.34, 0.52), vec3(0.98, 0.62, 0.42), day_f);
            float t2 = pow(clamp(h, 0.0, 1.0), 0.30);
            vec3 dusk_col = mix(hor, mid_dusk, clamp(t2 * 2.2, 0.0, 1.0));
            dusk_col = mix(dusk_col, top, clamp(pow(clamp(h, 0.0, 1.0), 0.85) * 1.5 - 0.18, 0.0, 1.0));
            col = mix(mix(hor, top, pow(clamp(h, 0.0, 1.0), 0.38)), dusk_col, dusk_f);
        } else {
            col = mix(hor, top, pow(clamp(h, 0.0, 1.0), 0.38));
        }
    } else {
        vec3 below = mix(hor * 0.4, vec3(0.10, 0.12, 0.16), night_f);
        col = mix(hor, below, clamp(-h * 5.0, 0.0, 1.0));
    }

    // 海平线大气光带：贴地平线一圈更亮更暖的薄雾，远海不死边、画面更有纵深
    // V105：暖度/强度略增（大气散射的"金边"是海岸审美的点睛）
    float hband = exp(-clamp(abs(EYEDIR.y), 0.0, 1.0) * 16.0);
    col = mix(col, hor * 1.12 + vec3(0.055, 0.032, 0.010), hband * 0.28 * (1.0 - night_f));

    // ===== V106 程序化云层（白天/黄昏可见，夜间淡出）=====
    // 把视线方向投影到一个高空平面（eyedir.xz / eyedir.y = 透视投影到平面），
    // 得到"天穹上的位置" → 在这个平面上画 FBM 云 → 天然带正确的透视收缩。
    vec3 sun_tint_early = mix(vec3(1.0, 0.62, 0.32), vec3(1.0, 0.96, 0.84), day_f);
    if (EYEDIR.y > 0.015) {
        vec2 plane = EYEDIR.xz / max(EYEDIR.y, 0.015);
        vec2 cuv = plane * 0.55 + vec2(TIME * 0.006, TIME * 0.0022);   // 缓慢飘移

        // 两层云：低层厚积云（大、慢）+ 高层薄卷云（小、快）
        float d1 = fbm_cloud(cuv * 1.0 + 3.7);
        float d2 = fbm_cloud(cuv * 2.9 + 11.3);
        float density = d1 * 0.62 + d2 * 0.38;

        // 高度遮罩：越靠天顶云越完整，贴近地平线被大气压平（透视拉伸 + 淡出）
        float hz = clamp(EYEDIR.y * 3.4, 0.0, 1.0);
        // V106b：覆盖率收敛（0.44-0.76 → 0.50-0.80）—— 首版云太密，天空被白云铺满 →
        // 全画面均亮 137→148、饱和 25.8%→21.8%（"发白"的老毛病又冒头）。稀疏的云才是蓝天的主角。
        float cov = smoothstep(0.50, 0.80, density) * hz;

        // 云色：受光面白亮（向阳侧）、背光面灰蓝（阴影侧），黄昏染上橙粉
        float lit = clamp(dot(normalize(vec3(EYEDIR.x, 0.42, EYEDIR.z)), sd) * 0.5 + 0.5, 0.0, 1.0);
        // V106b：受光面 1.0 → 0.90（纯白云在 tonemap 后会上飘成一片惨白，压到 0.90 保住云的体积感）
        vec3 cloud_lit = mix(vec3(0.60, 0.66, 0.78), vec3(0.90, 0.90, 0.89), day_f);
        vec3 cloud_dark = mix(vec3(0.32, 0.36, 0.48), vec3(0.62, 0.66, 0.74), day_f);
        // 黄昏：云顶被夕阳染橙粉（"烧云"是黄昏最动人的一笔）
        cloud_lit = mix(cloud_lit, vec3(1.0, 0.72, 0.52), dusk_f * 0.55);
        cloud_dark = mix(cloud_dark, vec3(0.72, 0.46, 0.48), dusk_f * 0.40);
        vec3 cloud_col = mix(cloud_dark, cloud_lit, lit);

        // 云缘透光：密度中等处（云边）被阳光穿透发亮 → 云有"厚度感"而非贴片
        float edge_glow = smoothstep(0.40, 0.58, density) * (1.0 - smoothstep(0.62, 0.80, density));
        cloud_col += sun_tint_early * edge_glow * 0.34 * (1.0 - night_f);

        col = mix(col, cloud_col, cov * (0.78 - 0.66 * night_f));   // V106b：0.86→0.78（云层不透到发白）
    }

    // 太阳眩光（电影感）：日冕（紧）+ 宽柔晕（松）+ 黄昏暖色铺满天 + 横向拉丝（anamorphic streak）
    float s = clamp(dot(EYEDIR, sd), 0.0, 1.0);
    vec3 glow_col = mix(vec3(1.0, 0.55, 0.32), vec3(1.0, 0.92, 0.70), day_f);
    col += glow_col * pow(s, 14.0) * (0.16 + day_f * 0.10) * (1.0 - night_f);   // 日冕外晕（压暗：与眩光/bloom 叠加曾把左上角整片冲白）
    col += glow_col * pow(s, 3.0) * dusk_f * 0.30;                              // 黄昏暖色薄雾铺满天（黄金时刻氛围）
    col += vec3(1.0, 0.88, 0.65) * pow(s, 220.0) * 1.0 * (1.0 - night_f);       // 紧贴日轮的高光晕（1.8→1.0 防爆白）
    // 横向拉丝：沿视线水平方向把阳光拉成一条光柱，黄昏逆光最明显（镜头炫光）
    vec3 perp = EYEDIR - s * sd;
    float plen = max(length(perp), 1e-4);
    float horiz = exp(-abs(perp.y) / (plen * 0.10));
    float streak = pow(s, 6.0) * horiz;
    col += vec3(1.0, 0.82, 0.55) * streak * (0.12 + dusk_f * 0.35) * (1.0 - night_f);
    // 太阳本体：可见的日轮 + 紧贴日冕（"阳光"要有看得见的焦点，之前天上根本没有太阳）
    vec3 sun_tint = mix(vec3(1.0, 0.62, 0.32), vec3(1.0, 0.96, 0.84), day_f);
    col += sun_tint * smoothstep(0.99930, 0.99975, s) * 1.6 * (1.0 - night_f);
    col += sun_tint * pow(s, 60.0) * 0.20 * (1.0 - night_f);

    // 月亮（夜晚，与太阳相对）
    float m = clamp(dot(EYEDIR, normalize(-sd)), 0.0, 1.0);
    col += vec3(0.92, 0.94, 1.0) * smoothstep(0.99970, 0.99990, m) * night_f;
    col += vec3(0.55, 0.65, 0.95) * pow(m, 350.0) * night_f * 0.8;

    // ===== 星空（V99 重做）=====
    // 原版只有两层稀疏点 + 一条均匀灰带，像"撒了把白芝麻"。真实夜空的三层结构：
    //   ① 银河带：沿倾斜大圆的浓密星云气辉（不是均匀灰雾，要有大尺度明暗起伏）
    //   ② 暗尘带：银河里的黑色尘埃裂缝（这是"真实感"最关键的一笔，缺了就像贴图）
    //   ③ 恒星：三层不同亮度/密度 + 闪烁，且越靠天顶越密（贴近地平线被大气消光）
    float hmask = clamp(h * 3.0, 0.0, 1.0);          // 地平线附近消光更多 → 星少且暗
    float twinkle = clamp(h * 2.2 + 0.15, 0.0, 1.0); // 低空星闪得更厉害（大气抖动）
    vec3 nd = normalize(EYEDIR);

    // ① 银河带主体：三层不同频率的带状噪声，制造云絮般的明暗结构
    vec3 gaxis = normalize(vec3(0.32, 0.60, 0.20));
    float gd = abs(dot(nd, gaxis));
    float band = pow(1.0 - gd, 5.0);                              // 主带
    float band2 = pow(1.0 - abs(dot(nd, normalize(vec3(0.28, 0.66, 0.26)))), 22.0);
    // 银心：银河系中心方向（人马座一带）更亮更暖
    float core = pow(clamp(dot(nd, normalize(vec3(0.55, 0.16, -0.62))), 0.0, 1.0), 6.0);
    // 云絮感：沿带方向的低频扰动
    float clump = 0.55 + 0.45 * sin(nd.x * 9.0 + nd.z * 7.0) * cos(nd.y * 11.0 - nd.z * 5.0);

    vec3 milky = mix(vec3(0.16, 0.18, 0.30), vec3(0.34, 0.30, 0.26), core);  // 银心偏暖黄，边缘偏冷蓝
    float milky_amt = (band * 0.85 + band2 * 0.55) * clump + core * 0.9;
    col += milky * milky_amt * hmask * night_f * 0.85;

    // ② 暗尘带：银河系里的黑色尘埃裂缝（沿带叠加暗色，抵消部分辉光）
    float dust = pow(1.0 - abs(dot(nd, normalize(vec3(0.36, 0.52, 0.14)))), 9.0);
    float dust_mod = 0.5 + 0.5 * sin(nd.x * 5.0 - nd.y * 8.0 + nd.z * 4.0);
    col *= 1.0 - clamp(dust * dust_mod * 0.55, 0.0, 0.6) * hmask * night_f;

    // ③ 恒星三层：亮星稀疏 / 中星 / 暗星极密，叠加闪烁与色温变化（蓝白~橙）
    vec3 gA = floor(nd * 90.0);
    float hA = fract(sin(dot(gA, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
    vec3 gB = floor(nd * 210.0);
    float hB = fract(sin(dot(gB, vec3(39.346, 11.135, 83.155))) * 24634.6345);
    vec3 gC = floor(nd * 420.0);
    float hC = fract(sin(dot(gC, vec3(7.13, 41.77, 93.19))) * 12743.1234);

    float twA = 0.70 + 0.30 * sin(TIME * 2.1 + hA * 63.0);
    float twB = 0.55 + 0.45 * sin(TIME * 3.3 + hB * 88.0);
    float twC = 0.40 + 0.60 * sin(TIME * 4.7 + hC * 111.0);

    float starA = smoothstep(0.9975, 1.0, hA) * twA;   // 亮星（少）
    float starB = smoothstep(0.9930, 1.0, hB) * twB;   // 中星
    float starC = smoothstep(0.9880, 1.0, hC) * twC * 0.55;  // 暗星（多，弱）

    // 恒星色温：多数偏蓝白，少数橙红（让星空有色彩变化而非纯白点）
    vec3 tintA = mix(vec3(0.72, 0.82, 1.0), vec3(1.0, 0.86, 0.68), step(0.75, hA));
    vec3 tintB = mix(vec3(0.80, 0.88, 1.0), vec3(1.0, 0.90, 0.76), step(0.86, hB));
    vec3 stars = tintA * starA + tintB * starB + vec3(0.88, 0.92, 1.0) * starC;
    // 银心方向星更密更亮（银河里恒星拥挤）
    stars *= 1.0 + core * 1.2;
    col += stars * twinkle * hmask * night_f;

    COLOR = col;
}
