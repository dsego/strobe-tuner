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

        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)

        draw_strobe_band_pattern(rect, &self.bands[i], band.target_interval, frame_count, drift)
        draw_strobe_lines(rect, &self.bands[i], band.target_interval, frame_count, drift)
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
    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    gain:f32 = 10.0 // find_abs_max(band_display.samples)

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

draw_strobe_band_pattern :: proc (
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    drift: f64,
) {
    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution
    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj
    gain:f32 = 1.0 // find_abs_max(band_display.samples)
    factor := (rect.height/2.0 - 1.0) * gain

    for i in 0..<frame_count {
        // convert from range -1.0 - 1.0 to range 0 - 255
        val := (factor * band_display.samples[i] + 1.0) / 2.0
        val = math.max(math.min(val, 1.0), 0.0)
        byte_val := u8(val * 255)
        rl.DrawLineEx({x, rect.y}, {x, rect.y + rect.height}, resolution, rl.Color{255, 255, 255, u8(byte_val)})
        x -= resolution
    }
}
