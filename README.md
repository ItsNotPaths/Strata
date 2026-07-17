# strata-tool

At its core an **svg → obj compiler**: the level *is* a top-down 2D vector
document — an **extended SVG** (`strata:` attribute namespace) of splines and
closed shapes carrying height fields, materials, and gameplay tags — and all
3D (terrain, walls, meshes, collision) is derived by a deterministic
evaluator: fields → world SDF → narrow-band dual-contoured tri-soup →
`level.obj` + a game-agnostic `level.txt` sidecar (meta lines, materials,
markers, portals). The editor is a frontend bolted onto that compiler: a real
scrolling/zooming 2D vector editor (all editing) piloting a live 3D pure
preview, Hammer-style. See `DESIGN.md`.

Successor to `dymeta-tool`'s authoring model (its spline-op editing was
fiddling with the solution instead of stating intent); keeps its backend DNA —
texgen recipe materials, angle splitter, box3d — and folly-editor's
derived-walls idea. Tool-only repo, game-agnostic: any game that reads
obj + the sidecar txt can consume its levels (`folly` is the first target).

Built with Odin; one binary holds the headless CLI (eval / dump / topo) and
the M3 editor: SDL3_GPU 2D vector canvas + live 3D preview, Dear ImGui chrome.
`vendor/` (static SDL3, prebuilt imgui lib, glslang, fonts) is copied from the
sibling `dymeta-tool` checkout.

## Layout

    src/engine/   THE COMPILER. document schema (document.odin), extended-SVG
                  reader/writer (svg.odin / svg_write.odin), 2D geometry
                  (geom.odin), harmonic height-field solver (field.odin),
                  world SDF evaluator — smooth CSG, noise, cliff fins
                  (sdf.odin), narrow-band dual contouring (mesh.odin), topo
                  oracle (topo.odin), OBJ + level-sidecar + checksum output
                  stage (export.odin)
    src/tool/     headless CLI (main.odin) + M3 editor: shell/frame loop
                  (editor.odin), 2D canvas render + edit (canvas2d.odin,
                  canvas_edit.odin), 3D preview (view3d.odin, camera3d.odin),
                  sidebar (sidebar.odin), GPU helpers (gpu.odin), earcut
    shaders/      GLSL -> SPIR-V, #load'ed into the binary
    content/      sample documents + golden outputs (§5)
    tests/        golden.sh — build, evaluate every sample, diff vs goldens
    tool/         built binary (gitignored)

## Build & run

    ./build.sh                                    -> tool/strata
    tool/strata content/samples/canyon.strata.svg        # open the editor
    tool/strata eval content/samples/canyon.strata.svg   # stats + checksum
    tool/strata dump content/samples/canyon.strata.svg   # -> canyon.obj + canyon.txt beside the doc
    tool/strata topo content/samples/canyon.strata.svg   # walkability oracle
    tool/strata resave <doc> <out>                       # writer round-trip
    tests/golden.sh                                      # regression suite (--update)

Editor: `1`/`2` select/node mode, `3`–`9` draw Sector/Path/Solid/Bridge/Hint/
Marker/Cliff (click points, Enter/first-point closes, Ctrl-click = corner node), wheel
zoom, MMB/Space pan, `F` fit, `X` snap, Tab maximize pane, Ctrl+S/Z/Y/D,
F5 re-eval. The 3D pane: RMB orbit, MMB pan, wheel dolly — pure preview.
