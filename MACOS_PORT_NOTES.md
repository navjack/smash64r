# smash64r — macOS port notes

**Status: COMPLETE.** Installed at `/Applications/Smash64r.app`. Boots, renders the
Super Smash Bros. title sequence on RT64's Metal backend, and accepts a ROM through the
native file picker.

This project had **never been built for macOS** — there is no macOS CI job — so everything
below is new work rather than a fix to an existing platform.

## Correction to the earlier assessment

The plan listed four blockers (window handle, CMake block, config path, `lib/sse2neon`).
All four were real but minor, and one was a false alarm. The actual blocker was the pinned
**rt64**, which predates the Metal backend entirely.

## 1 — Decomp (`lib/ssb-decomp-re`)

Produces a **matching build**: the rebuilt ROM is byte-identical to the baserom
(sha1 `e2929e10fccc0aa84e5776227e798abc07cedabf`), which is what validates the three
toolchain fixes below as byte-correct rather than merely quiet.

```bash
cd lib/ssb-decomp-re
export PATH="$PWD/.macos-tools:/opt/homebrew/opt/make/libexec/gnubin:$PATH"
source .venv/bin/activate        # see the PYTHON note below
gmake extract && gmake all -j8
```

**Toolchain:** `.macos-tools/` holds `mips-elf-*` symlinks to the binutils DKR built
(`dkr/extern/dkr-decomp/tools/binutils/mips64-elf-*`); the Darwin branch at `Makefile:24-34`
wants the `mips-elf` prefix and `elf32-bigmips`, both of which those satisfy. Compilation
uses IDO, not MIPS GCC, so only binutils is needed. Use Python **3.13** (3.14 has no
`rabbitizer` wheel).

**`Makefile:65` sets `PYTHON := python3`**, clobbering the venv-aware assignment made 25
lines earlier — the Makefile defeats its own venv support. Activate the venv; do not rely
on autodetection.

### The `nonmatching` / `enddlabel` macros

`include/macro.inc` defines `glabel`, `dlabel` and `jlabel` but not `nonmatching` (635
uses) or `enddlabel` (295). Both are spimdisasm `GlobalConfig` defaults — `ASM_NM_LABEL`
and `ASM_DATA_END_LABEL` — that **splat does not expose as options**, so they cannot be
turned off from `smashbrothers.yaml`. splat only wires up `ASM_TEXT_LABEL`,
`ASM_TEXT_ALT_LABEL`, `ASM_JTBL_LABEL`, `ASM_DATA_LABEL` and `ASM_END_LABEL`.

Two things that were previously recorded here wrongly, both now settled by inspection:

- **Regenerating `asm/` does not remove them.** A clean `gmake extract` emits them again.
- **`nonmatching` never stands in for a label.** All 635 markers are followed by a real
  `glabel`/`dlabel`, and all 295 `enddlabel` markers by their own `.size`. They are purely
  informational, so defining them as no-ops is safe. Do **not** delete the markers from the
  generated asm — `asm/` is gitignored splat output and they come straight back.

Fixes:

1. `include/macro.inc` — define both macros as no-ops (`nonmatching` needs `size=0`; the
   size argument is absent for symbols of unknown length).
2. `tools/asm-processor/asm_processor.py` — rewrite both markers to comments in
   `process_line`. The assembly this tool emits goes to a temp file that does **not**
   include `macro.inc`, so a macro definition cannot cover it. Neutralize in place rather
   than dropping the line: `asm_conts` is positionally tied to `num_lines` via
   `fn_ins_inds`, and removing an entry silently loses the function body.
3. Same file — translate `.align 3` inside `.late_rodata` (one occurrence) to
   asm-processor's own `late_rodata_alignment` mechanism instead of rejecting it.

> **Trap:** the Makefile does not declare `asm_processor.py` as a prerequisite of the
> objects it generates, so editing the code generator leaves every existing `.o` looking up
> to date and make keeps stale output. Any asm-processor change needs `rm -rf build/src` to
> be tested at all. Two fixes here appeared to fail for exactly this reason — the identical
> undefined-reference list each time was the tell.

## 2 — Recompiler

Build this project's own N64Recomp (never share one across projects):

