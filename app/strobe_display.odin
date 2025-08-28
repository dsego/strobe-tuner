// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package app

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import rl "vendor:raylib"

import "../core"

shadow_data := #load("../assets/images/shadow.2x.png")

StrobeDisplay :: struct {
    // GL Shader
    strobe_shader:         rl.Shader,
    inner_shadow_shader:   rl.Shader,

    // this is just a dummy texture to get the texture coordinates working right in the fragment shader
    texture:               rl.Texture,
    shadow_tex:            rl.Texture,
    texture_width:         i32,
    texture_height:        i32,
    position:              [2]f32,
    colors:                [2]rl.Color,
    background:            rl.Color,
    contrast:              f32,

    // strobe shader uniform locations
    color_a_loc:           i32,
    color_b_loc:           i32,
    time_stretch_loc:      i32,
    period_count_loc:      i32,
    phase_loc:             i32,
    amp_loc:               i32,
    norm_freq_loc:         i32,
    bounding_rect_loc:     i32,
    curvature_radius_loc:  i32,
    min_radius_loc:        i32,
    max_radius_loc:        i32,
    band_height_loc:       i32,
    err_cents_loc:         i32,
    strobe_blur_loc:       i32,
    display_type:          StrobeDisplayType,

    // shadow shader uniform locations
    shadow_dimensions_loc: i32,
    auto_gain_active:      [core.MAX_BANDS]bool,
    auto_gain:             [core.MAX_BANDS]f32,
}


