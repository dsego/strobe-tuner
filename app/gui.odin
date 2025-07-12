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

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:strings"

import rl "vendor:raylib"

import "../core"


texture_atlas: rl.Texture2D

// position can serve as an ID for slider controls
active_slider_position: [2]f32 = {}

// an active dropdown menu or slider dragging should not trigger other GUI controls
exclusive_control_mode := false

text_color_dark := rl.GetColor(0x15141BFF)
text_color_light := rl.GetColor(0xBDBDBDFF)

// gui_disabled_state := false


load_texture_atlas :: proc() {
    file_data := #load("../assets/images/atlas.2x.png")
    image := rl.LoadImageFromMemory(".png", raw_data(file_data), i32(len(file_data)))
    texture_atlas = rl.LoadTextureFromImage(image)
    rl.UnloadImage(image)
}

unload_texture_atlas :: proc() {
    rl.UnloadTexture(texture_atlas)
}

gui_strobe_mode_toggle :: proc(
    position: [2]f32,
    active_strobe_mode: core.StrobeMode,
) -> (
    core.StrobeMode,
    bool,
) {
    tex_src: rl.Rectangle
    label: cstring
    label_pos: rl.Vector2

    if active_strobe_mode == .HARMONIC_MODE {
        tex_src = rl.Rectangle{0, 96, 240, 48}
        label = "HARMONIC"
        label_pos = rl.Vector2{position.x + 27.0, position.y + 5}
    } else {
        tex_src = rl.Rectangle{0, 0, 240, 48}
        label = "VERNIER"
        label_pos = rl.Vector2{position.x + 32.0, position.y + 5}
    }

    // rounded button texture
    rl.DrawTexturePro(
        texture_atlas,
        tex_src,
        rl.Rectangle{position.x, position.y, 120, 24},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )

    rl.DrawTextEx(font_store.medium_28, label, label_pos, 14, 1, text_color_dark)

    if gui_button({position.x, position.y, 120, 24}) {
        if active_strobe_mode == .HARMONIC_MODE do return .VERNIER_MODE, true
        else do return .HARMONIC_MODE, true
    }

    return active_strobe_mode, false
}


gui_feedback_button :: proc(position: [2]f32) {
    // bug icon texture
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{64, 192, 32, 32},
        rl.Rectangle{position.x, position.y, 16, 16},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )

    if gui_button({position.x, position.y, 16, 16}) {
        // TODO: support windows & linux
        when ODIN_OS == .Darwin {
            libc.system(cstring("open https://github.com/dsego/strobe-tuner"))
        }
    }
}

gui_strobe_partial :: proc(
    position: [2]f32,
    type: PartialLabelType,
    band: core.PhaseBand,
) -> (
    PartialLabelType,
    bool,
) {

    text: cstring
    text_size: rl.Vector2
    font := font_store.medium_32
    font_size: f32 = 16

    if type == .FREQUENCY {
        font = font_store.medium_28
        text = fmt.ctprintf("%.1fHz", band.freq_hz)
        font_size = 14
    } else if type == .NOTE_NAMES {
        text = fmt.ctprintf(
            "%v%v%v",
            band.note.name,
            "♯" if band.note.is_accidental else "",
            band.note.octave,
        )
    } else {
        text = fmt.ctprintf("%v×", band.interval)
    }

    text_size = rl.MeasureTextEx(font, text, font_size, 0)
    bounds: rl.Rectangle = {position.x - text_size.x, position.y, text_size.x, text_size.y}

    rl.DrawTextEx(font, text, {bounds.x, bounds.y}, font_size, 0, rl.GetColor(0x82E2FFFF))

    if gui_button(bounds) {
        if type == .MULTIPLES do return .FREQUENCY, true
        else if type == .FREQUENCY do return .NOTE_NAMES, true
        return .MULTIPLES, true
    }
    return type, false
}


gui_agc_toggle :: proc(position: [2]f32, agc_on: bool) -> (bool, bool) {
    bounds := rl.Rectangle{position.x, position.y, 35, 14}
    bg_color := rl.GetColor(0x82E2FFFF) if agc_on else rl.GetColor(window_bg_color)

    rl.DrawRectangleRounded(bounds, 0.5, 6, bg_color)
    rl.DrawTextEx(
        font_store.medium_28,
        "AGC",
        {position.x + 5, position.y},
        14,
        0,
        rl.GetColor(strobe_bg_color),
    )

    if gui_button(bounds) {
        return !agc_on, true
    }

    return agc_on, false
}

