package shared

AudioCaptureNode :: struct {
    stream_callback: proc (ctx: ^AudioCaptureNode, input: []f32),
}
