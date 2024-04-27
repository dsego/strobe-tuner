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
    #version 330

    uniform mat4 mvp;

    in vec3 vertexPosition;
    in vec2 vertexTexCoord;
    out vec2 fragTexCoord;

    void main() {
        gl_Position = mvp*vec4(vertexPosition, 1.0);
        fragTexCoord = vertexPosition.xy;
    }
`

fs_code :: `
    #version 330

    uniform float dataBuffer[256];
    uniform vec2 resolution;

    in vec2 fragTexCoord;
    out vec4 finalColor;

    void main()
    {
        // vec4 tex = texelFetch(dataBuffer, 0);
        // finalColor = vec4(dataBuffer[0], 0.,0.,1.);
        vec2 st = fragTexCoord.xy/resolution;
        finalColor = vec4(st.x, 1.0 - st.y, 0., 1.);
    }
`

Vector2 :: distinct [2]f32

main :: proc() {
    init()
    defer cleanup()


    shader := rl.LoadShaderFromMemory(vs_code, fs_code)
    defer rl.UnloadShader(shader)


    // SetShaderValue :: proc "c" (shader: Shader, locIndex: ShaderLocationIndex, value: rawptr, uniformType: ShaderUniformDataType)
    data_buffer: []f32 = make([]f32, 256)
    defer delete(data_buffer)

    // image := rl.LoadImage("../assets/gradient.png")
    // texture := rl.LoadTextureFromImage(image)
    // texture_location := rl.GetShaderLocation(shader, "dataBuffer")
    resolution_location := rl.GetShaderLocation(shader, "resolution")
    data_buffer_location := rl.GetShaderLocation(shader, "dataBuffer")

    resolution := Vector2 {400, 400}

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)


        for i in 0..<len(data_buffer) {
            data_buffer[i] = 0.2 //math.sin(2.0 * math.PI * f32(i))
        }
        // rl.SetShaderValueTexture(shader, texture_location, texture)

        rl.SetShaderValue(shader, resolution_location, &resolution, rl.ShaderUniformDataType.VEC2);
        rl.SetShaderValueV(shader, data_buffer_location, &data_buffer, rl.ShaderUniformDataType.FLOAT, i32(len(data_buffer)));

        rl.BeginShaderMode(shader)
        defer rl.EndShaderMode()
        {

            // rl.DrawTexture(texture, 10, 10, rl.BLUE)
            // rl.rlSetTexture(texture.id)
            rl.DrawRectangle(40, 40, 400, 400, { 0, 100, 0, 255 });
        }

    }
}
