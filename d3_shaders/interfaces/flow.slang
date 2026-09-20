// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// The flow front of the stage combiner: what coordinates the stages read.
//
// Flow shaders (firewall, particle, wing and blend-add flows) scroll their
// colour layers along a flow field. One to three flow maps are sampled and
// multiplied into one field -- every map after the first doubled, keeping the
// product centred on 0.5 -- then recentred to a signed offset and halved, and
// that one offset displaces the coordinates of the units the pass warps.

implementing d3_shaders;

public interface IFlowFront
{
    static D3StageArgs args(D3Interpolants i);
}

/// The stages read their interpolated coordinates unchanged.
public struct FlowNone : IFlowFront
{
    public static D3StageArgs args(D3Interpolants i)
    {
        D3StageArgs a;
        a.color0 = i.color0();
        a.uv0 = d3UnitTexcoord(i, 0);
        a.uv1 = d3UnitTexcoord(i, 1);
        a.uv2 = d3UnitTexcoord(i, 2);
        a.uv3 = d3UnitTexcoord(i, 3);
        a.uv4 = d3UnitTexcoord(i, 4);
        a.uv5 = d3UnitTexcoord(i, 5);
        return a;
    }
};

/// One flow map folded into the running flow field.
public interface IFlowMap
{
    /// The field this map starts, when it is the first.
    static float2 first(D3Interpolants i);
    /// The running field with this map multiplied in (doubled).
    static float2 fold(float2 flow, D3Interpolants i);
}

/// A flow map: unit UNIT read through role TTex.
public struct FlowMap<TTex : ITextureRole, let UNIT : int> : IFlowMap
{
    public static float2 first(D3Interpolants i) { return TTex.sample(d3UnitTexcoord(i, UNIT)).xy; }
    public static float2 fold(float2 flow, D3Interpolants i) { return flow * (2.0 * first(i)); }
};

/// No further map.
public struct FlowMapNone : IFlowMap
{
    public static float2 first(D3Interpolants i) { return float2(0.5, 0.5); }
    public static float2 fold(float2 flow, D3Interpolants i) { return flow; }
};

/// The field of maps M0 * 2 M1 * 2 M2, recentred and halved, displaces every
/// unit whose bit is set in UNITS.
public struct FlowWarp<M0 : IFlowMap, M1 : IFlowMap, M2 : IFlowMap, let UNITS : uint> : IFlowFront
{
    static float2 displaced(D3Interpolants i, int unit, float2 offset)
    {
        float2 uv = d3UnitTexcoord(i, unit);
        if (((UNITS >> uint(unit)) & 1) != 0)
            uv += offset;
        return uv;
    }

    public static D3StageArgs args(D3Interpolants i)
    {
        float2 flow = M2.fold(M1.fold(M0.first(i), i), i);
        float2 offset = (flow - 0.5) * 0.5;
        D3StageArgs a;
        a.color0 = i.color0();
        a.uv0 = displaced(i, 0, offset);
        a.uv1 = displaced(i, 1, offset);
        a.uv2 = displaced(i, 2, offset);
        a.uv3 = displaced(i, 3, offset);
        a.uv4 = displaced(i, 4, offset);
        a.uv5 = displaced(i, 5, offset);
        return a;
    }
};
