/*
 * This file is part of the Colobot: Gold Edition source code
 * Copyright (C) 2001-2026, Daniel Roux, EPSITEC SA & TerranovaTeam
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

/**
 * \file graphics/opengl33/gl33_postprocess_renderer.h
 * \brief Full screen post-processing: ambient occlusion and sharpening
 */

#pragma once

#include "graphics/core/renderers.h"

#include <GL/glew.h>

namespace Gfx
{

class CGL33Device;

/**
 * \class CGL33PostProcessRenderer
 * \brief Applies screen space effects to the rendered 3D scene
 *
 * Two passes, both drawn as a single full screen triangle:
 * 1. ambient occlusion from the scene depth into an R8 texture (only when enabled),
 * 2. composite: blurred occlusion and sharpening applied to the scene color.
 */
class CGL33PostProcessRenderer : public CPostProcessRenderer
{
public:
    CGL33PostProcessRenderer(CGL33Device* device);
    virtual ~CGL33PostProcessRenderer();

    bool IsAvailable() override;

    void Draw(const PostProcessParams& params) override;

private:
    //! Creates or resizes the ambient occlusion target
    bool PrepareOcclusionTarget(const glm::ivec2& size);
    void DestroyOcclusionTarget();

    CGL33Device* const m_device;

    GLuint m_vao = 0;

    GLuint m_occlusionProgram = 0;
    GLint m_occlusionProjection = -1;
    GLint m_occlusionInverseProjection = -1;
    GLint m_occlusionFade = -1;

    GLuint m_compositeProgram = 0;
    GLint m_compositeInverseProjection = -1;
    GLint m_compositeOcclusionStrength = -1;
    GLint m_compositeSharpness = -1;

    GLuint m_occlusionFramebuffer = 0;
    GLuint m_occlusionTexture = 0;
    glm::ivec2 m_occlusionSize = { 0, 0 };
};

} // namespace Gfx