gui_note_detection_mode_toggle :: proc(
    position: [2]f32,
    active_detection_mode: NoteDetectionMode,
) -> (
    NoteDetectionMode,
    bool,
) {
    tex_src: rl.Rectangle
    label: cstring
    label_pos: rl.Vector2

    if active_detection_mode == .AUTO {
        tex_src = rl.Rectangle{0, 48, 240, 48}
        label = "AUTO"
        label_pos = rl.Vector2{position.x + 42.0, position.y + 5}
    } else {
        tex_src = rl.Rectangle{0, 0, 240, 48}
        label = "MANUAL"
        label_pos = rl.Vector2{position.x + 34.0, position.y + 5}
    }

    // rounded button texture
    rl.DrawTexturePro(
        texture_atlas,
        tex_src,
        rl.Rectangle{position.x, position.y, 120, 24},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTextEx(font_store.medium_28, label, label_pos, 14, 1, text_color_dark)

    if gui_button({position.x, position.y, 120, 24}) {
        if active_detection_mode == .AUTO do return .MANUAL, true
        else do return .AUTO, true
    }

    return active_detection_mode, false
}


gui_contrast_slider :: proc(position: [2]f32, value: ^f32) {
    gui_slider(position, value, 0.0, 7.0)
    // Draw the contrast icon
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{0, 192, 32, 32},
        rl.Rectangle{position.x + 6, position.y + 4, 16, 16},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTextEx(
        font_store.medium_28,
        "CONTRAST",
        rl.Vector2{position.x + 32.0, position.y + 5},
        14,
        1,
        text_color_dark,
    )
}

gui_speed_slider :: proc(position: [2]f32, value: ^f32) {
    gui_slider(position, value, 0.001, 0.05)
    // Draw the crosshair icon
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{32, 192, 32, 32},
        rl.Rectangle{position.x + 6, position.y + 4, 16, 16},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTextEx(
        font_store.medium_28,
        "SENSITIVITY", // speed ?
        rl.Vector2{position.x + 32.0, position.y + 5},
        14,
        1,
        text_color_dark,
    )
}


// assumes value is between 0 & 1
gui_slider :: proc(position: [2]f32, value: ^f32, min: f32, max: f32) {
    value^ = clamp(value^, min, max)
    fraction := (value^ - min) / (max - min)

    mouse_point := rl.GetMousePosition()

    width: f32 = 146
    height: f32 = 24

    bounds := rl.Rectangle{position.x, position.y, width, height}

    // use position to determine if this is the active slider
    is_active := active_slider_position.x == position.x && active_slider_position.y == position.y

    if exclusive_control_mode && is_active {
        // still dragging
        if rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
            fraction = clamp(mouse_point.x - position.x, 0, width) / width
            value^ = math.lerp(min, max, fraction)
        } else {
            exclusive_control_mode = false
            active_slider_position = {}
        }
    } else if rl.CheckCollisionPointRec(mouse_point, bounds) {
        // start drag
        if !exclusive_control_mode && rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
            exclusive_control_mode = true
            active_slider_position = position
            fraction = clamp(mouse_point.x - position.x, 0, width) / width
            value^ = math.lerp(min, max, fraction)
        } else {
            wheel := rl.GetMouseWheelMove()
            if wheel != 0 {
                fraction = clamp(fraction - wheel * 0.05, 0, 1)
                value^ = math.lerp(min, max, fraction)
            }
        }
    }

    slider_position: f32 = fraction * width

    // Draw the slider background
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{240, 48, width * 2, height * 2},
        rl.Rectangle{position.x, position.y, width, height},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    // Draw the filled (highlighted) area
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{240, 96, slider_position * 2, height * 2},
        rl.Rectangle{position.x, position.y, slider_position, height},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
}

gui_button :: proc(bounds: rl.Rectangle) -> bool {
    mouse_point := rl.GetMousePosition()
    if rl.CheckCollisionPointRec(mouse_point, bounds) && !exclusive_control_mode {
        if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
            return true
        }
    }
    return false
}


GuiOption :: struct {
    id:    i32,
    label: string,
}

