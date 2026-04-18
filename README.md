# Hwira

A minimalist real-time hardware monitor for LLM workloads, right in PowerShell terminal. One script, no dependencies, no GUI – just a calm dashboard of what your machine is actually doing while a model is loaded.

<p align="center">
  <picture>
    <img width="1148" alt="hwira" src="https://github.com/user-attachments/assets/694bffe8-fa6f-4979-b36b-aeefd655097a" />
  </picture>
</p>

It shows NVIDIA GPU load / VRAM / temperature / power, system memory, and (when toggled on) CPU, disk and network throughput. Each metric is rendered as a progress bar, a delta vs. the previous tick, and a 12-point sparkline.

Static info about the machine (OS build, CPU model, RAM type and frequency, disks, GPUs with driver versions) is collected once at startup, together with an AI-runtime health check: NVIDIA driver version, CUDA Toolkit, cuDNN, DirectML, and ONNX Runtime availability.

### Run it

**Option 1: Run directly from GitHub**
```powershell
irm https://raw.githubusercontent.com/penumbral/hwira/refs/heads/main/hwira.ps1 -OutFile "$env:TEMP\hwira.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\hwira.ps1"
```

**Option 2: Download and run locally**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\hwira.ps1
```

Works on Windows 10 / 11 with Windows PowerShell 5.1 or PowerShell 7+. No admin rights required. `nvidia-smi` must be in `PATH` for NVIDIA metrics (it is, if you have the driver installed).

### Keys

| Key | Action |
|---|---|
| `B` | Toggle PS Matmul block (synthetic CPU benchmark, see notes below) |
| `D` | Toggle CPU / Disk I/O / Network block |
| `S` | Toggle static system + AI runtime info |
| `P` | Toggle progress bars |
| `T` | Toggle delta + sparkline trend |
| `R` | Cycle refresh rate: 1s → 3s → 5s → 15s |
| `Ctrl+C` | Exit |

By default only the essentials are visible – NVIDIA GPU(s), RAM, and Intel iGPU 3D engine load if present.

### A note on "PS Matmul"

The `B` block runs a 256×256 matrix multiplication in triple-nested PowerShell loops on the CPU and reports elapsed time in ms. It is **not** a GPU benchmark and has nothing to do with real TFLOPS – it's a synthetic load whose trend line is useful for eyeballing CPU/interpreter responsiveness over time. One pass takes 15–60 seconds depending on your CPU, so while it's running you'll see `running Xs`.

### Common issues

**Resolved along the way**
- Flicker on every redraw → replaced `Clear-Host` with cursor repositioning + per-line padding + stale-line wipe; one shared `CimSession` instead of reconnecting WMI every tick.
- Header duplicating after toggling Static → long lines were wrapping past the tracked origin; `Out-Line` now hard-truncates to terminal width and the render origin is re-anchored on cursor failure.
- Localized Windows counters returning zero → added a PerfLib registry-based translation layer (`\009` ↔ `CurrentLanguage`) so counter paths are resolved in the OS UI language.

**Still open**
- On some machines (certain Russian-locale Windows 11 builds) CPU load, Disk I/O and Network counters still come back as zeros despite the translation layer. Cause is environment-specific; if you hit this, just leave the `D` block hidden.
- CPU temperature via `MSAcpi_ThermalZoneTemperature` is unavailable on most modern desktops/laptops – Intel and AMD simply don't expose sensors through that WMI class. No fix without a third-party driver like LibreHardwareMonitor.
- CPU power via `\Power Meter\Power` is mostly a laptop thing and not always present there either.
- AMD GPU metrics are not implemented – the project currently targets NVIDIA + Intel iGPU.
