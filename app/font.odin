package app

import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"


FontStore :: struct {
    _32:  rl.Font,
    _48:  rl.Font,
    _76:  rl.Font,
    _192: rl.Font,
}


font_store: FontStore


init_fonts :: proc() {
    font_data := #load("../assets/NotoSansMono-Medium.ttf")

    font_atlas: cstring = "ABCDEFGHIJKLMNOPQRSTUVWYZabcdefghijklmnopqrstuwvxyzz♯♭/+-1234567890.:π!▶︎◀︎|"
    count := i32(0)
    codepoints := rl.LoadCodepoints(font_atlas, &count)
    defer rl.UnloadCodepoints(codepoints)

    font_store._32 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(font_data),
        i32(len(font_data)),
        32,
        codepoints,
        count,
    )

    font_store._48 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(font_data),
        i32(len(font_data)),
        192,
        codepoints,
        count,
    )

    font_store._76 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(font_data),
        i32(len(font_data)),
        76,
        codepoints,
        count,
    )

    font_store._192 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(font_data),
        i32(len(font_data)),
        192,
        codepoints,
        count,
    )
}

destroy_fonts :: proc() {
    rl.UnloadFont(font_store._32)
    rl.UnloadFont(font_store._48)
    rl.UnloadFont(font_store._76)
    rl.UnloadFont(font_store._192)
}
