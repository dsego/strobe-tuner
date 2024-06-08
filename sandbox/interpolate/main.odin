package interpolate


import rl "vendor:raylib"
import "core:math"
import "core:fmt"


SCREEN_WIDTH :: 800
SCREEN_HEIGHT :: 600

target_freq := 2300.0
sample_count := 38
drift := 0.5217391304395278


signal: [38]f64
points: [38]rl.Vector2

adj_points: [38]rl.Vector2


main :: proc() {
    rl.SetTargetFPS(60)
    rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Strobe Tuner")
    defer rl.CloseWindow()


    for i in 0..<sample_count {
        signal[i] = math.sin(f64(i) * math.PI * 0.3) * 50.0
    }

    dx := 700 / f64(sample_count-1)
    drift_adj := drift * dx

    y: = 100.0
    x: = 50.0

    // drift adjusted by translating
    for i in 0..<sample_count {
        dy := signal[i]
        points[i] = { f32(x+drift_adj), f32(y + dy) }
        x += dx
    }

    // drift adjusted by interpolating (linear)
    x = 50.0
    adj_points[0] = { f32(x), f32(y) }
    x += dx

    for i in 1..<sample_count {
        dy := signal[i-1] + drift * (signal[i] - signal[i-1])
        adj_points[i] = { f32(x), f32(y + dy) }
        x += dx
    }
    fmt.println(adj_points)


    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.DrawRectangleLines(50, 50, 700, 100, rl.GRAY)
        rl.DrawLineStrip(raw_data(points[:]), i32(sample_count), rl.PINK)
        rl.DrawLineStrip(raw_data(adj_points[:]), i32(sample_count), rl.GOLD)
    }
}
