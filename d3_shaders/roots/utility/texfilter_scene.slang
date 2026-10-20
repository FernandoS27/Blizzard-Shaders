// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// texfilter_ps filters that rebuild view-space geometry from the depth of the
// frame: screen-space ambient occlusion (the occlusion pass, the normal/depth
// buffer it reads, its depth-aware upscale) and the retro posterise.
//
// Two encodings recur:
//   * the SSAO normal buffer keeps a view normal's xy in [0, 1] (z is rebuilt as
//     1 - |xy|) and a packed depth in zw: `(w * 256 + z) * -4`;
//   * a depth-target sample d is a view z of `cameraParams.x / (d - cameraParams.y)`,
//     and a view position is the screen coordinate's NDC scaled by
//     `-cameraParams.zw` and that z.

implementing d3_shaders;

/// The view normal of an SSAO normal-buffer texel.
public float3 d3DecodeScreenNormal(float4 texel)
{
    float2 xy = texel.xy * 2.0 + -1.0;
    return float3(xy, 1.0 - sqrt(dot(xy, xy)));
}

/// The packed depth of an SSAO normal-buffer texel.
public float d3DecodeScreenDepth(float4 texel)
{
    return (texel.w * 256.0 + texel.z) * -4.0;
}

/// View z of a depth-target sample.
public float d3ViewDepth(float depthSample)
{
    return cameraParams.x / (depthSample - cameraParams.y);
}

/// View position of a [0, 1] screen coordinate at view depth z.
public float3 d3ViewPosition(float2 uv, float z)
{
    float2 ndc = uv * float2(2.0, -2.0) + float2(-1.0, 1.0);
    return float3(ndc * -cameraParams.zw * z, z);
}

/// Sample directions of the occlusion kernel, each with its radius scale in
/// `.x` (the first three are used, at 0.5, 0.75 and 1 of the radius).
static const float4 kSsaoKernel[8] = {
    float4(0.5, 0.577350259, 0.577350259, 0.577350259),
    float4(0.75, -0.577350259, -0.577350259, -0.577350259),
    float4(1.0, -0.577350259, -0.577350259, 0.577350259),
    float4(0.0, -0.577350259, 0.577350259, -0.577350259),
    float4(0.0, -0.577350259, 0.577350259, 0.577350259),
    float4(0.0, 0.577350259, -0.577350259, -0.577350259),
    float4(0.0, 0.577350259, -0.577350259, 0.577350259),
    float4(0.0, 0.577350259, 0.577350259, -0.577350259) };

/// Screen-space ambient occlusion: 6 samples in the hemisphere around the view
/// normal (3 kernel directions, each reflected about 2 per-pixel random
/// vectors), projected through matEffect1 and compared against the depth
/// found there. Constant0 = (falloff exponent, radius, random rows, range),
/// Constant1.x scales the normal bias with distance.
public struct SsaoOcclusion : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 screen = i.texcoord0().xy;
        float randomStep = 1.0 / Constant0.z;
        float4 texel = texNormal.Sample(texNormal_s, d3ViewportUv(screen));
        float3 normal = d3DecodeScreenNormal(texel);
        float packed = d3DecodeScreenDepth(texel);
        float z = d3ViewDepth((packed * cameraParams.y + cameraParams.x) / packed);
        float3 position = d3ViewPosition(screen, z);
        float3 bias = (-z * Constant1.x + 0.5) * normal;
        float seed = dot(screen, float2(23.140692, 2.665144210)) * 256.0 + 1e-7;
        float noise = frac(cos(fmod(123456789.0, seed)));
        float range = Constant0.w + -0.001;
        float occlusion = 0.0;
        for (int row = 0; row < 2; row++)
        {
            for (int k = 0; k < 3; k++)
            {
                float2 randomUv = float2(noise, noise) + float2(randomStep * float(row * 3 + k), 0.0);
                float3 random = texRandom.Sample(texRandom_s, randomUv).xyz * 2.0 + -1.0;
                float3 offset = reflect(kSsaoKernel[k].yzw, random) * kSsaoKernel[k].x;
                offset = dot(offset, normal) < 0.0 ? -offset : offset;
                float4 probe = float4(position + (offset * Constant0.y + bias), 1.0);
                float4 clip = mul(matEffect1, probe);
                float2 projected = clip.xy / clip.w;
                float2 uv = (projected + float2(1.0, -1.0)) * viewport.xz * float2(0.5, -0.5) + viewport.yw;
                float4 found = texNormal.Sample(texNormal_s, d3ViewportClamp(uv));
                float depthGap = -(found.w * 256.0 + found.z) * -4.0 + probe.z;
                float falloff = max(1.0 - pow((-depthGap + -0.001) / range, Constant0.x), 0.0);
                float occluded = -depthGap < 0.001 ? 1.0 : falloff;
                occluded = 0.001 < -depthGap ? occluded : 0.0;
                occlusion = occluded * kSsaoKernel[k].x + occlusion;
            }
        }
        float ao = -occlusion * (2.0 / 9.0) + 1.0;
        return float4(ao, ao, ao, ao);
    }
};

/// The view position a quarter target texel away from the centre, at the depth
/// found there. The screen offset is stretched by the target's aspect.
float3 d3NeighbourPosition(float2 screen, float2 base, float2 quarter, float aspect)
{
    float2 uv = d3ViewportClamp(targetDimensions.zw * quarter + base);
    float z = d3ViewDepth(texDepth.Sample(texDepth_s, uv).x);
    float2 offset = float2(quarter.x * targetDimensions.z, quarter.y * targetDimensions.w) * float2(aspect, 1.0);
    return d3ViewPosition(offset + screen, z);
}

