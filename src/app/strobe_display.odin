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
import "../gfx"

// Bloom for the strobe glow, rendered at a fraction of the strobe size since it gets blurred anyway
BLOOM_DOWNSCALE :: 2
BLOOM_TAP_SPACING :: 1.5 // blur taps spaced apart for a wider glow at the same cost
BLOOM_ITERATIONS :: 2
BLOOM_STRENGTH :: 0.2

// The stripes shaped from the sine, off a hard square wave. Motion blur averages the pattern over its
// movement since the previous frame, it reduces shimmer when it spins fast.
STROBE_BLUR :: true
MOTION_BLUR :: true

StrobeDisplay :: struct {
    strobe_shader:   gfx.Shader,
    bloom_shader:    gfx.Shader,
    shadow_shader:   gfx.Shader,
    colors:          [2]gfx.Color,
    background:      gfx.Color,

    // bloom for the strobe glow, the strobe is rendered into scene_rt and blurred through bloom_rt
    scene_rt:        gfx.RenderTarget,
    bloom_rt:        [2]gfx.RenderTarget,
    glow_scale:      f32, // DPI scale the render targets were created for
    glow_size:       [2]f32, // and the strobe size in points
    glow_drawn:      GlowFrame, // what the render targets hold, see draw_strobe_display

    // per band stripe visibility, smoothed so it doesn't flicker, see update_band_visibility
    band_visibility: [core.MAX_BANDS]f32,
    // per band phase drawn in the previous frame, for the motion blur, see strobe_tracks
    band_drawn_phases: [core.MAX_BANDS]f32,
    // and of the scope's beam, see draw_scope_display
    scope_visibility: f32,
    // the scope's screen for its shader, a byte a cell, see draw_scope_screen
    scope_shader:     gfx.Shader,
    scope_texture:    gfx.Texture,
    scope_pixels:     []u8,
    // the tracks turned by the lamp, see lamp_bands: each one's phase on the screen at the previous
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

// The strobe in the glow's render targets, drawn again as it is while it's the same, see draw_strobe_display
GlowFrame :: struct {
    rect:       gfx.Rect,
    scale:      f32,
    background: gfx.Color,
    tracks:     StrobeTracks,
}

// Each track's uniforms from the centre outwards, a track too high for the sample rate isn't drawn
StrobeTracks :: struct {
    uniforms: [core.MAX_BANDS]gfx.StrobeUniforms,
    shown:    [core.MAX_BANDS]bool,
    count:    int,
}

// Where the tracks go in the strobe, the drawing and strobe_track_at share it
StrobeGeometry :: struct {
    y:                f32, // top of the outermost track
    curvature_radius: f32, // outer radius of the innermost track, each track further out is a band_height larger
    band_height:      f32,
    period_count:     f32, // how many strobe periods fit in a circle
    density:          f32, // period_count is this many times the desktop's, see strobe_density
    shape:            StrobeShape, // flat tracks are straightened, stacked from y down
}

// The strobe shader draws a curved track or a wheel's ring this far below the top of its quad, a flat one
// at the top
CURVED_TRACK_DROP :: 10

// Between the tracks, a track is this much thinner than band_height, as in the strobe shader
STROBE_TRACK_GAP :: 4

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
strobe_geometry :: proc(shape: StrobeShape, rect: gfx.Rect, scale: f32, band_count: int) -> (geometry: StrobeGeometry) {
    geometry.shape = shape
    geometry.y = rect.y + rect.height - scale * STROBE_HEIGHT

    switch shape {
    case .WHEEL:
        geometry.curvature_radius = 90 * scale
        geometry.band_height = 26 * scale
        geometry.period_count = 4
        geometry.density = 1
        return
    case .CURVED:
        geometry.y += 32 * scale
        geometry.band_height = (50 if band_count > 3 else 66) * scale
    case .FLAT:
        geometry.band_height = scale * STROBE_HEIGHT / f32(max(band_count, 1))
    }

    // The desktop's circle for the curved tracks and the flat ones, the top of its arc
    geometry.curvature_radius = DESKTOP_TRACKS_RADIUS * scale
    geometry.density = strobe_density(rect.width / 2, geometry.curvature_radius)
    geometry.period_count = DESKTOP_TRACKS_PERIODS * geometry.density
    return
}

// The track under point, -1 for none. The tracks are concentric, the gap outside a track counts as part
// of it, so the whole ring from one track to the next is its touch area. Flat ones are stacked.
strobe_track_at :: proc(shape: StrobeShape, rect: gfx.Rect, scale: f32, band_count: int, point: [2]f32) -> int {
    geometry := strobe_geometry(shape, rect, scale, band_count)
    if !gfx.point_in_rect(point, rect) do return -1

    if shape == .FLAT {
        // The first track is the bottom one
        order := int(math.floor((point.y - geometry.y) / geometry.band_height))
        if order < 0 || order >= band_count do return -1

        return band_count - 1 - order
    }

    // The centre of the circles, see strobe_tracks and the strobe shader
    outer_radius := geometry.curvature_radius + geometry.band_height * f32(band_count - 1)
    center := [2]f32{rect.x + rect.width / 2, geometry.y + CURVED_TRACK_DROP + outer_radius}
    distance := linalg.length(point - center)

    track := int(math.ceil((distance - geometry.curvature_radius) / geometry.band_height))
    if track < 0 || track >= band_count do return -1

    return track
}


init_strobe_display :: proc(colors: [2]u32, background: u32) -> (self: StrobeDisplay) {
    self.colors = {gfx.hex(colors.x), gfx.hex(colors.y)}
    self.background = gfx.hex(background)

    self.strobe_shader = gfx.load_shader(.STROBE)
    self.bloom_shader = gfx.load_shader(.BLOOM)
    self.shadow_shader = gfx.load_shader(.SHADOW)
    self.scope_shader = gfx.load_shader(.SCOPE)

    return
}

destroy_strobe_display :: proc(self: ^StrobeDisplay) {
    gfx.unload_shader(self.strobe_shader)
    gfx.unload_shader(self.bloom_shader)
    gfx.unload_shader(self.shadow_shader)
    gfx.unload_shader(self.scope_shader)
    gfx.unload_texture(self.scope_texture)
    delete(self.scope_pixels)
    unload_glow_targets(self)
}

unload_glow_targets :: proc(self: ^StrobeDisplay) {
    if self.glow_scale == 0 do return

    gfx.unload_render_target(self.scene_rt)
    for rt in self.bloom_rt {
        gfx.unload_render_target(rt)
    }
    self.glow_scale = 0
    self.glow_drawn = {}
}

// (Re)create the glow render targets, the scene is rendered at the display's DPI scale to stay sharp
ensure_glow_targets :: proc(self: ^StrobeDisplay, size: [2]f32) {
    scale := gfx.dpi_scale()
    if scale == self.glow_scale && size == self.glow_size do return

    unload_glow_targets(self)

    self.scene_rt = gfx.load_render_target(i32(size.x * scale), i32(size.y * scale))
    for &rt in self.bloom_rt {
        rt = gfx.load_render_target(i32(size.x / BLOOM_DOWNSCALE), i32(size.y / BLOOM_DOWNSCALE))
    }
    self.glow_scale = scale
    self.glow_size = size
}

// Separable gaussian blur, ping-pongs between the two targets and ends up in rts[0]
blur_render_targets :: proc(
    self: ^StrobeDisplay,
    rts: [2]gfx.RenderTarget,
    iterations: int,
    tap_spacing: f32,
) {
    size := gfx.render_target_size(rts[0])
    dest := gfx.Rect{0, 0, size.x, size.y}

    uniforms := gfx.BloomUniforms {
        mode = 1,
    }
    for _ in 0 ..< iterations {
        uniforms.texel_step = {tap_spacing / size.x, 0}
        gfx.set_shader_uniforms(self.bloom_shader, &uniforms)
        gfx.begin_render_target(rts[1], nil)
        gfx.draw_render_target(rts[0], dest)
        gfx.end_render_target()

        uniforms.texel_step = {0, tap_spacing / size.y}
        gfx.set_shader_uniforms(self.bloom_shader, &uniforms)
        gfx.begin_render_target(rts[0], nil)
        gfx.draw_render_target(rts[1], dest)
        gfx.end_render_target()
    }
}

// The filter the lamp shines through, the hue scaled up to full brightness and squared to saturate it
// (FF6767 -> 1.0, 0.16, 0.16). The same for the whole strobe, so the shader gets it ready made.
glow_filter :: proc(color: u32) -> [3]f32 {
    rgb := gfx.normalize_color(gfx.hex(color)).rgb
    filter := rgb / max(rgb.r, rgb.g, rgb.b, 0.001)
    return filter * filter
}

// Lift the background a little, as if some lamp light scatters behind the whole disc.
// Based on the darkest stripe, the dark stripes of the outer band away from the hotspot,
// mirrors the light model in the strobe shader.
glow_background :: proc(background: gfx.Color, glow: GlowParams) -> gfx.Color {
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

    base := gfx.normalize_color(background).rgb
    lifted := linalg.min(base + BACKGROUND_LIFT * darkest, 1)
    return gfx.color_from_normalized({lifted.r, lifted.g, lifted.b, 1})
}

render_bloom :: proc(self: ^StrobeDisplay) {
    gfx.set_blend_mode(.REPLACE)
    defer gfx.set_blend_mode(.ALPHA)
    gfx.begin_shader(self.bloom_shader)
    defer gfx.end_shader()

    // Downsample and keep the bright parts
    scene_size := gfx.render_target_size(self.scene_rt)
    uniforms := gfx.BloomUniforms {
        mode       = 0,
        texel_step = 1.0 / scene_size,
    }
    gfx.set_shader_uniforms(self.bloom_shader, &uniforms)
    bloom_size := gfx.render_target_size(self.bloom_rt[0])

    // Each pass replaces every pixel of its target, nothing to clear
    gfx.begin_render_target(self.bloom_rt[0], nil)
    gfx.draw_render_target(self.scene_rt, {0, 0, bloom_size.x, bloom_size.y})
    gfx.end_render_target()

    blur_render_targets(self, self.bloom_rt, BLOOM_ITERATIONS, BLOOM_TAP_SPACING)
}

set_strobe_colors :: proc(self: ^StrobeDisplay, colors: [2]u32) {
    self.colors = {gfx.hex(colors.x), gfx.hex(colors.y)}
}

// See strobe_geometry for the layout. bands are the comparator's, or the lamp's, see lamp_bands.
draw_strobe_display :: proc(
    self: ^StrobeDisplay,
    rect: gfx.Rect,
    scale: f32,
    bands: []core.PhaseBand,
    comparator: ^core.PhaseComparator,
    config: ^Config,
) {
    shape := config.strobe_shape
    geometry := strobe_geometry(shape, rect, scale, len(bands))
    band_height := geometry.band_height

    glow_enabled := config.strobe_glow
    glow := glow_params(config)

    // Shared by all bands, strobe_tracks fills in the rest
    uniforms := gfx.StrobeUniforms {
        band_height     = band_height,
        strobe_blur     = i32(STROBE_BLUR),
        motion_blur     = i32(MOTION_BLUR),
        glow            = i32(glow_enabled),
        flat_track      = i32(shape == .FLAT),
        // The wheel is lit evenly all around, the tracks only show the top of the disc
        lamp_spread     = 1000.0 if shape == .WHEEL else 0.45,
        glow_exposure   = glow.exposure,
        glow_saturation = glow.saturation,
        color_a         = gfx.normalize_color(self.colors.x),
        color_b         = gfx.normalize_color(self.colors.y),
        // The inner edge of the innermost track and the outer edge of the outermost
        min_radius      = geometry.curvature_radius - band_height,
        max_radius      = geometry.curvature_radius + band_height * f32(len(bands) - 1),
    }
    uniforms.glow_filter.rgb = glow_filter(glow.color)
    uniforms.glow_dark_filter.rgb = glow_filter(glow.dark_color) * glow.dark_level
    uniforms.highlight_color = gfx.normalize_color(accent_color)
    tracks := strobe_tracks(self, rect, bands, comparator, config.strobe_source == .LAMP, uniforms, geometry)

    if glow_enabled {
        // Render the strobe offscreen so the bright parts can bloom over the surroundings. A dark strobe
        // stays the same from frame to frame, what the render targets hold is drawn again.
        ensure_glow_targets(self, {rect.width, rect.height})
        frame := GlowFrame{rect, self.glow_scale, glow_background(self.background, glow), tracks}

        if frame != self.glow_drawn || gfx.last_frame_dropped() {
            gfx.begin_render_target(self.scene_rt, frame.background, {rect.x, rect.y}, self.glow_scale)
            draw_strobe_tracks(self, &tracks)
            gfx.end_render_target()

            render_bloom(self)
            self.glow_drawn = frame
        }
    }

    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if glow_enabled {
        gfx.set_blend_mode(.REPLACE)
        gfx.draw_render_target(self.scene_rt, rect)

        // Add the bloom on top, the light spills into the gaps and the dark background
        gfx.set_blend_mode(.ADD)
        strength := u8(BLOOM_STRENGTH * 255)
        gfx.draw_render_target(self.bloom_rt[0], rect, {strength, strength, strength, 255})
        gfx.set_blend_mode(.ALPHA)
    } else {
        gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)
        draw_strobe_tracks(self, &tracks)
    }

    if config.strobe_mode == .HARMONIC && config.partial_labels != .NONE {
        draw_track_labels(rect, bands, geometry, config)
    }

    // The partial of each track, e.g. 1×, 2×: on the right, on the curve of a curved track a little in from
    // the edge or in the middle of a flat one, and on the top of a wheel's ring, where the ring runs level
    // and the labels of the rings stack in a column
    draw_track_labels :: proc(rect: gfx.Rect, bands: []core.PhaseBand, geometry: StrobeGeometry, config: ^Config) {
        band_height := geometry.band_height

        // The middle of a track down from its top, see STROBE_TRACK_GAP
        track_middle := 0.5 * (band_height - STROBE_TRACK_GAP)

        // The wheel's centre, see strobe_tracks and the strobe shader
        center := [2]f32 {
            rect.x + 0.5 * rect.width,
            geometry.y + CURVED_TRACK_DROP + geometry.curvature_radius + band_height * f32(len(bands) - 1),
        }

        // The outer edge of each track, from the innermost one's
        radius := geometry.curvature_radius - band_height
        for band, band_index in bands {
            order := len(bands) - 1 - band_index
            radius += band_height

            label_y: f32
            on_ring: [2]f32 // a wheel's, the middle of the label
            switch geometry.shape {
            case .CURVED:
                // From the centre of the circles across to the label, and up to the track there
                across := 0.5 * rect.width - 28
                up := math.sqrt(radius * radius - across * across)
                label_y = geometry.y + band_height * (f32(order) + 0.6) + radius - up
            case .FLAT:
                label_y = geometry.y + band_height * f32(order) + track_middle - 0.5 * pixel_fonts.band_label.size
            case .WHEEL:
                on_ring = {center.x, center.y - (radius - track_middle)}
                label_y = on_ring.y - 0.5 * pixel_fonts.band_label.size
            }

            // Hidden, too high for the sample rate
            if !band.in_range do continue

            // How far off this partial is, nothing while it's too quiet to measure. Right aligned on the
            // decimal point like the readout, the digits don't shift as the value changes.
            if config.show_band_cents && band.snr_db > core.NOISE_FLOOR_SNR_DB_THRESHOLD {
                font := pixel_fonts.band_label
                right := rect.x + 16 + measure_label(font, "-00.0").x
                text := fmt.ctprintf("%+.1f", band.err_cents)
                draw_text_right(font.font, text, {right, label_y}, font.size, 0, accent_color)
            }

            if geometry.shape == .WHEEL do draw_strobe_partial(on_ring, config.partial_labels, band, centered = true)
            else do draw_strobe_partial({rect.x + rect.width - 12, label_y}, config.partial_labels, band)
        }
    }
}

