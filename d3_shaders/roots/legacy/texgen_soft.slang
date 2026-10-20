// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The soft-particle depth generator of the legacy mesh vertex shaders
// (SoftBillboard.fx and SoftParticleLegacy.fx meshes).
//
// A soft pixel shader fades the fragment as it nears the scene behind it
// (roots/legacy/combiner_ps.slang): it needs its own view distance, which the
// vertex shader hands over as one more texture coordinate after the stages
// the pass samples.

implementing d3_shaders;

/// The view distance in front of the camera, `-(matWorldView * model).z`.
public struct TexGenViewDepth : ITexGen
{
    public static float4 generate<TUv : IUvSource>(D3VertexIn i, D3LegacyVertex v)
    {
        return float4(-v.view.z, 0.0, 0.0, 0.0);
    }
};
