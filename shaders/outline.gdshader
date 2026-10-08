shader_type spatial;
render_mode cull_front, unshaded;

// 反向壳描边：放大顶点、只画背面
uniform float thickness = 0.012;
uniform vec4 line_color : source_color = vec4(0.16, 0.12, 0.20, 1.0);

void vertex() {
    VERTEX += NORMAL * thickness;
}

void fragment() {
    ALBEDO = line_color.rgb;
}
