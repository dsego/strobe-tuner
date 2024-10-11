package app

import "core:fmt"
import "core:math"
import "core:strings"
import "core:path/filepath"
import rl "vendor:raylib"


StrobeDisplay :: struct {
    strobe: ^Strobe,
    bands: [dynamic]StrobeBandDisplay,
    texture: rl.Texture2D,
}

StrobeBandDisplay :: struct {
    samples: []f32,
    filtered_samples: []f32,
    points: []rl.Vector2,
}

init_strobe_display :: proc (size: int, strobe: ^Strobe) -> (self: StrobeDisplay) {
    for band in strobe.bands {
        band_display := StrobeBandDisplay{}
        band_display.samples = make([]f32, size)
        band_display.filtered_samples = make([]f32, size)
        band_display.points = make([]rl.Vector2, size)
        append(&self.bands, band_display)
    }
    self.strobe = strobe

    root_dir := filepath.dir(#file)
    path := filepath.join({root_dir, "../assets/texture.png"})
    img_path := strings.clone_to_cstring(path)
    self.texture = rl.LoadTexture(img_path)
    return
}

destroy_strobe_display :: proc (self: ^StrobeDisplay) {
    for band_display in self.bands {
        delete(band_display.samples)
        delete(band_display.filtered_samples)
        delete(band_display.points)
    }
    rl.UnloadTexture(self.texture)
}

draw_strobe_display :: proc(self: ^StrobeDisplay, rms: f32) {
    for &band, i in self.strobe.bands {
        frame_count, drift := read_framerate_samples(
            &band.framerate_state,
            rb_ptr=&band.ringbuffer,
            samples=self.bands[i].samples,
            target_interval=f64(band.target_interval),
        )
        rect := rl.Rectangle{160, f32(50 + 110 * i), 800, 100}

        rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)

        if band.target_interval >= MAX_SPECTRUM_DISPLAY_LEN {
            continue
        }

        rl.DrawTextEx(font, fmt.ctprintf("Drift %.6f", drift), {50, 20}, 20, 0, rl.PINK)
        rl.DrawRectangleV({220, 30}, {200 * f32(drift), 4.0}, rl.PINK)
        rl.DrawRectangleLinesEx({220, 30, 200, 5}, 1, rl.PINK)

        // draw_fake_strobe_band_pattern(
        //     rect,
        //     self.texture,
        //     &self.bands[i],
        //     band.freq_hz,
        //     band.target_interval,
        //     frame_count,
        //     drift,
        //     i,
        // )



        band_display := &self.bands[i]
        max_peak := find_abs_max(band_display.samples)
        gain:f32 = 100.0 / (max_peak + 0.1)

        // for k in 0..<frame_count do band_display.filtered_samples[k] = band_display.samples[k]

        amp := reconstruct_from_dft(
            band.freq_hz,
            band_display.samples[:frame_count],
            band_display.filtered_samples[:frame_count],
            SAMPLERATE,
            drift,
        )


        // Linear interpolation to correct drift
        // for k in 0..<frame_count-1 {
        //     band_display.filtered_samples[k] = band_display.samples[k] + (1.0 - f32(drift)) * (band_display.samples[k+1] - band_display.samples[k])
        // }

        // draw_strobe_lines_drift(rect, &self.bands[i], band.target_interval, frame_count, drift)

        draw_strobe_band_pattern(rect, &self.bands[i], band.target_interval, band.freq_hz, frame_count, gain)
        // draw_strobe_lines(rect, &self.bands[i], band.target_interval, frame_count, gain)
    }
}


draw_strobe_lines :: proc(
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    gain: f32,
) {
    // fmt.println(target_interval, frame_count, drift)
    resolution := rect.width / f32(target_interval)

    x:f32 = f32(rect.x) + f32(rect.width)
    factor := (rect.height/2.0 - 1.0) * gain

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := rect.y + rect.height/2.0 - band_display.filtered_samples[i] * factor
        band_display.points[i] = { x, y }
        x -= resolution
    }

    // fmt.println(band_display.samples[:frame_count], target_interval, frame_count, drift)

    rl.DrawLineStrip(raw_data(band_display.points), i32(frame_count), rl.GOLD)

}


draw_strobe_lines_drift :: proc(
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    frame_count: u32,
    drift: f64,
) {
    // fmt.println(target_interval, frame_count, drift)
    resolution := rect.width / f32(target_interval)
    drift_adj := f32(drift) * resolution

    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj

    peak: f32 = find_abs_max(band_display.samples)
    gain := 1.0 / (peak + 0.2)

    factor := (rect.height/2.0 - 1.0) * gain

    for i in 0..<frame_count {
        // note that y is flipped (negative)
        y := rect.y + rect.height/2.0 - band_display.samples[i] * factor
        band_display.points[i] = { x, y }
        x -= resolution
    }

    // fmt.println(band_display.samples[:frame_count], target_interval, frame_count, drift)

    rl.DrawLineStrip(raw_data(band_display.points), i32(frame_count), rl.PINK)
}


