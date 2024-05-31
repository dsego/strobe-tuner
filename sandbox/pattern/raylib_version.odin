package pattern


import "core:fmt"
import "core:math"
import rl "vendor:raylib"

raylib_version :: proc() {
    rl.InitWindow(800, 600, "Filter")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})


    image := rl.GenImageColor(256, 1, {100, 0, 0, 255})
    defer rl.UnloadImage(image)

    for i in 0..<256 {
        freq := f32(5.0)
        val := math.sin_f32(f32(i)/256.0 * 2.0 * math.PI * freq) * 127.5 + 127.5
        rl.ImageDrawPixel(&image, i32(i), 0, {u8(val), u8(val), u8(val), 255})
    }

    texture := rl.LoadTextureFromImage(image)
    defer rl.UnloadTexture(texture)

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rl.DrawTexturePro(
            texture=texture,
            source={0, 0, 256, 100},
            dest={50, 50, 400, 100},
            origin={},
            rotation=0,
            tint=rl.WHITE,
        )
    }
}
