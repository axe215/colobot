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

#include "graphics/opengl33/gl33_postprocess_renderer.h"

#include "graphics/opengl33/gl33_device.h"
#include "graphics/opengl33/glutil.h"

#include "graphics/core/material.h"
#include "graphics/core/transparency.h"

#include "common/logger.h"

#include <glm/gtc/type_ptr.hpp>

using namespace Gfx;

namespace
{

// Texture units not used by the other renderers
constexpr int COLOR_UNIT = 12;
constexpr int DEPTH_UNIT = 13;
constexpr int OCCLUSION_UNIT = 14;

GLuint LoadProgram(const char* vertexFile, const char* fragmentFile)
{
    GLint shaders[2] = {};

    shaders[0] = LoadShader(GL_VERTEX_SHADER, vertexFile);
    if (shaders[0] == 0)
    {
        GetLogger()->Error("Could not create vertex shader from file '%%'", vertexFile);
        return 0;
    }

    shaders[1] = LoadShader(GL_FRAGMENT_SHADER, fragmentFile);
    if (shaders[1] == 0)
    {
        GetLogger()->Error("Could not create fragment shader from file '%%'", fragmentFile);
        glDeleteShader(shaders[0]);
        return 0;
    }

    GLuint program = LinkProgram(2, shaders);

    glDeleteShader(shaders[0]);
    glDeleteShader(shaders[1]);

    if (program == 0)
        GetLogger()->Error("Could not link shader program from '%%'", fragmentFile);

    return program;
}

} // namespace

CGL33PostProcessRenderer::CGL33PostProcessRenderer(CGL33Device* device)
    : m_device(device)
{
    GetLogger()->Info("Creating CGL33PostProcessRenderer");

    m_occlusionProgram = LoadProgram("shaders/gl33/postprocess_vs.glsl", "shaders/gl33/ambient_occlusion_fs.glsl");
    m_compositeProgram = LoadProgram("shaders/gl33/postprocess_vs.glsl", "shaders/gl33/postprocess_fs.glsl");

    if (m_occlusionProgram == 0 || m_compositeProgram == 0)
    {
        GetLogger()->Error("Post-processing is not available");
        return;
    }

    glUseProgram(m_occlusionProgram);
    glUniform1i(glGetUniformLocation(m_occlusionProgram, "uni_Depth"), DEPTH_UNIT);
    m_occlusionProjection = glGetUniformLocation(m_occlusionProgram, "uni_Projection");
    m_occlusionInverseProjection = glGetUniformLocation(m_occlusionProgram, "uni_InverseProjection");
    m_occlusionFade = glGetUniformLocation(m_occlusionProgram, "uni_FadeDistance");

    glUseProgram(m_compositeProgram);
    glUniform1i(glGetUniformLocation(m_compositeProgram, "uni_Color"), COLOR_UNIT);
    glUniform1i(glGetUniformLocation(m_compositeProgram, "uni_Depth"), DEPTH_UNIT);
    glUniform1i(glGetUniformLocation(m_compositeProgram, "uni_Occlusion"), OCCLUSION_UNIT);
    m_compositeInverseProjection = glGetUniformLocation(m_compositeProgram, "uni_InverseProjection");
    m_compositeOcclusionStrength = glGetUniformLocation(m_compositeProgram, "uni_OcclusionStrength");
    m_compositeSharpness = glGetUniformLocation(m_compositeProgram, "uni_Sharpness");

    glUseProgram(0);

    // The full screen triangle is generated from gl_VertexID, but core profile still needs a VAO
    glGenVertexArrays(1, &m_vao);

    GetLogger()->Info("CGL33PostProcessRenderer created successfully");
}

CGL33PostProcessRenderer::~CGL33PostProcessRenderer()
{
    DestroyOcclusionTarget();

    glDeleteVertexArrays(1, &m_vao);
    glDeleteProgram(m_occlusionProgram);
    glDeleteProgram(m_compositeProgram);
}

