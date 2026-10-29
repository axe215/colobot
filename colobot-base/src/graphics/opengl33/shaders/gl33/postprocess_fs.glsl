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


// FRAGMENT SHADER - POST-PROCESSING COMPOSITE
// Applies blurred ambient occlusion and sharpening to the scene color.

#version 330 core

uniform sampler2D uni_Color;
uniform sampler2D uni_Depth;
uniform sampler2D uni_Occlusion;
uniform mat4 uni_InverseProjection;
uniform float uni_OcclusionStrength;
uniform float uni_Sharpness;

in vec2 pass_TexCoord;

out vec4 out_FragColor;

float ViewDistance(ivec2 pixel, ivec2 size)
{
    vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
    float depth = texelFetch(uni_Depth, pixel, 0).r;
    vec4 position = uni_InverseProjection * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return length(position.xyz / position.w);
}

void main()
{
    ivec2 size = textureSize(uni_Color, 0);
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    ivec2 last = size - 1;

    vec3 color = texelFetch(uni_Color, pixel, 0).rgb;

    if (uni_Sharpness > 0.0)
    {
        vec3 north = texelFetch(uni_Color, clamp(pixel + ivec2( 0,  1), ivec2(0), last), 0).rgb;
        vec3 south = texelFetch(uni_Color, clamp(pixel + ivec2( 0, -1), ivec2(0), last), 0).rgb;
        vec3 east  = texelFetch(uni_Color, clamp(pixel + ivec2( 1,  0), ivec2(0), last), 0).rgb;
        vec3 west  = texelFetch(uni_Color, clamp(pixel + ivec2(-1,  0), ivec2(0), last), 0).rgb;

        vec3 minColor = min(color, min(min(north, south), min(east, west)));
        vec3 maxColor = max(color, max(max(north, south), max(east, west)));

        // Unsharp mask limited to the local range of colors, so edges get no halos
        vec3 blurred = (north + south + east + west) * 0.25;
        color = clamp(color + (color - blurred) * uni_Sharpness, minColor, maxColor);
    }

    if (uni_OcclusionStrength > 0.0)
    {
        // 4x4 blur removes the per-pixel noise; samples on other surfaces get low weight
        float center = ViewDistance(pixel, size);
        float occlusion = 0.0;
        float weights = 0.0;

        for (int y = -2; y < 2; y++)
        {
            for (int x = -2; x < 2; x++)
            {
                ivec2 tap = clamp(pixel + ivec2(x, y), ivec2(0), last);
                float weight = 1.0 / (1.0 + 8.0 * abs(ViewDistance(tap, size) - center));

                occlusion += texelFetch(uni_Occlusion, tap, 0).r * weight;
                weights += weight;
            }
        }

        occlusion /= weights;
        color *= mix(1.0, occlusion, uni_OcclusionStrength);
    }

    out_FragColor = vec4(color, 1.0);
}
