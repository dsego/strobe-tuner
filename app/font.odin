package app

import "core:path/filepath"
import "core:strings"
import rl "vendor:raylib"


FontStore :: struct {
    // regular
    medium_24:  rl.Font,
    medium_28:  rl.Font,
    medium_32:  rl.Font,
    medium_48:  rl.Font,
    medium_76:  rl.Font,
    medium_192: rl.Font,
    medium_256: rl.Font,

    // Note: Inter doesn't support the sharp sign ♯
    noto_medium_96: rl.Font,

    // bold
    bold_32: rl.Font,
    bold_36: rl.Font,
}

font_store: FontStore


init_fonts :: proc() {
    inter_medium := #load("../assets/Inter-Medium.ttf")
    inter_bold := #load("../assets/Inter-Bold.ttf")
    noto_sans_mono := #load("../assets/NotoSansMono-Medium.ttf")

    font_atlas: cstring = "ABCDEFGHIJKLMNOPQRSTUVWYZabcdefghijklmnopqrstuwvxyzz♯♭/+-1234567890.:π!▶︎◀︎|"
    count := i32(0)
    codepoints := rl.LoadCodepoints(font_atlas, &count)
    defer rl.UnloadCodepoints(codepoints)

    font_store.medium_24 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        24,
        codepoints,
        count,
    )

    font_store.medium_28 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        28,
        codepoints,
        count,
    )

    font_store.medium_32 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        32,
        codepoints,
        count,
    )

    font_store.medium_48 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        192,
        codepoints,
        count,
    )

    font_store.medium_76 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        76,
        codepoints,
        count,
    )

    font_store.medium_192 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        192,
        codepoints,
        count,
    )

    font_store.medium_256 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_medium),
        i32(len(inter_medium)),
        256,
        codepoints,
        count,
    )


    font_store.bold_32 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_bold),
        i32(len(inter_bold)),
        32,
        codepoints,
        count,
    )

    font_store.bold_36 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(inter_bold),
        i32(len(inter_bold)),
        36,
        codepoints,
        count,
    )

    font_store.noto_medium_96 = rl.LoadFontFromMemory(
        ".ttf",
        raw_data(noto_sans_mono),
        i32(len(noto_sans_mono)),
        92,
        codepoints,
        count,
    )



    // rl.SetTextureFilter(font_store.medium_24.texture, rl.TextureFilter.TRILINEAR)
    // rl.SetTextureFilter(font_store.medium_32.texture, rl.TextureFilter.TRILINEAR)
    // rl.SetTextureFilter(font_store.medium_48.texture, rl.TextureFilter.TRILINEAR)
    // rl.SetTextureFilter(font_store.medium_76.texture, rl.TextureFilter.TRILINEAR)
    // rl.SetTextureFilter(font_store.medium_192.texture, rl.TextureFilter.TRILINEAR)
}

destroy_fonts :: proc() {
    rl.UnloadFont(font_store.medium_24)
    rl.UnloadFont(font_store.medium_28)
    rl.UnloadFont(font_store.medium_32)
    rl.UnloadFont(font_store.medium_48)
    rl.UnloadFont(font_store.medium_76)
    rl.UnloadFont(font_store.medium_192)
    rl.UnloadFont(font_store.medium_256)
    rl.UnloadFont(font_store.bold_32)
    rl.UnloadFont(font_store.bold_36)
    rl.UnloadFont(font_store.noto_medium_96)
}
