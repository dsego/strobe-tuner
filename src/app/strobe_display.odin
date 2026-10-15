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
import "core:time"

import "../core"
import "../gfx"

// How much of the strobe's bloom is added over it, see glow.odin
BLOOM_STRENGTH :: 0.2

// The stripes shaped from the sine, off a hard square wave. Motion blur averages the pattern over its
// movement since the previous frame, it reduces shimmer when it spins fast.
STROBE_BLUR :: true
MOTION_BLUR :: true

StrobeDisplay :: struct {
    background:      gfx.Color,

    // what the glow's render targets hold and at which of their versions, see draw_strobe_display
    glow_drawn:      GlowFrame,
    glow_version:    int,

    // per band stripe visibility, smoothed so it doesn't flicker, see update_band_visibility
    band_visibility: [core.MAX_BANDS]f32,
    // per band phase drawn in the previous frame, for the motion blur, see strobe_tracks
    band_drawn_phases: [core.MAX_BANDS]f32,
    // per band average of the stripes' phasor over the persistence, 0 while dark, see strobe_persistence
    band_phasors:    [core.MAX_BANDS]complex64,
    // when the tracks were last drawn, another display may have shown in between, see strobe_tracks
    tracks_tick:     time.Tick,
    // what turned them and how, a change starts them over, see strobe_tracks
    tracks_lamp:     bool,
    tracks_mode:     core.StrobeMode,

    // The track whose sheet is open, outlined while the others dim. selection fades it in and out with
    // the sheet, 0 is no selection.
    selected_track:  int,
    selection:       f32,
}

// The strobe in the glow's render targets, drawn again as it is while it's the same, see draw_strobe_display
GlowFrame :: struct {
    rect:       gfx.Rect,
    turned:     bool,
    scale:      f32,
    background: gfx.Color,
    tracks:     StrobeTracks,
}

// Each track's uniforms from the centre outwards. A track too high for the sample rate is drawn dark, like a
// partial too quiet to show, see core.run_phase_detection.
StrobeTracks :: struct {
    uniforms: [core.MAX_BANDS]gfx.StrobeUniforms,
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

// A curved track's or a wheel's ring's quad is placed this far down from the track's slot, the shader draws
// the arc from the top of its quad. A flat one is at the top of its slot.
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

// The strobe is drawn in a frame of its own, upright: the tracks across it with the disc's hub below,
// hidden under the panel. With the panel beside the strobe the frame is set into the strobe's pane a
// quarter turn anticlockwise, its top along the pane's left edge and its bottom against the panel, so the
// hub hides behind the panel again. The disc turns the same way, so the stripes climb when sharp.
strobe_upright :: proc(pane: gfx.Rect, turned: bool) -> gfx.Rect {
    if !turned do return pane

    return {0, 0, pane.height, pane.width}
}

// Where a rect of the upright frame lands in the pane
strobe_pane_rect :: proc(pane: gfx.Rect, turned: bool, rect: gfx.Rect) -> gfx.Rect {
    if !turned do return rect

    return {pane.x + rect.y, pane.y + pane.height - rect.x - rect.width, rect.height, rect.width}
}

// Where a point of the upright frame lands in the pane
strobe_pane_point :: proc(pane: gfx.Rect, turned: bool, point: [2]f32) -> [2]f32 {
    if !turned do return point

    return {pane.x + point.y, pane.y + pane.height - point.x}
}

// A point of the pane in the upright frame, for a tap on a track
strobe_upright_point :: proc(pane: gfx.Rect, turned: bool, point: [2]f32) -> [2]f32 {
    if !turned do return point

    return {pane.y + pane.height - point.y, point.x - pane.x}
}

// The tracks are laid out for the desktop size and scaled by scale, then aligned to the bottom of rect,
// a taller rect only extends the background upwards (e.g. behind the notch). rect is the upright frame.
// Flat tracks fill the strobe, each is the top of a curved track's arc, with the stripes as wide.
// The centre of the circles in rect upright, the same as strobe_tracks gives the strobe shader, the tap
// targets and the labels go round it
strobe_center :: proc(geometry: StrobeGeometry, rect: gfx.Rect, band_count: int) -> [2]f32 {
    outer_radius := geometry.curvature_radius + geometry.band_height * f32(band_count - 1)
    return {rect.x + 0.5 * rect.width, geometry.y + CURVED_TRACK_DROP + outer_radius}
}

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

    // The desktop's circle for the curved tracks and the flat ones, the top of its arc, whatever the width
    // shows of it
    geometry.curvature_radius = DESKTOP_TRACKS_RADIUS * scale
    geometry.density = strobe_density(rect.width / 2, geometry.curvature_radius)
    geometry.period_count = DESKTOP_TRACKS_PERIODS * geometry.density
    return
}

