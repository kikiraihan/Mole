# MoleApp — macOS Menu Bar Indicator & Full Mac App untuk Mole CLI

Aplikasi macOS **ringan** berbasis **Swift + SwiftUI + AppKit** yang menggabungkan:
1. **macOS Menu Bar Indicator** (seperti [LiteMonitor](https://github.com/kikiraihan/mac-os-lite-monitor) & [LiteCalendar](https://github.com/kikiraihan/our-life-planner-calendar-mac-os)) untuk memantau CPU, RAM, sisa SSD, kecepatan jaringan, baterai, dan Health Score secara real-time.
   - **Klik kiri** ikon: popover berisi cincin Health Score (`mo status --json`), meter CPU/RAM/Disk/Jaringan/Baterai, dan 6 tombol akses cepat (Bersihkan, Uninstall, Analisis Disk, Optimasi, Purge, Kesehatan).
   - **Klik kanan** ikon: menu lengkap (dashboard, fitur Mole CLI, **Pengaturan…** ⌘,, cek pembaruan, uninstall MoleApp). Sejak 1.6.0 semua pengaturan ada di satu halaman Pengaturan di dashboard; ikon cog di popover juga membukanya. Sejak 1.7.0 tab **Aplikasi** di Pengaturan juga memuat cek pembaruan, menu interaktif `mo` di Terminal, uninstall MoleApp, dan keluar, jadi semua isi menu klik kanan bisa dijangkau dari dashboard.
   - **Gaya indikator** (1.6.0): Teks 2 baris (bawaan), Teks ringkas, **Glyph baris (A)** (RAM = garis sejajar berdempetan, Internet = kipas busur, Baterai, Storage = silinder berisi, CPU = cincin; sejak 1.7.0 ikon RAM dan Internet bisa diganti ke batang sinyal; sejak 1.8.0 bisa ditata **satu baris** atau **dua baris (grid)** berisi ikon mini yang lebarnya kira-kira separuh), atau **Glyph tunggal (B)** (cincin + pusat + titik, ±22 pt, aman untuk notch; pusat bisa berisi busur internet, baterai mini, atau angka CPU/RAM/Storage). Pada gaya glyph, klik di satu bagian membuka popover dengan bagian itu disorot dan tooltip menampilkan angka tepat. Desain: [`_tech_debt/combined-menubar-glyph.md`](_tech_debt/combined-menubar-glyph.md).
2. **Mac App Dashboard Lengkap** (SwiftUI, sidebar bergrup) yang membungkus seluruh fitur utama **Mole CLI (`mo`)** dengan pratinjau `--dry-run` dan integrasi Terminal untuk langkah yang butuh sudo atau pilihan interaktif:
   - **Kesehatan (`mo status --json`)**: Cincin skor kesehatan, info hardware, panel CPU/memori/disk/baterai/suhu & daya/Trash, serta grafik proses terberat menurut CPU dan menurut RAM. Ukuran Tong Sampah dibaca langsung bila MoleApp punya Full Disk Access, atau lewat Finder (izin Automation) bila belum.
   - **Bersihkan (`mo clean`)**: Pratinjau `--dry-run` dengan output streaming, daftar kandidat `~/.config/mole/clean-list.txt`, whitelist, pembersihan user-level, serta full clean (sudo) via Terminal.
   - **Uninstall (`mo uninstall`)**: Daftar aplikasi (`--list`) dengan ikon asli macOS, pencarian nama/bundle ID, urutkan menurut nama atau ukuran (naik/turun), label Homebrew, pratinjau sisa file (`--dry-run`), dan uninstall via Terminal dengan konfirmasi Mole.
   - **Analisis Disk (`mo analyze --json`)**: Batang proporsi ukuran per folder, penanda cache yang aman dibersihkan, klik dua kali untuk masuk folder, tombol kembali, daftar file terbesar, dan Tampilkan di Finder. Penghapusan sengaja lewat penjelajah interaktif di Terminal agar tercatat di riwayat Mole.
   - **Optimasi (`mo optimize`)**: Pratinjau dan eksekusi perbaikan preferensi rusak, Spotlight, CoreDuet, dan layanan sistem.
   - **Purge Proyek (`mo purge`)**: Pratinjau dan pembersihan artefak build (`node_modules`, `target`, `build`, `dist`, `.next`, `venv`, `Pods`), plus pengaturan folder proyek.
   - **Installer (`mo installer`)**: Temukan file installer `.dmg`, `.pkg`, `.iso`, `.xip`, `.zip`.
   - **Slim Apps (`mo slim`)**: Pindai dan hapus arsitektur Intel (`x86_64`) dari Universal Apps di Apple Silicon.
   - **Riwayat & Alat (`mo history --json`)**: Daftar sesi operasi dan file yang dihapus/dipindah ke Trash, serta pintasan Touch ID untuk `sudo` (`mo touchid`), shell completion (`mo completion`), whitelist clean/optimize, folder proyek purge, folder konfigurasi, dan log operasi.
   - **Pengaturan** (diringkas di 1.7.0): Satu halaman ringkas bergaya System Settings dengan pratinjau indikator live di baris judul, 2 tab (sejak 1.8.0 tab Glyph digabung ke Indikator). **Indikator**: gaya tampilan, interval update, metrik yang tampil beserta urutannya; bila gaya glyph dipilih, di bawahnya muncul pengaturan glyph: isi slot glyph tunggal (cincin/pusat/titik), tata letak (satu baris/grid dua baris) serta ikon RAM dan Internet untuk glyph baris, klik dan tooltip per bagian, warna peringatan beserta ambangnya, dan opsi lanjutan (cara membaca storage/internet, petir, angka di samping glyph, ukuran dan jarak glyph). **Aplikasi**: Buka saat Login, versi dan cek pembaruan, menu interaktif `mo` di Terminal, uninstall MoleApp, dan keluar.

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
