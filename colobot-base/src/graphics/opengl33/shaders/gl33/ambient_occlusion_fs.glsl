/*
 * This file is part of the Colobot: Gold Edition source code
 * Copyright (C) 2001-2021, Daniel Roux, EPSITEC SA & TerranovaTeam
 * http://epsitec.ch; http://colobot.info; http://github.com/colobot
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see http://gnu.org/licenses
 */


// FRAGMENT SHADER - AMBIENT OCCLUSION
// Screen space ambient occlusion from the depth buffer only:
// position and normal are reconstructed from depth, occlusion is tested
// with a cosine-weighted hemisphere of samples rotated per pixel.

#version 330 core

uniform sampler2D uni_Depth;
uniform mat4 uni_Projection;
uniform mat4 uni_InverseProjection;
uniform float uni_FadeDistance;

in vec2 pass_TexCoord;

out float out_Occlusion;

const int c_Samples = 16;
const float c_Radius = 1.6;    // in world units (a bot is about 3 units tall)
const float c_Bias = 0.05;

vec3 ViewPosition(vec2 uv, float depth)
{
    vec4 position = uni_InverseProjection * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return position.xyz / position.w;
}

void main()
{
    float depth = texture(uni_Depth, pass_TexCoord).r;

    // Sky and background
    if (depth >= 1.0)
    {
        out_Occlusion = 1.0;
        return;
    }

    vec3 position = ViewPosition(pass_TexCoord, depth);
    float pointDistance = length(position);

    if (pointDistance > uni_FadeDistance)
    {
        out_Occlusion = 1.0;
        return;
    }

    // Normal facing the camera, independent of the handedness of the view space
    vec3 normal = normalize(cross(dFdx(position), dFdy(position)));
    if (dot(normal, position) > 0.0)
        normal = -normal;

    vec3 tangent = normalize(cross(abs(normal.x) > 0.5 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), normal));
    vec3 bitangent = cross(normal, tangent);

    // Interleaved gradient noise: a different rotation of the kernel for each pixel
    float rotation = 6.2831853 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));

    float occlusion = 0.0;

    for (int i = 0; i < c_Samples; i++)
    {
        float t = (float(i) + 0.5) / float(c_Samples);
        float phi = float(i) * 2.3999632 + rotation;   // golden angle spiral
        float sinTheta = sqrt(t);
        vec3 direction = vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, sqrt(1.0 - t));

        // More samples close to the point
        float scale = mix(0.15, 1.0, t * t);
        vec3 samplePosition = position + (tangent * direction.x + bitangent * direction.y + normal * direction.z) * (c_Radius * scale);

        vec4 projected = uni_Projection * vec4(samplePosition, 1.0);
        vec2 uv = projected.xy / projected.w * 0.5 + 0.5;

        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
            continue;

        vec3 scenePosition = ViewPosition(uv, texture(uni_Depth, uv).r);

        float sceneDistance = length(scenePosition);
        float sampleDistance = length(samplePosition);

        // Ignore occluders far in front of the point (e.g. a bot in front of a distant wall)
        float range = smoothstep(0.0, 1.0, c_Radius / max(abs(pointDistance - sceneDistance), 0.0001));

        if (sceneDistance < sampleDistance - c_Bias)
            occlusion += range;
    }

    float result = 1.0 - occlusion / float(c_Samples);

    // Fade out with distance, where fog takes over
    out_Occlusion = mix(result, 1.0, smoothstep(0.5 * uni_FadeDistance, uni_FadeDistance, pointDistance));
}
