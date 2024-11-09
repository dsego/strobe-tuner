package shared

AudioCaptureNode :: struct {
    stream_callback: proc "c" (ctx: ^AudioCaptureNode, input: []f32),
}
