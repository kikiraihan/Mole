# MoleApp — macOS Menu Bar Indicator & Full Mac App untuk Mole CLI

Aplikasi macOS **ringan** berbasis **Swift + SwiftUI + AppKit** yang menggabungkan:
1. **macOS Menu Bar Indicator** (seperti [LiteMonitor](https://github.com/kikiraihan/mac-os-lite-monitor) & [LiteCalendar](https://github.com/kikiraihan/our-life-planner-calendar-mac-os)) untuk memantau CPU, RAM, sisa SSD, kecepatan jaringan, baterai, dan Health Score secara real-time beserta tombol Quick Actions.
2. **Mac App Dashboard Lengkap** yang membungkus seluruh fitur utama **Mole CLI (`mo`)** ke dalam antarmuka visual yang aman, lengkap dengan pratinjau `--dry-run` dan integrasi Terminal interaktif:
   - **Status & Monitor (`mo status --json`)**: Skor kesehatan Mac, detail hardware, suhu/daya, dan tabel Top Processes.
   - **Deep Clean (`mo clean`)**: Pratinjau `--dry-run`, daftar path kandidat `~/.config/mole/clean-list.txt`, proteksi satu-klik ke Whitelist, serta pembersihan user-level maupun full system via Terminal.
   - **Uninstall Apps (`mo uninstall`)**: Daftar seluruh aplikasi terinstal (`--list`) dengan ikon asli macOS, pencarian instan, pratinjau sisa file (`--dry-run`), dan penghapusan aman ke Trash.
   - **Disk Analyzer (`mo analyze --json`)**: Penjelajah pemakaian ruang disk per folder, penanda cache yang aman dibersihkan (`Cleanable Cache`), daftar file terbesar, buka di Finder, dan pindahkan ke Trash.
   - **Optimize System (`mo optimize`)**: Pratinjau dan eksekusi perbaikan preferensi rusak, Spotlight, CoreDuet, dan layanan sistem.
   - **Project Purge (`mo purge`)**: Pratinjau dan pembersihan artefak build (`node_modules`, `target`, `build`, `dist`, `.next`, `venv`, `Pods`).
   - **Installers (`mo installer`)**: Temukan dan bersihkan file installer `.dmg`, `.pkg`, `.iso`, `.xip`, `.zip`.
   - **Slim Universal Apps (`mo slim`)**: Pindai dan hapus arsitektur Intel (`x86_64`) dari Universal Apps di Apple Silicon.
   - **Audit History (`mo history --json`)**: Riwayat sesi operasi dan daftar file yang dihapus/dipindahkan ke Trash.
   - **CLI, TouchID & Whitelist**: Pengaturan tampilan indikator menu bar (Ringkas / 2 Baris / Ikon), Buka saat Login (`SMAppService`), konfigurasi Touch ID untuk `sudo` (`mo touchid`), shell completion (`mo completion`), serta editor langsung untuk `~/.config/mole/whitelist`, `whitelist_optimize`, dan `purge_paths`.

## Instalasi

### Opsi A: Unduh `.app` jadi dari GitHub Releases (Tanpa Xcode / Tanpa Install CLI Terpisah)
Seluruh engine Mole CLI beserta binary Go (`analyze-go` & `status-go`) sudah dibundle di dalam `MoleApp.app/Contents/Resources/mole-cli/`.

1. Unduh **`MoleApp.zip`** dari halaman [Releases](https://github.com/kikiraihan/mole/releases).
2. Ekstrak dan pindahkan **`MoleApp.app`** ke folder **`/Applications`**.
3. Hapus atribut karantina sekali saja lalu jalankan:
   ```bash
   xattr -cr /Applications/MoleApp.app
   open /Applications/MoleApp.app
   ```

### Opsi B: Installer Satu File (`install-MoleApp.command`)
Unduh **`install-MoleApp.zip`** dari halaman Releases, ekstrak, lalu jalankan:
```bash
bash ~/Downloads/install-MoleApp.command
```

### Opsi C: Build Sendiri dari Source
```bash
./macos-app/scripts/build.sh
cp -R macos-app/build/MoleApp.app /Applications/
open /Applications/MoleApp.app --args --dashboard
```

## Struktur Direktori `macos-app/`

```text
macos-app/
├── Sources/MoleApp/main.swift   # Kode sumber Swift (Menu Bar Indicator + SwiftUI Dashboard)
├── Resources/Info.plist         # Metadata bundle macOS (id.local.moleapp)
└── scripts/
    ├── build.sh                 # Build Go binaries + bundle Mole CLI + compile Swift .app
    └── make-installer.sh        # Buat dist/install-MoleApp.command
```
