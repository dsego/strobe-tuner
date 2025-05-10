package app

import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"


font: rl.Font


init_font :: proc(font_size: i32) {
    font_data := #load("../assets/NotoSansMono-Medium.ttf")

    font_atlas: cstring = "ABCDEFGHIJKLMNOPQRSTUVWYZabcdefghijklmnopqrstuwvxyzz♯♭/+-1234567890.:π!"
    count := i32(0)
    codepoints := rl.LoadCodepoints(font_atlas, &count)
    defer rl.UnloadCodepoints(codepoints)
    font = rl.LoadFontFromMemory(".ttf", raw_data(font_data), i32(len(font_data)), font_size, codepoints, count )
}

destroy_font :: proc() {
    rl.UnloadFont(font)
}
