package app

import "core:fmt"
import rl "vendor:raylib"

import "../shared"


PhaseTrackerDisplay :: struct {

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


init_phase_tracker_display :: proc () -> (self: PhaseTrackerDisplay) {
    self.band_width = 300
    self.band_height = 300

    imgRed := rl.GenImageColor(self.band_width, self.band_height, rl.Color{ 255, 0, 0, 255 })
    self.texture = rl.LoadTextureFromImage(imgRed)
    rl.UnloadImage(imgRed)
    self.shader = rl.LoadShaderFromMemory(nil, FRAGMENT_SHADER_CURVED_TRACK)

    // Get uniform locations
    self.color_a_loc = rl.GetShaderLocation(self.shader, "colorA")
    self.color_b_loc = rl.GetShaderLocation(self.shader, "colorB")
    self.time_stretch_loc = rl.GetShaderLocation(self.shader, "timeStretch")
    self.phase_correction_loc = rl.GetShaderLocation(self.shader, "phaseCorrection")
    self.phase_loc = rl.GetShaderLocation(self.shader, "phase")
    self.amp_loc = rl.GetShaderLocation(self.shader, "amp")
    self.norm_freq_loc = rl.GetShaderLocation(self.shader, "normFreq")
    self.win_size_loc = rl.GetShaderLocation(self.shader, "winSize")

    return
}

destroy_phase_tracker_display :: proc (self: ^PhaseTrackerDisplay) {
    rl.UnloadShader(self.shader)
}


draw_phase_tracker_display :: proc(self: ^PhaseTrackerDisplay, phase_info: ^shared.PhaseTracker) {

    rl.DrawTextEx(font, "phase", {160, 30}, 14, 0, rl.GOLD)

    rl.SetShaderValue(self.shader, self.win_size_loc, &phase_info.window_size,  rl.ShaderUniformDataType.INT)
    rl.SetShaderValue(self.shader, self.phase_correction_loc, &phase_info.phase_correction,  rl.ShaderUniformDataType.FLOAT)


    for &band, band_idx in phase_info.bands {

        order := len(phase_info.bands) - 1 - band_idx

        // rect := rl.Rectangle{
        //     160,
        //     f32(50 + (int(self.band_height) + 2) * order),
        //     f32(self.band_width),
        //     f32(self.band_height),
        // }

        rect := rl.Rectangle{
            160,
            f32(50 + 60 * order),
            f32(self.band_width),
            f32(self.band_height),
        }

        err_cents := shared.freq_to_cents(band.estimated_freq_hz) - shared.freq_to_cents(band.freq_hz)

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


        // DEBUG FRAME
        // rl.DrawRectangleLinesEx({rect.x-1, rect.y-1, rect.width+2, rect.height+2}, 1.0, rl.ORANGE)

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

