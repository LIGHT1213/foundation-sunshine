# AGENTS.md

Workspace instructions for ZCode agents working in this repository.

## What this is

**Foundation Sunshine** (Sunshine 基地版) — an enhanced, Windows-focused fork of
[LizardByte/Sunshine](https://github.com/LizardByte/Sunshine). It is a self-hosted game-stream
host for Moonlight clients. Enhanced areas: HDR pipeline (PQ+HLG, HDR10+/HDR Vivid dynamic
metadata), virtual display integration ([ZakoVDD](https://github.com/qiin2333/zako-vdd)), audio
(7.1.4, Opus DRED, remote mic), encoding (NVENC SDK 13.0, AMF QVBR, Vulkan), Windows folder
sharing, and an advanced Vue 3 / Tauri control panel.

Publisher metadata points to `qiin2333` / `alkaidlab.com` (see `cmake/prep/options.cmake`) — this
is a fork, not upstream LizardByte.

## Layout

- `src/` — C++23 host core. Key files: `main.cpp`, `nvhttp.cpp` / `nvhttp_stream_start.cpp`
  (GameStream HTTP API), `stream.cpp`, `video.cpp`, `audio.cpp`, `input.cpp`, `config.cpp`,
  `rtsp.cpp`.
  - `src/platform/{windows,linux,macos}/` — platform-specific code; cross-platform interfaces in
    `src/platform/common.h`. Most enhanced features are **Windows-only**.
  - `src/nvenc/`, `src/amf/` — encoder backends. VAAPI/Wayland capture under
    `src/platform/linux/`.
  - `src/display_device/` — virtual display (VDD) integration, IOCTL-based, Windows.
  - `src/file_mapping/` — Windows host folder sharing (HTTP + WS + RPC).
  - `src/nvhttp/` — control-plane endpoints: `apps`, `sessions`, `pairing`, `clipboard_api`,
    `display_control`, `display_scale`, `dynamic_params`, `abr_api`, `ai_api`.
- `src_assets/common/assets/web/` — Vue 3 WebUI built with Vite (see
  `docs/WEBUI_DEVELOPMENT.md`).
- `src_assets/common/sunshine-control-panel/` — Tauri 2 + Vue 3 desktop control panel
  (submodule, `tauri` branch).
- `tests/unit/` — GoogleTest unit tests. `tests/tools/` — test helpers.
- `tools/` — Windows diagnostic executables (`dxgi-info`, `audio-info`, `sunshinesvc`,
  `qiin-tabtip`, `vdd_frame_channel_probe`).
- `cmake/` — CMake modules. **Build options live in `cmake/prep/options.cmake`.**
- `scripts/` — i18n tooling, `linux_build.sh`, `update_clang_format.py`.
- `third-party/` — git submodules (moonlight-common-c, AMF, nvenc-headers, googletest,
  inputtino, build-deps, etc.).
- `docs/` — Sphinx docs. Read before touching sensitive areas (see below).

## Build

C++ (requires CMake ≥ 3.25, Ninja, C++23):

```bash
cmake -B build -G Ninja -S .
ninja -C build
```

Windows local dev uses the `dev-win` preset in `CMakePresets.json` (run inside MSYS2 UCRT64).
Notable CMake options (`-D…=ON/OFF`): `BUILD_TESTS`, `BUILD_DOCS`, `BUILD_WERROR`,
`SUNSHINE_ENABLE_TRAY` (off on macOS), `SUNSHINE_REQUIRE_TRAY`, `BUILD_WERROR`, plus Linux
capture toggles `SUNSHINE_ENABLE_{CUDA,DRM,VAAPI,WAYLAND,X11}`.

Submodules are required: clone with `--recurse-submodules`, or run
`git submodule update --init --recursive`. AMF is consumed headers-only via sparse-checkout
(see notes in `.gitmodules`).

Web UI (decoupled from the C++ build; output goes to `build/assets/web/`):

```bash
npm install
npm run dev          # vite build --watch
npm run dev-server   # HTTPS dev server on https://localhost:3000 (proxies /api/* → :47990)
npm run dev-full     # dev server + mock API service
npm run build        # production build
```

Via CMake target instead: `cmake -B build -G Ninja -S . --target web-ui && ninja -C build web-ui`.

## Test, lint, format

- C++ unit tests (GoogleTest): build with `-DBUILD_TESTS=ON`, then `./build/tests/test_sunshine`
  (`--help` for options). Tests mirror source names: `test_video`, `test_audio`, `test_stream`,
  `test_vdd_safety`, `test_file_mapping*`, `test_webhook*`, etc.
- WebUI tests: `npm run test:webui` (Node `--test`).
- C++ format: `.clang-format` is centrally managed — do not hand-edit. Apply with
  `find ./ \( -iname '*.cpp' -o -iname '*.h' \) | xargs clang-format -i` or
  `python ./scripts/update_clang_format.py`. CI enforces it.
- JS: Prettier (`.prettierrc.json`: 120 cols, no semicolons, single quotes).
- Python: flake8 (`.flake8`, max-line 120).

## Conventions

- **Logging** uses Boost.Log severity loggers declared in `src/logging.h`
  (`verbose`, `debug`, `info`, `warning`, `error`, `fatal`). Write e.g.
  `BOOST_LOG(info) << "message";`. Prefer the level that matches severity.
- **i18n (WebUI)**: add new strings **only** to
  `src_assets/common/assets/web/public/assets/locale/en.json`, then run
  `npm run i18n:sync && npm run i18n:format && npm run i18n:validate`. Never edit other locale
  files directly — translations flow through Crowdin. Brand names (LizardByte, Sunshine, AMD,
  Intel, NVIDIA) are never translated. CI rejects incomplete/malformed locale files.
- **WebUI architecture**: Vue 3 Composition API with `<script setup>`. Business logic lives in
  `composables/` (`useXxx.js`), API calls in `services/`, pages in `views/`, layout in
  `components/layout/`. Use `$t(...)` in templates and `useI18n()` inside `<script setup>`.
  Vite `manualChunks` is intentionally disabled (breaks Bootstrap/Popper).
- **Platform boundaries**: keep platform-specific code under `src/platform/<os>/` and expose
  shared interfaces via `src/platform/common.h`. Keep encoder backends isolated in
  `src/nvenc/`, `src/amf/`, etc.

## Docs to read before sensitive changes

- VDD sealed-frame channel / zero-copy capture: `docs/windows_vdd_sealed_frame_channel.md`
  (also `tools/check_vdd_ioctl_abi.ps1`, `tools/vdd_sealed_channel_stress.ps1`).
- Windows folder sharing: `docs/windows_directory_mapping_design.md`,
  `docs/windows_directory_mapping_hardening_notes.md`,
  `docs/windows_directory_mapping_user_interaction.md`.
- Capture path tradeoffs: `docs/WGC_vs_DDAPI_Smoothness_Fun_Guide.md`.
- WebUI conventions: `docs/WEBUI_DEVELOPMENT.md`.
- Config keys: `docs/configuration.md`. Webhook payloads: `docs/webhook_format.md`.
- Build/packages: `docs/building.md`, `docs/contributing.md`.

## Gotchas

- The primary dev/build target is **Windows** (MSYS2 UCRT64 + MinGW). Many features (VDD,
  folder sharing, remote mic, virtual mouse `vmouse`, `sunshinesvc`) compile only on Windows
  and require Windows 10 22H2+.
- macOS builds have the system tray disabled (`SUNSHINE_ENABLE_TRAY` is ignored on macOS).
- The WebUI is HTTPS-served; the dev server auto-generates a local cert and proxies
  `/api/*` → `https://localhost:47990` (the Sunshine backend). Preview mode has no backend —
  code must degrade gracefully.
- `README.md` is Simplified Chinese; `README.en.md` is English. `README.md.backup` is an older
  draft — edit the real `README.md`, not the backup.
- Commit messages follow Conventional Commits (e.g. `fix(vdd): …`, `feat(amf): …`,
  `chore: …`, `fix(web): …`) — match this style.
