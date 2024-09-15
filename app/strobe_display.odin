package app

import "core:fmt"
import "core:math"
import rl "vendor:raylib"


StrobeDisplay :: struct {
    samples: [STROBE_SAMPLE_SIZE]f32,
    pattern_image: rl.Image,
    pattern_texture: rl.Texture2D,
    points: [STROBE_SAMPLE_SIZE]rl.Vector2,
    framerate_state: FramerateState,
}


strobe_displays: [STROBE_COUNT]StrobeDisplay


init_strobe_display :: proc () {
    for i in 0..<STROBE_COUNT {
        strobe_displays[i].pattern_image = rl.GenImageColor(1024, 1, {100, 0, 0, 255})
        strobe_displays[i].framerate_state = init_framerate()
    }
}

destroy_strobe_display :: proc () {
    for i in 0..<STROBE_COUNT {
        rl.UnloadImage(strobe_displays[i].pattern_image)
    }
}


draw_strobe_display :: proc(target_freq: f64, target_interval: f64, show_pattern: bool = false) {
    for i in 0..<STROBE_COUNT {
        rect := rl.Rectangle{160, f32(50 + 110 * i), 800, 100}
        frame_count, drift := read_framerate_samples(
            &strobe_displays[i].framerate_state,
            rb_ptr=&strobe_ringbuffers[i],
            samples=strobe_displays[i].samples[:],
            target_interval=target_interval,
        )


        experiment(rect, &strobe_displays[i], target_interval, frame_count, drift, target_freq)

        draw_strobe_lines(rect, &strobe_displays[i], target_interval, frame_count, drift)

        if show_pattern {
            // draw_strobe_pattern(rect, &strobe_displays[i], target_interval, frame)
        }
    }
}

reset_strobe_display :: proc() {
    for i in 0..<STROBE_COUNT {
        reset_framerate(&strobe_displays[i].framerate_state)
    }
}


@(private)
draw_strobe_lines :: proc(
    rect: rl.Rectangle,
    strobe_display: ^StrobeDisplay,
    target_interval: f64,
    frame_count: u32,
    drift: f64,
) {
    // fmt.println(target_interval, frame_count, drift)
    rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.GRAY)
    rl.DrawLineEx({rect.x, rect.y + rect.height/2.0}, {rect.x+rect.width, rect.y + rect.height/2.0}, 1.0, rl.GRAY)

    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    factor := (rect.height/2.0 - 1.0)

    // TODO: resample by linear interpolation to fit the pixels
    // e.g. from 300 samples produce a value for each of the 800 pixels

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := rect.y + rect.height/2.0 - strobe_display.samples[i] * factor
        strobe_display.points[i] = { x, y }
        x -= resolution
    }


    // target_interval = 2.0 * f64(SAMPLERATE) / target_freq

    rl.DrawLineStrip(raw_data(strobe_display.points[:]), i32(frame_count), rl.PINK)
}

@(private)
draw_strobe_pattern :: proc() {

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


experiment :: proc(
    rect: rl.Rectangle,
    using strobe_display: ^StrobeDisplay,
    target_interval: f64,
    frame_count: u32,
    drift: f64,
    target_freq: f64,
) {

    // buffers: [802][1024]f32

    // period := f32(SAMPLERATE / target_freq)

    // flip := false
    // next_edge := period

    // for shift in 0..<len(buffers) {
    //     next_edge = period - f32(shift)

    //     // draw one black-white stripe pattern
    //     for i in 0..<frame_count {
    //         k := strobe_display.samples[i]
    //         buffers[shift][i] = flip ? 1.0 : -1.0
    //         buffers[shift][i] *= strobe_display.samples[shift]
    //         if f32(i) > next_edge {
    //             flip = !flip
    //             next_edge += period
    //         }
    //     }
    // }

    // for i in 0..<frame_count {
    //     for shift in 1..<len(buffers) {
    //         buffers[0][i] += buffers[shift][i] / f32(len(buffers))
    //     }
    // }




    dx := rect.width / f32(target_interval - 1.0)
    drift_adj := f32(drift) * dx

    pos := rect.x + rect.width //- drift_adj
    for i in 0..<frame_count {

        // convert from range -1.0 - 1.0 to range 0 - 255

        val := (5 * strobe_display.samples[i] + 1.0) / 2.0
        // val := (5 * buffers[0][i] + 1.0) / 2.0

        val = math.max(math.min(val, 1.0), 0.0)

        byte_val := u8(val * 255)
        rl.DrawLineEx({pos, rect.y}, {pos, rect.y + 10}, dx, rl.Color{255, 255, 255, u8(byte_val)})

        // val = u8(buffers[400][i] * 255)
        // rl.DrawLineEx({pos, rect.y + 10}, {pos, rect.y + 20}, dx, rl.Color{255, 255, 255, u8(val)})
        pos -= dx
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