// The track under point, -1 for none. The tracks are concentric, the gap outside a track counts as part
// of it, so the whole ring from one track to the next is its touch area. Flat ones are stacked. pane and
// turned are the strobe's, see strobe_upright.
strobe_track_at :: proc(shape: StrobeShape, pane: gfx.Rect, scale: f32, turned: bool, band_count: int, point: [2]f32) -> int {
    if !gfx.point_in_rect(point, pane) do return -1

    rect := strobe_upright(pane, turned)
    upright_point := strobe_upright_point(pane, turned, point)
    geometry := strobe_geometry(shape, rect, scale, band_count)

    if shape == .FLAT {
        // The first track is the bottom one
        order := int(math.floor((upright_point.y - geometry.y) / geometry.band_height))
        if order < 0 || order >= band_count do return -1

        return band_count - 1 - order
    }

    distance := linalg.length(upright_point - strobe_center(geometry, rect, band_count))

    track := int(math.ceil((distance - geometry.curvature_radius) / geometry.band_height))
    if track < 0 || track >= band_count do return -1

    return track
}


init_strobe_display :: proc(background: u32) -> (self: StrobeDisplay) {
    self.background = gfx.hex(background)
    return
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
    for channel, index in filter {
        darkest[index] = 1 - math.exp(-DARK_TRANSMISSION * MIN_LAMP * glow.exposure * channel)
    }

    luma := darkest.r * 0.299 + darkest.g * 0.587 + darkest.b * 0.114
    darkest = linalg.lerp([3]f32{luma, luma, luma}, darkest, glow.saturation)

    base := gfx.normalize_color(background).rgb
    lifted := linalg.min(base + BACKGROUND_LIFT * darkest, 1)
    return gfx.color_from_normalized({lifted.r, lifted.g, lifted.b, 1})
}