gui_dropdown :: proc(
    position: [2]f32,
    width: f32,
    options: []GuiOption,
    selected_idx: ^int,
    edit_mode: bool,
    left_pad: f32 = 12,
) -> bool {
    edit_mode := edit_mode
    btn_bounds := rl.Rectangle{position.x, position.y, width, 24}

    // TODO: make it either a prop or depend on actual width
    max_text_len := 25

    // Draw the button
    {
        // Draw the left part of the dropdown button
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, width * 2, 48},
            rl.Rectangle{position.x, position.y, width - 16, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        // Draw the rounded cap on the right side
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, -32, 48},
            rl.Rectangle{position.x + width - 16, position.y, 16, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        // Draw the triangle icon
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{128, 192, 32, 32},
            rl.Rectangle{position.x + width - 20, position.y + 4, 16, 16},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
    }

    if selected_idx != nil {
        label := strings.cut(options[selected_idx^].label, 0, max_text_len)
        rl.DrawTextEx(
            font_store.medium_28,
            fmt.ctprintf("%s", label),
            {position.x + left_pad, position.y + 5},
            14,
            1,
            text_color_light,
        )
    }

    // menu height without the top & bottom caps
    menu_height := f32(len(options) * 24)
    menu_bounds := rl.Rectangle{position.x, position.y - menu_height - 30, width, menu_height + 30}

    mouse_point := rl.GetMousePosition()

    if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
        if edit_mode {
            // clicked outside
            if !rl.CheckCollisionPointRec(mouse_point, menu_bounds) {
                edit_mode = false
                exclusive_control_mode = false
            }
        } else {
            if !exclusive_control_mode && rl.CheckCollisionPointRec(mouse_point, btn_bounds) {
                edit_mode = true
                exclusive_control_mode = true
            }
        }
    }

    // Draw the dropdown menu
    if edit_mode {
        menu_position := rl.Vector2{position.x, position.y - menu_height - 30}

        // Top cap
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, width * 2, 24},
            rl.Rectangle{menu_position.x, menu_position.y, width - 16, 12},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, -32, 24},
            rl.Rectangle{position.x + width - 16, menu_position.y, 16, 12},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )

        rl.DrawRectangleV(
            {menu_position.x, menu_position.y + 12},
            {width, menu_height},
            rl.GetColor(0x2D2E35FF),
        )

        // Bottom cap
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, width * 2, -24},
            rl.Rectangle{menu_position.x, menu_position.y + 12 + menu_height, width - 16, 12},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 144, -32, -24},
            rl.Rectangle{menu_position.x + width - 16, menu_position.y + 12 + menu_height, 16, 12},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        // debug
        // rl.DrawRectangleLinesEx(menu_bounds, 1.0, rl.ORANGE)

        for opt, i in options {
            option_bounds := rl.Rectangle {
                menu_position.x,
                menu_position.y + 12 + f32(i * 24),
                width,
                24,
            }

            hover := false

            if edit_mode && rl.CheckCollisionPointRec(mouse_point, option_bounds) {
                hover = true
                if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
                    edit_mode = false
                    exclusive_control_mode = false
                    selected_idx^ = i
                }
            }

            if hover {
                rl.DrawRectangleV(
                    {option_bounds.x, option_bounds.y},
                    {option_bounds.width, option_bounds.height},
                    rl.GetColor(0x15141BFF),
                )
            }

            text_pos := rl.Vector2{option_bounds.x + 12, option_bounds.y + 4}
            label := strings.cut(opt.label, 0, max_text_len)
            rl.DrawTextEx(
                font_store.medium_28,
                fmt.ctprintf("%s", label),
                text_pos,
                14,
                1,
                rl.GetColor(0xFFFFFFFF) if hover else text_color_light,
            )
        }
    }

    return edit_mode
}

draw_note :: proc(note: core.Note, pos: [2]f32, color: rl.Color, hide_accidental: bool = false) {
    if note.frequency == 0 do return

    // Note name
    rl.DrawTextEx(font_store.medium_256, fmt.ctprintf("%v", note.name), pos, 128, 0, color)

    // Sharp sign
    if note.is_accidental && !hide_accidental {
        rl.DrawTextEx(font_store.noto_medium_96, "♯", {pos.x + 76, pos.y + 12}, 48, 0, color)
    }

    // Octave number
    rl.DrawTextEx(
        font_store.medium_76,
        fmt.ctprintf("%v", note.octave),
        {pos.x + 76, pos.y + 72},
        38,
        0,
        color,
    )

    // Frequency
    // rl.DrawTextEx(
    //     font_store.medium_32,
    //     fmt.ctprintf("%.1f", note.frequency),
    //     {pos.x + 112, pos.y + 90},
    //     16,
    //     0,
    //     rl.GetColor(0x7D7E8FFF),
    // )
}


// TODO: show cents deviation as a graph

// draw_cent_deviation :: proc(
//     phase_comparator: ^core.PhaseComparator,
//     rect: rl.Rectangle,
//     max_samples: int,
// ) {
//     rl.DrawRectangleLinesEx(rect, 1.0, rl.ORANGE)

//     data_points := phase_comparator.data_points
//     x: f32 = rect.x
//     y: f32 = rect.y + rect.height * 0.5

//     dx := rect.width / f32(max_samples - 1)
//     i := phase_comparator.data_points_head

//     draw_point :: proc(x: f32, y: f32, value: f32, alpha: f32) {
//         rl.DrawPixelV({x, y - value}, rl.ColorAlpha(rl.GREEN, alpha))
//     }
//     limit := rect.x + rect.width

//     for i >= 0 && x <= limit {
//         draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
//         x += dx * f32(data_points[i].sample_count)
//         i -= 1
//     }

//     i = len(data_points) - 1

//     for i > phase_comparator.data_points_head && x <= limit {
//         draw_point(x, y, data_points[i].err_cents, data_points[i].amp)
//         x += dx * f32(data_points[i].sample_count)
//         i -= 1
//     }

//     rl.DrawLineV({rect.x, y}, {rect.x + rect.width, y}, rl.LIGHTGRAY)
// }