```bash
cmake -S lib/N64ModernRuntime/N64Recomp -B build-n64recomp -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-n64recomp -j8
cp build-n64recomp/N64Recomp build-n64recomp/RSPRecomp .
cp lib/ssb-decomp-re/build/smashbrothers.us.elf .
cp lib/ssb-decomp-re/baserom.us.z64 smashbrothers.us.z64
./N64Recomp smashbrothers.us.toml    # 11,447 functions -> 145 files
./RSPRecomp n_aspMain.us.toml
```

**fmt 10.2.2 cannot compile under AppleClang 21** — its consteval format-string parsing is
rejected (`base.h:757`, `remove_prefix` "not valid in a constant expression"). It breaks
fmt's own `os.cc` and `format-inl.h`, not just consumer code, so stripping `FMT_STRING` at
call sites is a losing game. Fix the version gate instead: in
`lib/fmt/include/fmt/base.h`, force `FMT_USE_CONSTEVAL 0` on `__apple_build_version__`.
Format strings are then checked at run time, the same path fmt uses for every older
compiler, and every translation unit including the header stays consistent.

**No entrypoint patch needed here.** N64Recomp's signedness bug (see `dkr/MACOS_PORT_NOTES.md`)
is present but harmless: `entry` sits at ROM `0x1000`, so the `rom_address == 0x1000`
fallback fires.

## 3 — The real blocker: rt64 predates Metal

Upstream pins **rt64 `88c618c`** (`frame-pacing-hotfix~73`), which has only `d3d12` and
`vulkan` backends — no Metal, no plume — and its Vulkan backend has **no `__APPLE__`
surface creation at all** (Win32, Android and Xlib only). There is no path by which it
renders on macOS. `RenderWindow { NSWindow* window; }` exists in the headers but nothing
consumes it.

Meanwhile `src/main/rt64_render_context.cpp:208-211` already assigns `.window` **and**
`.view` — the newer plume-era shape. Upstream wrote Apple-aware code against an rt64 they
never bumped to; it could never have compiled.

**Fix: bump `lib/rt64` to `6f1c2d9`** (the commit banjo and DKR both use successfully) and
migrate the RHI. Two things made this tractable:

- `ultramodern/renderer_context.hpp` already defines Apple's `WindowHandle` as
  `{void* window; void* view;}`, so N64ModernRuntime needed no change.
- The migration is mechanical: 139 references across two files, `RT64::Render*` ->
  `plume::Render*`. `RT64::Application`, `ApplicationConfiguration`,
  `EnhancementConfiguration`, `SetRenderHooks` and `UserConfiguration` stay in `RT64`.
  `rt64_render_interface_builders.h` becomes `plume_render_interface_builders.h`, and
  `lib/rt64/src/contrib/plume` joins the include dirs.

Post-bump chores: symlink `plume/contrib/metal-cpp` into `rt64/src/contrib/`, and add the
missing `<stdlib.h>` to hlslpp's `scalar.h` for `labs()` (rt64 forces `HLSLPP_SCALAR` on
Apple Silicon, so that header really is compiled).

## 4 — App fixes

| Issue | Fix |
|---|---|
| `static_assert(false && "Unimplemented")` at `main.cpp:149` | `__APPLE__` branch returning `{wmInfo.info.cocoa.window, SDL_Metal_GetLayer(view)}`, plus `SDL_WINDOW_METAL \| SDL_WINDOW_ALLOW_HIGHDPI` on the window |
| No macOS `CMakeLists.txt` support (one Apple branch, for DXC) | macOS block mirroring the Linux one minus X11, plus Cocoa/Metal/QuartzCore/IOKit |
| `lib/lunasvg` declares a pre-3.5 CMake minimum | configure with `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` |
| `ld: library 'SDL2' not found` | the link list names bare `SDL2`, but Homebrew's sdl2-compat is config-mode: it exports `SDL2::SDL2` and never sets `SDL2_LIBRARIES`. Recover the directory from the imported target's `IMPORTED_LOCATION`. |
| `config.cpp` had no `__APPLE__` case | path resolved **empty**, making every config write relative — fine from a build dir, fatal from `/Applications`. Points at `~/Library/Application Support/Smash-Bros-Recompiled`. |
| Ambiguous `Rml::Variant::Set` on `size_t` | On Linux `uint64_t` *is* `unsigned long` so `size_t` matches exactly; on macOS `uint64_t` is `unsigned long long`, so `size_t` matches neither overload. Cast explicitly. |

