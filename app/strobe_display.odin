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

import "../core"

// Bloom for the strobe glow, rendered at a fraction of the strobe size since it gets blurred anyway
BLOOM_DOWNSCALE :: 2
BLOOM_TAP_SPACING :: 1.5 // blur taps spaced apart for a wider glow at the same cost
BLOOM_ITERATIONS :: 2
BLOOM_STRENGTH :: 0.2

StrobeDisplay :: struct {
    strobe_shader:   Shader,
    bloom_shader:    Shader,
    shadow_shader:   Shader,
    colors:          [2]Color,
    background:      Color,

    // bloom for the strobe glow, the strobe is rendered into scene_rt and blurred through bloom_rt
    scene_rt:        RenderTarget,
    bloom_rt:        [2]RenderTarget,
    glow_scale:      f32, // DPI scale the render targets were created for
    glow_size:       [2]f32, // and the strobe size in points

    // per band stripe sharpness and visibility, smoothed so they don't flicker, see update_band_look
    band_amp:        [core.MAX_BANDS]f32,
    band_visibility: [core.MAX_BANDS]f32,
    // and of the scope's beam, see draw_scope_display
    scope_visibility: f32,
    // the tracks turned by the lamp, see lamp_comparator: each one's phase on the screen at the previous
    // frame, at this reference and this sample, and the phase it turned to
    lamp_phases:        [core.MAX_BANDS]f64,
    lamp_freq_hz:       f64,
    lamp_clock:         i64,
    lamp_scaled_phases: [core.MAX_BANDS]f32,

    // The track whose sheet is open, outlined while the others dim. selection fades it in and out with
    // the sheet, 0 is no selection.
    selected_track:  int,
    selection:       f32,
}

// Where the tracks go in the strobe, the drawing and strobe_track_at share it
StrobeGeometry :: struct {
    y:                f32, // top of the outermost track
    curvature_radius: f32, // outer radius of the innermost track, each track further out is a band_height larger
    band_height:      f32,
    period_count:     f32, // how many strobe periods fit in a circle
    density:          f32, // period_count is this many times the desktop's, see strobe_density
    // The tracks straightened, stacked from y down, see strobe_geometry
    flat:             bool,
}

// The desktop tracks' circle and how much of it shows across the window
DESKTOP_TRACKS_RADIUS :: 440.0
DESKTOP_TRACKS_PERIODS :: 12.0

// A phone's strobe is scaled up and narrower, it shows a thinner slice of a larger circle and only a
// stripe or two of the desktop's pattern. The periods are packed tighter to show as many across as the
// desktop, a whole number of them so the circle stays seamless, and never fewer than the desktop's.
strobe_density :: proc(half_width, radius: f32) -> f32 {
    visible_angle :: proc(half_width, radius: f32) -> f32 {
        return math.asin(min(half_width / radius, 1))
    }
    desktop := visible_angle(STROBE_WIDTH / 2, DESKTOP_TRACKS_RADIUS)
    periods := math.round(DESKTOP_TRACKS_PERIODS * desktop / visible_angle(half_width, radius))
    return max(periods, DESKTOP_TRACKS_PERIODS) / DESKTOP_TRACKS_PERIODS
}

// The tracks are laid out for the desktop size and scaled by scale, then aligned to the bottom of rect,
// a taller rect only extends the background upwards (e.g. behind the notch).
// Flat tracks fill the strobe, each is the top of a curved track's arc, with the stripes as wide.
strobe_geometry :: proc(shape: StrobeShape, rect: Rect, scale: f32, band_count: int) -> (geometry: StrobeGeometry) {
    switch shape {
    case .WHEEL:
        geometry.curvature_radius = 90.0
        geometry.band_height = 26.0
        geometry.period_count = 4.0
    case .CURVED, .FLAT:
        geometry.curvature_radius = DESKTOP_TRACKS_RADIUS
        geometry.band_height = 66.0
        if band_count > 3 {
            geometry.band_height = 50.0
        }
        geometry.period_count = DESKTOP_TRACKS_PERIODS
    }
    geometry.curvature_radius *= scale
    geometry.band_height *= scale

    geometry.density = 1
    if shape != .WHEEL {
        geometry.density = strobe_density(rect.width / 2, geometry.curvature_radius)
        geometry.period_count *= geometry.density
    }

    geometry.y = rect.y + rect.height - scale * STROBE_HEIGHT
    switch shape {
    case .CURVED:
        geometry.y += 32 * scale
    case .FLAT:
        geometry.flat = true
        geometry.band_height = scale * STROBE_HEIGHT / f32(max(band_count, 1))
    case .WHEEL:
    }
    return
}