init_strobe_display :: proc(
    position: [2]f32,
    size: [2]i32,
    colors: [2]u32,
    background: u32,
    contrast: f32,
    display_type: StrobeDisplayType,
) -> (
    self: StrobeDisplay,
) {
    for i in 0 ..< len(self.auto_gain) {
        self.auto_gain[i] = 1.0
    }
    self.texture_width = i32(size.x)
    self.texture_height = i32(size.y)
    self.position = position
    self.colors = {rl.GetColor(colors.x), rl.GetColor(colors.y)}
    self.background = rl.GetColor(background)
    self.contrast = contrast

    // We need this to draw the fragment shader
    texture_image := rl.GenImageColor(
        self.texture_width,
        self.texture_height,
        rl.Color{255, 0, 0, 255},
    )
    self.texture = rl.LoadTextureFromImage(texture_image)
    rl.UnloadImage(texture_image)


    // File path relative to our current odin file
    dir := filepath.dir(#file)
    defer delete(dir)

    {
        frag_shader_data := #load("../shaders/strobe-shader.frag")
        self.strobe_shader = rl.LoadShaderFromMemory(nil, cstring(&frag_shader_data[0]))
    }

    // Get uniform locations
    self.color_a_loc = rl.GetShaderLocation(self.strobe_shader, "color_a")
    self.color_b_loc = rl.GetShaderLocation(self.strobe_shader, "color_b")
    self.time_stretch_loc = rl.GetShaderLocation(self.strobe_shader, "time_stretch")
    self.phase_loc = rl.GetShaderLocation(self.strobe_shader, "phase")
    self.amp_loc = rl.GetShaderLocation(self.strobe_shader, "amp")
    self.norm_freq_loc = rl.GetShaderLocation(self.strobe_shader, "norm_freq")
    self.bounding_rect_loc = rl.GetShaderLocation(self.strobe_shader, "bounding_rect")
    self.curvature_radius_loc = rl.GetShaderLocation(self.strobe_shader, "curvature_radius")
    self.band_height_loc = rl.GetShaderLocation(self.strobe_shader, "band_height")
    self.err_cents_loc = rl.GetShaderLocation(self.strobe_shader, "err_cents")
    self.period_count_loc = rl.GetShaderLocation(self.strobe_shader, "period_count")
    self.min_radius_loc = rl.GetShaderLocation(self.strobe_shader, "min_radius")
    self.max_radius_loc = rl.GetShaderLocation(self.strobe_shader, "max_radius")
    self.strobe_blur_loc = rl.GetShaderLocation(self.strobe_shader, "strobe_blur")
    self.display_type = display_type

    // Load shadow texture
    {
        image := rl.LoadImageFromMemory(".png", raw_data(shadow_data), i32(len(shadow_data)))
        defer rl.UnloadImage(image)
        self.shadow_tex = rl.LoadTextureFromImage(image)
    }

    return
}

setup_strobe_display :: proc(
    self: ^StrobeDisplay,
    contrast: f32,
    display_type: StrobeDisplayType,
) {
    self.contrast = contrast
    self.display_type = display_type
}

destroy_strobe_display :: proc(self: ^StrobeDisplay) {
    rl.UnloadShader(self.strobe_shader)
    rl.UnloadShader(self.inner_shadow_shader)
    rl.UnloadTexture(self.texture)
    rl.UnloadTexture(self.shadow_tex)
}

set_display_type :: proc(self: ^StrobeDisplay, display_type: StrobeDisplayType) {
    self.display_type = display_type
}

set_strobe_colors :: proc(self: ^StrobeDisplay, colors: [2]u32) {
    self.colors = {rl.GetColor(colors.x), rl.GetColor(colors.y)}
}

draw_strobe_display :: proc(
    self: ^StrobeDisplay,
    phase_info: ^core.PhaseComparator,
    out_of_range: bool,
    config: ^Config,
) {

    curvature_radius: f32
    band_height: f32
    period_count: f32


    switch self.display_type {
    case .SPINNING_WHEEL:
        curvature_radius = 90.0
        band_height = 26.0
        period_count = 4.0 // how many strobe periods to fit in a circle
    case .CURVED_TRACKS:
        curvature_radius = 440.0
        band_height = 66.0
        if len(phase_info.bands) > 3 {
            band_height = 50.0
        }
        period_count = 12.0
    }

    rl.BeginScissorMode(0, 0, 488, 306)
    defer rl.EndScissorMode()

    rl.DrawRectangleV(self.position, {f32(self.texture_width), 306.0}, self.background)

    rl.SetShaderValue(
        self.strobe_shader,
        self.band_height_loc,
        &band_height,
        rl.ShaderUniformDataType.FLOAT,
    )
    strobe_blur := int(config.strobe_blur)
    rl.SetShaderValue(
        self.strobe_shader,
        self.strobe_blur_loc,
        &strobe_blur,
        rl.ShaderUniformDataType.INT,
    )

    n_color_a := rl.ColorNormalize(self.colors.x)
    rl.SetShaderValue(
        self.strobe_shader,
        self.color_a_loc,
        raw_data(n_color_a[:]),
        rl.ShaderUniformDataType.VEC3,
    )

    n_color_b := rl.ColorNormalize(self.colors.y)
    rl.SetShaderValue(
        self.strobe_shader,
        self.color_b_loc,
        raw_data(n_color_b[:]),
        rl.ShaderUniformDataType.VEC3,
    )

    // most inner radius
    min_radius := curvature_radius - band_height

    // most outer radius
    max_radius := curvature_radius + band_height * f32(len(phase_info.bands) - 1)

    rl.SetShaderValue(
        self.strobe_shader,
        self.min_radius_loc,
        &min_radius,
        rl.ShaderUniformDataType.FLOAT,
    )

    rl.SetShaderValue(
        self.strobe_shader,
        self.max_radius_loc,
        &max_radius,
        rl.ShaderUniformDataType.FLOAT,
    )

    y := self.position.y
    if self.display_type == .CURVED_TRACKS {
        y += 32
    }

    // Draw circular bands from the center outwards, so the lowest frequency is the bottom one
    for &band, band_idx in phase_info.bands {
        order := len(phase_info.bands) - 1 - band_idx

        rect := rl.Rectangle {
            self.position.x,
            y + band_height * f32(order),
            f32(self.texture_width),
            f32(self.texture_height),
        }

        bounding_rect := [4]f32{rect.x, rect.y, rect.width, rect.height}

        // rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

        // Note, for concentric circles the radius needs to expand as the bands move from the bottom up
        rl.SetShaderValue(
            self.strobe_shader,
            self.curvature_radius_loc,
            &curvature_radius,
            rl.ShaderUniformDataType.FLOAT,
        )
        curvature_radius += band_height

        rl.SetShaderValue(
            self.strobe_shader,
            self.bounding_rect_loc,
            &bounding_rect,
            rl.ShaderUniformDataType.VEC4,
        )

        rl.SetShaderValue(
            self.strobe_shader,
            self.period_count_loc,
            &period_count,
            rl.ShaderUniformDataType.FLOAT,
        )

        rl.SetShaderValue(
            self.strobe_shader,
            self.time_stretch_loc,
            &band.time_stretch,
            rl.ShaderUniformDataType.FLOAT,
        )

        rl.SetShaderValue(
            self.strobe_shader,
            self.phase_loc,
            // &band.dummy_phase if out_of_range else &band.scaled_phase,
            &band.scaled_phase,
            rl.ShaderUniformDataType.FLOAT,
        )

        amp := self.contrast * band.amp

        self.auto_gain_active[band_idx] = core.schmitt_trigger(
            self.auto_gain_active[band_idx],
            band.snr_db,
            config.auto_gain_snr_db_low,
            config.auto_gain_snr_db_high,
        )
        if self.auto_gain_active[band_idx] {
            self.auto_gain[band_idx] = clamp(1.0 / band.amp, 0, config.max_auto_gain)
        } else {
            // Slowly release gain with exponential decay
            self.auto_gain[band_idx] +=
                config.gain_release_coefficient * (1.0 - self.auto_gain[band_idx])
        }

        if config.auto_gain_control {
            amp *= self.auto_gain[band_idx]
        }

        // limit max amp to avoid jagged edges in the strobe display
        amp = clamp(amp, 0.0, 50.0)

        attenuation: f32 = 0.0

        // fade out if the spinning is too rapid
        if config.apply_attenuation && config.strobe_mode == .VERNIER_MODE {
            // TBD: if these need to be tweaked some more
            attenuation = linalg.smoothstep(
                f32(0.04),
                f32(0.005),
                math.abs(band.phase_diff * band.speed),
            )
            amp *= attenuation
        }

        rl.SetShaderValue(self.strobe_shader, self.amp_loc, &amp, rl.ShaderUniformDataType.FLOAT)

        rl.SetShaderValue(
            self.strobe_shader,
            self.norm_freq_loc,
            &band.norm_freq,
            rl.ShaderUniformDataType.FLOAT,
        )

        rl.SetShaderValue(
            self.strobe_shader,
            self.err_cents_loc,
            &band.err_cents,
            rl.ShaderUniformDataType.FLOAT,
        )

        // Draw
        {
            rl.BeginShaderMode(self.strobe_shader)
            rl.DrawTextureV(self.texture, {rect.x, rect.y + 10}, rl.WHITE)
            rl.EndShaderMode()
        }

        if phase_info.mode == .VERNIER_MODE {
            period_count *= 2.0
        }
    }

    // Draw labels for partials
    if config.strobe_mode == .HARMONIC_MODE &&
       self.display_type == .CURVED_TRACKS &&
       config.partial_labels != .NONE {
        r := min_radius

        for &band, band_idx in phase_info.bands {
            order := len(phase_info.bands) - 1 - band_idx
            cos: f32 = 216
            r += band_height
            sin := math.sqrt(r * r - cos * cos)

            if config.show_band_cents {
                // Cents offset
                rl.DrawTextEx(
                    font_store.medium_32,
                    fmt.ctprintf("%.4f", band.err_cents),
                    {self.position.x + 16, y + band_height * (f32(order) + 0.6) + r - sin},
                    16,
                    0,
                    rl.GetColor(0x82E2FFFF),
                )
            }

            // Partial order, e.g. 1x, 2x, etc
            partial_labels, changed := gui_strobe_partial(
                {self.position.x + 260 + cos, y + band_height * (f32(order) + 0.6) + r - sin},
                config.partial_labels,
                band,
            )
            if changed {
                config.partial_labels = partial_labels
            }
        }
    }

    rl.DrawTexturePro(
        self.shadow_tex,
        rl.Rectangle{0, 0, f32(self.shadow_tex.width), f32(self.shadow_tex.height)},
        rl.Rectangle{0, -20, 488, 328},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )

    // rl.DrawTexture(self.shadow_tex, rl.Vector2{0, 0}, 0, 0.5, rl.WHITE)
    // rl.DrawRectangleLinesEx({0, 0, 488, 308}, 1, rl.ORANGE)

    // rl.BeginShaderMode(self.inner_shadow_shader)
    // rl.DrawTextureV(self.texture, {self.position.x, self.position.y}, rl.WHITE)
    // rl.EndShaderMode()
}
