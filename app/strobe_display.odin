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
        max := find_abs_max(strobe_samples[:frame_count])
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

    // fmt.println(target_interval, frame_count, drift)

    width: f32 = 800
    height: f32 = 100

    // floored_interval := math.trunc(target_interval)

    // resolution
    dx := width / f32(target_interval-1.0)

    drift_adj := f32(drift) * dx


    for i in 0..<STROBE_COUNT {
        points: [SAMPLE_SIZE]rl.Vector2
        x :f32 = width + 50.0 //+ drift_adj

        // fmt.println(drift, x)

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
            max := find_abs_max(strobe_samples[:frame_count])
            // factor := (height/2.0 - 1.0) / max
            factor := (height/2.0 - 1.0) * 10.0

            // TODO: resample by linear interpolation to fit the pixels
            // e.g. from 300 samples produce a value for each of the 800 pixels

            for j in 0..<frame_count {
                // note that y is flipped (negative)
                dy := height/2.0 - strobe_samples[i+int(j)] * factor
                points[j] = { x - f32(drift) * dx, f32(y) + dy }
                x -= dx
            }

            rl.DrawLineStrip(raw_data(points[:]), i32(frame_count), rl.PINK)
        }

    }
}


find_abs_max :: proc (slice: []f32) -> f32 {
    max: f32 = 0.0
    for i in 0..<len(slice) {
        abs_val := abs(slice[i])
        if abs_val > max {
            max = abs_val
        }
    }
    return max
}
