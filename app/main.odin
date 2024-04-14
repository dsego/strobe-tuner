package app

import "core:fmt"

main :: proc() {
    audio_capture, ok := init_audio_capture()
    if !ok {
        return
    }
    defer destroy_audio_capture(audio_capture)

    run_app()
}



