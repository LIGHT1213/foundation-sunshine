### ░▒▓ Core Features

- **Full HDR Pipeline** — Dual-format encoding (PQ + HLG)・Per-frame GPU luminance analysis・HDR10+ / HDR Vivid dynamic metadata・Complete static metadata passthrough
- **Virtual Display** — Deep integration with [ZakoVDD](https://github.com/qiin2333/zako-vdd)・Zako Direct zero-copy frame borrowing・5 screen modes・Multi-client GUID sessions
- **Audio Enhancement** — 7.1.4 Surround Sound (12ch)・Opus DRED packet loss recovery・Continuous audio stream・Remote microphone・Virtual speaker bit depth matching
- **Encoding Optimization** — NVENC SDK 13.0・AMF QVBR/HQVBR/Multi-HW Instance・Encoder result caching (260x)・Adaptive downsampling・Vulkan encoder
- **Folder Sharing** — Windows host directory mapping・Right-click share from Explorer・Read-only secure defaults・Authorized paired devices
- **Control Panel** — Tauri 2 + Vue 3 + Vite・Dark mode・QR pairing・Real-time monitoring・WebUI rendering optimization
- **Input Enhancement** — Independent client configuration・Native precision trackpad adaptation・Virtual mouse driver (vmouse)

### ░▒▓ Technical Details

<details>
<summary><b>Full HDR Pipeline Technical Solution</b></summary>

#### Dual-format HDR Encoding: HDR10 (PQ) + HLG Parallel Support

Traditional streaming solutions only support HDR10 (PQ) absolute luminance mapping. When the terminal device's capabilities are insufficient or luminance parameters don't match, issues like loss of shadow detail and highlight clipping can occur.

Therefore, HLG (Hybrid Log-Gamma, ITU-R BT.2100) support has been added at the encoding layer, using relative luminance mapping:
- **Scene-referenced Luminance Adaptation**: HLG is based on a relative luminance curve. The display end automatically performs tone mapping according to its own peak luminance. Shadow detail retention on low-luminance devices is significantly better than PQ.
- **Smooth Highlight Roll-off**: The logarithmic-gamma hybrid transfer function of HLG provides a gradual roll-off in highlight areas, avoiding the highlight banding caused by PQ's hard clipping.
- **Native SDR Backward Compatibility**: HLG signals can be directly decoded by SDR displays as standard BT.709 images without additional tone mapping processing.

**Per-frame Luminance Analysis and Adaptive Metadata Generation**

A real-time luminance analysis module is integrated on the GPU side, using Compute Shaders to perform the following on each frame:
- **MaxFALL / MaxCLL Per-frame Calculation**: Real-time statistics of frame-level Maximum Content Light Level (MaxCLL) and Frame Average Light Level (MaxFALL), dynamically injecting HEVC/AV1 SEI/OBU metadata.
- **Robust Outlier Filtering**: Uses percentile truncation to filter out extreme luminance pixels (e.g., specular highlights), preventing isolated bright points from raising the global luminance reference and causing the overall image to appear darker.
- **Inter-frame Exponential Smoothing**: Applies EMA (Exponential Moving Average) filtering to the luminance statistics of consecutive frames, eliminating luminance flickering caused by abrupt metadata changes during scene transitions.

**Complete HDR Metadata Passthrough**

HDR10 static metadata (Mastering Display Info + Content Light Level) is fully passed through. The bitstream output by NVENC / AMF / QSV encoding carries complete color volume and luminance information conforming to the CTA-861 specification.

**HDR10+ / HDR Vivid Dynamic Metadata Injection**

In the NVENC encoding pipeline, based on per-frame luminance analysis results, the following dynamic metadata SEIs are automatically generated and injected:
- **HDR10+ (ST 2094-40)**: Carries scene-level tone mapping references such as MaxSCL / distribution percentiles / knee point, supporting precise tone mapping on HDR10+ certified TVs from Samsung/Panasonic, etc.
- **HDR Vivid (CUVA T/UWA 005.3)**: An ITU-T T.35 registered standard from the China Ultra High Definition Video Alliance (CUVA). Provides absolute luminance tone mapping in PQ mode and scene-referenced relative luminance tone mapping in HLG mode, covering the domestic terminal ecosystem.

</details>

<details>
<summary><b>Virtual Display Integration</b> (Requires Windows 10 22H2+)</summary>

Deep integration with the [ZakoVDD](https://github.com/qiin2333/zako-vdd) virtual display driver:
- Custom resolution and refresh rate support, 10-bit HDR color depth
- **5 Screen Combination Modes**: Virtual only, Physical only, Hybrid, Mirror, Extend
- IOCTL real-time communication, automatically creates/destroys virtual display on stream start/stop
- Each client independently binds a VDD session (GUID), supporting fast multi-client switching
- Real-time configuration changes without reboot
- **Zako Direct Zero-copy Frame Borrowing**: Can directly borrow VDD shared frame textures, returning them immediately after conversion, reducing GPU copies in the VDD capture pipeline

</details>

<details>
<summary><b>Audio Enhancement</b></summary>

- **7.1.4 Surround Sound (12 channels)**: Complete channel mapping for immersive audio layouts like Dolby Atmos
- **Opus DRED Deep Redundancy**: Neural network-based packet loss recovery, 100ms redundancy window smoothly compensates during network jitter
- **Continuous Audio Stream**: Uninterrupted audio stream, automatically fills silence data when no audio is present, avoiding repeated audio device initialization
- **Virtual Speaker Auto-matching**: Automatically detects and matches virtual audio devices with bit depths like 16bit/24bit

</details>

<details>
<summary><b>Capture and Encoding Optimization</b></summary>

**Capture Pipeline**
- **Gamma-Aware Shader**: Automatically selects sRGB / Linear Gamma color conversion based on DXGI ColorSpace
- **High-Quality Downsampling**: Bicubic interpolation, supports fast / balanced / high_quality three levels
- **Dynamic Resolution Detection**: Real-time awareness of monitor resolution and rotation changes, encoder adapts automatically
- **GPU Luminance Analysis**: Compute Shader two-stage reduction, P95/P99 truncation, inter-frame EMA temporal smoothing

**NVENC**
- **SDK 13.0**: Refined bitrate control and Look-ahead
- **HDR Metadata API**: Native Mastering Display / Content Light Level writing via NVENC SDK 12.2+
- **HDR10+ / HDR Vivid SEI**: Automatic per-frame generation of ST 2094-40 and CUVA T.35 dynamic metadata
- **SPS Bitstream Compliance**: Complete writing of H.264/HEVC SPS bitstream restrictions

**AMF (AMD)**
- **QVBR / HQVBR / HQCBR**: Advanced bitrate control, supports quality level UI adjustment
- **Low Latency Control**: AMF Low Latency, input queue size, and AV1 encoding latency mode can be explicitly adjusted in the WebUI, balancing extremely low latency with driver stability
- **Multi-Hardware Instance Encoding**: Supports AMF Multi-HW Instance / Smart Access Video related switches, allowing the driver to split encoding load on supported platforms

**General**
- **Encoder Result Caching**: Probe results are persisted, subsequent connections 26s → <100ms (260x speedup)
- **Adaptive Downsampling**: Supports Bilinear / Bicubic / High Quality three levels of resolution scaling, adapting to 4K host → 1080p streaming scenarios
- **Vulkan Encoder**: Experimental Vulkan video encoding support
- **Lock-free Certificate Chain**: `shared_mutex` replaces mutex, eliminating TLS queue overhead

</details>

<br>

---

### ░▒▓ Recommended Clients

For the best experience (activating set bonuses), pair with the following optimized Moonlight clients:

- **PC** — [Moonlight-PC](https://github.com/qiin2333/moonlight-qt) (Windows · macOS · Linux)
- **Android** — [Power Plus Edition](https://github.com/qiin2333/moonlight-vplus) · [Crown Edition](https://github.com/WACrown/moonlight-android)
- **iOS** — [VoidLink](https://github.com/The-Fried-Fish/VoidLink-previously-moonlight-zwm)
- **HarmonyOS** — [Moonlight V+](https://appgallery.huawei.com/app/detail?id=com.alkaidlab.sdream)

More resources: [awesome-sunshine](https://github.com/LizardByte/awesome-sunshine)

<br>

<details>
<summary><b>░▒▓ System Requirements</b></summary>

| Component | Minimum | 4K Recommended |
|------|----------|---------|
| **GPU** | AMD VCE 1.0+ / Intel VAAPI / NVIDIA NVENC | AMD VCE 3.1+ / Intel HD 510+ / GTX 1080+ |
| **CPU** | Ryzen 3 / Core i3 | Ryzen 5 / Core i5 |
| **RAM** | 4 GB | 8 GB |
| **OS** | Windows 10 22H2+ | Windows 10 22H2+ |
| **Network** | 5GHz 802.11ac | CAT5e Ethernet |

GPU Compatibility: [NVENC](https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new) · [AMD VCE](https://github.com/obsproject/obs-amd-encoder/wiki/Hardware-Support) · [Intel VAAPI](https://www.intel.com/content/www/us/en/developer/articles/technical/linuxmedia-vaapi.html)

</details>

---

### ░▒▓ Documentation & Support

[![Docs](https://img.shields.io/badge/Documentation-ff69b4?style=flat-square)](https://docs.qq.com/aio/DSGdQc3htbFJjSFdO?p=YTpMj5JNNdB5hEKJhhqlSB) [![LizardByte](https://img.shields.io/badge/LizardByte_Docs-a78bfa?style=flat-square)](https://docs.lizardbyte.dev/projects/sunshine/latest/) [![QQ Group](https://img.shields.io/badge/QQ_Group-38bdf8?style=flat-square)](https://qm.qq.com/cgi-bin/qm/qr?k=5qnkzSaLIrIaU4FvumftZH_6Hg7fUuLD&jump_from=webapi)

Want to help write code? → [![Build](https://img.shields.io/badge/Build_Guide-34d399?style=flat-square)](docs/building.md) [![Config](https://img.shields.io/badge/Configuration_Guide-fbbf24?style=flat-square)](docs/configuration.md) [![WebUI](https://img.shields.io/badge/WebUI_Development-fb923c?style=flat-square)](docs/WEBUI_DEVELOPMENT.md)

<br>

<div align="center">

「 ░▒▓ 」

<a href="https://github.com/qiin2333/foundation-sunshine/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=qiin2333/foundation-sunshine&max=100" />
</a>

<br>

[![Join QQ Group](https://pub.idqqimg.com/wpa/images/group.png 'Join QQ Group')](https://qm.qq.com/cgi-bin/qm/qr?k=WC2PSZ3Q6Hk6j8U_DG9S7522GPtItk0m&jump_from=webapi&authKey=zVDLFrS83s/0Xg3hMbkMeAqI7xoHXaM3sxZIF/u9JW7qO/D8xd0npytVBC2lOS+z)

[![Star History Chart](https://api.star-history.com/svg?repos=qiin2333/Sunshine-Foundation&type=Date)](https://www.star-history.com/#qiin2333/Sunshine-Foundation&Date)

</div>