// See strobe_geometry for the layout. rect is the strobe's pane, turned sets the strobe into it a quarter
// turn, see strobe_upright. bands are the lock-in's, or the lamp's, see core.strobe_lamp_bands.
draw_strobe_display :: proc(
    self: ^StrobeDisplay,
    targets: ^GlowTargets,
    rect: gfx.Rect,
    scale: f32,
    turned: bool,
    bands: []core.PhaseBand,
    lock_in: ^core.StrobeLockIn,
    config: ^Config,
) {
    shape := config.strobe_shape
    upright := strobe_upright(rect, turned)
    geometry := strobe_geometry(shape, upright, scale, len(bands))
    band_height := geometry.band_height

    // The colorway and the glow as the config has them, a change shows the next frame
    colors := strobe_colors(config)
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
        color_a         = gfx.normalize_color(gfx.hex(colors.x)),
        color_b         = gfx.normalize_color(gfx.hex(colors.y)),
        // The inner edge of the innermost track and the outer edge of the outermost
        min_radius      = geometry.curvature_radius - band_height,
        max_radius      = geometry.curvature_radius + band_height * f32(len(bands) - 1),
    }
    uniforms.glow_filter.rgb = glow_filter(glow.color)
    uniforms.glow_dark_filter.rgb = glow_filter(glow.dark_color) * glow.dark_level
    uniforms.highlight_color = gfx.normalize_color(accent_color)
    tracks := strobe_tracks(self, upright, bands, lock_in, config.strobe_source == .LAMP, config.persistence_periods, uniforms, geometry)

    if glow_enabled {
        // Render the strobe offscreen so the bright parts can bloom over the surroundings. A dark strobe
        // stays the same from frame to frame, what the render targets hold is drawn again.
        ensure_glow_targets(targets, {rect.width, rect.height})
        frame := GlowFrame{rect, turned, targets.scale, glow_background(self.background, glow), tracks}

        if frame != self.glow_drawn || self.glow_version != targets.version || gfx.last_frame_dropped() {
            gfx.begin_render_target(targets.scene_rt, frame.background, {rect.x, rect.y}, targets.scale)
            draw_strobe_tracks(self, &tracks, rect, turned)
            gfx.end_render_target()

            render_bloom(targets)
            self.glow_drawn = frame
            self.glow_version = targets.version
        }
    }

    gfx.begin_scissor(rect)
    defer gfx.end_scissor()

    if glow_enabled {
        gfx.set_blend_mode(.REPLACE)
        gfx.draw_render_target(targets.scene_rt, rect)

        // Add the bloom on top, the light spills into the gaps and the dark background
        gfx.set_blend_mode(.ADD)
        strength := u8(BLOOM_STRENGTH * 255)
        gfx.draw_render_target(targets.bloom_rt[0], rect, {strength, strength, strength, 255})
        gfx.set_blend_mode(.ALPHA)
    } else {
        gfx.draw_rect({rect.x, rect.y}, {rect.width, rect.height}, self.background)
        draw_strobe_tracks(self, &tracks, rect, turned)
    }

    if config.strobe_mode == .HARMONIC && (config.partial_labels != .NONE || config.show_band_cents) {
        for band, band_index in bands do draw_track_label(rect, turned, upright, band, band_index, len(bands), geometry, config)
    }
}

// The track's partial, e.g. 1×, 2×: on the right, on the curve of a curved track a little in from the edge or
// in the middle of a flat one, and on the top of a wheel's ring, where the ring runs level and the labels of
// the rings stack in a column. The cents on the left. Turned, the right is the pane's top and the left its
// bottom: the labels sit along them over the ends of their tracks, upright.
draw_track_label :: proc(
    pane: gfx.Rect,
    turned: bool,
    upright: gfx.Rect,
    band: core.PhaseBand,
    band_index, band_count: int,
    geometry: StrobeGeometry,
    config: ^Config,
) {
    label_height := pixel_fonts.band_label.size
    label_y, on_ring := track_label_y(upright, band_index, band_count, geometry)

    // Turned, the middle of the label across the pane
    label_x := pane.x + label_y + 0.5 * label_height

    // How far off this partial is, nothing while it's too quiet to measure. Right aligned on the decimal point
    // like the readout, the digits don't shift as the value changes.
    if config.show_band_cents && band.snr_db > core.NOISE_FLOOR_SNR_DB_THRESHOLD {
        font := pixel_fonts.band_label
        width := measure_label(font, "-00.0").x
        text := fmt.ctprintf("%+.1f", band.err_cents)
        position := [2]f32{upright.x + 16 + width, label_y}
        if turned do position = {label_x + 0.5 * width, pane.y + pane.height - 16 - label_height}

        draw_text_right(font.font, text, position, font.size, 0, accent_color)
    }

    if config.partial_labels == .NONE do return

    if geometry.shape == .WHEEL {
        draw_strobe_partial_label(strobe_pane_point(pane, turned, on_ring), config.partial_labels, band, centered = true)
    } else if turned {
        draw_strobe_partial_label({label_x, pane.y + 12 + 0.5 * label_height}, config.partial_labels, band, centered = true)
    } else {
        draw_strobe_partial_label({upright.x + upright.width - 12, label_y}, config.partial_labels, band)
    }
}

