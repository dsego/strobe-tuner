package app

import "core:fmt"
import "core:math"
import rl "vendor:raylib"


StrobeDisplay :: struct {
    samples: [STROBE_SAMPLE_SIZE]f32,
    pattern_image: rl.Image,
    pattern_texture: rl.Texture2D,
    points: [STROBE_SAMPLE_SIZE]rl.Vector2,
}


strobe_displays: [STROBE_COUNT]StrobeDisplay


init_strobe_display :: proc () {
    for i in 0..<STROBE_COUNT {
        strobe_displays[i].pattern_image = rl.GenImageColor(1024, 1, {100, 0, 0, 255})
    }
}

destroy_strobe_display :: proc () {
    for i in 0..<STROBE_COUNT {
        rl.UnloadImage(strobe_displays[i].pattern_image)
    }
}


draw_strobe_display :: proc(target_interval: f64, show_pattern: bool = false) {
    for i in 0..<STROBE_COUNT {
        rect := rl.Rectangle{160, f32(50 + 110 * i), 800, 100}
        frame_count, drift := read_samples(
            rb_ptr=&strobe_ringbuffers[i],
            samples=strobe_displays[i].samples[:],
            target_interval=target_interval,
        )
        _draw_strobe_lines(rect, &strobe_displays[i], target_interval, frame_count, drift)

        if show_pattern {
            // _draw_strobe_pattern(rect, &strobe_displays[i], target_interval, frame)
        }
    }
}

@(private)
_draw_strobe_lines :: proc(
    rect: rl.Rectangle,
    strobe_display: ^StrobeDisplay,
    target_interval: f64,
    frame_count: u32,
    drift: f64,
) {
    // fmt.println(target_interval, frame_count, drift)
    rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.GRAY)

    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    factor := (rect.height/2.0 - 1.0)

    // TODO: resample by linear interpolation to fit the pixels
    // e.g. from 300 samples produce a value for each of the 800 pixels

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := rect.y + rect.height/2.0 - strobe_display.samples[i] * factor
        strobe_display.points[frame_count-i-1] = { x, y }
        x -= resolution
    }

    rl.DrawLineStrip(raw_data(strobe_display.points[:]), i32(frame_count), rl.PINK)
}

@(private)
_draw_strobe_pattern :: proc() {

    // max := find_abs_max(strobe_samples[:frame_count])
    // factor := 1.0 / max

    // for j in 0..<frame_count {
    //     // convert from range -1.0 - 1.0 to range 0 - 255
    //     val := u8(f32(factor) * strobe_samples[i+int(j)] * 127.5 + 127.5)
    //     // val := u8(255)
    //     // freq := f32(10.0)
    //     // val := u8(math.sin_f32(f32(j)/256.0 * 2.0 * math.PI * freq) * 127.5 + 127.5)
    //     rl.ImageDrawPixel(&pattern_image, i32(frame_count-j-1), 0, {val, val, val, 255})
    // }

    // pattern_texture = rl.LoadTextureFromImage(pattern_image)
    // defer rl.UnloadTexture(pattern_texture)

    // rl.DrawTexturePro(
    //     texture=pattern_texture,
    //     source={0, 0, f32(frame_count), 1},
    //     dest={50, f32(y), 800, 100},
    //     origin={},
    //     rotation=0,
    //     tint=rl.WHITE,
    // )
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