// The shadow's rounded rectangle is on the strobe's sides and a little past its top and bottom, so those
// are a little less dark. The shade reaches 2 points under the strobe, onto the panel.
SHADOW_TOP :: 4
SHADOW_BOTTOM :: 4
SHADOW_OVERHANG :: 2

// The inner shadow that sets the strobe into the window, over the trace and the scope's views too
draw_strobe_shadow :: proc(self: ^StrobeDisplay, strobe: gfx.Rect) {
    shape := gfx.Rect{strobe.x, strobe.y - SHADOW_TOP, strobe.width, strobe.height + SHADOW_TOP + SHADOW_BOTTOM}
    draw_inner_shadow(self, strobe, shape)
}

// Just the bottom edge of the shadow, ending at bottom, where something covers the strobe from below
// like the settings sheet. The sides of the shape are far out, the whole shadow has darkened them already.
draw_strobe_bottom_shadow :: proc(self: ^StrobeDisplay, strobe: gfx.Rect, bottom: f32) {
    EDGE :: 24 // enough for the darkening, the shade has faded out above it
    FAR :: 1000
    area := gfx.Rect{strobe.x, bottom + SHADOW_OVERHANG - EDGE, strobe.width, EDGE}
    shape := gfx.Rect{strobe.x - FAR, area.y - FAR, strobe.width + 2 * FAR, bottom + SHADOW_BOTTOM - area.y + FAR}
    draw_inner_shadow(self, area, shape)
}

