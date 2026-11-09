# MoleApp — macOS Menu Bar Indicator & Full Mac App untuk Mole CLI

Aplikasi macOS **ringan** berbasis **Swift + SwiftUI + AppKit** yang menggabungkan:
1. **macOS Menu Bar Indicator** (seperti [LiteMonitor](https://github.com/kikiraihan/mac-os-lite-monitor) & [LiteCalendar](https://github.com/kikiraihan/our-life-planner-calendar-mac-os)) untuk memantau CPU, RAM, sisa SSD, kecepatan jaringan, baterai, dan Health Score secara real-time.
   - **Klik kiri** ikon: popover berisi cincin Health Score (`mo status --json`), meter CPU/RAM/Disk/Jaringan/Baterai, dan 6 tombol akses cepat (Bersihkan, Uninstall, Analisis Disk, Optimasi, Purge, Kesehatan).
   - **Klik kanan** ikon: menu lengkap (pilih metrik di menu bar, mode ringkas/2 baris, interval update, Buka saat Login, cek pembaruan, uninstall MoleApp).
2. **Mac App Dashboard Lengkap** (SwiftUI, sidebar bergrup) yang membungkus seluruh fitur utama **Mole CLI (`mo`)** dengan pratinjau `--dry-run` dan integrasi Terminal untuk langkah yang butuh sudo atau pilihan interaktif:
   - **Kesehatan (`mo status --json`)**: Cincin skor kesehatan, info hardware, panel CPU/memori/disk/baterai/suhu & daya/Trash, serta grafik Top Processes.
   - **Bersihkan (`mo clean`)**: Pratinjau `--dry-run` dengan output streaming, daftar kandidat `~/.config/mole/clean-list.txt`, whitelist, pembersihan user-level, serta full clean (sudo) via Terminal.
   - **Uninstall (`mo uninstall`)**: Daftar aplikasi (`--list`) dengan ikon asli macOS, pencarian nama/bundle ID, label Homebrew, pratinjau sisa file (`--dry-run`), dan uninstall via Terminal dengan konfirmasi Mole.
   - **Analisis Disk (`mo analyze --json`)**: Batang proporsi ukuran per folder, penanda cache yang aman dibersihkan, klik dua kali untuk masuk folder, tombol kembali, daftar file terbesar, dan Tampilkan di Finder. Penghapusan sengaja lewat penjelajah interaktif di Terminal agar tercatat di riwayat Mole.
   - **Optimasi (`mo optimize`)**: Pratinjau dan eksekusi perbaikan preferensi rusak, Spotlight, CoreDuet, dan layanan sistem.
   - **Purge Proyek (`mo purge`)**: Pratinjau dan pembersihan artefak build (`node_modules`, `target`, `build`, `dist`, `.next`, `venv`, `Pods`), plus pengaturan folder proyek.
   - **Installer (`mo installer`)**: Temukan file installer `.dmg`, `.pkg`, `.iso`, `.xip`, `.zip`.
   - **Slim Apps (`mo slim`)**: Pindai dan hapus arsitektur Intel (`x86_64`) dari Universal Apps di Apple Silicon.
   - **Riwayat & Alat (`mo history --json`)**: Daftar sesi operasi dan file yang dihapus/dipindah ke Trash, serta pintasan Touch ID untuk `sudo` (`mo touchid`), shell completion (`mo completion`), whitelist clean/optimize, folder proyek purge, folder konfigurasi, dan log operasi.
   - **Pengaturan Indikator**: Pilih metrik yang tampil di menu bar (CPU, RAM, sisa SSD, jaringan, baterai), mode 2 baris/ringkas, interval update, dan Buka saat Login, lengkap dengan pratinjau indikator live. Sinkron dengan menu klik kanan.

### Desain
Tema "liang tikus tanah": aksen merah muda hidung mole `#D9668A`, hijau lumut `#6E9F6B` untuk kondisi sehat, amber `#E0A43A` untuk waspada, merah bara `#D9534F` untuk kritis. Angka dan judul memakai SF Rounded; latar mengikuti mode terang/gelap macOS.

## Instalasi

> **Auto update (mulai v1.2.0):** MoleApp mengecek rilis `app-v*` terbaru saat dibuka lalu sehari sekali. Jika ada versi baru, popover menampilkan **"Update tersedia"** dan menu klik kanan berubah menjadi **"Update tersedia: app-v…"**. Klik **Update sekarang** → MoleApp mengunduh `MoleApp.zip`, memverifikasi bundle ID-nya, menutup diri, mengganti `.app` (versi lama dicadangkan dulu), lalu membuka lagi. Versi 1.0.0 dan 1.1.0 belum punya fitur ini, jadi pasang v1.2.0 secara manual sekali.

### Opsi A: Unduh `.app` jadi dari GitHub Releases (Tanpa Xcode / Tanpa Install CLI Terpisah)
Seluruh engine Mole CLI beserta binary Go (`analyze-go` & `status-go`) sudah dibundle di dalam `MoleApp.app/Contents/Resources/mole-cli/`.

1. Unduh **`MoleApp.zip`** dari halaman [Releases](https://github.com/kikiraihan/mole/releases).
2. Ekstrak dan pindahkan **`MoleApp.app`** ke folder **`/Applications`**.
3. Hapus atribut karantina sekali saja lalu jalankan:
   ```bash
   /usr/bin/xattr -cr /Applications/MoleApp.app
   open /Applications/MoleApp.app
   ```
   Pakai path lengkap `/usr/bin/xattr`: Python/conda (mis. miniconda) bisa memasang `xattr` lain di PATH yang tidak mengenal opsi `-r`.

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
├── Sources/MoleApp/
│   ├── main.swift               # Indikator menu bar, sampler metrik, bridge Mole CLI, updater
│   ├── Dashboard.swift          # Jendela dashboard SwiftUI untuk semua fitur
│   └── Popover.swift            # Popover klik kiri di menu bar
├── Resources/Info.plist         # Metadata bundle macOS (id.local.moleapp)
└── scripts/
    ├── build.sh                 # Build Go binaries + bundle Mole CLI + compile Swift .app
    └── make-installer.sh        # Buat dist/install-MoleApp.command
```
