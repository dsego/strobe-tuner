#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Output fragment color
out vec4 finalColor;

uniform vec2 shadow_dimensions;

// Author @kynd - 2016 (the book of shaders)
// https://thebookofshaders.com/edit.php?log=160414041142
float round_rect(vec2 p, vec2 size, float radius) {
  vec2 d = abs(p) - size;
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - radius;
}

void main()
{
    vec2 res = shadow_dimensions;

    vec2 offset = vec2(28 / res.x, 28 / res.y);
    // float d = round_rect(pos - vec2(offset, offset), vec2(shadow_dimensions.x - offset, shadow_dimensions.y - offset), radius);

    float d = round_rect(fragTexCoord.xy - vec2(0.5, 0.5), vec2(0.5, 0.5) - offset, 0.02);
    float alpha = smoothstep(0.0, 20.0/res.x, d);

    finalColor = vec4(0, 0, 0, 0.0);
}
