package portaudio

foreign import lib "portaudio.a"

import "core:c"

VersionInfo :: struct {
    versionMajor: i32,
    versionMinor: i32,
    versionSubMinor: i32,
    versionControlRevision: cstring,
    versionText: cstring,
}

NoDevice :: -1
UseHostApiSpecificDeviceSpecification :: -2

HostApiIndex :: i32
DeviceIndex :: i32
Error :: i32
Time :: f64
SampleFormat :: c.ulong

ErrorCode :: enum i32 {
    NoError = 0,
    NotInitialized = -10000,
    UnanticipatedHostError,
    InvalidChannelCount,
    InvalidSampleRate,
    InvalidDevice,
    InvalidFlag,
    SampleFormatNotSupported,
    BadIODeviceCombination,
    InsufficientMemory,
    BufferTooBig,
    BufferTooSmall,
    NullCallback,
    BadStreamPtr,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    IncompatibleHostApiSpecificStreamInfo,
    StreamIsStopped,
    StreamIsNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    CanNotReadFromACallbackStream,
    CanNotWriteToACallbackStream,
    CanNotReadFromAnOutputOnlyStream,
    CanNotWriteToAnInputOnlyStream,
    IncompatibleStreamHostApi,
    BadBufferPtr,
    CanNotInitializeRecursively,
}

HostApiTypeId :: enum i32 {
    paInDevelopment=0, /* use while developing support for a new host API */
    paDirectSound=1,
    paMME=2,
    paASIO=3,
    paSoundManager=4,
    paCoreAudio=5,
    paOSS=7,
    paALSA=8,
    paAL=9,
    paBeOS=10,
    paWDMKS=11,
    paJACK=12,
    paWASAPI=13,
    paAudioScienceHPI=14,
    paAudioIO=15,
    paPulseAudio=16,
    paSndio=17
}


HostApiInfo :: struct {
    structVersion: i32,
    name: cstring,
    deviceCount: int,
    defaultInputDevice: DeviceIndex,
    defaultOutputDevice: DeviceIndex,
}


HostErrorInfo :: struct {
    hostApiType: HostApiTypeId,
    errorCode: c.long,
    errorText : cstring,
}

DeviceInfo :: struct {
    structVersion: i32,
    name: cstring,
    hostApi: HostApiIndex,
    maxInputChannels: i32,
    maxOutputChannels: i32,
    defaultLowInputLatency: Time,
    defaultLowOutputLatency: Time,
    defaultHighInputLatency: Time,
    defaultHighOutputLatency: Time,
    defaultSampleRate: f64,
}


StreamParameters :: struct {
    device: DeviceIndex,
    channelCount: i32,
    sampleFormat: SampleFormat,
    suggestedLatency: Time,
    hostApiSpecificStreamInfo: rawptr,

}



@(default_calling_convention="c", link_prefix="Pa_")
foreign lib {
    GetVersion :: proc() ---
    GetVersionText :: proc() -> cstring ---
    GetVersionInfo :: proc() -> ^VersionInfo ---
    GetErrorText :: proc(errorCode: Error) -> cstring ---

    Initialize :: proc() -> Error ---
    Terminate :: proc() -> Error ---

    GetHostApiCount :: proc() -> HostApiIndex ---
    GetDefaultHostApi :: proc() -> HostApiIndex ---

    GetHostApiInfo :: proc(hostApi: HostApiIndex) -> ^HostApiInfo ---
    HostApiTypeIdToHostApiIndex :: proc(type: HostApiTypeId) -> HostApiIndex ---
    HostApiDeviceIndexToDeviceIndex :: proc(hostApi: HostApiIndex, hostApiDeviceIndex: i32) -> DeviceIndex ---

    GetLastHostErrorInfo :: proc () -> ^HostErrorInfo ---
    GetDeviceCount :: proc () -> DeviceIndex ---
    GetDefaultInputDevice :: proc () -> DeviceIndex ---
    GetDefaultOutputDevice :: proc () -> DeviceIndex ---
    GetDeviceInfo :: proc (device: DeviceIndex) -> ^DeviceInfo ---

    IsFormatSupported :: proc (inputParameters: ^StreamParameters, outputParameters: ^StreamParameters, sampleRate: f64) -> Error ---

}
