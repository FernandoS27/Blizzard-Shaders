// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026, Fernando Sahmkow
// See LICENSE in the repository root for full terms.
//
// Depth-prepass back-face stub for the 2.0.0 HD pipeline.
//
// All that is left here is the stub. The alpha-tested prepass body that used
// to sit beside it existed for `hd_ps` and the toon / gritty variants, all of
// which are gone — `hd_ps` is 3.0.0 now and has its own prepass in
// ps/hd_ps_prepass.slang. `crystal_ps` still calls this stub, and
// ps/crystal_ps_depth_prepass.slang has its own alpha-tested body.

implementing wc3_shaders;

// Back-face discard stub used when the alpha-test policy is "off": the
// prepass skips all the alpha math but must still drop back faces that
// the VS marked via negative worldPos.w (see computeFogDepth's
// underWater sign convention).
public void depthPrepassStub(PSInput input)
{
    if (input.worldPos.w < 0)
        discard;
}
