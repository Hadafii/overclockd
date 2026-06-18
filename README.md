# ⚡ overclockd

> Bare metal performance tuning script for game server nodes — built by [RaeHost](https://raehost.com)

```
  ██████╗  █████╗ ███████╗██╗  ██╗ ██████╗ ███████╗████████╗
  ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔═══██╗██╔════╝╚══██╔══╝
  ██████╔╝███████║█████╗  ███████║██║   ██║███████╗   ██║
  ██╔══██╗██╔══██║██╔══╝  ██╔══██║██║   ██║╚════██║   ██║
  ██║  ██║██║  ██║███████╗██║  ██║╚██████╔╝███████║   ██║
  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝
```

`overclockd` adalah script satu-command untuk mengoptimalkan bare metal node ke performa maksimal. Dirancang khusus untuk game server hosting (Minecraft-optimized), dengan support penuh untuk semua generasi CPU Intel dan AMD.

---

## ⚡ Quick Start

```bash
curl -s https://raw.githubusercontent.com/raehost/overclockd/main/overclockd.sh | bash
```

> Harus dijalankan sebagai **root**. Script akan melakukan deteksi sistem terlebih dahulu sebelum apply tuning apapun.

---

## 🔍 System Detection

Sebelum apply tuning, script menampilkan info lengkap node — mirip YABS:

```
  Basic System Information
  ─────────────────────────────────────────────────
  Uptime                  : 21 days, 12 hours, 45 minutes
  Distro                  : Ubuntu 24.04.4 LTS
  Kernel                  : 6.8.0-117-generic (x86_64)
  VM Type                 : NONE

  CPU
  ─────────────────────────────────────────────────
  Processor               : AMD Ryzen 9 7950X 16-Core Processor
  Family                  : AMD Ryzen 9 (Desktop/WS)
  CPU Cores               : 32 cores / 32 threads
  Frequency               : 5007 MHz (cur) / 5879 MHz (max)
  AES-NI                  : ✔ Enabled
  VM-x/AMD-V              : ✔ Enabled (AMD-V)
  AVX2 / AVX-512          : ✔ / ✘

  Memory
  ─────────────────────────────────────────────────
  RAM                     : 125.0 GiB total / 98.3 GiB used
  RAM Type                : DDR5
  RAM Speed               : 4800 MT/s
  Swap                    : 0B / 0B

  Network
  ─────────────────────────────────────────────────
  Interface               : eth0 (1000Mbps)
  IPv4/IPv6               : ✔ Online (103.x.x.x) / ✘ Offline
  ISP                     : Perfect International
  ASN                     : AS22439
  Location                : Singapore, Central Singapore, SG

  Current Tuning State
  ─────────────────────────────────────────────────
  CPU Governor            : schedutil
  vm.swappiness           : 60
  Hugepages               : madvise
  TCP CC                  : cubic
  nofile limit            : 1024
  BBR loaded              : no
```

---

## 🛠️ What It Tunes

### CPU
- Governor → `performance` (fallback: `schedutil` → `ondemand`)
- AMD: P-state EPP → `performance`, C6 state disabled
- Intel: EPP → `performance`, C-state via `intel_idle` → 1, Turbo Boost ensured enabled
- Persistent via systemd service + cpufrequtils
- EPYC/Threadripper: extra NUMA balancing disable

### Memory
- `vm.swappiness=60`
- `vm.dirty_ratio=10`, `vm.dirty_background_ratio=5`
- Transparent Hugepages → `never` (persistent via systemd)
- NUMA auto-balancing → disabled
- `vm.overcommit_memory=1` (JVM/Java friendly)

### Swap
- Interactive — pilih mau setup swap atau tidak
- Input ukuran bebas dalam GB (32, 64, 128, dll)
- Otomatis hapus swap lama sebelum buat baru
- Validasi disk space sebelum alokasi
- Persistent via `/etc/fstab`

### Network
- TCP congestion control → **BBR** + FQ qdisc
- Buffer size: `rmem_max` / `wmem_max` → 128MB
- `tcp_slow_start_after_idle=0`
- `tcp_tw_reuse=1`
- Backlog & somaxconn tuning

### File Descriptors
- `nofile` → 65536 (via `limits.conf` + systemd)
- Docker default ulimits updated

### Docker
- Log rotation: `max-size: 10m`, `max-file: 3`
- Default ulimits: `nofile=65536`
- Storage driver: `overlay2`

### IRQ
- `irqbalance` installed dan enabled

---

## 🚫 VM Detection

Script **otomatis block** jika dijalankan di VM:

```
[✗] VM environment terdeteksi: kvm
[✗] Script ini hanya untuk bare metal node.
```

Deteksi via: `systemd-detect-virt`, DMI table, `/proc/cpuinfo` hypervisor flag.

Kalau false positive (bare metal tapi terdeteksi sebagai VM):

```bash
curl -s https://raw.githubusercontent.com/raehost/overclockd/main/overclockd.sh | bash -s -- --force
```

---

## ✅ Compatibility

| CPU | Status |
|-----|--------|
| AMD Ryzen (semua generasi) | ✅ |
| AMD EPYC (Naples, Rome, Milan, Genoa) | ✅ |
| AMD Threadripper | ✅ |
| Intel Core i5/i7/i9 | ✅ |
| Intel Core Ultra | ✅ |
| Intel Xeon (semua generasi) | ✅ |
| Intel/AMD generasi lama | ✅ (fallback governor) |

| OS | Status |
|----|--------|
| Ubuntu 22.04 LTS | ✅ |
| Ubuntu 24.04 LTS | ✅ |
| Debian 11/12 | ✅ |

---

## ⚠️ Notes

- Beberapa tuning butuh **reboot** untuk fully berlaku (C-state GRUB changes)
- `nofile` limit butuh **logout/login** ulang agar berlaku di session aktif
- RAM speed (XMP/EXPO) harus di-set dari **BIOS** — tidak bisa dari OS
- Fan speed harus via **IPMI** — minta vendor jika tidak punya akses

---

## 📁 Structure

```
overclockd/
└── overclockd.sh    # main script
```

---

## 🔗 Links

- [RaeHost](https://raehost.com) — Game Server Hosting Indonesia
- Dibuat untuk internal use, open for community

---

<sub>Maintained by RaeHost Infrastructure Team</sub>