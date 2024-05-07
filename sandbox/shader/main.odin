package shader

import rl "vendor:raylib"

import "core:fmt"
import "core:math"

SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768

init :: proc() {
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Shader")
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
}

cleanup :: proc() {
    rl.CloseWindow()
}

vs_code :: `
    #version 410

    uniform mat4 mvp;

    in vec3 vertexPosition;
    in vec2 vertexTexCoord;

    out vec2 fragCoord;

    void main() {
        gl_Position = mvp*vec4(vertexPosition, 1.0);
        fragCoord = vertexPosition.xy;
        // fragCoord = vertexTexCoord;
    }
`

fs_code :: `
    #version 410

    uniform sampler2D textureSampler;
    uniform vec2 resolution;

    in vec2 fragCoord;
    out vec4 finalColor;

    void main()
    {
        vec2 uv = fragCoord.xy / resolution;
        vec4 tex = texture(textureSampler, vec2(uv.x, 0.));
        finalColor = vec4(1., 1., 1., tex.x);
    }
`

Vector2 :: distinct [2]f32

main :: proc() {
    init()
    defer cleanup()


    shader := rl.LoadShaderFromMemory(vs_code, fs_code)
    defer rl.UnloadShader(shader)

    rl.rlEnableShader(shader.id);

    data_buffer: []f32 = make([]f32, 256)
    defer delete(data_buffer)


    for i in 0..<len(data_buffer) {
        data_buffer[i] = 0.2 // f32(i) / f32(len(data_buffer))
    }

    texture_id := rl.rlLoadTexture(
        &data_buffer,
        width=i32(len(data_buffer)),
        height=1,
        format=i32(rl.PixelFormat.UNCOMPRESSED_R32),
        mipmapCount=0
    )
    defer rl.rlUnloadTexture(texture_id)

    rl.rlActiveTextureSlot(10);
    rl.rlEnableTexture(texture_id)
    defer rl.rlDisableTexture()

    rl.rlSetTexture(texture_id)
    defer rl.rlSetTexture(0)

    rl.rlTextureParameters(texture_id, rl.RL_TEXTURE_MIN_FILTER, rl.RL_TEXTURE_FILTER_NEAREST)
    rl.rlTextureParameters(texture_id, rl.RL_TEXTURE_WRAP_S, rl.RL_TEXTURE_WRAP_CLAMP)
    rl.rlTextureParameters(texture_id, rl.RL_TEXTURE_WRAP_T, rl.RL_TEXTURE_WRAP_CLAMP)

    uniform_loc_idx := rl.GetShaderLocation(shader, "textureSampler")
    resolution_loc_idx := rl.GetShaderLocation(shader, "resolution")

    resolution := Vector2 {400, 400}

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rl.BeginShaderMode(shader)
        defer rl.EndShaderMode()


        rl.rlSetUniformSampler(i32(uniform_loc_idx), texture_id)
        rl.rlSetUniform(i32(resolution_loc_idx), &resolution, i32(rl.ShaderUniformDataType.VEC2), 1)
        rl.rlSetUniform(i32(uniform_loc_idx), &data_buffer, i32(rl.ShaderUniformDataType.SAMPLER2D), i32(len(data_buffer)))

        rl.DrawRectangle(40, 40, 400, 400, {})
    }
}