// The track under point, -1 for none. The tracks are concentric, the gap outside a track counts as part
// of it, so the whole ring from one track to the next is its touch area. Flat ones are stacked.
strobe_track_at :: proc(shape: StrobeShape, rect: Rect, scale: f32, band_count: int, point: [2]f32) -> int {
    geometry := strobe_geometry(shape, rect, scale, band_count)
    if !point_in_rect(point, rect) do return -1

    if geometry.flat {
        // The first track is the bottom one
        order := int(math.floor((point.y - geometry.y) / geometry.band_height))
        if order < 0 || order >= band_count do return -1
        return band_count - 1 - order
    }

    // The centre of the circles, see draw_strobe_bands and the strobe shader
    outer_radius := geometry.curvature_radius + geometry.band_height * f32(band_count - 1)
    center := [2]f32{rect.x + rect.width / 2, geometry.y + 10 + outer_radius}
    distance := linalg.length(point - center)

    track := int(math.ceil((distance - geometry.curvature_radius) / geometry.band_height))
    if track < 0 || track >= band_count do return -1
    return track
}


init_strobe_display :: proc(colors: [2]u32, background: u32) -> (self: StrobeDisplay) {
    self.colors = {hex(colors.x), hex(colors.y)}
    self.background = hex(background)

    self.strobe_shader = gfx_load_shader(.STROBE)
    self.bloom_shader = gfx_load_shader(.BLOOM)
    self.shadow_shader = gfx_load_shader(.SHADOW)

    return
}

destroy_strobe_display :: proc(self: ^StrobeDisplay) {
    gfx_unload_shader(self.strobe_shader)
    gfx_unload_shader(self.bloom_shader)
    gfx_unload_shader(self.shadow_shader)
    unload_glow_targets(self)
}

unload_glow_targets :: proc(self: ^StrobeDisplay) {
    if self.glow_scale == 0 do return
    gfx_unload_render_target(self.scene_rt)
    for rt in self.bloom_rt {
        gfx_unload_render_target(rt)
    }
    self.glow_scale = 0
}

// (Re)create the glow render targets, the scene is rendered at the display's DPI scale to stay sharp
ensure_glow_targets :: proc(self: ^StrobeDisplay, size: [2]f32) {
    scale := gfx_dpi_scale()
    if scale == self.glow_scale && size == self.glow_size do return

    unload_glow_targets(self)

    self.scene_rt = gfx_load_render_target(i32(size.x * scale), i32(size.y * scale))
    for &rt in self.bloom_rt {
        rt = gfx_load_render_target(i32(size.x / BLOOM_DOWNSCALE), i32(size.y / BLOOM_DOWNSCALE))
    }
    self.glow_scale = scale
    self.glow_size = size
}

// Separable gaussian blur, ping-pongs between the two targets and ends up in rts[0]
blur_render_targets :: proc(
    self: ^StrobeDisplay,
    rts: [2]RenderTarget,
    iterations: int,
    tap_spacing: f32,
) {
    size := render_target_size(rts[0])
    dest := Rect{0, 0, size.x, size.y}

    uniforms := BloomUniforms {
        mode = 1,
    }
    for _ in 0 ..< iterations {
        uniforms.texel_step = {tap_spacing / size.x, 0}
        set_shader_uniforms(self.bloom_shader, &uniforms)
        begin_render_target(rts[1], {})
        draw_render_target(rts[0], dest)
        end_render_target()

        uniforms.texel_step = {0, tap_spacing / size.y}
        set_shader_uniforms(self.bloom_shader, &uniforms)
        begin_render_target(rts[0], {})
        draw_render_target(rts[1], dest)
        end_render_target()
    }
}

// The filter the lamp shines through, the hue scaled up to full brightness and squared to saturate it
// (FF6767 -> 1.0, 0.16, 0.16). The same for the whole strobe, so the shader gets it ready made.
glow_filter :: proc(color: u32) -> [3]f32 {
    rgb := normalize_color(hex(color)).rgb
    filter := rgb / max(rgb.r, rgb.g, rgb.b, 0.001)
    return filter * filter
}