bool CGL33PostProcessRenderer::IsAvailable()
{
    return m_occlusionProgram != 0 && m_compositeProgram != 0;
}

void CGL33PostProcessRenderer::Draw(const PostProcessParams& params)
{
    if (!IsAvailable())
        return;

    m_device->SetDepthTest(false);
    m_device->SetDepthMask(false);
    m_device->SetTransparency(TransparencyMode::NONE);
    m_device->SetCullFace(CullFace::NONE);

    glBindVertexArray(m_vao);

    glActiveTexture(GL_TEXTURE0 + COLOR_UNIT);
    glBindTexture(GL_TEXTURE_2D, params.colorTexture);

    // The scene depth texture is created for shadow-style comparisons; here it is read as plain values
    glActiveTexture(GL_TEXTURE0 + DEPTH_UNIT);
    glBindTexture(GL_TEXTURE_2D, params.depthTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);

    glm::mat4 inverseProjection = glm::inverse(params.projection);

    bool occlusion = params.ambientOcclusion > 0.0f && PrepareOcclusionTarget(params.size);

    if (occlusion)
    {
        GLint target = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &target);

        glBindFramebuffer(GL_FRAMEBUFFER, m_occlusionFramebuffer);
        glViewport(0, 0, params.size.x, params.size.y);

        glUseProgram(m_occlusionProgram);
        glUniformMatrix4fv(m_occlusionProjection, 1, GL_FALSE, glm::value_ptr(params.projection));
        glUniformMatrix4fv(m_occlusionInverseProjection, 1, GL_FALSE, glm::value_ptr(inverseProjection));
        glUniform1f(m_occlusionFade, params.ambientOcclusionFade);
        glDrawArrays(GL_TRIANGLES, 0, 3);

        glBindFramebuffer(GL_FRAMEBUFFER, target);
    }

    glViewport(0, 0, params.size.x, params.size.y);

    glActiveTexture(GL_TEXTURE0 + OCCLUSION_UNIT);
    glBindTexture(GL_TEXTURE_2D, occlusion ? m_occlusionTexture : 0);

    glUseProgram(m_compositeProgram);
    glUniformMatrix4fv(m_compositeInverseProjection, 1, GL_FALSE, glm::value_ptr(inverseProjection));
    glUniform1f(m_compositeOcclusionStrength, occlusion ? params.ambientOcclusion : 0.0f);
    glUniform1f(m_compositeSharpness, params.sharpness);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glUseProgram(0);
    glActiveTexture(GL_TEXTURE0);
}

bool CGL33PostProcessRenderer::PrepareOcclusionTarget(const glm::ivec2& size)
{
    if (m_occlusionFramebuffer != 0 && m_occlusionSize == size)
        return true;

    DestroyOcclusionTarget();

    GLint previousTexture = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);

    glGenTextures(1, &m_occlusionTexture);
    glBindTexture(GL_TEXTURE_2D, m_occlusionTexture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, size.x, size.y, 0, GL_RED, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, previousTexture);

    GLint previousFramebuffer = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);

    glGenFramebuffers(1, &m_occlusionFramebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, m_occlusionFramebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, m_occlusionTexture, 0);

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);

    if (status != GL_FRAMEBUFFER_COMPLETE)
    {
        GetLogger()->Error("Ambient occlusion framebuffer is incomplete (status %%)", status);
        DestroyOcclusionTarget();
        return false;
    }

    m_occlusionSize = size;
    return true;
}

void CGL33PostProcessRenderer::DestroyOcclusionTarget()
{
    if (m_occlusionFramebuffer != 0)
        glDeleteFramebuffers(1, &m_occlusionFramebuffer);

    if (m_occlusionTexture != 0)
        glDeleteTextures(1, &m_occlusionTexture);

    m_occlusionFramebuffer = 0;
    m_occlusionTexture = 0;
    m_occlusionSize = { 0, 0 };
}