// The top of a track's labels in the upright strobe, and on a wheel the middle of the label on its ring
track_label_y :: proc(
    upright: gfx.Rect,
    band_index, band_count: int,
    geometry: StrobeGeometry,
) -> (
    label_y: f32,
    on_ring: [2]f32,
) {
    band_height := geometry.band_height
    label_height := pixel_fonts.band_label.size

    // The middle of a track down from its top, see STROBE_TRACK_GAP
    track_middle := 0.5 * (band_height - STROBE_TRACK_GAP)

    // Tracks counted from the top, and the track's outer edge, the innermost one's on the curvature radius
    order := band_count - 1 - band_index
    radius := geometry.curvature_radius + band_height * f32(band_index)

    switch geometry.shape {
    case .CURVED:
        // From the centre of the circles across to the label, and up to the track there
        // A pane wider than the outer track, past STROBE_MAX_SCALE, has the label at the track's end
        across := min(0.5 * upright.width - 28, radius)
        up := math.sqrt(radius * radius - across * across)
        label_y = geometry.y + band_height * (f32(order) + 0.6) + radius - up
    case .FLAT:
        label_y = geometry.y + band_height * f32(order) + track_middle - 0.5 * label_height
    case .WHEEL:
        center := strobe_center(geometry, upright, band_count)
        on_ring = {center.x, center.y - (radius - track_middle)}
        label_y = on_ring.y - 0.5 * label_height
    }
    return
}

// The shadow's rounded rectangle is on the strobe's sides and a little past its top and bottom, so those
// are a little less dark. The shade reaches 2 points under the strobe, onto the panel.
SHADOW_TOP :: 4
SHADOW_BOTTOM :: 4
SHADOW_OVERHANG :: 2

// The inner shadow that sets the strobe into the window, over the trace and the scope's views too
draw_strobe_shadow :: proc(strobe: gfx.Rect) {
    shape := gfx.Rect{strobe.x, strobe.y - SHADOW_TOP, strobe.width, strobe.height + SHADOW_TOP + SHADOW_BOTTOM}
    draw_inner_shadow(strobe, shape)
}

// Just the bottom edge of the shadow, ending at bottom, where something covers the strobe from below
// like the settings sheet. The sides of the shape are far out, the whole shadow has darkened them already.
draw_strobe_bottom_shadow :: proc(strobe: gfx.Rect, bottom: f32) {
    EDGE :: 24 // enough for the darkening, the shade has faded out above it
    FAR :: 1000
    area := gfx.Rect{strobe.x, bottom + SHADOW_OVERHANG - EDGE, strobe.width, EDGE}
    shape := gfx.Rect{strobe.x - FAR, area.y - FAR, strobe.width + 2 * FAR, bottom + SHADOW_BOTTOM - area.y + FAR}
    draw_inner_shadow(area, shape)
}

