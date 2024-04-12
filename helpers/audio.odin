package helpers

import "core:fmt"
import ma "vendor:miniaudio"


read_wav :: proc(path: cstring, from: u64, frames_to_read: u64, samples: []f32) {
    assert(frames_to_read <= u64(len(samples)), "`frames_to_read` should be less or equal to samples length")

    decoder: ma.decoder
    config := ma.decoder_config_init(ma.format.f32, 1, 44100)
    if ma.decoder_init_file(path, &config, &decoder) != ma.result.SUCCESS {
        fmt.println("Failed to decode wav file '%s'.", path)
        return
    }
    defer ma.decoder_uninit(&decoder)

    ma.decoder_seek_to_pcm_frame(&decoder, from)
    ma.decoder_read_pcm_frames(&decoder, raw_data(samples), frames_to_read, nil)
}
