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

// Shadow mapping implementation

struct ShadowParam
{
    mat4 transform;
    vec2 uv_offset;
    vec2 uv_scale;
};

uniform sampler2DShadow uni_ShadowMap;
uniform int uni_ShadowRegions;
uniform ShadowParam uni_ShadowParam[4];

// Projects world-space position into an array of shadow coordinates
vec3[4] ProjectShadows(vec3 position)
{
    vec3 result[4];

    for (int i = 0; i < uni_ShadowRegions; i++)
    {
        vec4 projected = uni_ShadowParam[i].transform * vec4(position, 1.0);

        result[i] = projected.xyz / projected.w;
    }

    return result;
}

// Calculates shadow based on array of shadow coordinates
// Poisson disk for soft shadow edges; every tap is also a 2x2 hardware PCF lookup
const vec2 c_PoissonDisk[12] = vec2[](
    vec2(-0.326, -0.406), vec2(-0.840, -0.074), vec2(-0.696,  0.457),
    vec2(-0.203,  0.621), vec2( 0.962, -0.195), vec2( 0.473, -0.480),
    vec2( 0.519,  0.767), vec2( 0.185, -0.893), vec2( 0.507,  0.064),
    vec2( 0.896,  0.412), vec2(-0.322, -0.933), vec2(-0.792, -0.598)
);

// Radius of the soft edge in shadow map texels
const float c_ShadowSoftness = 1.75;

float CalculateShadow(vec3 projected[4])
{
    for (int i = 0; i < uni_ShadowRegions; i++)
    {
        if (projected[i].x < 0.0 || projected[i].x > 1.0) continue;
        if (projected[i].y < 0.0 || projected[i].y > 1.0) continue;

        vec2 uv = projected[i].xy * uni_ShadowParam[i].uv_scale + uni_ShadowParam[i].uv_offset;
        float depth = projected[i].z;

        // Taps must stay inside this region of the shadow map atlas
        vec2 texel = 1.0 / vec2(textureSize(uni_ShadowMap, 0));
        vec2 regionMin = uni_ShadowParam[i].uv_offset + texel;
        vec2 regionMax = uni_ShadowParam[i].uv_offset + uni_ShadowParam[i].uv_scale - texel;

        float value = 0.0;
        for (int k = 0; k < 12; k++)
        {
            vec2 tap = clamp(uv + c_PoissonDisk[k] * texel * c_ShadowSoftness, regionMin, regionMax);
            value += texture(uni_ShadowMap, vec3(tap, depth));
        }
        return value * (1.0 / 12.0);
    }

    return 1.0;
}
