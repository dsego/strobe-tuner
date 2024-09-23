package app

import "core:fmt"
import "core:math"
import rl "vendor:raylib"


StrobeDisplay :: struct {
    strobe: ^Strobe,
    bands: [dynamic]StrobeBandDisplay,
}

StrobeBandDisplay :: struct {
    samples: []f32,
    points: []rl.Vector2,
}

init_strobe_display :: proc (size: int, strobe: ^Strobe) -> (self: StrobeDisplay) {
    for band in strobe.bands {
        band_display := StrobeBandDisplay{}
        band_display.samples = make([]f32, size)
        band_display.points = make([]rl.Vector2, size)
        append(&self.bands, band_display)
    }
    self.strobe = strobe
    return
}

destroy_strobe_display :: proc (self: ^StrobeDisplay) {
    for band_display in self.bands {
        delete(band_display.samples)
        delete(band_display.points)
    }
}

draw_strobe_display :: proc(self: ^StrobeDisplay) {
    for &band, i in self.strobe.bands {
        frame_count, drift := read_framerate_samples(
            &band.framerate_state,
            rb_ptr=&band.ringbuffer,
            samples=self.bands[i].samples,
            target_interval=f64(band.target_interval),
        )
        rect := rl.Rectangle{160, f32(50 + 110 * i), 800, 100}
        draw_strobe_lines(rect, &self.bands[i], band.target_interval, frame_count, drift)
        // experiment(rect, &strobe_displays[i], target_interval, frame_count, drift, target_freq)
    }
}


@(private)
draw_strobe_lines :: proc(
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    drift: f64,
) {
    // fmt.println(target_interval, frame_count, drift)
    rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.GRAY)
    rl.DrawLineEx({rect.x, rect.y + rect.height/2.0}, {rect.x+rect.width, rect.y + rect.height/2.0}, 1.0, rl.GRAY)

    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    gain:f32 = 20.0 // find_abs_max(band_display.samples)

    factor := (rect.height/2.0 - 1.0) * gain

    // TODO: resample by linear interpolation to fit the pixels
    // e.g. from 300 samples produce a value for each of the 800 pixels

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := rect.y + rect.height/2.0 - band_display.samples[i] * factor
        band_display.points[i] = { x, y }
        x -= resolution
    }


    // target_interval = 2.0 * f64(SAMPLERATE) / target_freq

    rl.DrawLineStrip(raw_data(band_display.points), i32(frame_count), rl.PINK)
}

/*

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

    // draw strobe pattern by calculating DFT phase
    dft := run_dft(f32(target_freq), strobe_display.samples[:], SAMPLERATE)
    sin := real(dft)
    cos := imag(dft)

    //  how to account for the small drift here
    phase := -math.atan2(sin, cos)



    // fmt.println(phase, magnitude(dft))

    rl.DrawCircleLines(700, 600, 80, rl.GRAY)
    rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase), 600.0 - 80.0 * math.sin(phase)}, 6.0, rl.PINK)
    rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase+math.PI), 600.0 - 80.0 * math.sin(phase+math.PI)}, 6.0, rl.PINK)


    // ============

    // draw strobe pattern directly from samples

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


*/
