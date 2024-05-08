package pattern

import "core:fmt"
import glm "core:math/linalg/glsl"
import "core:time"

import SDL "vendor:sdl2"
import gl "vendor:OpenGL"

GL_VERSION_MAJOR :: 3
GL_VERSION_MINOR :: 3


sdl_version :: proc() {
    WINDOW_WIDTH  :: 854
    WINDOW_HEIGHT :: 480

    SDL.Init({.VIDEO})
    defer SDL.Quit()

    window := SDL.CreateWindow("Odin SDL2 Demo", SDL.WINDOWPOS_UNDEFINED, SDL.WINDOWPOS_UNDEFINED, WINDOW_WIDTH, WINDOW_HEIGHT, {.OPENGL})
    if window == nil {
        fmt.eprintln("Failed to create window")
        return
    }
    defer SDL.DestroyWindow(window)

    SDL.GL_SetAttribute(.CONTEXT_PROFILE_MASK,  i32(SDL.GLprofile.CORE))
    SDL.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, GL_VERSION_MAJOR)
    SDL.GL_SetAttribute(.CONTEXT_MINOR_VERSION, GL_VERSION_MINOR)

    gl_context := SDL.GL_CreateContext(window)
    defer SDL.GL_DeleteContext(gl_context)

    // load the OpenGL procedures once an OpenGL context has been established
    gl.load_up_to(GL_VERSION_MAJOR, GL_VERSION_MINOR, SDL.gl_set_proc_address)

    // useful utility procedures that are part of vendor:OpenGl
    program, program_ok := gl.load_shaders_source(vertex_source, fragment_source)
    if !program_ok {
        fmt.eprintln("Failed to create GLSL program")
        return
    }
    defer gl.DeleteProgram(program)

    gl.UseProgram(program)




    uniforms := gl.get_uniforms_from_program(program)
    defer delete(uniforms)

    vao: u32
    gl.GenVertexArrays(1, &vao)
    defer gl.DeleteVertexArrays(1, &vao)
    gl.BindVertexArray(vao)

    // initialization of OpenGL buffers
    vbo, ebo: u32
    gl.GenBuffers(1, &vbo); defer gl.DeleteBuffers(1, &vbo)
    gl.GenBuffers(1, &ebo); defer gl.DeleteBuffers(1, &ebo)

    Vertex :: struct {
        pos: glm.vec3,
        tex: glm.vec2,
    }

    vertices := []Vertex{
        {{-0.5, 0.5, 0}, {0.0, 0.0}},
        {{-0.5, -0.5, 0}, {0.0, 1.0}},
        {{0.5, -0.5, 0}, {1.0, 1.0}},
        {{0.5, 0.5, 0}, {1.0, 1.0}},
    }

    indices := []u16{
        0, 1, 2,
        2, 3, 0,
    }


    gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
    gl.BufferData(gl.ARRAY_BUFFER, len(vertices)*size_of(vertices[0]), raw_data(vertices), gl.STATIC_DRAW)

    gl.VertexAttribPointer(
        index=0,
        size=3,
        type=gl.FLOAT,
        normalized=false,
        stride=size_of(Vertex),
        pointer=offset_of(Vertex, pos)
    )
    gl.VertexAttribPointer(
        index=1,
        size=2,
        type=gl.FLOAT,
        normalized=false,
        stride=size_of(Vertex),
        pointer=offset_of(Vertex, tex)
    )


    gl.EnableVertexAttribArray(0)
    gl.EnableVertexAttribArray(1)

    gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo)
    gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(indices)*size_of(indices[0]), raw_data(indices), gl.STATIC_DRAW)




    data_buffer: []Pixel = make([]Pixel, 256)
    defer delete(data_buffer)

    for i in 0..<len(data_buffer) {
        data_buffer[i] = Pixel {u8(i), 0, 0, 0}
    }


    texture: u32
    gl.GenTextures(1, &texture)
    gl.BindTexture(gl.TEXTURE_2D, texture)


    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexImage2D(
        target=gl.TEXTURE_2D,
        level=0,
        internalformat=gl.RGBA,
        width=i32(len(data_buffer)),
        height=1,
        border=0,
        format=gl.RGBA,
        type=gl.UNSIGNED_BYTE,
        pixels=nil,
    )

    gl.Uniform1i(uniforms["textureSampler"].location, 0)

    loop: for {
        // event polling
        event: SDL.Event
        for SDL.PollEvent(&event) {
            // #partial switch tells the compiler not to error if every case is not present
            #partial switch event.type {
            case .QUIT:
                // labelled control flow
                break loop
            }
        }

        gl.Viewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT)
        gl.ClearColor(0.0, 0.0, 0.0, 1.0)
        gl.Clear(gl.COLOR_BUFFER_BIT)

        gl.ActiveTexture(gl.TEXTURE0)
        gl.Uniform1i(gl.GetUniformLocation(program, "textureSampler"), 0)


        gl.TexSubImage2D(
            target=gl.TEXTURE_2D,
            level=0,
            xoffset=0,
            yoffset=0,
            width=i32(len(data_buffer)),
            height=1,
            format=gl.RGBA,
            type=gl.UNSIGNED_BYTE,
            pixels=&data_buffer[0],
        )

        gl.DrawElements(gl.TRIANGLES, i32(len(indices)), gl.UNSIGNED_SHORT, nil)

        SDL.GL_SwapWindow(window)
    }
}

@(private="file")
vertex_source :: `
    #version 330

    layout (location = 0) in vec3 vertexPosition;
    layout (location = 1) in vec2 vertexTexCoord;
    out vec2 fragCoord;

    void main() {
        gl_Position = vec4(vertexPosition, 1.0);
        fragCoord = vertexTexCoord;
    }
`

@(private="file")
fragment_source :: `
    #version 330

    uniform sampler2D textureSampler;

    in vec2 fragCoord;
    out vec4 finalColor;

    void main()
    {
        vec4 tex = texture(textureSampler, vec2(fragCoord.x, 0.));
        finalColor = vec4(tex.x, tex.x, tex.x, 1.);
    }
`
