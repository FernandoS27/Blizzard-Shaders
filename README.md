# Blizzard Shaders

An open-source effort to reverse-engineer and reimplement the shaders used by Blizzard's games, then re-pack the results into the engine's own shader-bundle wire formats so they can be dropped back into the game.

Every game here runs on a shared lineage of Blizzard engine tech — the same StormLib SComp compression, the same `.fx` / BLS shader tooling — so the reconstruction toolchain is shared: shaders are authored once in [Slang](https://shader-slang.com/), compiled to the target bytecode, and packed back into the game's bundle format, with correctness verified against the retail blobs.

## Sub-projects

| Game | Status | Details |
| --- | --- | --- |
| **Warcraft III: Reforged** | ✅ Complete & verified | [README-Warcraft3.md](README-Warcraft3.md) |
| **StarCraft II** / **Heroes of the Storm** | ✅ All 18 families reimplemented, validated & packed | [docs/SC2_SHADERS_PLAN.md](docs/SC2_SHADERS_PLAN.md) |

### Warcraft III: Reforged

The complete, shipped-parity half of the repo. All 19 shipped shader families — SD, SD-on-HD, HD, Crystal, water, terrain, foliage, sprite, distortion, PopcornFX particles, and the tonemap — are reimplemented in Slang and re-packed into the game's `.bls` bundles, DX and Metal, with optional OpenGL / Vulkan / WebGPU output for engine ports. Correctness is proven **bit-identical** against the retail DXBC via a custom DXBC interpreter harness. A `custom_shaders` module layers user-authored variants (e.g. a toon / cel-shaded HD look) on top of the reconstruction.

**→ Full build instructions, family list, and the custom-shader guide live in [README-Warcraft3.md](README-Warcraft3.md).**

### StarCraft II / Heroes of the Storm

Active reverse-engineering work targeting the StarCraft II engine (shared with Heroes of the Storm, which uses the same `.fx` über-shaders, `baselinecache.bin` container, and StormLib SComp compression).

Unlike Warcraft III — which ships pre-compiled BLS bundles that give a fixed permutation set and an extractable retail-DXBC anchor — SC2 ships a `MSER` `baselinecache.bin` cache with neither: the permutation set has to be *mined* out of the cache, and the retail bytecode is not extractable at all. Both problems are now solved, and every shader family is reimplemented in Slang under [sc2_shaders/](sc2_shaders/).

Progress so far:

- **Container & compression reversed.** The `baselinecache.bin` / `MSER` format and the StormLib FGK adaptive-Huffman (SComp) decompressor are decoded — see [tools/storm_huffman.py](tools/storm_huffman.py) (a faithful port of StormLib's `huff.cpp`, confirmed against the reversed Wc3 debug build) and [docs/SC2_BASELINECACHE_ANALYSIS.md](docs/SC2_BASELINECACHE_ANALYSIS.md).
- **Family taxonomy mapped.** All 50 shader entry points and their `b_*` permutation axes are catalogued in [docs/SC2_SHADER_FAMILIES.md](docs/SC2_SHADER_FAMILIES.md) (build 41359: **65,369** unique compiled permutations, **101,184** named retail instances).
- **Permutation decode complete.** Every family's key schema is transcribed from its `<Family>_BuildSection` in the retail binary and laid out by the engine's own packing rule (`[104-bit header][own axes][pad to byte][linked sub-sections]`), giving the exact `b_*` feature vector behind each retail permutation — per-family manifests under [sc2_perms/](sc2_perms/).
- **All 18 families reimplemented and validated.** Both stages of every family are ported to Slang and checked **behaviourally bit-exact** against the fxc-compiled original `.fx` for the same decoded permutation: both legs run through the [DXBC interpreter](tools/dxbc_interp.py) on identical random inputs, aligned by constant name / input semantic / output register. Coverage is the *complete* retail permutation set per family, not a sample; the only non-exact results anywhere are two documented interpreter floors (the `pow` rounding difference between fxc and slangc, and the parallax-occlusion ray-march discontinuity).
- **Packed to BLS v1.14.** [compile_all_sc2.py](compile_all_sc2.py) sweeps every permutation to DXBC and [build_sc2_bls.py](build_sc2_bls.py) packs each family+stage into a template-less v1.14 DX50 bundle whose slots are the retail permutation set in retail cache order — **107,976 permutations across 36 bundles**, each one round-trip verified.

**→ The full plan, milestones, and verification strategy live in [docs/SC2_SHADERS_PLAN.md](docs/SC2_SHADERS_PLAN.md); the per-milestone implementation log is in [docs/SC2_SHADERS_IMPLEMENTATION.md](docs/SC2_SHADERS_IMPLEMENTATION.md).**

```sh
python compile_all_sc2.py --all --jobs 24 --skip-existing   # every perm -> DXBC
python build_sc2_bls.py   --all --verify                    # -> bls_out_sc2_1_14/
python tools/sc2_validate_all.py                            # slang vs original .fx
```

## Shared toolchain

The build engine is shared across sub-projects; the SC2 work reuses it directly rather than forking it.

| Path | Purpose |
| --- | --- |
| [compile_all_slang.py](compile_all_slang.py) | The permutation sweep engine — compiles every permutation of every family to a chosen graphics API target (D3D11, Metal, GL, Vulkan, WebGPU). |
| [build_bls.py](build_bls.py) | Packs compiled bytecode into `.bls` bundles. Handles the v1.8 / v1.12 / v1.14 outer containers and the DX / Metal / extra-backend inner layouts. |
| [shader_config.py](shader_config.py) | Merges the per-project family JSONs into a single config view. |
| [tools/](tools/) | Reverse-engineering utilities, including the StormLib SComp / Huffman decompressor shared by the SC2/HotS/Wc3 engines. |
| [docs/](docs/) | Format specifications and per-game reverse-engineering plans and analyses. |
| [re_shaders/](re_shaders/) | Per-family retail disassembly, notes, and comparison reports. |

### Reference documentation

| Document | Covers |
| --- | --- |
| [docs/BLS_FILE_FORMAT_SPECIFICATION.md](docs/BLS_FILE_FORMAT_SPECIFICATION.md) | The BLS shader-bundle wire format (v1.8 / v1.12 / v1.14). |
| [docs/SHADER_VERIFICATION.md](docs/SHADER_VERIFICATION.md) | How reconstructed shaders are verified against retail bytecode. |
| [docs/SC2_BASELINECACHE_ANALYSIS.md](docs/SC2_BASELINECACHE_ANALYSIS.md) | The SC2 `baselinecache.bin` container and its SComp compression. |
| [docs/SC2_SHADER_FAMILIES.md](docs/SC2_SHADER_FAMILIES.md) | The SC2 family taxonomy and per-family permutation axes. |
| [docs/SC2_SHADERS_PLAN.md](docs/SC2_SHADERS_PLAN.md) | The plan to reimplement SC2 `.fx` shaders as Slang → BLS v1.14. |
| [docs/SC2_SHADERS_MODULE_DESIGN.md](docs/SC2_SHADERS_MODULE_DESIGN.md) | The `sc2_shaders` module architecture and validation model. |
| [docs/SC2_SHADERS_IMPLEMENTATION.md](docs/SC2_SHADERS_IMPLEMENTATION.md) | The per-milestone implementation log (M0–M5) and its measured results. |

## License

Source is released under the **BSD 3-Clause License** — see [LICENSE](LICENSE).

An additional [LICENSE-AI.md](LICENSE-AI.md) notice clarifies that AI-generated derivative works are subject to the same attribution and license conditions as any other derivative work.

This project is an independent, fan-made reimplementation and is not affiliated with or endorsed by Blizzard Entertainment. Warcraft III, StarCraft II, and Heroes of the Storm are trademarks of Blizzard Entertainment.
