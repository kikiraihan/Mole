# Konsep: Ikon Gabungan Menu Bar ala Apple (CPU, RAM, Storage, Baterai, Internet)

Status: **konsep, belum diimplementasi**. Dicatat 2026-11-09.

## Latar

Apple menggabungkan beberapa status dalam satu kelompok glyph yang tetap terbaca di ukuran kecil:

- **Baris cluster** (sinyal seluler 4 batang, kipas Wi-Fi, baterai): setiap metrik punya bentuk khas, levelnya ditunjukkan dengan *berapa bagian yang terisi*, bukan angka.
- **Glyph komposit cincin** (Wi-Fi di tengah, cincin progres di luar, titik-titik di bawah): satu ikon membawa tiga informasi sekaligus: pusat = jenis/status, cincin = progres, titik = langkah atau tingkat.

Saat ini MoleApp menampilkan teks/tick per metrik (mode 2 baris/ringkas). Ini makan lebar menu bar, terutama di MacBook bernotch.

## Apakah mungkin di macOS?

**Ya.** `NSStatusItem` tidak dibatasi pada SF Symbol bawaan:

1. **Gambar sendiri** dengan `NSImage(size:flipped:drawingHandler:)` + Core Graphics/`NSBezierPath`, lalu set `isTemplate = true` supaya otomatis putih/hitam mengikuti menu bar, tema terang/gelap, dan wallpaper (macOS 26 Liquid Glass juga mengikuti template image).
2. **Interaktif per bagian**: tombol status item menerima event klik beserta lokasinya (`NSEvent.locationInWindow` → koordinat tombol). Lebar tiap glyph diketahui saat menggambar, jadi klik di glyph RAM bisa membuka popover langsung ke bagian RAM, klik di baterai ke bagian Baterai, dsb. Klik kanan tetap menu pengaturan.
3. **Tooltip per bagian**: `NSTrackingArea` di tombol untuk menampilkan nilai tepat (mis. "RAM 6,7 / 8,0 GB") saat kursor diam di atas glyph tertentu.
4. **Warna opsional**: template image monokrom adalah gaya Apple. Untuk kondisi kritis bisa menggambar non-template khusus bagian itu (mis. baterai < 20% merah), seperti indikator baterai Apple yang berubah merah.

Keterbatasan: tinggi menu bar ~22 pt (24 pt di Mac bernotch), jadi tiap glyph realistis 14–18 pt; detail harus dari bentuk dan jumlah segmen, bukan teks kecil.

## Pemetaan metrik ke glyph

| Metrik | Glyph | Cara membaca level |
|---|---|---|
| Prosesor | Cincin/arc (seperti cincin di sekitar Wi-Fi) | Panjang arc = % CPU |
| RAM | 4 batang naik (seperti sinyal seluler) | Batang terisi = tekanan/pemakaian (0–25–50–75–100%) |
| Storage | Silinder/kotak dengan isian bawah | Tinggi isian = % terpakai; bila sisa < 10% garis tepi tebal |
| Baterai | Bentuk baterai bawaan | Isian = %; petir saat mengisi |
| Internet | Kipas 3 busur (seperti Wi-Fi) | Busur menyala sesuai kecepatan (≥10 KB/s, ≥1 MB/s, ≥10 MB/s); panah kecil ↑/↓ bila dominan |

## Dua varian tata letak

**A. Cluster baris (gaya status bar iPhone)** — paling mudah dibaca, lebar ±70–90 pt:

```
 ▂▄▆█   ◜◝   ▭▭▭▭▯   ⛁   (CPU arc)
  RAM   Net  Baterai  SSD   CPU
```

**B. Glyph komposit tunggal (gaya cincin + titik)** — paling hemat tempat, lebar ±22 pt:

```
     ╭───╮      cincin luar  = CPU %
    ( ◜◝ )      pusat        = Internet (busur)
     ╰───╯
    • • • • •   titik bawah  = RAM (titik terisi = level)
```
Storage dan baterai pindah ke tooltip/popover, atau titik berubah warna saat disk hampir penuh.

Pengguna memilih varian di **Pengaturan Indikator** (menggantikan/menambah mode "2 baris" dan "ringkas"), dengan checklist metrik yang sudah ada tetap menentukan glyph mana yang ikut tampil.

## Sketsa implementasi

- `GlyphRenderer` (file baru, mis. `MenuBarGlyph.swift`): fungsi murni `render(metrics, layout) -> (NSImage, [GlyphRegion])`; `GlyphRegion` = rentang x + jenis metrik, dipakai untuk klik dan tooltip.
- Cache gambar: gambar ulang hanya bila level terkuantisasi berubah (mis. CPU dibulatkan ke 5%), supaya timer 1–2 detik tidak membebani CPU/WindowServer.
- `StatusBarController`: `button.image = image`, `button.imagePosition = .imageOnly`; di aksi klik, hitung `x` relatif terhadap tombol → cari `GlyphRegion` → buka popover dan scroll ke bagian terkait.
- Aksesibilitas: `button.setAccessibilityLabel("CPU 65 persen, RAM 84 persen, …")` karena glyph tidak terbaca VoiceOver.
- Uji: snapshot PNG per level (0/25/50/75/100) di mode terang & gelap, dan uji pemetaan klik → region.

## Risiko / pertanyaan terbuka

- Glyph tanpa angka kurang presisi; perlu tooltip dan popover sebagai sumber angka tepat.
- Menu bar bernotch bisa menyembunyikan item bila terlalu lebar → varian B lebih aman.
- Warna non-template harus hemat agar tidak terlihat "ramai" dibanding ikon Apple lain.
- Perlu keputusan: varian A, B, atau keduanya sebagai opsi.

## Langkah berikutnya (saat diimplementasi)

1. Prototipe `GlyphRenderer` varian B + snapshot PNG untuk ditinjau.
2. Tambahkan varian A.
3. Klik per region + tooltip.
4. Opsi di Pengaturan Indikator dan menu klik kanan.
