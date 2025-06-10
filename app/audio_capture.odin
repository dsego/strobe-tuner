package app

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"


import pa "../vendor/odin-portaudio"

import "../core"


AudioCapture :: struct {
    active_device: i32,
    stream:        ^pa.Stream,
    nodes:         [dynamic]^core.AudioCaptureNode,
    samplerate:    u32,
}


// TODO: list only input devices
list_audio_devices :: proc(self: ^AudioCapture) -> [dynamic]string {
    device_list: [dynamic]string = {}
    device_count := pa.GetDeviceCount()
    for i in 0 ..< device_count {
        info := pa.GetDeviceInfo(i)
        append(&device_list, string(info.name))
    }
    return device_list
}


switch_audio_device :: proc(self: ^AudioCapture, device_index: i32) {
    pa.AbortStream(self.stream)

    self.active_device = device_index
    info := pa.GetDeviceInfo(device_index)

    fmt.println("Switching audio device to: ", info.name)

    open_stream_on_active_device(self)
    start_audio_capture(self)
}

open_stream_on_active_device :: proc(self: ^AudioCapture) -> bool {
    stream_params := pa.StreamParameters {
        device                    = self.active_device,
        channelCount              = 1,
        sampleFormat              = pa.Float32,
        suggestedLatency          = pa.GetDeviceInfo(self.active_device).defaultLowInputLatency,
        hostApiSpecificStreamInfo = nil,
    }

    err := pa.OpenStream(
        stream = &self.stream,
        inputParameters = &stream_params,
        outputParameters = nil,
        sampleRate = f64(self.samplerate),
        framesPerBuffer = pa.FramesPerBufferUnspecified,
        streamFlags = 0,
        streamCallback = stream_callback,
        userData = self,
    )

    if check(err) do return false

    fmt.println("Opened input stream")

    return true
}


// TODO can't listen to default input device refresh without hotplug
// https://github.com/PortAudio/portaudio/wiki/HotPlug
init_audio_capture :: proc(samplerate: u32) -> (bool, ^AudioCapture) {
    err: pa.Error

    self := new(AudioCapture)
    self.samplerate = samplerate

    err = pa.Initialize()
    if check(err) do return false, self

    fmt.println("Initialized PortAudio")

    device_count := pa.GetDeviceCount()
    self.active_device = pa.GetDefaultInputDevice()

    for i in 0 ..< device_count {
        info := pa.GetDeviceInfo(i)
        str := "  %v  ‣  %s (%v ch)\n"
        if i == self.active_device {
            str = "  %v [‣] %s (%v ch)\n"
        }
        fmt.printf(str, i, info.name, info.maxInputChannels)
    }

    ok := open_stream_on_active_device(self)

    return ok, self
}


start_audio_capture :: proc(self: ^AudioCapture) -> bool {
    err: pa.Error

    err = pa.StartStream(self.stream)
    if check(err) do return false

    fmt.println("Started input stream")
    return true
}

register_audio_node :: proc(self: ^AudioCapture, node: ^core.AudioCaptureNode) {
    append(&self.nodes, node)
}


// TODO: remove node?

destroy_audio_capture :: proc(self: ^AudioCapture) {
    err: pa.Error

    err = pa.AbortStream(self.stream)
    check(err)
    fmt.println("Stopped input stream")

    err = pa.CloseStream(self.stream)
    check(err)
    fmt.println("Closed input stream")

    err = pa.Terminate()
    check(err)
    fmt.println("Terminated PortAudio")

    delete(self.nodes)
    free(self)
}


@(private)
stream_callback :: proc "c" (
    input: rawptr,
    output: rawptr,
    frameCount: c.ulong,
    timeInfo: ^pa.StreamCallbackTimeInfo,
    statusFlags: pa.StreamCallbackFlags,
    userData: rawptr,
) -> int {
    context = runtime.default_context()

    input_slice: []f32 = slice.from_ptr(cast([^]f32)input, int(frameCount))

    self := cast(^AudioCapture)userData

    // process all nodes
    for node in self.nodes {
        if node.stream_callback != nil {
            node.stream_callback(node, input_slice)
        }
    }

    return 0
}

check :: proc(err: pa.Error) -> bool {
    if pa.ErrorCode(err) != .NoError {
        fmt.println("PortAudio error: ", pa.GetErrorText(err))
        return true
    }
    return false
}