// Lift the background a little, as if some lamp light scatters behind the whole disc.
// Based on the darkest stripe, the dark stripes of the outer band away from the hotspot,
// mirrors the light model in the strobe shader.
glow_background :: proc(background: Color, glow: GlowParams) -> Color {
    DARK_TRANSMISSION :: 0.3
    MIN_LAMP :: 0.6
    BACKGROUND_LIFT :: 0.25

    filter := glow_filter(glow.dark_color) * glow.dark_level

    darkest: [3]f32
    for channel, i in filter {
        darkest[i] = 1 - math.exp(-DARK_TRANSMISSION * MIN_LAMP * glow.exposure * channel)
    }

    luma := darkest.r * 0.299 + darkest.g * 0.587 + darkest.b * 0.114
    darkest = linalg.lerp([3]f32{luma, luma, luma}, darkest, glow.saturation)

    base := normalize_color(background).rgb
    lifted := linalg.min(base + BACKGROUND_LIFT * darkest, 1)
    return color_from_normalized({lifted.r, lifted.g, lifted.b, 1})
}

render_bloom :: proc(self: ^StrobeDisplay) {
    set_blend_mode(.REPLACE)
    defer set_blend_mode(.ALPHA)
    begin_shader(self.bloom_shader)
    defer end_shader()

    // Downsample and keep the bright parts
    scene_size := render_target_size(self.scene_rt)
    uniforms := BloomUniforms {
        mode       = 0,
        texel_step = 1.0 / scene_size,
    }
    set_shader_uniforms(self.bloom_shader, &uniforms)
    bloom_size := render_target_size(self.bloom_rt[0])
    begin_render_target(self.bloom_rt[0], {})
    draw_render_target(self.scene_rt, {0, 0, bloom_size.x, bloom_size.y})
    end_render_target()

    blur_render_targets(self, self.bloom_rt, BLOOM_ITERATIONS, BLOOM_TAP_SPACING)
}

set_strobe_colors :: proc(self: ^StrobeDisplay, colors: [2]u32) {
    self.colors = {hex(colors.x), hex(colors.y)}
}

// See strobe_geometry for the layout
draw_strobe_display :: proc(
    self: ^StrobeDisplay,
    rect: Rect,
    scale: f32,
    comparator: ^core.PhaseComparator,
    config: ^Config,
) {
    shape := config.strobe_shape
    geometry := strobe_geometry(shape, rect, scale, len(comparator.bands))
    band_height := geometry.band_height

    glow_enabled := config.strobe_glow
    glow := glow_params(config)

    // Shared by all bands, draw_strobe_bands fills in the rest
    uniforms := StrobeUniforms {
        band_height     = band_height,
        strobe_blur     = i32(config.strobe_blur),
        motion_blur     = i32(config.motion_blur),
        glow            = i32(glow_enabled),
        flat_track      = i32(geometry.flat),
        // The wheel is lit evenly all around, the tracks only show the top of the disc
        lamp_spread     = 1000.0 if shape == .WHEEL else 0.45,
        glow_exposure   = glow.exposure,
        glow_saturation = glow.saturation,
        color_a         = normalize_color(self.colors.x),
        color_b         = normalize_color(self.colors.y),
        // The inner edge of the innermost track and the outer edge of the outermost
        min_radius      = geometry.curvature_radius - band_height,
        max_radius      = geometry.curvature_radius + band_height * f32(len(comparator.bands) - 1),
    }
    uniforms.glow_filter.rgb = glow_filter(glow.color)
    uniforms.glow_dark_filter.rgb = glow_filter(glow.dark_color) * glow.dark_level
    uniforms.highlight_color = normalize_color(accent_color)

    if glow_enabled {
        // Render the strobe offscreen so the bright parts can bloom over the surroundings
        ensure_glow_targets(self, {rect.width, rect.height})

        begin_render_target(
            self.scene_rt,
            glow_background(self.background, glow),
            {rect.x, rect.y},
            self.glow_scale,
        )
        draw_strobe_bands(self, rect, comparator, &uniforms, geometry)
        end_render_target()

        render_bloom(self)
    }

    begin_scissor(rect)
    defer end_scissor()

    if glow_enabled {
        set_blend_mode(.REPLACE)
        draw_render_target(self.scene_rt, rect)

        // Add the bloom on top, the light spills into the gaps and the dark background
        set_blend_mode(.ADD)
        strength := u8(BLOOM_STRENGTH * 255)
        draw_render_target(self.bloom_rt[0], rect, {strength, strength, strength, 255})
        set_blend_mode(.ALPHA)
    } else {
        draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)
        draw_strobe_bands(self, rect, comparator, &uniforms, geometry)
    }

    // The partial of each track, e.g. 1×, 2×: on the right, on the curve of a curved track a little in from
    // the edge or in the middle of a flat one, and on the top of a wheel's ring, where the ring runs level
    // and the labels of the rings stack in a column
    if config.strobe_mode == .HARMONIC && config.partial_labels != .NONE {
        // The wheel's centre, see draw_strobe_bands and the strobe shader
        center := [2]f32 {
            rect.x + 0.5 * rect.width,
            geometry.y + 10 + geometry.curvature_radius + band_height * f32(len(comparator.bands) - 1),
        }
        middle := 0.5 * (band_height - 4) - 0.5 * pixel_fonts.band_label.size

        radius := uniforms.min_radius
        for &band, band_index in comparator.bands {
            order := len(comparator.bands) - 1 - band_index
            radius += band_height

            label_y: f32
            on_ring: [2]f32 // a wheel's, the middle of the label
            switch shape {
            case .CURVED:
                // From the centre of the circles across to the label, and up to the track there
                across := 0.5 * rect.width - 28
                up := math.sqrt(radius * radius - across * across)
                label_y = geometry.y + band_height * (f32(order) + 0.6) + radius - up
            case .FLAT:
                label_y = geometry.y + band_height * f32(order) + middle
            case .WHEEL:
                ring_middle := radius - 0.5 * (band_height - 4)
                on_ring = {center.x, center.y - ring_middle}
                label_y = on_ring.y - 0.5 * pixel_fonts.band_label.size
            }

            // Hidden, too high for the sample rate
            if !band.in_range do continue

            // How far off this partial is, nothing while it's too quiet to measure. Right aligned on the
            // decimal point like the readout, the digits don't shift as the value changes.
            if config.show_band_cents && band.snr_db > band.noise_floor.snr_threshold_db {
                font := pixel_fonts.band_label
                right := rect.x + 16 + measure_label(font, "-00.0").x
                text := fmt.ctprintf("%+.1f", band.err_cents)
                draw_text_right(font.font, text, {right, label_y}, font.size, 0, accent_color)
            }

            if shape == .WHEEL do draw_strobe_partial(on_ring, config.partial_labels, band, centered = true)
            else do draw_strobe_partial({rect.x + rect.width - 12, label_y}, config.partial_labels, band)
        }
    }

    draw_strobe_shadow(self, rect)
}