// Shades area along the inside of the rounded rectangle shape, see src/shaders/vulkan/shadow.frag
draw_inner_shadow :: proc(area: gfx.Rect, shape: gfx.Rect) {
    uniforms := gfx.ShadowUniforms {
        shape = {shape.x - area.x, shape.y - area.y, shape.x + shape.width - area.x, shape.y + shape.height - area.y},
        size  = {area.width, area.height},
    }
    gfx.begin_shader(.SHADOW)
    defer gfx.end_shader()
    gfx.set_shader_uniforms(.SHADOW, &uniforms)
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

// The visibility of a band's stripes, smoothed so they don't flicker. response is track_response's, smear
// the persistence's contrast, see strobe_persistence, stripes_per_s how fast the track's own stripes move,
// frame_time the screen's.
update_band_visibility :: proc(
    self: ^StrobeDisplay,
    band: ^core.PhaseBand,
    band_index: int,
    response: f32,
    smear: f32,
    stripes_per_s: f32,
    frame_time: f32,
) -> f32 {
    fade := core.STROBE_FADE_SNR_DB
    alias := STROBE_ALIAS_FADE_STRIPES
    target := math.smoothstep(fade[0], fade[1], band.snr_db) * min(NARROW_BAND_CONTRAST * response, 1) * smear
    target *= 1 - math.smoothstep(alias[0], alias[1], stripes_per_s * frame_time)

    alpha := 1.0 - math.exp(-gfx.frame_time() / STROBE_LOOK_TIME_S)
    visibility := &self.band_visibility[band_index]
    visibility^ += alpha * (target - visibility^)

    // Dark all the way in the end, a dark strobe's glow is drawn again as it was, see draw_strobe_display
    if target == 0 && visibility^ < 0.001 do visibility^ = 0

    return visibility^
}

// The persistence of the strobe's stripes, the lamp's smear on the lock-in's phase: the stripes' phasor
// averaged over the persistence, as the lamp's screen averages the wave. The average rides along with the
// stripes at the readout's rate, expected_step is how far they move this frame by it: the frames before are
// carried that far on before the newest joins them, so a steady drift keeps them aligned and the stripes move
// sharp and on time, as a disc's do for an eye that follows them, and only what wanders off the rate smears.
// The average's angle is where the smeared stripes sit, a jittery phase comes out calm, and its length is
// their contrast, 1 for a phase on the rate and short for one that wandered within the window. phase is the
// track's as drawn and comes back averaged, period_count the shader's stripes per turn of it, drawn_phase
// the previous frame's: the averaged phase goes on from where the rate takes it the shortest way round, so
// the motion blur sees no wrap. Lit again after dark the stripes come in where they are, not out of a dark
// screen.
strobe_persistence :: proc(
    phasor: ^complex64,
    phase: ^f32,
    drawn_phase: f32,
    expected_step: f32,
    period_count: f32,
    persistence_s: f32,
    frame_time: f32,
) -> (
    contrast: f32,
) {
    angle := phase^ * period_count
    newest := complex(math.cos(angle), math.sin(angle))
    carry := expected_step * period_count
    if phasor^ == 0 do phasor^ = newest
    else do phasor^ *= complex(math.cos(carry), math.sin(carry))

    alpha := 1 - math.exp(-frame_time / persistence_s)
    phasor^ += complex(alpha, 0) * (newest - phasor^)

    averaged := math.atan2(imag(phasor^), real(phasor^))
    predicted := drawn_phase + expected_step
    phase^ = predicted + f32(core.wrap_phase(f64(averaged - predicted * period_count))) / period_count
    return abs(phasor^)
}

// The circular bands from the centre outwards, the lowest frequency is the bottom one
strobe_tracks :: proc(
    self: ^StrobeDisplay,
    strobe_rect: gfx.Rect,
    bands: []core.PhaseBand,
    lock_in: ^core.StrobeLockIn,
    lamp: bool,
    persistence_periods: f32,
    shared: gfx.StrobeUniforms,
    geometry: StrobeGeometry,
) -> (
    tracks: StrobeTracks,
) {
    mode := lock_in.mode
    curvature_radius := geometry.curvature_radius
    band_height := geometry.band_height
    period_count := geometry.period_count
    density := geometry.density
    tracks.count = len(bands)

    stale := time.duration_seconds(time.tick_since(self.tracks_tick)) > core.STROBE_STALE_S
    self.tracks_tick = time.tick_now()

    // The lamp's phase isn't the lock-in's, and a vernier track's stripes are packed tighter than a harmonic
    // one's: the phase drawn before and the average of it don't carry over
    if lamp != self.tracks_lamp || mode != self.tracks_mode do stale = true

    self.tracks_lamp, self.tracks_mode = lamp, mode

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
        ahead := core.strobe_phase_ahead(lock_in, band) if !lamp else 0
        uniforms.phase = (band.scaled_phase + ahead) / density

        // The persistence smears the stripes and calms a jittery phase like the lamp's screen. Not the lamp's
        // tracks, their screen smeared already. A pluck starts it over, the plucked note's stripes come in
        // where they are instead of through dark, as the lamp's loud attack outweighs its faded picture.
        frame_time := min(gfx.frame_time(), STROBE_MAX_FRAME_TIME_S)
        drawn_phase := &self.band_drawn_phases[band_index]

        // The phase wrapped by whole turns, see core.STROBE_PHASE_WRAP, the drawn one goes with it and the
        // step stays what the stripes moved
        wrap := core.STROBE_PHASE_WRAP / density
        drawn_phase^ += wrap * math.round((uniforms.phase - drawn_phase^) / wrap)

        // Coming back to the strobe or turned another way, the stripes start where they are like after a
        // pluck, not smeared from a phase seconds old or from another one
        if stale {
            self.band_phasors[band_index] = 0
            drawn_phase^ = uniforms.phase
        }

        smear: f32 = 1
        if !lamp && persistence_periods > 0 {
            if band.onset do self.band_phasors[band_index] = 0

            persistence_s := persistence_periods / lock_in.base_freq_hz

            // How far the stripes moved this frame at the readout's rate, the whole frame however long it
            // took: a hitch moved them all the way
            expected_step := core.strobe_phase_rate(lock_in, band) * gfx.frame_time() / density
            smear = strobe_persistence(&self.band_phasors[band_index], &uniforms.phase, drawn_phase^, expected_step, period_count, persistence_s, frame_time)
        }

        // How far the strobe moved since the previous frame as drawn
        uniforms.phase_step = uniforms.phase - drawn_phase^
        drawn_phase^ = uniforms.phase

        // The shader's sine of the phase times the period count, up to 64 turns times it is tens of thousands
        // of radians on the outer vernier tracks. Within a stripe the same, the GPU's fast sine is accurate
        // near 0.
        uniforms.phase = math.mod(uniforms.phase, math.TAU / period_count)

        // Vernier tracks show the first one's measurement. The lamp's tracks are as far off as the lock-in's.
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
        drift_cents := bands[0].drift_cents if mode == .VERNIER else band.drift_cents
        drift_hz := core.freq_at_cents(band.freq_hz, drift_cents) - band.freq_hz
        phase_per_s := math.TAU * drift_hz * f32(core.strobe_rescale(band.freq_hz)) * band.speed
        stripes_per_s := period_count * phase_per_s / density / math.TAU

        // Off the note the edges go soft, the stripes a sine before they fade. Squared, as the response alone
        // still leaves an edge a few percent of a stripe wide where they're half faded. Smeared they soften
        // and dim the same way.
        uniforms.amp = STROBE_AMP * response * response * smear * smear
        uniforms.visibility = update_band_visibility(self, &band, band_index, response, smear, stripes_per_s, frame_time)
        uniforms.norm_freq = band.norm_freq

        // Without stripes the track looks the same whatever its phase, and doesn't change from frame to frame.
        // The persistence starts over when they show again.
        if uniforms.visibility == 0 {
            uniforms.phase, uniforms.phase_step = 0, 0
            self.band_phasors[band_index] = 0
        }

        selected := band_index == self.selected_track
        uniforms.highlight = self.selection if selected else 0
        uniforms.dim = 0 if selected else self.selection

        // Each vernier track turns faster, its stripes are packed twice as tight
        if mode == .VERNIER do period_count *= 2.0
    }
    return
}

// pane and turned are the strobe's, see strobe_upright
draw_strobe_tracks :: proc(self: ^StrobeDisplay, tracks: ^StrobeTracks, pane: gfx.Rect, turned: bool) {
    gfx.begin_shader(.STROBE)
    defer gfx.end_shader()

    for &uniforms in tracks.uniforms[:tracks.count] {
        // A curved track drops below the top of its quad, see CURVED_TRACK_DROP
        rect := uniforms.bounding_rect
        offset: f32 = 0 if uniforms.flat_track != 0 else CURVED_TRACK_DROP
        gfx.set_shader_uniforms(.STROBE, &uniforms)

        // The quad is laid out in the upright frame, it lands in the pane turned with it
        quad := strobe_pane_rect(pane, turned, {rect.x, rect.y + offset, rect.z, rect.w})
        if turned do gfx.draw_shader_quad_turned(quad)
        else do gfx.draw_shader_quad(quad)
    }
}
