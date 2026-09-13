// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Post-shading stages for the 3.0.0 HD mesh pixel shader: the blight overlay,
// fog, and the colour-correction / fog-application pair that closes the frame.
//
// Fog is where 3.0.0 diverges most from 2.0.0. 2.0.0 had FOG_LINEAR and
// FOG_EXPONENTIAL as compile-time permutation axes and one apply() that always
// lerped toward the fog colour. 3.0.0 selects one of seven modes from a
// constant at RUNTIME — including a whole second, volumetric implementation —
// and then applies the result differently depending on the material's blend
// mode, so an additive material fades to black and a modulate material to
// white instead of both fading toward the fog colour.

implementing wc3_shaders;

// Blighted ground tints everything standing on it. The mask is a scalar
// coverage value that indexes a colour ramp; 0.75 is the ramp row the engine
// samples, and the ramp is what turns coverage into the sickly green.
public float3 hdApplyBlight(float3 rgb, float2 blightUV)
{
    float mask = t_hdBlightMask.Sample(s_hdBlightMask, blightUV).x;
    float3 blight = t_hdBlightRamp.Sample(s_hdBlightRamp, float2(mask, 0.75)).xyz;
    return rgb * blight;
}

// The six distance-based fog modes (everything except volumetric).
//
// Modes 3, 5 and 6 all share the same normalised distance and density, so they
// are evaluated together and selected between — which is also how the shipped
// bytecode does it, because a branch per mode would cost more than the three
// exponentials.
static float hdDistanceFog(int mode, float viewZ)
{
    if (mode == 0)
        return 1;

    float f;
    if (mode == 2)
    {
        f = 1.0 / exp(hdPsCB2.fogDensity * viewZ);
    }
    else
    {
        float fogStart = hdPsCB2.fogColorStart.w;
        float clampedEnd = max(hdPsCB2.fogEnd, SAFE_EPS + fogStart);
        float invRange = 1.0 / (clampedEnd - fogStart);
        float density2 = hdPsCB2.fogDensity * hdPsCB2.fogDensity;

        float expSq = 1.0 / exp(density2 * (viewZ * viewZ));
        float t = saturate(invRange * (viewZ - fogStart));
        float expT = 1.0 / exp(hdPsCB2.fogDensity * t);
        float expT2 = 1.0 / exp(density2 * (t * t));
        float linearF = invRange * (hdPsCB2.fogEnd - viewZ);

        bool3 pick = int3(mode, mode, mode) == int3(3, 5, 6);
        f = pick.z ? expT2 : linearF;
        f = pick.y ? expT : f;
        f = pick.x ? expSq : f;
    }

    // Smoothstep the survival factor so fog does not band at its own start.
    f = saturate(f);
    return -f * f + (f + f);
}

// Volumetric fog: a radial falloff around the camera, faded in by height.
//
// Two radial bands are evaluated — an inner one gated by the height fade and
// an outer one at a fixed strength — and the denser of the two wins. The
// height term takes the larger of "how deep is this pixel" and "how deep is
// the camera", so flying the camera into the fog bank fogs the whole view
// rather than only the parts of it that are physically inside.
static float hdVolumetricFog(float viewZ, float3 worldPos)
{
    float fogStart = hdPsCB2.fogColorStart.w;
    float radialEnd = max(hdPsCB2.fogEnd, SAFE_EPS + fogStart);
    float heightLow = min(hdPsCB2.heightBottom, -SAFE_EPS + hdPsCB2.heightTop);
    float outerEnd = max(hdPsCB2.radialOuter, SAFE_EPS + hdPsCB2.radialInner);
    float outerStrength = saturate(hdPsCB2.radialStrength);
    bool fogEverywhere = asint(hdPsCB2.fogEverywhere) != 0;

    float invHeight = 1.0 / (hdPsCB2.heightTop - heightLow);
    // Past this the pixel is the sky box, which is fogged from the camera's
    // height alone.
    bool nearEnough = viewZ < 32768;
    float hereH = invHeight * (hdPsCB2.heightTop - worldPos.z);
    hereH = nearEnough ? hereH : 0;
    float camH = invHeight * (hdPsCB2.heightTop - hdPsCB2.fogCentre.z);
    float heightF = saturate(max(hereH, camH));

    float2 toCentre = worldPos.xy - hdPsCB2.fogCentre.xy;
    float radial = sqrt(dot(toCentre, toCentre));

    float inner = saturate((radial - fogStart) / (radialEnd - fogStart));
    inner = heightF * inner;
    float outer = saturate((radial - hdPsCB2.radialInner) / (outerEnd - hdPsCB2.radialInner));
    outer = outerStrength * outer;
    outer = max(outer, inner);

    float fogNear = -outer * outer + 1;
    float fogFar = -inner * inner + 1;
    return (nearEnough || fogEverywhere) ? fogNear : fogFar;
}

// Survival factor: 1 means the surface colour survives untouched, 0 means it
// is entirely replaced by whatever the blend mode fades toward.
public float hdFogFactor(float viewZ, float3 worldPos)
{
    int mode = asint(hdPsCB2.fogMode);
    return (mode != 4) ? hdDistanceFog(mode, viewZ)
                       : hdVolumetricFog(viewZ, worldPos);
}

// Colour grade, alpha scale, and the blend-mode-aware fog application.
//
// The switch is the 3.0.0 addition. Fading an additive material toward the fog
// colour would make it BRIGHTER in fog; fading a modulate material toward it
// would darken everything it multiplies. Each family therefore fades toward
// its own identity: black for additive, white for modulate, grey for
// modulate-2x, and the fog colour only for the ordinary opaque and
// alpha-blended cases.
public float4 hdApplyFog(float4 shaded, float fogFactor)
{
    float4 result;
    result.xyz = applyColorMatrix(shaded.xyz);
    result.w = hdPsCB2.outputAlphaScale * shaded.w;

    switch (asint(hdPsCB2.blendMode))
    {
        case 0: case 1: case 2: case 10:   // opaque / alpha blends
            result.xyz = fogFactor * (result.xyz - hdPsCB2.fogColorStart.xyz)
                       + hdPsCB2.fogColorStart.xyz;
            break;
        case 8: case 3: case 7:            // additive -> black
            result.xyz = fogFactor * result.xyz;
            break;
        case 9: case 4:                    // modulate -> white
            result.xyz = fogFactor * (result.xyz + float3(-1, -1, -1))
                       + float3(1, 1, 1);
            break;
        case 5:                            // modulate 2x -> grey
            result.xyz = fogFactor * (result.xyz + float3(-0.5, -0.5, -0.5))
                       + float3(0.5, 0.5, 0.5);
            break;
        case 6:                            // premultiplied -> fade everything
            result = fogFactor * result;
            break;
        default:
            break;
    }
    return result;
}

// Soft-edge cull for the deferred targets only.
//
// A pixel that the output alpha scale has faded out still tints the colour
// buffer, but must not overwrite depth and normal in the G-buffer — the
// resolve would then shade a surface that is barely there as if it were solid.
public void hdMRTSoftnessDiscard(float albedoAlpha)
{
    if (-(1 - hdPsCB2.outputAlphaScale) * HD_MRT_SOFTNESS_FACTOR + albedoAlpha < 0)
        discard;
}