/// SSAO normal/depth buffer: the view normal of the four triangles around the
/// pixel (left-down, down-right, up-left, right-up) that faces the camera most,
/// in xy; the view depth, scaled by 64 and split into fraction and 1/256
/// whole part, in zw.
public struct SsaoNormalDepth : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 screen = i.texcoord0().xy;
        float2 base = d3ViewportUv(screen);
        float aspect = targetDimensions.y / targetDimensions.x;
        float3 left = d3NeighbourPosition(screen, base, float2(-0.25, 0.0), aspect);
        float3 up = d3NeighbourPosition(screen, base, float2(0.0, -0.25), aspect);
        float3 right = d3NeighbourPosition(screen, base, float2(0.25, 0.0), aspect);
        float3 down = d3NeighbourPosition(screen, base, float2(0.0, 0.25), aspect);
        float zCenter = d3ViewDepth(texDepth.Sample(texDepth_s, base).x);
        float3 center = d3ViewPosition(screen, zCenter);
        float3 toLeft = left - center;
        float3 toUp = up - center;
        float3 toRight = right - center;
        float3 toDown = down - center;

        float3 best = float3(-1.0, -1.0, -10000.0);
        float3 n = normalize(cross(toDown, toRight));
        best = best.z < n.z ? n : best;
        n = normalize(cross(toLeft, toDown));
        best = best.z < n.z ? n : best;
        n = normalize(cross(toUp, toLeft));
        best = best.z < n.z ? n : best;
        n = normalize(cross(toRight, toUp));
        best = best.z < n.z ? n : best;

        // The fraction is spelled out: fxc drops the saturate of a `frac`, and
        // retail's saturate is what turns a non-finite depth into 0.
        float depth = trunc(zCenter * -64.0) * (1.0 / 256.0);
        return float4(best.xy * 0.5 + 0.5, saturate(depth - floor(depth)), saturate(trunc(depth) * (1.0 / 256.0)));
    }
};

/// Depth-aware SSAO upscale: the average occlusion of the four diagonal
/// neighbours whose packed depth is within 1 of the full-resolution depth (the
/// nearest texel when none is), faded towards unoccluded by the vignette.
public struct SsaoUpscale : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 screen = i.texcoord0().xy;
        float2 base = d3ViewportUv(screen);
        float z = d3ViewDepth(texDepth.Sample(texDepth_s, screen).x);
        float sum = 0.0;
        float count = 0.0;
        float2 quarters[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        for (int k = 0; k < 4; k++)
        {
            float2 uv = d3ViewportClamp(targetDimensions.zw * quarters[k] + base);
            float4 texel = texNormal.Sample(texNormal_s, uv);
            float occlusion = texSSAOBuffer.Sample(texSSAOBuffer_s, uv).w;
            if (abs(-(texel.w * 256.0 + texel.z) * -4.0 + z) < 1.0)
            {
                sum = sum + occlusion;
                count = count + 1.0;
            }
        }
        if (count == 0.0)
        {
            sum = texSSAOBuffer.Sample(texSSAOBuffer_s, d3ViewportClamp(base)).w;
            count = 1.0;
        }
        float ao = sum * (1.0 / count) + -1.0;
        float faded = texVignette.Sample(texVignette_s, screen).w * ao + 1.0;
        return float4(faded, faded, faded, faded);
    }
};

/// Retro look: the frame snapped to a 400-line grid (aspect-corrected), box
/// filtered, dithered in world space through matEffect2 (a 3x3x3 cell pattern
/// indexing the dither strip), and quantised to 16 levels in gamma 2.2.
public struct RetroPosterize : ITexFilter
{
    public static float4 shade(D3Interpolants i)
    {
        float2 screen = i.texcoord0().xy;
        float lines = 400.0 / viewport.z;
        float2 grid = float2(targetDimensions.w * targetDimensions.x * lines, lines);
        float2 snapped = d3ViewportUv(trunc(grid * screen) / grid);
        float2 texel = targetDimensions.zw;
        float3 sum = texColor.Sample(texColor_s, d3ViewportClamp(texel * float2(-0.5, 0.5) + snapped)).xyz
                   + texColor.Sample(texColor_s, d3ViewportClamp(texel * float2(-0.5, -0.5) + snapped)).xyz;
        sum = sum + texColor.Sample(texColor_s, d3ViewportClamp(texel * float2(0.5, -0.5) + snapped)).xyz;
        sum = texColor.Sample(texColor_s, d3ViewportClamp(texel * float2(0.5, 0.5) + snapped)).xyz + sum;
        float3 color = pow(sum * 0.25, 1.0 / 2.2);

        float z = d3ViewDepth(texDepth.Sample(texDepth_s, d3ViewportUv(screen)).x);
        float4 view = float4(d3ViewPosition(screen, z), 1.0);
        float3 world = mul(matEffect2, view).xyz;
        int3 cell = d3FtoiExact((world + 0.12345) * 6.25) % 3;
        float pattern = float(cell.x * 9 + cell.y * 3 + cell.z) * 0.03125;
        float dither = texDither.Sample(texDither_s, float2(pattern, 0.0)).x;
        color = dither * 0.284598202 + color;
        color = trunc(color * 16.0) * 0.0625;
        return float4(pow(color, 2.2), 1.0);
    }
};