// The shadow's rounded rectangle is on the strobe's sides and a little past its top and bottom, so those
// are a little less dark. The shade reaches 2 points under the strobe, onto the panel.
SHADOW_TOP :: 4
SHADOW_BOTTOM :: 4
SHADOW_OVERHANG :: 2

// The inner shadow that sets the strobe into the window, over the trace and the scope's views too
draw_strobe_shadow :: proc(self: ^StrobeDisplay, strobe: Rect) {
    shape := Rect{strobe.x, strobe.y - SHADOW_TOP, strobe.width, strobe.height + SHADOW_TOP + SHADOW_BOTTOM}
    area := Rect{strobe.x, strobe.y, strobe.width, strobe.height + SHADOW_OVERHANG}
    draw_inner_shadow(self, area, shape)
}

// Just the bottom edge of the shadow, ending at bottom, where something covers the strobe from below
// like the settings sheet. The sides of the shape are far out, the whole shadow has darkened them already.
draw_strobe_bottom_shadow :: proc(self: ^StrobeDisplay, strobe: Rect, bottom: f32) {
    EDGE :: 24 // enough for the darkening, the shade has faded out above it
    FAR :: 1000
    area := Rect{strobe.x, bottom + SHADOW_OVERHANG - EDGE, strobe.width, EDGE}
    shape := Rect{strobe.x - FAR, area.y - FAR, strobe.width + 2 * FAR, bottom + SHADOW_BOTTOM - area.y + FAR}
    draw_inner_shadow(self, area, shape)
}

// Shades area along the inside of the rounded rectangle shape, see shaders/shadow.frag
draw_inner_shadow :: proc(self: ^StrobeDisplay, area: Rect, shape: Rect) {
    uniforms := ShadowUniforms {
        shape = {shape.x - area.x, shape.y - area.y, shape.x + shape.width - area.x, shape.y + shape.height - area.y},
        size  = {area.width, area.height},
    }
    begin_shader(self.shadow_shader)
    defer end_shader()
    set_shader_uniforms(self.shadow_shader, &uniforms)
    draw_shader_quad(area)
}

