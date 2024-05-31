package app

import "core:fmt"
import "core:math"
import rl "vendor:raylib"


strobe_samples: [STROBE_COUNT*SAMPLE_SIZE]f32
pattern_image: rl.Image
pattern_texture: rl.Texture2D

init_strobe_display :: proc () {
    pattern_image = rl.GenImageColor(1024, 1, {100, 0, 0, 255})

}

destroy_strobe_display :: proc () {
    rl.UnloadImage(pattern_image)
}

load_strobe_texture :: proc (frame_count: u32) {
    for i in 0..<STROBE_COUNT {
        max: f32 = 0.0
        for j in 0..<frame_count {
            abs_val := abs(strobe_samples[i+int(j)])
            if abs_val > max {
                max = abs_val
            }
        }

        factor := 1.0 / max

        for j in 0..<frame_count {
            // convert from range -1.0 - 1.0 to range 0 - 255
            val := u8(f32(factor) * strobe_samples[i+int(j)] * 127.5 + 127.5)
            // val := u8(255)
            // freq := f32(10.0)
            // val := u8(math.sin_f32(f32(j)/256.0 * 2.0 * math.PI * freq) * 127.5 + 127.5)
            rl.ImageDrawPixel(&pattern_image, i32(frame_count-j-1), 0, {val, val, val, 255})
        }
    }
    pattern_texture = rl.LoadTextureFromImage(pattern_image)
}

unload_strobe_texture :: proc () {
    rl.UnloadTexture(pattern_texture)
}

draw_strobes :: proc(
    target_interval: f64,
    drift: f64,
    frame_count: u32,
    show_pattern: bool,
) {

    width :f32 = 800

    dx := width / f32(target_interval-1)

    // TODO:
    // Resample based on sub-sample drift


    drift_adj := f32(drift) * dx


    for i in 0..<STROBE_COUNT {
        points: [SAMPLE_SIZE]rl.Vector2
        x := width + 50 + drift_adj
        // x := 50.0 - drift_adj
        y := 200 + 110 * i32(i)

        rl.DrawRectangleLines(49, y-1, 802, 102, rl.GRAY)

        // fmt.println(frame_count)

        if show_pattern {
            rl.DrawTexturePro(
                texture=pattern_texture,
                source={0, 0, f32(frame_count), 1},
                dest={50, f32(y), 800, 100},
                origin={},
                rotation=0,
                tint=rl.WHITE,
            )

        } else {
            for j in 0..<frame_count {
                // note that y is flipped (negative)
                dy := 100.0 / 2.0 - strobe_samples[i+int(j)] * 400.0
                points[j] = { x, f32(y) + dy }
                x -= dx
            }
            rl.DrawLineStrip(raw_data(points[:]), i32(frame_count), rl.PINK)
        }

    }
}
