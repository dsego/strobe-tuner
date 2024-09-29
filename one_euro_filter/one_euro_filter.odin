package one_euro_filter


// SF1eFilter.a
foreign import lib "SF1eFilter.a"

// BUILD
// clang SF1eFilter.c SF1eFilter.h -c -O2 -Os -fPIC
// ar rcs SF1eFilter.a SF1eFilter.o

SFLowPassFilter :: struct {
    hatxprev: f32,
    xprev: f32,
    usedBefore: bool,
}

SF1eFilterConfiguration :: struct {
    frequency: f32,
    minCutoffFrequency: f32,
    cutoffSlope: f32,
    derivativeCutoffFrequency: f32,
}


SF1eFilter :: struct {
    config: SF1eFilterConfiguration,
    xfilt: SFLowPassFilter,
    dxfilt: SFLowPassFilter,
    lastTime: f64,
    frequency: f32,
}


@(default_calling_convention="c", link_prefix="SF1eFilter")
foreign lib {
    Create :: proc (
        frequency: f32,
        minCutoffFrequency: f32,
        cutoffSlope: f32,
        derivativeCutoffFrequency: f32,
    ) -> ^SF1eFilter ---
    Destroy :: proc (filter: ^SF1eFilter) ---
    Do :: proc (filter: ^SF1eFilter, x: f32) -> f32 ---
    DoAtTime :: proc (filter: ^SF1eFilter, x: f32, timestamp: f64) -> f32 ---
}
