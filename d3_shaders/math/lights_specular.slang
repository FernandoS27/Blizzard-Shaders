// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Per-vertex light accumulation with a Phong specular term.
//
// The same light rig as math/lights.slang, extended with the specular the
// glossy actor programs hand to their pixel stage: every positional light
// adds `pow(max(dot(R, L), 0), SpecularPower.x) * colSpecular`, attenuated like
// its diffuse, where R is the view-space eye vector reflected about the normal.
// The cylindrical light has no specular.

implementing d3_shaders;

/// Ambient, diffuse and specular accumulated separately.
public struct D3VertexLightSpecular
{
    public float3 ambient;
    public float3 diffuse;
    public float3 specular;
};

/// The eye vector (the view-space position) reflected about the normal.
public float3 d3ViewReflection(float3 viewPos, float3 viewNormal)
{
    return normalize(reflect(viewPos, viewNormal));
}

/// The primary light with specular: lightPoints[0], quadratic attenuation,
/// positional or directional by wp.w.
public void d3AddPrimaryPointLightSpecular(float3 viewPos, float3 viewNormal, float3 reflection,
                                           inout D3VertexLightSpecular acc)
{
    float3 toLight = lightPoints[0].wp.xyz - viewPos * lightPoints[0].wp.w;
    float dist2 = dot(toLight, toLight);
    float atten = 1.0 / (lightPoints[0].atten.x + lightPoints[0].atten.y * sqrt(dist2)
                         + lightPoints[0].atten.z * dist2);
    float3 dir = toLight * rsqrt(dist2);
    float ndotl = max(dot(dir, viewNormal), 0.0);
    float highlight = pow(max(dot(reflection, dir), 0.0), SpecularPower.x);
    acc.diffuse = (ndotl * lightPoints[0].colDiffuse.xyz) * atten;
    acc.specular = (highlight * lightPoints[0].colSpecular.xyz) * atten;
    acc.ambient = lightPoints[0].colAmbient.xyz * atten + colAmbient.xyz;
}

/// The linear point lights with specular: a clamped linear falloff on distance.
public void d3AddLinearPointLightsSpecular(float3 viewPos, float3 viewNormal, float3 reflection,
                                           inout D3VertexLightSpecular acc)
{
    int count = min(int(numLights.x), 16);
    for (int k = 0; k < count; ++k)
    {
        float3 toLight = lightPointLinears[k].wp.xyz - viewPos;
        float dist2 = dot(toLight, toLight);
        float falloff = saturate((lightPointLinears[k].colDiffuse_radiiB.w - sqrt(dist2))
                                 * lightPointLinears[k].colAmbient_radiiA.w);
        float3 dir = toLight * rsqrt(dist2);
        float ndotl = max(dot(dir, viewNormal), 0.0);
        float highlight = pow(max(dot(reflection, dir), 0.0), SpecularPower.x);
        acc.ambient += lightPointLinears[k].colAmbient_radiiA.xyz * falloff;
        acc.diffuse += (ndotl * lightPointLinears[k].colDiffuse_radiiB.xyz) * falloff;
        acc.specular += (highlight * lightPointLinears[k].colSpecular.xyz) * falloff;
    }
}
