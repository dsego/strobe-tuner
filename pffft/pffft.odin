package pffft

// clang -fPIC pffft.c -shared -o pffft.dylib -O3
foreign import lib "pffft.dylib"

direction_t :: enum {
    FORWARD,
    BACKWARD,
}

transform_t :: enum {
    REAL,
    COMPLEX,
}

@(default_calling_convention="c", link_prefix="pffft_")
foreign lib {
    new_setup :: proc(N: int, transform: transform_t) -> rawptr ---
    destroy_setup :: proc(setup: rawptr) ---
    transform :: proc(setup: rawptr, input: [^]f32, output: [^]f32, work: [^]f32, direction: direction_t) ---
    transform_ordered :: proc(setup: rawptr, input: [^]f32, output: [^]f32, work: [^]f32, direction: direction_t) ---
    zreorder :: proc(setup, input: [^]f32, output: [^]f32, direction: direction_t) ---
    zconvolve_accumulate :: proc(setup, dft_a: [^]f32, dft_b: [^]f32, dft_ab: [^]f32, scaling: f32) ---
    aligned_malloc :: proc(nb_bytes: uint) -> rawptr ---
    aligned_free :: proc(setup: rawptr) ---
    simd_size :: proc() -> int ---
}
