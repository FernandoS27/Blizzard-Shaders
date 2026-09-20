// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Per-vertex light accumulation over CBLights.
//
// Diablo III lights in view space and keeps ambient and diffuse separate until
// the end. `numLights.x` counts the linear point lights; every loop over them
// clamps it to the 16 array entries.

implementing d3_shaders;

/// Ambient and diffuse accumulated separately.
public struct D3VertexLight
{
    public float3 ambient;
    public float3 diffuse;
};

/// The primary light: lightPoints[0] with quadratic attenuation, positional or
/// directional by wp.w.
public void d3AddPrimaryPointLight(float3 viewPos, float3 viewNormal, inout D3VertexLight acc)
{
    float3 toLight = lightPoints[0].wp.xyz - viewPos * lightPoints[0].wp.w;
    float dist2 = dot(toLight, toLight);
    float atten = 1.0 / (lightPoints[0].atten.x + lightPoints[0].atten.y * sqrt(dist2)
                         + lightPoints[0].atten.z * dist2);
    float ndotl = max(dot(toLight * rsqrt(dist2), viewNormal), 0.0);
    acc.diffuse = (ndotl * lightPoints[0].colDiffuse.xyz) * atten;
    acc.ambient = lightPoints[0].colAmbient.xyz * atten + colAmbient.xyz;
}

/// The linear point lights: a clamped linear falloff on distance.
public void d3AddLinearPointLights(float3 viewPos, float3 viewNormal, inout D3VertexLight acc)
{
    int count = min(int(numLights.x), 16);
    for (int k = 0; k < count; ++k)
    {
        float3 toLight = lightPointLinears[k].wp.xyz - viewPos;
        float dist2 = dot(toLight, toLight);
        float atten = saturate((lightPointLinears[k].colDiffuse_radiiB.w - sqrt(dist2))
                               * lightPointLinears[k].colAmbient_radiiA.w);
        float ndotl = max(dot(toLight * rsqrt(dist2), viewNormal), 0.0);
        acc.ambient += lightPointLinears[k].colAmbient_radiiA.xyz * atten;
        acc.diffuse += (ndotl * lightPointLinears[k].colDiffuse_radiiB.xyz) * atten;
    }
}

/// One cylindrical light: falloff on the perpendicular distance to its axis.
public void d3AddCylindricalLight(float3 viewPos, float3 viewNormal, inout D3VertexLight acc)
{
    float3 toLight = lightCylindricals[0].wp.xyz - viewPos;
    float dist2 = dot(toLight, toLight);
    float axial = dot(toLight, lightCylindricals[0].wv.xyz);
    float perp = sqrt(max(dist2 - axial * axial, 0.0));
    float atten = saturate((lightCylindricals[0].radii.y - perp) * lightCylindricals[0].radii.x);
    float ndotl = max(dot(toLight * rsqrt(dist2), viewNormal), 0.0);
    acc.ambient += lightCylindricals[0].colAmbient.xyz * atten;
    acc.diffuse += (ndotl * lightCylindricals[0].colDiffuse.xyz) * atten;
}
