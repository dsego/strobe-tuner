/* ------------------------------------------------------------------------------------------------


    Phase tracker
    - Generates a reference signal and detects the phase difference between the reference
      and target. The reference phase is calculated in the drawing method and synthesizes a strobe
      based on the detected phase difference.


 -------------------------------------------------------------------------------------------------*/


package app

import "core:math"
import "core:fmt"
import rl "vendor:raylib"


PhaseTrackerBand :: struct {
    freq_hz: f32,
    norm_freq: f32,
    freq_diff_hz: f32,
    estimated_freq_hz: f32,
    angle: f32,
    dft: SingleFreqDFT,
    time_stretch: f32,
    phase: f32,
    amp: f32,
}

PhaseTracker :: struct {
    using node: AudioCaptureNode,
    sample_buffer: []f32,
    window_size: int,
    overlap_size: int,
    ringbuffer: RingBuffer,
    ringbuffer_data: []u8,
    phase_correction: f32,
    time_reference: f32,
    bands: [dynamic]PhaseTrackerBand,
    samplerate: f32,

    // GL Shader
    shader: rl.Shader,

    // this is just a dummy texture to get the texture coordinates working right in the fragment shader
    texture: rl.Texture,

    // shader uniform locations
    color_a_loc: i32,
    color_b_loc: i32,
    time_stretch_loc: i32,
    phase_correction_loc: i32,
    phase_loc: i32,
    amp_loc: i32,
    norm_freq_loc: i32,
    win_size_loc: i32,

    band_width: i32,
    band_height: i32,
}


init_phase_tracker :: proc (base_freq_hz: f32, samplerate: f32, band_count: int) -> (self: PhaseTracker) {
    self.window_size = 4096
    self.overlap_size = 256
    self.band_width = 300
    self.band_height = 300

    rb, rb_data := init_ringbuffer(DEFAULT_RB_SIZE)
    self.ringbuffer = rb
    self.ringbuffer_data = rb_data
    self.sample_buffer = make([]f32, self.window_size)

    imgRed := rl.GenImageColor(self.band_width, self.band_height, rl.Color{ 255, 0, 0, 255 })
    self.texture = rl.LoadTextureFromImage(imgRed)
    rl.UnloadImage(imgRed)
    self.shader = rl.LoadShaderFromMemory(nil, FRAGMENT_SHADER)


    // Get uniform locations
    self.color_a_loc = rl.GetShaderLocation(self.shader, "colorA")
    self.color_b_loc = rl.GetShaderLocation(self.shader, "colorB")
    self.time_stretch_loc = rl.GetShaderLocation(self.shader, "timeStretch")
    self.phase_correction_loc = rl.GetShaderLocation(self.shader, "phaseCorrection")
    self.phase_loc = rl.GetShaderLocation(self.shader, "phase")
    self.amp_loc = rl.GetShaderLocation(self.shader, "amp")
    self.norm_freq_loc = rl.GetShaderLocation(self.shader, "normFreq")
    self.win_size_loc = rl.GetShaderLocation(self.shader, "winSize")


    for i in 0..<band_count {
        band := PhaseTrackerBand{}
        band.dft = init_dft(self.window_size)
        append(&self.bands, band)
    }



    set_phase_tracker_freq(&self, base_freq_hz)

    self.samplerate = samplerate
    self.stream_callback = phase_tracker_audio_callback
    return
}

destroy_phase_tracker :: proc(self: ^PhaseTracker) {
    delete(self.ringbuffer_data)
    delete(self.sample_buffer)
    rl.UnloadShader(self.shader)
    for &band in self.bands {
        destory_dft(&band.dft)
    }
    delete(self.bands)
}

set_phase_tracker_freq :: proc (self: ^PhaseTracker, base_freq_hz: f32) {
    self.phase_correction = 0.0
    flush_ringbuffer(&self.ringbuffer)
    multiplier := 1

    for &band, i in self.bands {
        freq_hz := f32(multiplier) * base_freq_hz
        band.freq_hz = freq_hz
        band.norm_freq = freq_hz / self.samplerate
        set_dft_freq(&band.dft, band.norm_freq )
        multiplier *= 2
    }
}


phase_tracker_audio_callback :: proc (ctx: ^AudioCaptureNode, input: []f32) {
    self := container_of(ctx, PhaseTracker, "node")

    out1, out2, num_written := get_ringbuffer_write_regions(&self.ringbuffer, len(input))

    if len(out1) > 0 do write_to_rb_region(out1, input[:len(out1)])
    if len(out2) > 0 do write_to_rb_region(out2, input[len(out1):])

    advance_ringbuffer_write(&self.ringbuffer, i32(num_written))
}

// TODO: filtering ??
@(private="file")
write_to_rb_region :: proc(output: []f32, input: []f32) {
    copy(output, input)
}


// -------------------------------------------------------------------------------------------------
//  Drawing methods
// -------------------------------------------------------------------------------------------------


