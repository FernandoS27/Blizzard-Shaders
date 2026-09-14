// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Shadow lookups for the 3.0.0 HD mesh pixel shader.
//
// Both live here because 3.0.0 moved shadowing wholesale into the pixel stage:
// 2.0.0 had the vertex shader project into three cascade textures and the
// pixel shader just sampled them, while 3.0.0 hands the pixel shader a world
// position and has it do the projection — for the main light's cascade array
// AND for a cube-map array covering the cluster lights, which 2.0.0 had no
// equivalent of at all.

implementing wc3_shaders;

// Walk one cascade set from tightest to loosest, take the first cascade the
// pixel falls inside, and 3x3-PCF it. A pixel outside every cascade is lit.
//
// `set` selects the matrix triple in `cascadeSets` and doubles as the array
// slice base — the engine numbers the two sets so those two agree.
//
// `atlasOffset` starts at zero and is halved by every cascade that misses, so
// in practice it stays zero for the whole walk. It is kept because it is the
// engine's, and because a non-zero start is the only thing that would make the
// shipped cascade atlas addressable at all.
public float hdCascadeShadow(float4 worldPos, uint set, float2 texel)
{
    return hdCascadeShadowJittered(worldPos, set, texel, float2(0, 0));
}

// The same walk from a caller-chosen starting atlas offset. HD starts at zero;
// `water_ps` starts at a small offset along its ripple normal, so the ripples
// wobble the shadow they receive.
public float hdCascadeShadowJittered(float4 worldPos, uint set, float2 texel,
                                     float2 jitter)
{
    float3 atlasOffset = float3(jitter, 0);
    float shadow = 1;

    [loop] for (uint i = 0; i < asuint(hdPsCB1.cascadeCount); i++)
    {
        float3 p = mul(hdPsCB1.cascadeSets[set * 3 + i], worldPos).xyz;
        p.xy = p.xy * float2(0.5, -0.5) + atlasOffset.xy;
        float3 c = float3(p.x + 0.5, p.y + 0.5, p.z + atlasOffset.z);

        bool inside = (c.x >= 0) && (c.y >= 0) && (c.z >= 0)
                   && (1 >= c.x) && (1 >= c.y) && (c.z < 1);
        if (inside)
        {
            float slice = (float)(uint)(i * 3 + set);
            float taps = 0;
            float sum = 0;
            [loop] for (int a = -1; a < 2; a++)
            {
                [loop] for (int b = -1; b < 2; b++)
                {
                    taps = 1 + taps;
                    float2 uvc = float2(a, b) * texel + c.xy;
                    sum += t_hdCascadeShadow.SampleCmpLevelZero(
                        s_hdCascadeShadow, float3(uvc, slice), c.z).x;
                }
            }
            shadow = saturate(sum / taps);
            break;
        }
        atlasOffset = float3(0.5, 0.5, 0.5) * atlasOffset;
    }
    return shadow;
}

// Main-light shadow for this pixel. With the second cascade set enabled the
// two are combined by taking the darker — but only when the first set left
// enough light for the second to matter, which is what the early-out buys.
public float hdMainLightShadow<let HAS_SHADOW_CASCADE2 : bool>(float4 worldPos)
{
    return hdMainLightShadowJittered<HAS_SHADOW_CASCADE2>(worldPos, float2(0, 0));
}

// The same, with both cascade walks started from `jitter` (see
// hdCascadeShadowJittered).
public float hdMainLightShadowJittered<let HAS_SHADOW_CASCADE2 : bool>(
    float4 worldPos, float2 jitter)
{
    uint w, h, slices, levels;
    t_hdCascadeShadow.GetDimensions(0, w, h, slices, levels);
    float2 texel = float2(1, 1) / float2(w, h);

    if (HAS_SHADOW_CASCADE2)
    {
        float shadow = hdCascadeShadowJittered(worldPos, 1, texel, jitter);
        if (shadow >= HD_CASCADE_EARLY_OUT)
            shadow = min(hdCascadeShadowJittered(worldPos, 2, texel, jitter), shadow);
        return shadow;
    }
    return hdCascadeShadowJittered(worldPos, 2, texel, jitter);
}

