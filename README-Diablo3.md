# Diablo III Shaders

> Part of **[Blizzard Shaders](README.md)** — see the top-level README for the umbrella project and the
> sibling Warcraft III: Reforged and StarCraft II efforts.

An open-source recreation of the `.fx` über-shaders used by **Diablo III**, reimplemented as one
[Slang](https://shader-slang.com/) module under [d3_shaders/](d3_shaders/) and validated against the
**shipped retail bytecode** through the project's [DXBC interpreter](tools/dxbc_interp.py).

The game ships 2,848 retail permutation keys across 105 `(fx, entry point)` families, which compile to
**1,594 distinct programs**. This project reproduces exactly that permutation set: every distinct retail
program is one slot of one of **8 bundles** (pixel | vertex × legacy / surface / actor / utility), and
every slot

* **declares** what its retail program declares, row for row — interpolant and vertex-stream
  signatures, texture and sampler registers, constant-buffer layout; and
* **behaves** like its retail program on a ~450-trial differential per slot: **1,360 slots bit-exact**,
  **234 order-only** (the same real-valued function, evaluated in a different float32 order), **0 failing**.

## How this differs from Warcraft III and StarCraft II

| | Warcraft III | StarCraft II | **Diablo III** |
| --- | --- | --- | --- |
| Reference | retail DXBC | fxc on the original `.fx` | **retail DXBC** |
| Permutation identity | engine index | cache key | **content hash** — a slot is a distinct program |
| Bundle unit | family | family × stage | **domain × stage**; the 105 retail families are subfamilies of 14 roots |
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
| [d3_perms/](d3_perms/) | The frozen permutation set: one slot list per bundle with each slot's retail keys and measured axes; `_spec_notes.md` audits the RE reconstructions against retail |
| [compile_all_d3.py](compile_all_d3.py) | Compiles every slot to a graphics-API target (D3D11 SM4 by default) |
| [build_d3_bls.py](build_d3_bls.py) | Packs the slots into template-less BLS v1.14 bundles and verifies the written files |
| [tools/d3_validate_all.py](tools/d3_validate_all.py) | Declaration surface + behavioural differential of every slot against retail |
| [tools/d3_shaders_cfg.py](tools/d3_shaders_cfg.py), `tools/d3_cfg_*.py` | The slot → compile-spec mapper (translators per retail subfamily) |
| [docs/D3_SHADERS_MODULE_DESIGN.md](docs/D3_SHADERS_MODULE_DESIGN.md), [docs/D3_SHADERS_PLAN.md](docs/D3_SHADERS_PLAN.md), [docs/D3_SHADERS_PORTING_GUIDE.md](docs/D3_SHADERS_PORTING_GUIDE.md) | Design, execution plan with measured results, and the guide for extending a root |

## Bundles

| Bundle | Roots | Slots | Exact | Order-only |
| --- | --- | ---: | ---: | ---: |
| `pixel/legacy.bls` | `combiner_ps` (fixed-function stage combiner), `legacy_aux_ps` | 540 | 531 | 9 |
| `vertex/legacy.bls` | `texgen_vs`, `particle_vs` | 393 | 351 | 42 |
| `pixel/surface.bls` | `scene_ps`, `landscape_ps`, `water_ps` | 456 | 273 | 183 |
| `vertex/surface.bls` | `surface_vs` | 74 | 74 | 0 |
| `pixel/actor.bls` | `actor_ps` | 62 | 62 | 0 |
| `vertex/actor.bls` | `actor_vs` | 57 | 57 | 0 |
| `pixel/utility.bls` | `cookie_ps`, `blur_ps` | 8 | 8 | 0 |
| `vertex/utility.bls` | `cookie_vs`, `filter_vs` | 4 | 4 | 0 |
| **Total** | **14 roots** | **1,594** | **1,360** | **234** |

## Requirements

* **Python 3.8+** (standard library only) and **`slangc`** (Vulkan SDK or a Slang release).
* For **validation only**: the Diablo III retail shader tree extracted as `d3_re_shaders/`
  (`perm_<hash>.dxbc` + `.asm` per family, pointed to by `$D3_RE`) and 3Dmigoto's `cmd_Decompiler`.
  Building the bundles needs neither — the permutation set is committed in `d3_perms/`.

## Building and validating

```sh
python compile_all_d3.py --all --jobs 16                 # 1,594 slots -> d3_slang_out/d3d11/
python build_d3_bls.py   --all --complete --verify       # -> bls_out_d3_1_14/shaders/<pixel|vertex>/dx_5_0/

python tools/d3_perm_manifest.py --check --partition     # D0 permutation set, D1 spec partition
python tools/d3_validate_all.py --all --fold             # D2 declarations, D4 behaviour, D5 folds
python tools/d3_mutate.py                                # D8: 196 deliberate breakages, all must be caught
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
