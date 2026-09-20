// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Actor pixel shaders: characters, monsters, cloth and banners
// (Actor.fx, ActorIrrad.fx, banner.fx).
//
// The root is generic over the shading model, which produces the final colour
// and coverage, and over the alpha test applied to that coverage.

implementing d3_shaders;

public interface IActorPixelModel
{
    static float4 shade(D3Interpolants i);
}

/// Actor.fx transparent alpha-composite: diffuse times vertex colour, coverage
/// from diffuse alpha times a separate alpha-mask texture, then fog.
public struct ActorAlphaComposite : IActorPixelModel
{
    public static float4 shade(D3Interpolants i)
    {
        float4 diffuse = texDiffuse.Sample(texDiffuse_s, i.texcoord0().xy);
        float alpha = diffuse.a * texAlphaMask.Sample(texAlphaMask_s, i.texcoord1().xy).a;
        return float4(d3ApplyFog(diffuse.rgb * i.color0().rgb, i.fog().x), alpha);
    }
};

[shader("fragment")]
public float4 actor_ps_main<TModel : IActorPixelModel, TAlpha : IAlphaTest>(D3Interpolants i) : SV_Target
{
    float4 color = TModel.shade(i);
    TAlpha.apply(color.a);
    return color;
}
