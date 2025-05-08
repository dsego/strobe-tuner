package app

import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"


font: rl.Font

init_font :: proc(font_size: i32) {
    font_atlas: cstring = "ABCDEFGHIJKLMNOPQRSTUVWYZabcdefghijklmnopqrstuwvxyzz♯♭/+-1234567890.:π!"
    count := i32(0)
    codepoints := rl.LoadCodepoints(font_atlas, &count)
    defer rl.UnloadCodepoints(codepoints)

    // Root directory relative to this file
    root_dir := filepath.dir(#file)
    defer delete(root_dir)

    path := filepath.join({root_dir, "../assets/NotoSansMono-Medium.ttf"})
    defer delete(path)

    // TODO - use #load and LoadFontFromMemory
    // https://odin-lang.org/docs/overview/#loadstring-path-or-loadstring-path-type
    font = rl.LoadFontEx(cstring(raw_data(path)), font_size, codepoints, count)
}

destroy_font :: proc() {
    rl.UnloadFont(font)
}