`lib/sse2neon` is referenced at `CMakeLists.txt:196` but absent — and that is **fine**.
Nothing includes `sse2neon.h`; the real header is vendored at
`lib/N64ModernRuntime/thirdparty/sse2neon/`. A non-existent include dir is harmless.

### Metal shaders were handed to the GPU empty

Symptom: `newLibraryWithSource: Invalid library file (unexpected end of file)`, then
`vertexFunction must not be nil`, aborting inside `MetalGraphicsPipeline`'s constructor via
`RmlRenderInterface_RT64`.

`ui_renderer.cpp`'s `GET_SHADER_BLOB`/`GET_SHADER_SIZE` handled only `SPIRV` on non-Windows
and returned `nullptr`/`0` for anything else. plume's Metal backend reports
`RenderShaderFormat::METAL`, so the app passed an empty source string. rt64's
`build_shader` already emits MSL on Apple, so the blobs existed — nothing consumed them.
Added a `METAL` branch including `Interface{VS,PS}.hlsl.metal.h` and using the generated
`…BlobMSL` / `…BlobMSL_size` symbols.

### Native file dialog aborted the process

`select_rom()` runs on **RT64's Present thread** (RmlUi event dispatch happens inside
`draw_hook`). NFD's macOS backend builds an `NSOpenPanel`, and AppKit raises an
NSException — and aborts — if an `NSWindow`/`NSPanel` is constructed off the main thread.
Fine on Windows and Linux.

`dispatch_get_main_queue()` is **not** usable here: librecomp's main loop is
`while (!exited) sleep_milliseconds(1);` (`librecomp/src/recomp.cpp:695`) and never drains
the dispatch queue, so `dispatch_sync` would deadlock. That loop does call the `update_gfx`
callback every iteration, which is this app's only main-thread execution point. Added
`recompui::run_on_main_thread` / `drain_main_thread_tasks` serviced from `update_gfx`, and
`select_rom` hops over for just the dialog — validation and the data-model update stay on
the calling thread, as on every platform.

### Null document guard

`swap_document` has `assert(find_it->second && "Document for menu not loaded!")`, which is
compiled out in Release (`-DNDEBUG`), so a null document went straight into
`GetElementById` and segfaulted. Documents are null when `LoadDocument` fails — e.g. when
the working directory has no `assets/`. Converted to a real null check.

## 5 — Bundling

```bash
./tools/make_macos_app.sh          # -> Smash64r.app
ditto Smash64r.app /Applications/Smash64r.app
```

`assets/`, `gamecontrollerdb.txt` and the `.rml` documents are all opened by **relative**
path, so `main()` chdirs to `Contents/Resources` on macOS
(`macos_prepare_bundle_environment`). Without it every load fails silently from
`/Applications`, where the working directory is `/`.

Three bundling details, each of which was a real bug earlier in this batch:

1. dyld searches `LC_RPATH` entries **in order**, so an `@rpath` load command is only as
   good as that list — a clean-looking `otool -L` proves nothing. Verify with
   `otool -l <bin> | grep -A2 LC_RPATH`.
2. sdl2-compat `dlopen`s `libSDL3.dylib` by name, searching `@loader_path` first. It is not
   a link-time dependency, so dependency walkers miss it and it must be vendored by hand.
3. Resolve each dylib from the binary's own load commands, not from `brew --prefix sdl2` —
   that reports the sdl2-compat keg while the recorded install name is
   `/opt/homebrew/opt/sdl2/...`, and `install_name_tool -change` needs an exact match.

Verified: sole `LC_RPATH` is `@executable_path/../Frameworks`, zero Homebrew references,
`codesign --verify --deep --strict` passes, and the installed copy loads every asset when
launched from `cd /`.

## Stale upstream files (not touched)

`README.md`, `BUILDING.md`, `overlays.us.rev1.txt` and `patches.toml:1` are unmodified
Zelda64Recomp copies describing Majora's Mask.
