# Diablo III Shaders

> Part of **[Blizzard Shaders](README.md)** — see the top-level README for the umbrella project and the
> sibling Warcraft III: Reforged and StarCraft II efforts.

An open-source recreation of the `.fx` über-shaders used by **Diablo III**, reimplemented as one
[Slang](https://shader-slang.com/) module under [d3_shaders/](d3_shaders/) and validated against the
**shipped retail bytecode** through the project's [DXBC interpreter](tools/dxbc_interp.py).

The game's shader atlas ships 4,117 DXBC permutation keys: 2,848 in the 105 `(fx, entry point)` families
with two or more permutations, and 1,269 **residue** keys -- the only permutation of their family, or
named by no shipped Shaders asset, or by assets that disagree on the entry point. They compile to
**2,156 distinct programs**. This project reproduces exactly that permutation set: every distinct retail
program is one slot of one of **8 bundles** (pixel | vertex × legacy / surface / actor / utility), and
every slot

* **declares** what its retail program declares, row for row — interpolant and vertex-stream
  signatures, texture and sampler registers, constant-buffer layout; and
* **behaves** like its retail program on a ~450-trial differential per slot: **1,895 slots bit-exact**,
  **261 order-only** (the same real-valued function, evaluated in a different float32 order), **0 failing**.

## How this differs from Warcraft III and StarCraft II

| | Warcraft III | StarCraft II | **Diablo III** |
| --- | --- | --- | --- |
| Reference | retail DXBC | fxc on the original `.fx` | **retail DXBC** |
| Permutation identity | engine index | cache key | **content hash** — a slot is a distinct program |
| Bundle unit | family | family × stage | **domain × stage**; the 105 retail families are subfamilies of 23 roots, which also hold the residue |
| Profile | SM5 | SM5 | **SM4** throughout |

Two Diablo III facts shape the module:

* **Interpolant layout is data.** fxc packs signature elements in declaration order, and retail declares
  the same semantics in different orders and widths from permutation to permutation. The layouts
  (`D3Interpolants`, `D3VertexIn`) are therefore positional structs whose types and semantics come from
  each slot's measured retail signature; roots only use semantic accessors.
* **The alpha test has four spellings.** `a <= ref`, `a < ref` and their inversions are distinct retail
  programs that differ only at exact ties and NaN. Each slot's spelling is measured from its program,
  and the differential runs tie trials and NaN-reference trials to check it.

## What's in the repo

| Path | Contents |
| --- | --- |
| [d3_shaders/](d3_shaders/) | The Slang module: `types/` (constant buffers, measured layouts, texture roles), `math/`, `interfaces/`, and `roots/{legacy,surface,actor,utility}/` |
| [d3_shaders.json](d3_shaders.json) | Bundles, roots, and the retail subfamilies each root reproduces |
| [d3_perms/](d3_perms/) | The frozen permutation set: one slot list per bundle with each slot's retail keys and measured axes; `_residue_keys.json` the atlas evidence per residue key; `_spec_notes.md` audits the RE reconstructions against retail |
| [d3_residue.json](d3_residue.json) | Where each residue program lands: its root and specialization (a residue key has no local defines to translate) |
| [tools/d3_residue.py](tools/d3_residue.py) | Extracts the residue programs from the shader atlas (`$D3_RE_RESIDUE`) and checks the census |
| [compile_all_d3.py](compile_all_d3.py) | Compiles every slot to a graphics-API target (D3D11 SM4 by default) |
| [build_d3_bls.py](build_d3_bls.py) | Packs the slots into template-less BLS v1.14 bundles and verifies the written files |
| [tools/d3_validate_all.py](tools/d3_validate_all.py) | Declaration surface + behavioural differential of every slot against retail |
| [tools/d3_shaders_cfg.py](tools/d3_shaders_cfg.py), `tools/d3_cfg_*.py` | The slot → compile-spec mapper (translators per retail subfamily) |
| [docs/D3_SHADERS_MODULE_DESIGN.md](docs/D3_SHADERS_MODULE_DESIGN.md), [docs/D3_SHADERS_PLAN.md](docs/D3_SHADERS_PLAN.md), [docs/D3_SHADERS_PORTING_GUIDE.md](docs/D3_SHADERS_PORTING_GUIDE.md) | Design, execution plan with measured results, and the guide for extending a root |

## Bundles

| Bundle | Roots | Slots | Exact | Order-only |
| --- | --- | ---: | ---: | ---: |
| `pixel/legacy.bls` | `combiner_ps` (fixed-function stage combiner), `legacy_aux_ps`, `legacy_fixed_ps` (`_v11` fallbacks, UI and debug views), `depth_clear_ps` | 751 | 740 | 11 |
| `vertex/legacy.bls` | `texgen_vs`, `particle_vs`, `restore_vs` | 517 | 472 | 45 |
| `pixel/surface.bls` | `scene_ps`, `landscape_ps`, `water_ps` | 549 | 348 | 201 |
| `vertex/surface.bls` | `surface_vs` | 96 | 96 | 0 |
| `pixel/actor.bls` | `actor_ps` | 91 | 91 | 0 |
| `vertex/actor.bls` | `actor_vs` | 81 | 81 | 0 |
| `pixel/utility.bls` | `cookie_ps`, `blur_ps`, `texfilter_ps`, `texdepth_ps`, `postfx_ps` (tonemap, FXAA, minimap, ...) | 60 | 56 | 4 |
| `vertex/utility.bls` | `cookie_vs`, `filter_vs`, `texfilter_vs`, `cookie_tint_vs`, `postfx_vs` | 11 | 11 | 0 |
| **Total** | **23 roots** | **2,156** | **1,895** | **261** |

## Requirements

* **Python 3.8+** (standard library only) and **`slangc`** (Vulkan SDK or a Slang release).
* For **validation only**: the Diablo III retail shader tree extracted as `d3_re_shaders/`
  (`perm_<hash>.dxbc` + `.asm` per family, pointed to by `$D3_RE`), the residue programs as
  `d3_re_residue/<ps|vs>/<hash>.dxbc` (`$D3_RE_RESIDUE`, written by `tools/d3_residue.py extract`) and
  3Dmigoto's `cmd_Decompiler`.
  Building the bundles needs neither — the permutation set is committed in `d3_perms/`.

## Building and validating

```sh
python compile_all_d3.py --all --jobs 16                 # 2,156 slots -> d3_slang_out/d3d11/
python build_d3_bls.py   --all --complete --verify       # -> bls_out_d3_1_14/shaders/<pixel|vertex>/dx_5_0/

python tools/d3_perm_manifest.py --check --partition     # D0 permutation set, D1 spec partition
python tools/d3_validate_all.py --all --fold             # D2 declarations, D4 behaviour, D5 folds
python tools/d3_mutate.py                                # D8: 363 deliberate breakages, all must be caught
python tools/d3_style_lint.py                            # D9
python tools/d3_retail_controls.py                       # harness self-checks on retail alone
python tools/d3_coverage.py                              # every retail decision reached by the schedule
```

### Other backends

```sh
python compile_all_d3.py --all --target d3d12,vulkan,opengl,metal,webgpu
python tools/d3_backends.py                              # spirv-val, glslangValidator -V, naga
```

Non-D3D targets get explicit bindings for the shared binding space, and WebGPU omits the clip-distance
interpolants it cannot express; the D3D11 bytecode is unaffected.

### The WhiteoutFlakes engine target

`D3_TARGET_FLAKES` builds the same programs for the WhiteoutFlakes renderer, which cannot feed retail's
per-program declarations: it has one vertex record for every mesh, binds by its own per-backend scheme
and pairs any vertex slot with any pixel slot. The target keeps what each slot computes and swaps what
it declares ([tools/d3_flakes.py](tools/d3_flakes.py)):

* **Vertex input** is one fixed stream (`types/streams.slang`): the engine's 68-byte mesh record plus
  its 8-byte bone stream, or retail's own 56-byte particle vertex. The retail accessors rebuild each
  retail stream from it exactly -- the packed bytes re-encoded from the engine's decoded floats -- and a
  slot declares the bone elements only when it reads them.
* **Interpolants** keep the retail layout on D3D. Vulkan, WebGPU and Metal link by location (Metal by
  `[[user(D3REG_<register>)]]`), so there each retail register is one float4 at `location = register`,
  and the clip distances are dropped.
* **Bindings**: CBs at b0-b2 and textures / samplers at the retail register, shifted per stage into the
  engine's sets (Vulkan) or groups (WebGPU); Metal's per-stage argument tables take them unshifted
  (`[[buffer(b)]]`, `[[texture(t)]]`, `[[sampler(s)]]`). CBBones holds the engine's 256 bones; the
  irradiance cube is a cube array read at slice 0.

```sh
python compile_all_d3.py --all --target flakes            # flakes-d3d11, -d3d12, -vulkan, -webgpu, -metal
python build_d3_bls.py   --all --target flakes --verify   # -> bls_out_d3_flakes/ + d3_flakes_slots.json
python tools/d3_flakes_metal_check.py --all               # Metal interface of every slot, CB layouts
python tools/d3_flakes_gate.py --all                      # D4 on the engine target (D3D11)
python tools/d3_flakes_xcheck.py --all --static           # Vulkan / WebGPU interface of every slot
python tools/d3_flakes_xcheck.py --all --sample 12        # Vulkan / WebGPU behaviour, via spirv-cross + fxc
python tools/d3_backends.py                               # spirv-val, naga
```

The gate feeds every trial as packed retail data -- seen by retail through retail's input layout and by
the engine build through the engine's records -- and requires the engine build to be exact wherever the
retail-target build is exact under the same trials, and order-only where that is: all 2,152 built slots
pass (1,891 exact, 261 order-only). A stream the engine record has no exact source for is fed its stand-in
on both legs (a float uv0 / uv1 stream, as utility quads declare, reads the record's xy, then 0 and 1).
The manifest lists per slot the retail program hashes it reproduces, its stream kind, bone use and
stand-ins (vertex), its texture and sampler registers (pixel), and the backends it runs on; a slot a
backend cannot hold is a null permutation there. The four multisampled depth copies (`texture2dms`) are
null on every engine backend, and `d3_perms/_flakes_exceptions.json` leaves `clear_depth` null on WebGPU
(WGSL clamps `frag_depth` inside the shader, which the cross-check cannot prove against retail). Vulkan
binds the pixel stage's t16-t19 at set 1 bindings 36-39, past its storage buffers, and s16-s19 at set 2
bindings 32-35, so the 18 landscape slots that bind t16/t17 run there; every other built slot runs on
all four backends.

On Metal every built slot runs except the 18 landscape pixel slots that bind t16/t17 (the engine's
Metal device binds texture and sampler indices 0-15 per stage) and the four multisampled depth copies. `compile_all_d3.py` writes `.metal` source on any host; macOS links it
(`tools/metal_compile_libs.py --slang-out d3_slang_out --subdir flakes-metal --pattern 'slot_*.metal'`)
and `build_d3_bls.py` packs the `.metallib`s into the v1.8 MTLB bundles the engine already reads for
Warcraft III (`shaders/<pixel|vertex>/metal/`), recording them in `d3_flakes_slots.metal.json`. So
`--target flakes` packs Metal only where `.metallib`s exist; elsewhere it takes Metal's slots from that
record while each slot's compile spec still matches. The manual workflow
[build-d3-metal-bls.yml](.github/workflows/build-d3-metal-bls.yml) runs both stages -- Windows, because
the vertex reads need fxc, then macOS -- with the Vulkan SDK's slangc, the one every D3 bundle is built
with (slang 2026.9.2 rejects the retail D3D11 build's float4 `SV_ClipDistance`). It uploads the bundles
as `prebuilt/shaders/metal/{ps,vs}/d3/` for WhiteoutFlakes and, with their record, for
`bls_out_d3_flakes/`.
