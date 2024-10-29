package app


FRAGMENT_SHADER :: `
////////////////////////////////////////////

#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Output fragment color
out vec4 finalColor;

void main()
{
    finalColor = vec4(fragTexCoord.s, 0.0, 0.0, 1.0 );
}

////////////////////////////////////////////
`
