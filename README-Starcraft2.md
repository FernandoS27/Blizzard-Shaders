# StarCraft II / Heroes of the Storm Shaders

> Part of **[Blizzard Shaders](README.md)** — see the top-level README for the
> umbrella project and the sibling Warcraft III: Reforged effort.

An open-source recreation of the `.fx` über-shaders used by **StarCraft II** — and, unchanged, by **Heroes of the Storm**, which shares the same engine, shaders, `baselinecache.bin` shader cache, and StormLib SComp compression.

All **18 shader families** — the Model über-shader (whose pixel root is shared by Particle, Ribbon and Foliage), the splat / terrain-blend / water surfaces, and the full-screen stack (DeferredLight, PostProcessQuad, HDR, Bokeh, Image, Flash, LensFlare, RenderPlane, MinimapTerrain, Simple) — are reimplemented in [Slang](https://shader-slang.com/) under [sc2_shaders/](sc2_shaders/), validated **behaviourally bit-exact** against the fxc-compiled original `.fx` over the *complete* retail permutation set, and packed into BLS v1.14 bundles whose slots follow retail cache order: **107,976 permutations across 36 bundles**, each round-trip verified.

## How this differs from Warcraft III

Warcraft III ships pre-compiled BLS bundles, so its permutation set is explicit and the retail DXBC is directly extractable — correctness can be proven byte-for-byte. SC2 ships neither: its `baselinecache.bin` (`MSER`) cache had to be reverse-engineered end-to-end.

- **The container and its compression were decoded.** [tools/sc2_cache.py](tools/sc2_cache.py) parses the `MSER` container and each permutation's RLE-encoded key; [tools/sc2_d3d_decode.py](tools/sc2_d3d_decode.py) decodes the compressed D3D shader blobs.
- **The permutation keys were fully decoded.** Every family's key schema is transcribed from the engine's own section-packing rule, giving the exact `b_*` feature vector behind each retail permutation. The resulting per-family manifests are committed under [sc2_perms/](sc2_perms/), so the retail cache is *not* needed to build.
- **Verification is behavioural.** With no extractable retail bytecode to diff, each ported permutation is compiled with `slangc`, the matching original `.fx` permutation is compiled with `fxc`, and both are executed on random inputs by the [DXBC interpreter](tools/dxbc_interp.py); outputs must agree bit-exactly, with documented tolerance floors only where fxc and slangc round transcendentals (`pow` / `log2`) differently.

## What's in the repo

| Path | Contents |
| --- | --- |
| [sc2_shaders/](sc2_shaders/) | Slang source for the reconstruction. One unified module ([sc2_shaders.slang](sc2_shaders/sc2_shaders.slang)) exposes one entry point per family and stage. |
| [sc2_shaders.json](sc2_shaders.json) | Declarative family config: original `.fx` entry points, slang entry points, permutation counts, BLS bundle names. |
| [sc2_perms/](sc2_perms/) | Per-family, per-stage permutation manifests mined from the retail cache — cache-order slot lists with each slot's decoded `b_*` feature vector. |
| [compile_all_sc2.py](compile_all_sc2.py) | Compiles every permutation of every family to a chosen graphics API target (D3D11 by default). |
| [build_sc2_bls.py](build_sc2_bls.py) | Packs the compiled DXBC into BLS v1.14 bundles in retail cache order, with full round-trip verification. |
| [tools/sc2_validate_all.py](tools/sc2_validate_all.py) | Whole-module behavioural validation: slang candidate vs fxc-compiled original `.fx` through the DXBC interpreter. |
| [tools/sc2_cache.py](tools/sc2_cache.py) | `baselinecache.bin` (`MSER`) miner: parses the container and decodes the RLE-encoded permutation keys. |
| [tools/sc2_perm_manifest.py](tools/sc2_perm_manifest.py) | Turns mined cache records into the per-family manifests under `sc2_perms/`. |

## Shader families

Defined in [sc2_shaders.json](sc2_shaders.json); each family's permutation set (and its decoded `b_*` axes) comes from its manifest in [sc2_perms/](sc2_perms/). Counts are the retail permutation sets of build 41359.

| Family | VS perms | PS perms | Ships as |
| --- | ---: | ---: | --- |
| `Model` | 25,696 | 50,322 | `model.bls` |
| `Particle` | 6,154 | 10,637 | `particle.bls` |
| `Ribbon` | 2,192 | 3,161 | `ribbon.bls` |
| `Foliage` | 96 | 349 | `foliage.bls` |
| `SplatDirect` | 196 | 3,488 | `splatdirect.bls` |
| `SplatDeferred` | 12 | 468 | `splatdeferred.bls` |
| `TerrainBlend` | 9 | 54 | `terrainblend.bls` |
| `Water` | 17 | 66 | `water.bls` |
| `Image` | 7 | 3,520 | `image.bls` |
| `PostProcessQuad` | 23 | 1,031 | `postprocessquad.bls` |
| `HDR` | 1 | 320 | `hdr.bls` |
| `DeferredLight` | 8 | 82 | `deferredlight.bls` |
| `Bokeh` | 1 | 21 | `bokeh.bls` |
| `Flash` | 5 | 14 | `flash.bls` |
| `LensFlare` | 1 | 8 | `lensflare.bls` |
| `Simple` | 1 | 6 | `simple.bls` |
| `RenderPlane` | 1 | 4 | `renderplane.bls` |
| `MinimapTerrain` | 1 | 4 | `minimapterrain.bls` |

Totals: **34,421** vertex + **73,555** pixel permutations = **107,976** across **36** bundles.

Particle, Ribbon and Foliage have no dedicated pixel entry — their `.fx` files reuse the shared `DefaultPixelMain` root (slang `model_ps_main`); the counts above are each family's own retail permutation set and bundle.

## Requirements

- **Python 3.8+** (standard library only — no dependencies).
- **`slangc`** from the [Shader Slang](https://github.com/shader-slang/slang) compiler (via the [Vulkan SDK](https://vulkan.lunarg.com/) or a standalone Slang release).
- For **validation only**: `fxc.exe` from the Windows SDK, plus the game's original `.fx` shader sources — extract `mods/core.sc2mod/base.sc2data/shaders/` from your StarCraft II installation with a CASC extractor into the repo root. These are **not** included in this repo, and compiling / packing the bundles needs neither.

## Building

```sh
python compile_all_sc2.py --all --jobs 24 --skip-existing   # every perm -> DXBC under sc2_slang_out/
python build_sc2_bls.py   --all --verify                    # -> bls_out_sc2_1_14/shaders/<pixel|vertex>/dx_5_0/
python tools/sc2_validate_all.py                            # slang vs original .fx (requires fxc + retail .fx tree)
```

### Other backends

The same module compiles to D3D12 DXIL, Vulkan SPIR-V, Metal, WGSL and GLSL as well as the shipped D3D11 DXBC. `compile_all_sc2.py --target` selects the API, and `--sample N` compiles a per-family subset chosen to exercise every `b_*` axis value, so a portability check costs minutes instead of a 108k-permutation sweep:

```sh
python compile_all_sc2.py --all --target d3d12,vulkan,webgpu,metal,opengl --sample 12
```

The D3D11 bytecode stays byte-identical regardless of which extra targets are built, so the bundles and the bit-exactness validation are unaffected.