draw_strobe_bands :: proc (self: ^PhaseTracker, rms_level: f32) {

    rl.DrawTextEx(font, "phase", {160, 30}, 14, 0, rl.GOLD)

    rl.SetShaderValue(self.shader, self.win_size_loc, &self.window_size,  rl.ShaderUniformDataType.INT)
    rl.SetShaderValue(self.shader, self.phase_correction_loc, &self.phase_correction,  rl.ShaderUniformDataType.FLOAT)


    for &band, band_idx in self.bands {

        order := len(self.bands) - 1 - band_idx

        // Draw frame
        rect := rl.Rectangle{
            160,
            f32(50 + (int(self.band_height) + 2) * order),
            f32(self.band_width),
            f32(self.band_height),
        }

        err_cents := freq_to_cents(band.estimated_freq_hz) - freq_to_cents(band.freq_hz)

        // Colors
        // hsv_a := rl.ColorToHSV(rl.Color{226, 101, 70, 255})
        // hsv_b := rl.ColorToHSV(rl.Color{84, 32, 43, 255})

        // saturation_a := math.min(rms_level * 100.0, hsv_a[1])
        // saturation_b := math.min(rms_level * 100.0, hsv_b[1])

        // value_a := math.min(rms_level * 100.0, hsv_a[2])
        // value_b := math.min(rms_level * 100.0, hsv_b[2])

        // color_a := rl.ColorNormalize(rl.ColorFromHSV(hsv_a[0], saturation_a, value_a))
        // color_b := rl.ColorNormalize(rl.ColorFromHSV(hsv_b[0], saturation_b, value_b))



        // color_a := rl.ColorNormalize(rl.Color{28, 118, 170, 255})
        // color_b := rl.ColorNormalize(rl.Color{132, 215, 255, 255})


        // RED SCHEME
        color_a := rl.ColorNormalize(rl.Color{226, 101, 70, 255})
        color_b := rl.ColorNormalize(rl.Color{84, 32, 43, 255})

        // BLUISH SCHEME
        // color_a := rl.ColorNormalize(rl.Color{107, 61, 125, 255})
        // color_b := rl.ColorNormalize(rl.Color{181, 242, 219, 255})


        // TODO: adjust hue based on cents offset
        // convert colors to HSV, move hue towards green based on error, 10 cents cutoff for full green?
        // rl.ColorToHSV()
        // if err_cents > -15 && err_cents < 15 {
        //     color_a = color_a_intune
        //     color_b = color_b_intune
        // }

        // dr := color_a.r - color_b.r
        // dg := color_a.g - color_b.g
        // db := color_a.b - color_b.b
        // base_color := color_b.rgb
        // color_delta := [3]f32{dr, dg, db}


        // rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.LIGHTGRAY)

        rl.SetShaderValue(self.shader, self.color_a_loc, raw_data(color_a[:]),  rl.ShaderUniformDataType.VEC3)
        rl.SetShaderValue(self.shader, self.color_b_loc, raw_data(color_b[:]),  rl.ShaderUniformDataType.VEC3)
        rl.SetShaderValue(self.shader, self.time_stretch_loc, &band.time_stretch,  rl.ShaderUniformDataType.FLOAT)
        rl.SetShaderValue(self.shader, self.phase_loc, &band.phase,  rl.ShaderUniformDataType.FLOAT)
        rl.SetShaderValue(self.shader, self.amp_loc, &band.amp,  rl.ShaderUniformDataType.FLOAT)
        rl.SetShaderValue(self.shader, self.norm_freq_loc, &band.norm_freq,  rl.ShaderUniformDataType.FLOAT)

        {
            rl.BeginShaderMode(self.shader)
            rl.DrawTextureV(self.texture, {rect.x, rect.y}, rl.WHITE);
            rl.EndShaderMode()
        }

        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.1fHz", band.estimated_freq_hz),
            {870, 60 + f32(self.band_height) * f32(order)},
            18,
            0,
            rl.GOLD
        )
        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.1fc", err_cents),
            {800, 90 + f32(self.band_height) * f32(order)},
            18,
            0,
            rl.GREEN
        )
    }
}

run_dft_analysis :: proc(self: ^PhaseTracker) {
    available := frames_available_in_ringbuffer(&self.ringbuffer)

    if available <= 0 do return

    reference_interval := self.samplerate / self.bands[0].freq_hz

    copy(self.sample_buffer, self.sample_buffer[available:self.window_size])
    offset := self.window_size - int(available)
    read_ringbuffer(&self.ringbuffer, self.sample_buffer[offset:], u32(available))


    // phase runaway compensation
    self.time_reference += f32(available)

    num_periods := self.time_reference / reference_interval
    self.phase_correction = math.ceil(num_periods) * reference_interval - self.time_reference

    for &band, band_idx in self.bands {
        normalized_freq:f32 = band.freq_hz / self.samplerate

        // Calculate DFT for this band
        dft := run_single_dft(&band.dft, self.sample_buffer[:self.window_size])

        cos := real(dft)
        sin := imag(dft)
        phase := math.atan2(sin, cos) // [-pi, pi]
        amp := magnitude(dft)

        // Calculate estimated frequency
        angle :=  phase - normalized_freq * math.TAU * self.phase_correction
        phase_diff := angle - band.angle
        band.angle = angle

        // Unwrap phase diff
        //  shifts the angles by adding multiples of ±2π until the jump is less than π
        for phase_diff >= math.PI {
            phase_diff -= math.TAU
        }

        for phase_diff <= -math.PI {
            phase_diff += math.TAU
        }

        time_delta := f32(available) / f32(self.samplerate)
        band.freq_diff_hz = -(phase_diff / time_delta) / math.TAU
        estimated_freq := band.freq_hz + band.freq_diff_hz
        band.estimated_freq_hz = estimated_freq

        time_stretch_factor := 4.0 * reference_interval/ f32(self.window_size)
        // gain: f32 = 1.0 // (amp + 0.1)

        // TODO can I fade out the band when the freq difference is significant
        // if band.freq_diff_hz > 15.0 || band.freq_diff_hz < -15.0 do gain = 1.0

        // Generate a (synthetic strobe) sinusoid based on detected phase & amplitude
        band.time_stretch = time_stretch_factor
        band.phase = phase
        band.amp = amp
    }
}

draw_phase_tracker_display :: proc(self: ^PhaseTracker, rms_level: f32) {
    run_dft_analysis(self)
    draw_strobe_bands(self, rms_level)
}