// Shades area along the inside of the rounded rectangle shape, see src/shaders/vulkan/shadow.frag
draw_inner_shadow :: proc(self: ^StrobeDisplay, area: gfx.Rect, shape: gfx.Rect) {
    uniforms := gfx.ShadowUniforms {
        shape = {shape.x - area.x, shape.y - area.y, shape.x + shape.width - area.x, shape.y + shape.height - area.y},
        size  = {area.width, area.height},
    }
    gfx.begin_shader(self.shadow_shader)
    defer gfx.end_shader()
    gfx.set_shader_uniforms(self.shadow_shader, &uniforms)
    gfx.draw_shader_quad(area)
}

// The shader draws amp * sin(phase), an edge spans about 2 / amp radians of the strobe phase. The edges
// stay this sharp while a note fades, the stripes dim like a lamp's, and soften off the note, see
// track_response. Sharper gets jagged.
STROBE_AMP :: 50.0
STROBE_LOOK_TIME_S :: 0.05

// A track off its partial fades as it did when the bands were narrow: a Blackman window a bin of this many
// cents of the track's own partial, so a harmonic note's tracks fade alike. Half a bin off is 1 dB down, a
// bin 4.5, two bins 20, three are its null.
NARROW_BAND_CENTS :: 25

// The stripes' contrast was the band's level 1000 times, full from 1 up, so a louder note stayed further off.
// Every note fades as one at -40 dBFS did instead, its band's level 0.21 of the sine's amplitude: full to
// about 29 cents off, half at 39, a tenth at 55, nothing at 75. A quiet note or a decay doesn't dim the
// stripes, the SNR fades them as before.
NARROW_BAND_CONTRAST :: 1000 * 0.21 * 0.01

