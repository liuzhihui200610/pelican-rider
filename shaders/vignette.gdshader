shader_type canvas_item;

// 电影感后期：暗角 + 轻微色散(CA) + 胶片颗粒
// 作用于 3D 画面（hint_screen_texture 采样当前已渲染的屏幕）；HUD 在更上层保持清晰。
// 注意：Godot 4.7 已移除内置 SCREEN_TEXTURE，必须用 hint_screen_texture 的 sampler 统一声明。
uniform sampler2D screen_tex : hint_screen_texture;
uniform float strength   : hint_range(0.0, 1.0) = 0.30;   // 暗角强度
uniform float ca_amount : hint_range(0.0, 0.01) = 0.0014; // 色散强度（边缘红蓝分离）
uniform float grain     : hint_range(0.0, 0.2)  = 0.045;  // 胶片颗粒强度

void fragment() {
    vec2 uv = SCREEN_UV;
    vec2 dir = uv - 0.5;
    float r = length(dir);

    // 色散：红/蓝通道沿径向微移，越靠边越强（镜头边缘色差，电影质感）
    float ca = ca_amount * (0.25 + r * 1.5);
    vec2 off = normalize(dir + vec2(1e-5)) * ca;
    vec3 col;
    col.r = texture(screen_tex, uv + off).r;
    col.g = texture(screen_tex, uv).g;
    col.b = texture(screen_tex, uv - off).b;

    // 暗角：只压四角，不影响中心
    float vig = smoothstep(0.40, 0.92, r) * strength;
    col *= (1.0 - vig);

    // 胶片颗粒（动态噪声，低密度）
    vec2 gn = uv * vec2(1280.0, 720.0) + TIME * 47.0;
    float n = fract(sin(dot(gn, vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * grain;

    COLOR = vec4(col, 1.0);
}
