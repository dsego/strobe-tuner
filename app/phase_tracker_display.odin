package app

import "core:fmt"
import "core:math"
import "core:path/filepath"
import rl "vendor:raylib"

import "../shared"


PhaseTrackerDisplay :: struct {
    // GL Shader
    shader:               rl.Shader,

    // this is just a dummy texture to get the texture coordinates working right in the fragment shader
    texture:              rl.Texture,
    texture_width:        i32,
    texture_height:       i32,

    // shader uniform locations
    color_a_loc:          i32,
    color_b_loc:          i32,
    time_stretch_loc:     i32,
    phase_correction_loc: i32,
    phase_loc:            i32,
    amp_loc:              i32,
    norm_freq_loc:        i32,
    bounding_rect_loc:    i32,
    curvature_radius_loc: i32,
    band_height_loc:      i32,
}


init_phase_tracker_display :: proc() -> (self: PhaseTrackerDisplay) {
    self.texture_width = 400
    self.texture_height = 410

    imgRed := rl.GenImageColor(self.texture_width, self.texture_height, rl.Color{255, 0, 0, 255})
    self.texture = rl.LoadTextureFromImage(imgRed)
    rl.UnloadImage(imgRed)


    // File path relative to our current odin file
    frag_shader_path := filepath.join({filepath.dir(#file), "./shader.frag"})
    self.shader = rl.LoadShader(nil, fmt.ctprintf("%v", frag_shader_path))

    // Get uniform locations
    self.color_a_loc = rl.GetShaderLocation(self.shader, "colorA")
    self.color_b_loc = rl.GetShaderLocation(self.shader, "colorB")
    self.time_stretch_loc = rl.GetShaderLocation(self.shader, "timeStretch")
    self.phase_correction_loc = rl.GetShaderLocation(self.shader, "phaseCorrection")
    self.phase_loc = rl.GetShaderLocation(self.shader, "phase")
    self.amp_loc = rl.GetShaderLocation(self.shader, "amp")
    self.norm_freq_loc = rl.GetShaderLocation(self.shader, "normFreq")
    self.bounding_rect_loc = rl.GetShaderLocation(self.shader, "boundingRect")
    self.curvature_radius_loc = rl.GetShaderLocation(self.shader, "curvatureRadius")
    self.band_height_loc = rl.GetShaderLocation(self.shader, "bandHeight")

    return
}

destroy_phase_tracker_display :: proc(self: ^PhaseTrackerDisplay) {
    rl.UnloadShader(self.shader)
}


// TODO: param to define what style of strobe to display (strobe_style) - curved track or full wheels
draw_phase_tracker_display :: proc(self: ^PhaseTrackerDisplay, phase_info: ^shared.PhaseTracker) {

    rl.DrawTextEx(font, "phase", {160, 30}, 14, 0, rl.GOLD)

    // Full circles
    curvature_radius: f32 = 100.0
    band_height: f32 = 26.0
    period_count: f32 = 4.0 // how many strobe periods to fit in a circle

    // Curved tracks
    if true {
        curvature_radius = 1000.0
        band_height = 66.0
        period_count = 24.0
    }

    // RED SCHEME
    // color_a := rl.ColorNormalize(rl.Color{248, 120, 85, 255})
    // color_b := rl.ColorNormalize(rl.Color{88, 27, 26, 255})

    color_a := rl.ColorNormalize(rl.Color{226, 101, 70, 255})
    color_b := rl.ColorNormalize(rl.Color{84, 32, 43, 255})

    rl.SetShaderValue(
        self.shader,
        self.phase_correction_loc,
        &phase_info.phase_correction,
        rl.ShaderUniformDataType.FLOAT,
    )
    rl.SetShaderValue(
        self.shader,
        self.band_height_loc,
        &band_height,
        rl.ShaderUniformDataType.FLOAT,
    )

    rl.SetShaderValue(
        self.shader,
        self.color_a_loc,
        raw_data(color_a[:]),
        rl.ShaderUniformDataType.VEC3,
    )
    rl.SetShaderValue(
        self.shader,
        self.color_b_loc,
        raw_data(color_b[:]),
        rl.ShaderUniformDataType.VEC3,
    )

    // Draw circular bands from the center outwards, so the lowest frequency is the bottom one
    for &band, band_idx in phase_info.bands {

        // if band_idx > 0 do break

        order := len(phase_info.bands) - 1 - band_idx

        rect := rl.Rectangle {
            160,
            50.0 + band_height * f32(order),
            f32(self.texture_width),
            f32(self.texture_height),
        }

        err_cents :=
            shared.freq_to_cents(band.estimated_freq_hz) - shared.freq_to_cents(band.freq_hz)


        bounding_rect := [4]f32{rect.x, rect.y, rect.width, rect.height}

        // rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

        // Note, for concentric circles the radius needs to expand as the bands move from the bottom up
        {
            rl.SetShaderValue(
                self.shader,
                self.curvature_radius_loc,
                &curvature_radius,
                rl.ShaderUniformDataType.FLOAT,
            )
            curvature_radius += band_height
        }

        rl.SetShaderValue(
            self.shader,
            self.bounding_rect_loc,
            &bounding_rect,
            rl.ShaderUniformDataType.VEC4,
        )

        time_stretch := band.time_stretch * period_count
        rl.SetShaderValue(
            self.shader,
            self.time_stretch_loc,
            &time_stretch,
            rl.ShaderUniformDataType.FLOAT,
        )

        rl.SetShaderValue(self.shader, self.phase_loc, &band.phase, rl.ShaderUniformDataType.FLOAT)
        rl.SetShaderValue(self.shader, self.amp_loc, &band.amp, rl.ShaderUniformDataType.FLOAT)
        rl.SetShaderValue(
            self.shader,
            self.norm_freq_loc,
            &band.norm_freq,
            rl.ShaderUniformDataType.FLOAT,
        )

        {
            rl.BeginShaderMode(self.shader)
            rl.DrawTextureV(self.texture, {rect.x, rect.y}, rl.WHITE)
            rl.EndShaderMode()
        }

        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.1fHz", band.estimated_freq_hz),
            {570, 100 + f32(band_height) * f32(order)},
            18,
            0,
            rl.GOLD,
        )
        rl.DrawTextEx(
            font,
            fmt.ctprintf("%+.1fc", err_cents),
            {570, 120 + f32(band_height) * f32(order)},
            18,
            0,
            rl.GREEN,
        )


    }
}
