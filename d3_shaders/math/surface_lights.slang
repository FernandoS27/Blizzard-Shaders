// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The per-vertex light rig of scenery, terrain, water and fog surfaces.
//
// Every vertex-lit surface accumulates the same lights in the same order, in
// view space: the primary light (lightPoints[0], positional or directional by
// wp.w, with quadratic attenuation), optionally the four scene spot lights,
// the linear point lights (numLights.x of them, clamped to 16) and one
// cylindrical light. Ambient, diffuse and -- for glossy materials -- Phong
// specular are kept apart, together with the primary light's own diffuse
// gated by (1 - wp.w): the directional sun term the pixel shader shadows.

implementing d3_shaders;

public struct D3SurfaceLighting
{
    public float3 ambient;
    public float3 diffuse;
    public float3 specular;
    /// The primary light's diffuse when it is directional (wp.w = 0).
    public float3 sunDiffuse;
};

/// Phong lobe between the reflected view ray and a light direction.
public float d3PhongLobe(float3 reflected, float3 toLight)
{
    return pow(max(dot(reflected, toLight), 0.0), SpecularPower.x);
}

/// The light rig at one view-space vertex. SPOT adds the four spot lights;
/// GLOSS accumulates specular (zero otherwise).
public struct SurfaceLightRig<let SPOT : bool, let GLOSS : bool>
{
    public static D3SurfaceLighting evaluate(float3 viewPos, float3 viewNormal)
    {
        D3SurfaceLighting l;
        float3 reflected = normalize(reflect(viewPos, viewNormal));

        // primary light
        float3 toPrimary = lightPoints[0].wp.xyz - viewPos * lightPoints[0].wp.w;
        float primaryDist2 = dot(toPrimary, toPrimary);
        float primaryAtten = 1.0 / (lightPoints[0].atten.y * sqrt(primaryDist2) + lightPoints[0].atten.x
                                    + primaryDist2 * lightPoints[0].atten.z);
        float3 primaryDir = toPrimary * rsqrt(primaryDist2);
        float3 primaryDiffuse = (max(dot(primaryDir, viewNormal), 0.0) * lightPoints[0].colDiffuse.xyz)
                                * primaryAtten;
        l.ambient = lightPoints[0].colAmbient.xyz * primaryAtten + colAmbient.xyz;
        l.diffuse = primaryDiffuse;
        l.specular = float3(0.0, 0.0, 0.0);
        if (GLOSS)
            l.specular = (d3PhongLobe(reflected, primaryDir) * lightPoints[0].colSpecular.xyz) * primaryAtten;
        l.sunDiffuse = (1.0 - lightPoints[0].wp.w) * primaryDiffuse;

        // spot lights: distance falloff times a cone, full inside radii.w and
        // ramping linearly down to radii.z
        if (SPOT)
        {
            for (int s = 0; s < 4; ++s)
            {
                float3 toSpot = lightSpots[s].wp - viewPos;
                float spotDist2 = dot(toSpot, toSpot);
                float falloff = saturate((lightSpots[s].radii.y - sqrt(spotDist2)) * lightSpots[s].radii.x);
                float3 spotDir = toSpot * rsqrt(spotDist2);
                float cosAngle = dot(spotDir, -lightSpots[s].wv);
                bool inside = cosAngle >= lightSpots[s].radii.w;
                float full = inside ? 1.0 : 0.0;
                float ramp = inside ? 0.0 : 1.0;
                float edge = max((cosAngle - lightSpots[s].radii.z) / (lightSpots[s].radii.w - lightSpots[s].radii.z), 0.0);
                float cone = ramp * edge + full;
                l.ambient += (falloff * lightSpots[s].colAmbient.xyz) * cone;
                l.diffuse += ((max(dot(spotDir, viewNormal), 0.0) * lightSpots[s].colDiffuse.xyz) * falloff) * cone;
                if (GLOSS)
                    l.specular += (d3PhongLobe(reflected, spotDir) * lightSpots[s].colSpecular.xyz) * (cone * falloff);
            }
        }

        // linear point lights
        int count = min(int(numLights.x), 16);
        for (int k = 0; k < count; ++k)
        {
            float3 toPoint = lightPointLinears[k].wp - viewPos;
            float pointDist2 = dot(toPoint, toPoint);
            float pointDist = sqrt(pointDist2);
            float3 pointDir = toPoint * rsqrt(pointDist2);
            float falloff = saturate((lightPointLinears[k].colDiffuse_radiiB.w - pointDist)
                                     * lightPointLinears[k].colAmbient_radiiA.w);
            float3 diffuseTerm = max(dot(pointDir, viewNormal), 0.0) * lightPointLinears[k].colDiffuse_radiiB.xyz;
            l.ambient += lightPointLinears[k].colAmbient_radiiA.xyz * falloff;
            l.diffuse += diffuseTerm * falloff;
            if (GLOSS)
                l.specular += (d3PhongLobe(reflected, pointDir) * lightPointLinears[k].colSpecular.xyz) * falloff;
        }

        // cylindrical light: falloff on the distance to its axis, no specular
        float3 toAxis = lightCylindricals[0].wp - viewPos;
        float axisDist2 = dot(toAxis, toAxis);
        float along = dot(toAxis, lightCylindricals[0].wv);
        float perp = sqrt(max(axisDist2 - along * along, 0.0));
        float3 axisDir = toAxis * rsqrt(axisDist2);
        float axisFalloff = saturate((lightCylindricals[0].radii.y - perp) * lightCylindricals[0].radii.x);
        l.ambient = lightCylindricals[0].colAmbient.xyz * axisFalloff + l.ambient;
        l.diffuse = (max(dot(axisDir, viewNormal), 0.0) * lightCylindricals[0].colDiffuse.xyz) * axisFalloff + l.diffuse;
        return l;
    }
};
