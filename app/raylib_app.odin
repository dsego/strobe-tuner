package app

import rl "vendor:raylib"
import "core:fmt"

SCREEN_WIDTH :: 1024
SCREEN_HEIGHT :: 768

run_app :: proc () {
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    for !rl.WindowShouldClose() {
        draw_screen()
    }
    rl.CloseWindow()
}

@(private)
draw_screen :: proc() {
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.BLACK)
}
