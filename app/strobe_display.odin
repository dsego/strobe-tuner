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

        draw_strobe_band_pattern(rect, &self.bands[i], band.target_interval, band.freq_hz, frame_count, drift)
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


// draw strobe pattern directly from samples
draw_strobe_band_pattern :: proc (
    rect: rl.Rectangle,
    band_display: ^StrobeBandDisplay,
    target_interval: f32,
    target_freq: f32,
    frame_count: u32,
    drift: f64,
) {
    resolution := rect.width / f32(target_interval-1.0)
    drift_adj := f32(drift) * resolution
    x: f32 = f32(rect.x) + f32(rect.width) - drift_adj

    peak: f32 = find_abs_max(band_display.samples)

    // limit gain
    gain := 10.0 / (peak + 0.2)
    // gain := 100.0 / peak

    reconstruct_from_dft(target_freq, band_display.samples[:], band_display.filtered_samples[:], SAMPLERATE)

    factor := (rect.height/2.0 - 1.0) * gain

    // color_a := rl.Color{181, 242, 219, 255}
    // color_b := rl.Color{107, 61, 125, 255}


    color_a := rl.Color{226, 101, 70, 255}
    color_b := rl.Color{84, 32, 43, 255}


    dr := color_a.r - color_b.r
    dg := color_a.g - color_b.g
    db := color_a.b - color_b.b



    for i in 0..<frame_count {
        // convert from range -1.0 - 1.0 to range 0 - 255
        val := 0.5 * factor * band_display.filtered_samples[i] + 0.5
        // val := 0.5 * factor * band_display.samples[i] + 0.5
        val = math.max(math.min(val, 1.0), 0.0)

        r := u8(f32(color_b.r) + f32(dr) * val)
        g := u8(f32(color_b.g) + f32(dg) * val)
        b := u8(f32(color_b.b) + f32(db) * val)


        // byte_val := u8(val * 255)
        rl.DrawLineEx({x, rect.y}, {x, rect.y + rect.height}, resolution, rl.Color{r, g, b, 255})
        x -= resolution
    }
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
    drift_adj := f32(drift) * resolution
    x:f32 = f32(rect.x) + f32(rect.width) - drift_adj
    gain:f32 = 1.0 // find_abs_max(band_display.samples)
    factor := (rect.height/2.0 - 1.0) * gain


    // TODO: how to account for the small drift here?
    //  need to interpolate before running DFT!!


    dft := run_dft(target_freq, band_display.samples[:], SAMPLERATE)
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
        tint=rl.WHITE
        // tint=rl.ColorAlpha(rl.WHITE, 0.1*mag)
    )


    // rl.DrawCircleLines(700, 600, 80, rl.GRAY)
    // rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase), 600.0 - 80.0 * math.sin(phase)}, 6.0, rl.PINK)
    // rl.DrawCircleV(rl.Vector2{700.0 - 80.0 * math.cos(phase+math.PI), 600.0 - 80.0 * math.sin(phase+math.PI)}, 6.0, rl.PINK)
}

