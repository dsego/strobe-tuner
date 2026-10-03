// Copyright (C) 2025  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


// The input on Android, through AAudio. The same procs as audio_capture.odin, which uses miniaudio
// everywhere else. Like iOS there's one input, the system routes it: built-in mic, headset or a USB
// interface.
#+build linux:android
package app

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
import sdl "vendor:sdl3"

import "../core"


AudioCapture :: struct {
    stream:             ^AAudioStream,
    device_open:        bool,
    active_device:      i32, // always 0, the one input
    nodes:              [dynamic]^core.AudioCaptureNode,
    samplerate:         u32,

    // Set from AAudio's thread when the stream was disconnected, a headset plugged in or out, then it's
    // opened again
    interruption_ended: bool,
}

MicrophonePermission :: enum i32 {
    UNKNOWN,
    GRANTED,
    DENIED,
}

// Set from SDL's thread when the permission dialog is answered
microphone_permission: MicrophonePermission
// Set with the permission granted, the input is opened then
microphone_granted: bool

audio_device_count :: proc(self: ^AudioCapture) -> i32 {
    return 1
}

audio_device_name :: proc(self: ^AudioCapture, device_index: i32) -> string {
    return "Microphone"
}

switch_audio_device :: proc(self: ^AudioCapture, device_index: i32) {
    close_device(self)

    // Flush ring buffers to discard stale samples from the previous stream
    for node in self.nodes {
        core.flush_audio_capture_ringbuffer(node)
    }

    if open_stream_on_active_device(self) {
        start_audio_capture(self)
    }
}

open_stream_on_active_device :: proc(self: ^AudioCapture) -> bool {
    // Opened once the microphone is allowed, see allow_microphone
    if intrinsics.atomic_load(&microphone_permission) != .GRANTED do return false

    // Unprocessed has no automatic gain or noise suppression, not every phone has it. Voice recognition
    // is the next least processed.
    for preset in ([]AAudioInputPreset{.UNPROCESSED, .VOICE_RECOGNITION}) {
        builder: ^AAudioStreamBuilder
        if failed(AAudio_createStreamBuilder(&builder)) do return false
        defer AAudioStreamBuilder_delete(builder)

        AAudioStreamBuilder_setDirection(builder, .INPUT)
        AAudioStreamBuilder_setFormat(builder, .PCM_FLOAT)
        AAudioStreamBuilder_setChannelCount(builder, 1)
        AAudioStreamBuilder_setSampleRate(builder, i32(self.samplerate))
        AAudioStreamBuilder_setPerformanceMode(builder, .LOW_LATENCY)
        AAudioStreamBuilder_setInputPreset(builder, preset)
        AAudioStreamBuilder_setDataCallback(builder, stream_callback, self)
        AAudioStreamBuilder_setErrorCallback(builder, error_callback, self)

        if !failed(AAudioStreamBuilder_openStream(builder, &self.stream)) {
            self.device_open = true
            fmt.println("Opened input stream, preset", preset, "at", AAudioStream_getSampleRate(self.stream), "Hz")
            return true
        }
    }
    return false
}


// Asks for the microphone, the input opens once it's allowed
init_audio_capture :: proc(samplerate: u32) -> (self: ^AudioCapture, ok: bool) {
    self = new(AudioCapture)
    self.samplerate = samplerate
    allow_microphone()
    return self, true
}


start_audio_capture :: proc(self: ^AudioCapture) -> bool {
    if !self.device_open do return false
    if failed(AAudioStream_requestStart(self.stream)) do return false

    fmt.println("Started input stream")
    return true
}

stop_audio_capture :: proc(self: ^AudioCapture) {
    if !self.device_open do return
    if failed(AAudioStream_requestStop(self.stream)) do return

    fmt.println("Stopped input stream")
}

// Whether the input has to be opened again since the last call
audio_interruption_ended :: proc(self: ^AudioCapture) -> bool {
    granted := intrinsics.atomic_exchange(&microphone_granted, false)
    return intrinsics.atomic_exchange(&self.interruption_ended, false) || granted
}

register_audio_node :: proc(self: ^AudioCapture, node: ^core.AudioCaptureNode) {
    append(&self.nodes, node)
}

close_device :: proc(self: ^AudioCapture) {
    if !self.device_open do return
    // Stops the stream and waits for any in-flight callback to finish
    failed(AAudioStream_close(self.stream))
    self.stream = nil
    self.device_open = false
    fmt.println("Closed input stream")
}

destroy_audio_capture :: proc(self: ^AudioCapture) {
    close_device(self)
    delete(self.nodes)
    free(self)
}


stream_callback :: proc "c" (
    stream: ^AAudioStream,
    userdata: rawptr,
    audio_data: rawptr,
    frame_count: i32,
) -> AAudioCallbackResult {
    context = runtime.default_context()
    self := cast(^AudioCapture)userdata
    samples := slice.from_ptr(cast([^]f32)audio_data, int(frame_count))

    // The input as it is to every node, the pitch detection filters its own
    for node in self.nodes do core.audio_capture_write(node, samples)
    return .CONTINUE
}