// Vernier tracks all hear the note, the faster ones fade by their speed instead, as they used to: the first
// track between these cents, each faster one as much sooner as it turns faster.
VERNIER_FADE_CENTS :: [2]f32{10, 80}

// How much of a track's stripes is left off its note, 1 on it. drift_cents is how far the track is off lately,
// see PhaseBand, speed_ratio how many times faster than the first track it turns, vernier mode only.
// The old bands' level was also the shader's amp, the edges went soft before the stripes faded, the stripes
// here soften by it too.
track_response :: proc(drift_cents: f32, speed_ratio: f32 = 0) -> f32 {
    response := math.pow(10, core.blackman_response_db(drift_cents / NARROW_BAND_CENTS) / 20)

    if speed_ratio > 0 {
        vernier := VERNIER_FADE_CENTS
        response *= 1 - math.smoothstep(vernier[0], vernier[1], drift_cents * speed_ratio)
    }
    return response
}

// The screen shows the stripes once a frame. Moving half a stripe a frame they seem to alternate, further
// they turn backwards, a whole one they stand still. The stripes fade out before that, between these, in the
// track's own stripes a frame. Slower they stay lit and sharp, a voice or a vibrato wavers that fast on the
// note, most of all on a partial's track.
STROBE_ALIAS_FADE_STRIPES :: [2]f32{0.25, 0.45}

