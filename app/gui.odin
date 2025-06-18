package app

import "core:fmt"
import "core:math"

import rl "vendor:raylib"

import "../core"


texture_atlas: rl.Texture2D

// position can serve as an ID for slider controls
active_slider_position: [2]f32 = {}
active_slider_mode := false
text_color := rl.GetColor(0x15141BFF)

load_texture_atlas :: proc() {
    file_data := #load("../assets/atlas.2x.png")
    image := rl.LoadImageFromMemory(".png", raw_data(file_data), i32(len(file_data)))
    texture_atlas = rl.LoadTextureFromImage(image)
    // rl.SetTextureFilter(texture_atlas, rl.TextureFilter.BILINEAR)
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
    text_color := rl.GetColor(0x15141BFF)

    if active_strobe_mode == .HARMONIC_MODE {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 96, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_28,
            "HARMONIC",
            rl.Vector2{position.x + 27.0, position.y + 5},
            14,
            0.5,
            text_color,
        )
    } else {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 0, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_28,
            "VERNIER",
            rl.Vector2{position.x + 32.0, position.y + 5},
            14,
            0.5,
            text_color,
        )
    }

    if gui_button({position.x, position.y, 120, 24}) {
        if active_strobe_mode == .HARMONIC_MODE do return .VERNIER_MODE, true
        else do return .HARMONIC_MODE, true
    }

    return active_strobe_mode, false
}


gui_note_detection_mode_toggle :: proc(
    position: [2]f32,
    active_detection_mode: NoteDetectionMode,
) -> (
    NoteDetectionMode,
    bool,
) {
    if active_detection_mode == .AUTO {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 48, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_28,
            "AUTO",
            rl.Vector2{position.x + 42.0, position.y + 5},
            14,
            0.5,
            text_color,
        )
    } else {
        rl.DrawTexturePro(
            texture_atlas,
            rl.Rectangle{0, 0, 240, 48},
            rl.Rectangle{position.x, position.y, 120, 24},
            rl.Vector2{0, 0},
            0,
            rl.WHITE,
        )
        rl.DrawTextEx(
            font_store.size_28,
            "MANUAL",
            rl.Vector2{position.x + 34.0, position.y + 5},
            14,
            0.5,
            text_color,
        )
    }

    if gui_button({position.x, position.y, 120, 24}) {
        if active_detection_mode == .AUTO do return .MANUAL, true
        else do return .AUTO, true
    }

    return active_detection_mode, false
}


gui_contrast_slider :: proc(position: [2]f32, value: ^f32) {
    gui_slider(position, value, 0.0, 5.0)
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{0, 192, 32, 32},
        rl.Rectangle{position.x + 6, position.y + 4, 16, 16},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTextEx(
        font_store.size_28,
        "CONTRAST",
        rl.Vector2{position.x + 32.0, position.y + 5},
        14,
        0.5,
        text_color,
    )
}

gui_speed_slider :: proc(position: [2]f32, value: ^f32) {
    gui_slider(position, value, 0.001, 0.05)
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{32, 192, 32, 32},
        rl.Rectangle{position.x + 6, position.y + 4, 16, 16},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTextEx(
        font_store.size_28,
        "SENSITIVITY", // speed ?
        rl.Vector2{position.x + 32.0, position.y + 5},
        14,
        0.5,
        text_color,
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

    if active_slider_mode && is_active {
        // still dragging
        if rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
            fraction = clamp(mouse_point.x - position.x, 0, width) / width
            value^ = math.lerp(min, max, fraction)
        } else {
            active_slider_mode = false
            active_slider_position = {}
        }
    } else if rl.CheckCollisionPointRec(mouse_point, bounds) {
        // start drag
        if !active_slider_mode && rl.IsMouseButtonDown(rl.MouseButton.LEFT) {
            active_slider_mode = true
            active_slider_position = position
            fraction = clamp(mouse_point.x - position.x, 0, width) / width
            value^ = math.lerp(min, max, fraction)
        }
    }

    slider_position: f32 = fraction * width

    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{240, 48, width * 2, height * 2},
        rl.Rectangle{position.x, position.y, width, height},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
    rl.DrawTexturePro(
        texture_atlas,
        rl.Rectangle{240, 96, slider_position * 2, height * 2},
        rl.Rectangle{position.x, position.y, slider_position, height},
        rl.Vector2{0, 0},
        0,
        rl.WHITE,
    )
}

// note_detection_mode_toggle


// rl.DrawTexture(texture_atlas, 10, 10, rl.WHITE)
// rl.DrawTexturePro(
//     texture_atlas,
//     rl.Rectangle{0, 48, 240, 48},
//     rl.Rectangle{0, 0, 120, 24},
//     rl.Vector2{-100, -400},
//     0,
//     rl.WHITE,
// )
// rl.DrawRectangleLines(100, 10, 120,24, rl.ORANGE)


gui_button :: proc(bounds: rl.Rectangle) -> bool {
    mouse_point := rl.GetMousePosition()
    if rl.CheckCollisionPointRec(mouse_point, bounds) {
        if rl.IsMouseButtonPressed(rl.MouseButton.LEFT) {
            return true
        }
    }
    return false
}


draw_note :: proc(note: core.Note, pos: [2]f32, color: rl.Color, hide_accidental: bool = false) {
    if note.frequency == 0 do return

    // Note name
    rl.DrawTextEx(font_store.size_192, fmt.ctprintf("%v", note.name), pos, 96, 0, color)

    // Sharp sign
    if note.is_accidental && !hide_accidental {
        rl.DrawTextEx(font_store.size_192, "♯", {pos.x + 48, pos.y + 12}, 38, 0, color)
    }

    // Octave number
    rl.DrawTextEx(
        font_store.size_192,
        fmt.ctprintf("%v", note.octave),
        {pos.x + 48, pos.y + 48},
        38,
        0,
        color,
    )
}


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