// A disconnected stream stays dead, it's opened again from the main loop, not from AAudio's thread
error_callback :: proc "c" (stream: ^AAudioStream, userdata: rawptr, error: AAudioResult) {
    self := cast(^AudioCapture)userdata
    intrinsics.atomic_store(&self.interruption_ended, true)
}


// Asks for the microphone, answered right away when it was allowed before, else after the system's
// dialog. After two denials Android stops asking and only the app's page in its settings can allow it.
allow_microphone :: proc() {
    permission_answered :: proc "c" (userdata: rawptr, permission: cstring, granted: bool) {
        intrinsics.atomic_store(&microphone_permission, MicrophonePermission.GRANTED if granted else .DENIED)
        if granted do intrinsics.atomic_store(&microphone_granted, true)
    }
    if !sdl.RequestAndroidPermission("android.permission.RECORD_AUDIO", permission_answered, nil) {
        fmt.println("Couldn't ask for the microphone:", sdl.GetError())
    }
}

microphone_denied :: proc() -> bool {
    return intrinsics.atomic_load(&microphone_permission) == .DENIED
}

// Prints what went wrong
failed :: proc(result: AAudioResult) -> bool {
    if result >= .OK do return false
    fmt.println("AAudio error:", AAudio_convertResultToText(result))
    return true
}


// The part of AAudio used here, from the NDK's aaudio/AAudio.h

AAudioStream :: struct {}
AAudioStreamBuilder :: struct {}

AAudioResult :: enum i32 {
    OK                 = 0,
    ERROR_DISCONNECTED = -899,
}

AAudioDirection :: enum i32 {
    OUTPUT = 0,
    INPUT  = 1,
}

AAudioFormat :: enum i32 {
    PCM_I16   = 1,
    PCM_FLOAT = 2,
}

AAudioPerformanceMode :: enum i32 {
    NONE         = 10,
    POWER_SAVING = 11,
    LOW_LATENCY  = 12,
}

AAudioInputPreset :: enum i32 {
    GENERIC             = 1,
    CAMCORDER           = 5,
    VOICE_RECOGNITION   = 6,
    VOICE_COMMUNICATION = 7,
    UNPROCESSED         = 9,
}

AAudioCallbackResult :: enum i32 {
    CONTINUE = 0,
    STOP     = 1,
}

AAudioDataCallback :: #type proc "c" (
    stream: ^AAudioStream,
    userdata: rawptr,
    audio_data: rawptr,
    frame_count: i32,
) -> AAudioCallbackResult
AAudioErrorCallback :: #type proc "c" (stream: ^AAudioStream, userdata: rawptr, error: AAudioResult)

foreign import aaudio "system:aaudio"

@(default_calling_convention = "c")
foreign aaudio {
    AAudio_createStreamBuilder :: proc(builder: ^^AAudioStreamBuilder) -> AAudioResult ---
    AAudio_convertResultToText :: proc(result: AAudioResult) -> cstring ---
    AAudioStreamBuilder_setDirection :: proc(builder: ^AAudioStreamBuilder, direction: AAudioDirection) ---
    AAudioStreamBuilder_setFormat :: proc(builder: ^AAudioStreamBuilder, format: AAudioFormat) ---
    AAudioStreamBuilder_setChannelCount :: proc(builder: ^AAudioStreamBuilder, channel_count: i32) ---
    AAudioStreamBuilder_setSampleRate :: proc(builder: ^AAudioStreamBuilder, sample_rate: i32) ---
    AAudioStreamBuilder_setPerformanceMode :: proc(builder: ^AAudioStreamBuilder, mode: AAudioPerformanceMode) ---
    AAudioStreamBuilder_setInputPreset :: proc(builder: ^AAudioStreamBuilder, preset: AAudioInputPreset) ---
    AAudioStreamBuilder_setDataCallback :: proc(builder: ^AAudioStreamBuilder, callback: AAudioDataCallback, userdata: rawptr) ---
    AAudioStreamBuilder_setErrorCallback :: proc(builder: ^AAudioStreamBuilder, callback: AAudioErrorCallback, userdata: rawptr) ---
    AAudioStreamBuilder_openStream :: proc(builder: ^AAudioStreamBuilder, stream: ^^AAudioStream) -> AAudioResult ---
    AAudioStreamBuilder_delete :: proc(builder: ^AAudioStreamBuilder) -> AAudioResult ---
    AAudioStream_requestStart :: proc(stream: ^AAudioStream) -> AAudioResult ---
    AAudioStream_requestStop :: proc(stream: ^AAudioStream) -> AAudioResult ---
    AAudioStream_close :: proc(stream: ^AAudioStream) -> AAudioResult ---
    AAudioStream_getSampleRate :: proc(stream: ^AAudioStream) -> i32 ---
}