// Which cube face a direction lands on: the major axis of |dir|, with the sign
// picking between the two faces of that axis. Ordered X, Y, Z so that a tie
// resolves the way the shipped shader's chain of comparisons does.
static int hdCubeFace(float3 dir)
{
    bool yMajor = (abs(dir.y) >= abs(dir.z)) && (abs(dir.y) >= abs(dir.x));
    bool zMajor = (abs(dir.z) >= abs(dir.y)) && (abs(dir.z) >= abs(dir.x));
    int face = zMajor ? ((0 < dir.z) ? 4 : 5) : ((0 < dir.x) ? 0 : 1);
    return yMajor ? ((0 < dir.y) ? 2 : 3) : face;
}

// Cube shadow for one cluster light, 3x3-PCF'd around the light-to-pixel
// direction.
//
// Only the shell between the record's near and far planes is shadowed; inside
// the near plane or beyond the far one the light is unoccluded, which is how
// the engine keeps a light from shadowing the geometry it is embedded in.
// `cubeDist` (the Chebyshev distance to the light) is handed back because the
// debug overlay draws those two shells.
public float hdCubeShadow(int shadowIndex, float3 worldPos, out float cubeDist)
{
    return hdCubeShadowOffset<false>(shadowIndex, worldPos, float3(0, 0, 0), cubeDist);
}

// The same lookup, optionally with the kernel's centre direction pushed along
// `normalOffset` and renormalised before the basis is built. `water_ps` offsets
// by the same ripple jitter it starts its cascade walk from; every other family passes NORMAL_OFFSET = false, which
// removes the offset outright rather than adding zero -- renormalising an
// already-unit vector is not bit-exact, so "offset by zero" would not be the
// same program.
public float hdCubeShadowOffset<let NORMAL_OFFSET : bool>(
    int shadowIndex, float3 worldPos, float3 normalOffset, out float cubeDist)
{
    HDCubeShadow rec = hdPsCB1.cubeShadows[shadowIndex];
    float3 toShadow = worldPos - rec.position.xyz;
    cubeDist = max(max(abs(toShadow.x), abs(toShadow.y)), abs(toShadow.z));

    if (!((cubeDist < rec.range.y) && (rec.range.x < cubeDist)))
        return 1;

    // A basis around the light direction so the 3x3 kernel steps across the
    // cube face rather than along it.
    float3 dn = normalize(toShadow);
    if (NORMAL_OFFSET)
        dn = normalize(dn + normalOffset);
    float3 tangentC = (abs(dn.z) < 0.999000013)
                    ? normalize(cross(dn, float3(0, 0, 1)))
                    : normalize(cross(dn, float3(0, 1, 0)));
    float3 bitangentC = normalize(cross(dn, tangentC));

    float slice = (float)(uint)shadowIndex;
    float taps = 0;
    float occl = 0;
    [loop] for (int a = -1; a < 2; a++)
    {
        [loop] for (int b = -1; b < 2; b++)
        {
            taps = 1 + taps;
            float2 off = float2(HD_CUBE_PCF_STEP, HD_CUBE_PCF_STEP) * float2(a, b);
            float3 dir = normalize(bitangentC * off.y + (tangentC * off.x + dn));

            // Reproject through the face this tap actually landed on. Only .zw
            // of each row is uploaded — the pair IS the clip-space z and w the
            // comparison needs, so the xy the projection would produce is
            // never computed.
            float2 zw = mul(rec.faces[hdCubeFace(dir)], float4(worldPos, 1)).zw;
            float ref = zw.x / zw.y - hdPsCB2.shadowDepthBias;
            occl = 1 + (occl - t_hdCubeShadow.SampleCmpLevelZero(
                s_hdCubeShadow, float4(dir, slice), ref).x);
        }
    }
    return -(occl / max(1, taps)) * rec.range.z + 1;
}
