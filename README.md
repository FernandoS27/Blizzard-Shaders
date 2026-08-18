# Blizzard Shaders

**Blizzard Shaders** is an open-source recreation of the shaders used by Blizzard's games. The shaders are reverse-engineered from the games' shipped shader containers, reimplemented in [Slang](https://shader-slang.com/), verified against the retail bytecode, and re-packed into the engine's own shader-bundle wire formats so they can be dropped back into the game.

The project currently covers **Warcraft III: Reforged** and **StarCraft II** (whose engine is shared with **Heroes of the Storm**), with **World of Warcraft** shaders planned in the future.

All of these games run on a shared lineage of Blizzard engine tech — the same StormLib SComp compression and the same `.fx` / BLS shader tooling — so the reconstruction toolchain is shared across sub-projects: shaders are authored once in Slang, compiled to the target bytecode, verified against the retail blobs, and packed back into each game's bundle format.

## Sub-projects

| Game | Status | Details |
| --- | --- | --- |
| **Warcraft III: Reforged** | ✅ Complete & verified | [README-Warcraft3.md](README-Warcraft3.md) |
| **StarCraft II** / **Heroes of the Storm** | ✅ All 18 families reimplemented, validated & packed | [docs/SC2_SHADERS_PLAN.md](docs/SC2_SHADERS_PLAN.md) |
| **World of Warcraft** | 🔮 Planned | — |

### Warcraft III: Reforged

The complete, shipped-parity half of the repo. All 19 shipped shader families — SD, SD-on-HD, HD, Crystal, water, terrain, foliage, sprite, distortion, PopcornFX particles, and the tonemap — are reimplemented in Slang and re-packed into the game's `.bls` bundles, DX and Metal, with optional OpenGL / Vulkan / WebGPU output for engine ports. Correctness is proven **bit-identical** against the retail DXBC via a custom DXBC interpreter harness. A `custom_shaders` module layers user-authored variants (e.g. a toon / cel-shaded HD look) on top of the reconstruction.

**→ Full build instructions, family list, and the custom-shader guide live in [README-Warcraft3.md](README-Warcraft3.md).**

### StarCraft II / Heroes of the Storm

A recreation of the StarCraft II engine's `.fx` über-shaders (shared with Heroes of the Storm, which uses the same shaders, `baselinecache.bin` container, and StormLib SComp compression).

Unlike Warcraft III — which ships pre-compiled BLS bundles that give a fixed permutation set and an extractable retail-DXBC anchor — SC2 ships a `MSER` `baselinecache.bin` cache with neither: the permutation set had to be *mined* out of the cache, and the retail bytecode is not directly extractable. Both problems are solved, and every shader family is reimplemented in Slang under [sc2_shaders/](sc2_shaders/):

- **Container & compression reversed.** The `baselinecache.bin` / `MSER` format and the StormLib FGK adaptive-Huffman (SComp) decompressor are decoded — see [tools/storm_huffman.py](tools/storm_huffman.py) and [docs/SC2_BASELINECACHE_ANALYSIS.md](docs/SC2_BASELINECACHE_ANALYSIS.md).
- **Family taxonomy mapped.** All 50 shader entry points and their `b_*` permutation axes are catalogued in [docs/SC2_SHADER_FAMILIES.md](docs/SC2_SHADER_FAMILIES.md) (build 41359: **65,369** unique compiled permutations, **101,184** named retail instances).
- **Permutation decode complete.** Every family's key schema is transcribed from the engine's own `<Family>_BuildSection` packing rule, giving the exact `b_*` feature vector behind each retail permutation — per-family manifests under [sc2_perms/](sc2_perms/).
- **All 18 families reimplemented and validated.** Both stages of every family are ported to Slang and checked **behaviourally bit-exact** against the fxc-compiled original `.fx` for the same decoded permutation, over the *complete* retail permutation set — not a sample.
- **Packed to BLS v1.14.** [compile_all_sc2.py](compile_all_sc2.py) sweeps every permutation to DXBC and [build_sc2_bls.py](build_sc2_bls.py) packs each family+stage into v1.14 bundles whose slots follow retail cache order — **107,976 permutations across 36 bundles**, each round-trip verified.
- **Portable across backends.** The same module compiles to D3D12 DXIL, Vulkan SPIR-V, Metal, WGSL and GLSL as well as the shipped D3D11 DXBC — `compile_all_sc2.py --target` selects the API and `--sample N` compiles a subset per family chosen to exercise every `b_*` axis value, so a portability check costs minutes instead of a 108k-permutation sweep. The reconstruction itself is unaffected: the D3D11 bytecode stays byte-identical, so the bundles and the bit-exactness proof are untouched.

**→ The full plan, milestones, and verification strategy live in [docs/SC2_SHADERS_PLAN.md](docs/SC2_SHADERS_PLAN.md); the per-milestone implementation log is in [docs/SC2_SHADERS_IMPLEMENTATION.md](docs/SC2_SHADERS_IMPLEMENTATION.md).**

```sh
python compile_all_sc2.py --all --jobs 24 --skip-existing   # every perm -> DXBC
python build_sc2_bls.py   --all --verify                    # -> bls_out_sc2_1_14/
python tools/sc2_validate_all.py                            # slang vs original .fx

# portability check: every family, every other backend, 12 perms per stage
python compile_all_sc2.py --all --target d3d12,vulkan,webgpu,metal,opengl --sample 12
```

### World of Warcraft (planned)

World of Warcraft shaders are the next planned target. The shared toolchain — Slang authoring, permutation sweeping, retail-bytecode verification, and bundle re-packing — is designed to extend to it the same way it was extended from Warcraft III to StarCraft II.

## How it works

Every sub-project follows the same pipeline:

1. **Reverse-engineer the container.** Decode the game's shader-bundle format (BLS, `baselinecache.bin`, …) and its compression to enumerate every shipped shader permutation.
2. **Reconstruct the shaders in Slang.** Each family becomes a Slang über-shader whose preprocessor axes mirror the engine's own permutation flags.
3. **Verify against retail.** Compiled output is compared against the retail bytecode — bit-identical DXBC where the retail blobs are extractable, or behaviourally bit-exact through a custom [DXBC interpreter](tools/dxbc_interp.py) on random inputs where they are not.
4. **Re-pack into the game's format.** The verified bytecode is packed back into the engine's own bundle wire format so the shaders drop straight back into the game.

## Shared toolchain

| Path | Purpose |
| --- | --- |
| [compile_all_slang.py](compile_all_slang.py) | The permutation sweep engine — compiles every permutation of every family to a chosen graphics API target (D3D11, Metal, GL, Vulkan, WebGPU). |
| [build_bls.py](build_bls.py) | Packs compiled bytecode into `.bls` bundles. Handles the v1.8 / v1.12 / v1.14 outer containers and the DX / Metal / extra-backend inner layouts. |
| [shader_config.py](shader_config.py) | Merges the per-project family JSONs into a single config view. |
| [tools/](tools/) | Reverse-engineering utilities, including the DXBC interpreter and the StormLib SComp / Huffman decompressor shared by the SC2/HotS/Wc3 engines. |
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

This project is an independent, fan-made reimplementation and is not affiliated with or endorsed by Blizzard Entertainment. Warcraft III, StarCraft II, Heroes of the Storm, and World of Warcraft are trademarks of Blizzard Entertainment.

## A note on AI use

AI tools are used in this project to generate scripts that assist the reverse-engineering work, to document code, to transpile reverse-engineered shader mockups to Slang, and to help find matches when reconstructing the über-shaders from their compiled permutations. The reverse engineering itself, the analysis, and the verification methodology are human-driven; AI output is always validated against the retail bytecode like every other part of the project.