// The stripe edges are as sharp as the phase is certain: a sharp edge on a jittery phase twitches,
// a soft edge on a clean one looks washed out. The shader draws amp * sin(phase), so an edge spans
// about 2 / amp radians of the strobe phase, keep that a few standard deviations of the phase wide.
STROBE_EDGE_SIGMAS :: 3.0
STROBE_MAX_AMP :: 50.0 // limit, to avoid jagged edges in the strobe display
STROBE_LOOK_TIME_S :: 0.05

// The sharpness and visibility of a band's stripes, smoothed so they don't flicker
update_band_look :: proc(
    self: ^StrobeDisplay,
    band: ^core.PhaseBand,
    band_index: int,
    period_count: f32,
) -> (
    amp: f32,
    visibility: f32,
) {
    // Uncertainty of the phase as drawn on the screen
    sigma := band.phase_sigma * band.speed * period_count
    target_amp := clamp(2.0 / (STROBE_EDGE_SIGMAS * max(sigma, 1e-6)), 1.0, STROBE_MAX_AMP)

    fade := core.STROBE_FADE_SNR_DB
    target_visibility := math.smoothstep(fade[0], fade[1], band.snr_db)

    alpha := 1.0 - math.exp(-gfx_frame_time() / STROBE_LOOK_TIME_S)
    self.band_amp[band_index] += alpha * (target_amp - self.band_amp[band_index])
    self.band_visibility[band_index] += alpha * (target_visibility - self.band_visibility[band_index])

    return self.band_amp[band_index], self.band_visibility[band_index]
}

// The circular bands from the centre outwards, the lowest frequency is the bottom one
draw_strobe_bands :: proc(
    self: ^StrobeDisplay,
    strobe_rect: Rect,
    comparator: ^core.PhaseComparator,
    uniforms: ^StrobeUniforms,
    geometry: StrobeGeometry,
) {
    curvature_radius := geometry.curvature_radius
    band_height := geometry.band_height
    period_count := geometry.period_count
    density := geometry.density

    begin_shader(self.strobe_shader)
    defer end_shader()

    for &band, band_index in comparator.bands {
        order := len(comparator.bands) - 1 - band_index

        // Down to where the arc ends, it drops towards the sides. The inner edge meets the sides of the strobe
        // on a wide arc, a narrow one like the wheel is a whole ring.
        band_y := geometry.y + band_height * f32(order)
        half_width := strobe_rect.width / 2
        inner_radius := curvature_radius - band_height
        arc_height := 2 * curvature_radius
        if inner_radius > half_width {
            arc_height = curvature_radius - math.sqrt(inner_radius * inner_radius - half_width * half_width)
        }
        height := min(strobe_rect.y + strobe_rect.height - band_y, arc_height + 4)
        // The shader draws a track from the top of its quad, a curved one a little lower
        offset: f32 = 10
        if geometry.flat do height, offset = band_height, 0
        rect := Rect{strobe_rect.x, band_y, strobe_rect.width, height}

        uniforms.bounding_rect = {rect.x, rect.y, rect.width, rect.height}

        // Note, for concentric circles the radius needs to expand as the bands move from the bottom up
        uniforms.curvature_radius = curvature_radius
        curvature_radius += band_height

        uniforms.period_count = period_count
        uniforms.time_stretch = band.time_stretch
        // The shader multiplies the phase by the period count, a denser pattern turns slower to drift as
        // many stripes a second as the desktop's
        uniforms.phase = band.scaled_phase / density

        // How far the strobe moved this frame, see determine_band_phase
        uniforms.phase_step = -band.phase_diff * band.speed / density

        uniforms.amp, uniforms.visibility = update_band_look(self, &band, band_index, period_count / density)
        uniforms.norm_freq = band.norm_freq
        uniforms.err_cents = band.err_cents

        selected := band_index == self.selected_track
        uniforms.highlight = self.selection if selected else 0
        uniforms.dim = 0 if selected else self.selection

        // A partial too high for the sample rate leaves a gap, its sheet still opens there
        if band.in_range {
            set_shader_uniforms(self.strobe_shader, uniforms)
            draw_shader_quad({rect.x, rect.y + offset, rect.width, rect.height})
        }

        // Each fine track turns faster, its stripes are packed twice as tight
        if comparator.mode == .FINE do period_count *= 2.0
    }
}
