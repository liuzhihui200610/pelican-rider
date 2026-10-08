shader_type spatial;
// 积云：不受光照明暗（永远不会过曝），顶部亮白、底部淡蓝灰，边缘柔和
render_mode unshaded, blend_mix, cull_back, depth_draw_never;

uniform vec4 top_color : source_color = vec4(1.00, 1.00, 1.00, 1.0);
uniform vec4 bot_color : source_color = vec4(0.74, 0.80, 0.92, 1.0);
uniform float alpha : hint_range(0.0, 1.0) = 0.72;
uniform float puff_radius : hint_range(1.0, 30.0) = 8.0;

varying float v_h;

void vertex() {
    // 归一化局部高度（0=云底，1=云顶）
    v_h = clamp(VERTEX.y / puff_radius * 0.5 + 0.5, 0.0, 1.0);
}

void fragment() {
    vec3 c = mix(bot_color.rgb, top_color.rgb, smoothstep(0.15, 0.9, v_h));
    ALBEDO = c;
    ALPHA = alpha;
}
