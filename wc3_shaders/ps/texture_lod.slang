// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Active mip level for a 2D sample, as a portable one-function file.
//
// This is what is left of the 2.0.0 `ps/ps_post.slang`. That file held the
// backface discard, the deferred-target alpha test, the MRT normal pack and
// the debug-visualisation router, all of which died with the last family that
// used them when P6 moved `crystal_ps` onto the 3.0.0 HD stack. Only this
// helper outlived them, because `foliage_ps` borrows it — so it keeps its own
// file under an honest name rather than being the sole occupant of one called
// "post".

implementing wc3_shaders;

// WGSL has no direct `CalculateLevelOfDetail` intrinsic, so the LOD is
// reconstructed there from scaled-UV derivatives; every other target uses the
// native call. The derivative form matches the spec's definition for the
// trilinear case (log2 of the max footprint axis length in texels).
public float queryTextureLOD(Texture2D<float4> tex, SamplerState samp, float2 uv)
{
    __target_switch
    {
    case wgsl:
        {
            uint w, h;
            tex.GetDimensions(w, h);
            float2 scaledUV = uv * float2(w, h);
            float2 dx = ddx(scaledUV);
            float2 dy = ddy(scaledUV);
            return 0.5 * log2(max(dot(dx, dx), dot(dy, dy)));
        }
    default:
        return tex.CalculateLevelOfDetail(samp, uv);
    }
}