// A hitch isn't the screen's refresh, the stripes don't fade for one
STROBE_MAX_FRAME_TIME_S :: 1.0 / 30

// The visibility of a band's stripes, smoothed so they don't flicker. response is track_response's,
// stripes_per_s how fast the track's own stripes move, frame_time the screen's.
update_band_visibility :: proc(
    self: ^StrobeDisplay,
    band: ^core.PhaseBand,
    band_index: int,
    response: f32,
    stripes_per_s: f32,
    frame_time: f32,
) -> f32 {
    fade := core.STROBE_FADE_SNR_DB
    alias := STROBE_ALIAS_FADE_STRIPES
    target := math.smoothstep(fade[0], fade[1], band.snr_db) * min(NARROW_BAND_CONTRAST * response, 1)
    target *= 1 - math.smoothstep(alias[0], alias[1], stripes_per_s * frame_time)

    alpha := 1.0 - math.exp(-gfx.frame_time() / STROBE_LOOK_TIME_S)
    visibility := &self.band_visibility[band_index]
    visibility^ += alpha * (target - visibility^)

    // Dark all the way in the end, a dark strobe's glow is drawn again as it was, see draw_strobe_display
    if target == 0 && visibility^ < 0.001 do visibility^ = 0

    return visibility^
}

// The circular bands from the centre outwards, the lowest frequency is the bottom one
strobe_tracks :: proc(
    self: ^StrobeDisplay,
    strobe_rect: gfx.Rect,
    bands: []core.PhaseBand,
    comparator: ^core.PhaseComparator,
    lamp: bool,
    shared: gfx.StrobeUniforms,
    geometry: StrobeGeometry,
) -> (
    tracks: StrobeTracks,
) {
    mode := comparator.mode
    curvature_radius := geometry.curvature_radius
    band_height := geometry.band_height
    period_count := geometry.period_count
    density := geometry.density
    tracks.count = len(bands)

    for &band, band_index in bands {
        uniforms := &tracks.uniforms[band_index]
        uniforms^ = shared

        order := len(bands) - 1 - band_index

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
        if geometry.shape == .FLAT do height = band_height

        uniforms.bounding_rect = {strobe_rect.x, band_y, strobe_rect.width, height}

        // Note, for concentric circles the radius needs to expand as the bands move from the bottom up
        uniforms.curvature_radius = curvature_radius
        curvature_radius += band_height

        uniforms.period_count = period_count
        uniforms.time_stretch = band.time_stretch

        // The shader multiplies the phase by the period count, a denser pattern turns slower to drift as
        // many stripes a second as the desktop's. Drawn as of now, see strobe_phase_ahead. Not the lamp's
        // tracks, they turn by the screen and the readout's rate isn't theirs, they'd jump back each chunk.
        ahead := core.strobe_phase_ahead(comparator, band) if !lamp else 0
        uniforms.phase = (band.scaled_phase + ahead) / density

        // How far the strobe moved since the previous frame as drawn
        drawn_phase := &self.band_drawn_phases[band_index]
        uniforms.phase_step = uniforms.phase - drawn_phase^
        drawn_phase^ = uniforms.phase

        // Vernier tracks show the first one's measurement. The lamp's tracks are as far off as the comparator's.
        response: f32
        if mode == .VERNIER {
            first := bands[0]
            speed_ratio := band.speed / first.speed if first.speed != 0 else 1
            response = track_response(first.drift_cents, speed_ratio)
        } else {
            response = track_response(band.drift_cents)
        }

        // How fast the track's own stripes, a period of the shader's sine, move. By the drift, the phase as
        // measured, averaged: the readout's rate holds on a weak partial while its phase still moves. Vernier
        // tracks by the first one's, at their own speed. The lamp's tracks move by the screen, about as fast.
        frame_time := min(gfx.frame_time(), STROBE_MAX_FRAME_TIME_S)
        drift_cents := bands[0].drift_cents if mode == .VERNIER else band.drift_cents
        drift_hz := band.freq_hz * (math.pow(2, drift_cents / 1200) - 1)
        phase_per_s := math.TAU * drift_hz * f32(core.strobe_rescale(band.freq_hz)) * band.speed
        stripes_per_s := period_count * phase_per_s / density / math.TAU

        // Off the note the edges go soft, the stripes a sine before they fade. Squared, as the response alone
        // still leaves an edge a few percent of a stripe wide where they're half faded.
        uniforms.amp = STROBE_AMP * response * response
        uniforms.visibility = update_band_visibility(self, &band, band_index, response, stripes_per_s, frame_time)
        uniforms.norm_freq = band.norm_freq
        uniforms.err_cents = band.err_cents

        // Without stripes the track looks the same whatever its phase, and doesn't change from frame to frame
        if uniforms.visibility == 0 do uniforms.phase, uniforms.phase_step, uniforms.err_cents = 0, 0, 0

        selected := band_index == self.selected_track
        uniforms.highlight = self.selection if selected else 0
        uniforms.dim = 0 if selected else self.selection

        // A partial too high for the sample rate leaves a gap, its sheet still opens there
        tracks.shown[band_index] = band.in_range

        // Each vernier track turns faster, its stripes are packed twice as tight
        if mode == .VERNIER do period_count *= 2.0
    }
    return
}

draw_strobe_tracks :: proc(self: ^StrobeDisplay, tracks: ^StrobeTracks) {
    gfx.begin_shader(self.strobe_shader)
    defer gfx.end_shader()

    for &uniforms, index in tracks.uniforms[:tracks.count] {
        if !tracks.shown[index] do continue

        // A curved track drops below the top of its quad, see CURVED_TRACK_DROP
        rect := uniforms.bounding_rect
        offset: f32 = 0 if uniforms.flat_track != 0 else CURVED_TRACK_DROP
        gfx.set_shader_uniforms(self.strobe_shader, &uniforms)
        gfx.draw_shader_quad({rect.x, rect.y + offset, rect.z, rect.w})
    }
}