// draw strobe pattern directly from samples
draw_strobe_band_pattern :: proc (
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    target_freq: f32,
    frame_count: u32,
    gain: f32,
) {
    resolution := rect.width / f32(frame_count)
    x: f32 = f32(rect.x) + f32(rect.width)



    // rl.DrawText(fmt.ctprintf("%.2f", amp), 120, i32(rect.y) + 50, 14, rl.GRAY)

    // color_a := rl.Color{181, 242, 219, 255}
    // color_b := rl.Color{107, 61, 125, 255}



    // Need to up-sample to get smoother motion on the pattern strobe,
    // because it's not interpolating like the lines - otherwise we get wavering effect


    // if f32(frame_count) < rect.width {
    //     out_size := rect.width
    //     in_size := frame_count
    //     interval: f32 = f32(in_size) / out_size

    //     time: f32 = 0.0
    //     in_idx :u32 = 0
    //     out_idx :u32 = 0

    //     in_data := band_display.filtered_samples[:frame_count]

    //     for in_idx < (in_size - 1)  {
    //         out := lerp(in_data[in_idx], in_data[in_idx+1], time)

    //         color := convert_to_rgba(factor * out)
    //         rl.DrawLineEx(
    //             {x - resolution/2, rect.y},
    //             {x - resolution/2, rect.y + rect.height},
    //             resolution,
    //             color,
    //         )

    //         time += interval
    //         in_idx = u32(math.trunc(time))
    //         x -= 1.0
    //     }

    // } else {

        for i in 0..<frame_count {
            color := convert_to_rgba(band_display.filtered_samples[i] * gain)

            // byte_val := u8(val * 255)
            rl.DrawLineEx(
                {x - resolution/2, rect.y},
                {x - resolution/2, rect.y + rect.height},
                resolution,
                color,
            )
            x -= resolution
        }
    // }



}

lerp :: proc (a: f32, b: f32, t: f32) -> f32 {
  return a + t * (b - a)
}


convert_to_rgba :: proc (value: f32) -> rl.Color {
    value := value

    color_a := rl.Color{226, 101, 70, 255}
    color_b := rl.Color{84, 32, 43, 255}

    // TODO optimize, no need to calculate per sample
    dr := color_a.r - color_b.r
    dg := color_a.g - color_b.g
    db := color_a.b - color_b.b


    // convert from range -1.0 - 1.0 to range 0 - 255
    value = 0.5 * value + 0.5
    // val := 0.5 * factor * band_display.samples[i] + 0.5
    value = math.max(math.min(value, 1.0), 0.0)

    r := u8(f32(color_b.r) + f32(dr) * value)
    g := u8(f32(color_b.g) + f32(dg) * value)
    b := u8(f32(color_b.b) + f32(db) * value)

    return rl.Color{r, g, b, 255}
}


// draw strobe pattern by calculating DFT phase
draw_fake_strobe_band_pattern :: proc (
    rect: rl.Rectangle,
    texture: rl.Texture2D,
    band_display: ^StrobeBandDisplay,
    target_freq: f32,
    target_interval: f32,
    frame_count: u32,
    drift: f64,
    band_index: int,
) {
    resolution := rect.width / f32(target_interval-1.0)
    x:f32 = f32(rect.x) + f32(rect.width)
    gain:f32 = 1.0 // find_abs_max(band_display.samples)
    factor := (rect.height/2.0 - 1.0) * gain


    dft := run_dft(target_freq, band_display.samples[:], SAMPLERATE, f32(drift))
    sin := real(dft)
    cos := imag(dft)

    phase := math.atan2(sin, cos)
    mag := magnitude(dft)

    repeats := 2 * (band_index + 1)

    // convert phase from -PI to PI to -64 to 64 (pattern width = 128)
    phase *= 64.0 / math.PI

    rl.DrawTexturePro(
        texture=texture,
        source={phase, 0, 128 * f32(repeats), 64},
        dest=rect,
        origin={0, 0},
        rotation=0.0,
        // tint=rl.WHITE,
        tint=rl.ColorAlpha(rl.WHITE, 0.1* mag)
    )


    rl.DrawCircleLines(700, 600, 80, rl.GRAY)
    rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase), 600.0 - 80.0 * math.sin(phase)}, 6.0, rl.PINK)
    rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase+math.PI), 600.0 - 80.0 * math.sin(phase+math.PI)}, 6.0, rl.PINK)
}

