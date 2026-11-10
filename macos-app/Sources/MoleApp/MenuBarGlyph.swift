// MoleApp — Ikon gabungan menu bar ala Apple (lihat macos-app/_tech_debt/combined-menubar-glyph.md).
// Varian A (glyph baris): RAM = 4 batang sinyal, Internet = kipas 3 busur, Baterai = isian,
// Storage = silinder berisi, CPU = cincin. Varian B (glyph tunggal): cincin + pusat + 5 titik,
// isi tiap slot bisa dipilih di Pengaturan.
// Sejak 1.7.0: ikon RAM bawaan = garis sejajar berdempetan (batang sinyal tetap bisa dipilih, juga
// untuk Internet), dan pusat glyph B bisa diisi CPU/RAM/Storage berupa angka kecil.
// Sejak 1.8.0: glyph A bisa ditata 1 baris (seperti sebelumnya) atau grid 2 baris berisi ikon mini
// (kolom diisi atas lalu bawah, mengikuti urutan metrik), jadi lebarnya kira-kira separuh.
// Sejak 1.9.0: ikon CPU (cincin + chip, kotak CPU 4 level, batang sinyal, garis sejajar) dan ikon
// Baterai (horizontal, vertikal, lingkaran, batang lurus) di glyph A bisa diganti, dan angka CPU/RAM
// bisa dibaca sebagai persen atau angka (core terpakai / GB terpakai).
// Semua glyph digambar dengan Core Graphics di koordinat "unit" (sama dengan mockup SVG),
// lalu diskalakan ke tinggi menu bar 22 pt. Tanpa warna peringatan → template image (ikut
// terang/gelap otomatis); dengan warna peringatan → gambar biasa dengan tinta putih/hitam.

import Cocoa

// MARK: - Model pengaturan

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case text2, compact, glyphRow, glyphSingle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text2: return "Teks 2 baris"
        case .compact: return "Teks ringkas"
        case .glyphRow: return "Glyph baris (A)"
        case .glyphSingle: return "Glyph tunggal (B)"
        }
    }

    var detail: String {
        switch self {
        case .text2: return "Label di atas, nilai di bawah"
        case .compact: return "1 baris, ikon + angka"
        case .glyphRow: return "Bentuk per metrik, 1 baris (±80 pt) atau grid 2 baris"
        case .glyphSingle: return "Cincin + pusat + titik, ±22 pt, aman untuk notch"
        }
    }

    var isGlyph: Bool { self == .glyphRow || self == .glyphSingle }
}

enum MetricKind: String, CaseIterable, Identifiable {
    case cpu, mem, disk, net, bat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .mem: return "Memori (RAM)"
        case .disk: return "SSD"
        case .net: return "Kecepatan Jaringan"
        case .bat: return "Baterai"
        }
    }

    var short: String {
        switch self {
        case .cpu: return "CPU"
        case .mem: return "RAM"
        case .disk: return "SSD"
        case .net: return "Internet"
        case .bat: return "Baterai"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .mem: return "memorychip"
        case .disk: return "internaldrive"
        case .net: return "arrow.up.arrow.down"
        case .bat: return "battery.100"
        }
    }
}

/// Bentuk ikon per metrik pada glyph baris (A). RAM dan Internet bisa memilih bentuknya.
/// Sejak 1.9.0 CPU dan Baterai juga bisa memilih bentuknya.
enum GlyphIcon: String, CaseIterable, Identifiable {
    case lanes, bars, fan
    case ring, chip            // CPU: cincin dengan chip di tengah (bawaan), kotak CPU berisi 4 level
    case batH, batV, pill      // Baterai: horizontal (bawaan), vertikal, batang lurus (lingkaran = .ring)
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lanes: return "Garis sejajar"
        case .bars: return "Batang sinyal"
        case .fan: return "Kipas busur"
        case .ring: return "Lingkaran"
        case .chip: return "Kotak CPU (4 level)"
        case .batH: return "Baterai horizontal"
        case .batV: return "Baterai vertikal"
        case .pill: return "Batang lurus"
        }
    }
}

/// Tata letak glyph baris (A): 1 baris berjajar, atau grid 2 baris berisi ikon mini
enum GlyphLayout: String, CaseIterable, Identifiable {
    case single, grid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "Satu baris"
        case .grid: return "Dua baris (grid)"
        }
    }
}

enum NetDirection: String, CaseIterable, Identifiable {
    case down, up, total
    var id: String { rawValue }
    var title: String {
        switch self {
        case .down: return "Unduh"
        case .up: return "Unggah"
        case .total: return "Gabungan"
        }
    }
}

struct GlyphPrefs: Equatable {
    // Varian B: isi slot (nil = kosong)
    var ring: MetricKind = .cpu
    var center: MetricKind? = .net
    var dots: MetricKind? = .mem
    // Varian A: bentuk ikon RAM dan Internet
    var memIcon: GlyphIcon = .lanes
    var netIcon: GlyphIcon = .fan
    // Varian A: bentuk ikon CPU dan Baterai (sejak 1.9.0)
    var cpuIcon: GlyphIcon = .ring
    var batIcon: GlyphIcon = .batH
    // Varian A: tata letak 1 baris atau grid 2 baris (sejak 1.8.0)
    var rowLayout: GlyphLayout = .single
    // Cara membaca metrik
    var diskShowsFree = false
    // Angka CPU/RAM: persen (bawaan) atau angka (core terpakai / GB terpakai), sejak 1.9.0
    var cpuShowsNumber = false
    var memShowsNumber = false
    var netDirection: NetDirection = .down
    var netFast = false
    var bolt = true
    var numbers: Set<MetricKind> = []
    // Peringatan warna
    var warnColors = true
    var warnBattery = 20
    var warnDisk = 10
    var warnCPUOn = false
    var warnCPU = 90
    // Ukuran
    var small = false
    var tight = false
    // Interaksi
    var clickRegions = true
    var tooltips = true

    static let ringOptions: [MetricKind] = [.cpu, .mem, .disk, .bat]
    /// Internet dan baterai punya ikon mini; CPU/RAM/Storage tampil sebagai angka kecil di tengah cincin
    static let centerOptions: [MetricKind] = [.net, .bat, .cpu, .mem, .disk]
    static let memIconOptions: [GlyphIcon] = [.lanes, .bars]
    static let netIconOptions: [GlyphIcon] = [.fan, .bars]
    static let cpuIconOptions: [GlyphIcon] = [.ring, .chip, .bars, .lanes]
    static let batIconOptions: [GlyphIcon] = [.batH, .batV, .ring, .pill]
    static let dotsOptions: [MetricKind] = [.mem, .cpu, .disk]

    /// Ambang busur internet (byte/detik): Rumahan 10 KB/s · 1 MB/s · 10 MB/s, Cepat 100 KB/s · 10 MB/s · 100 MB/s
    /// Literal byte ditulis langsung (bukan perkalian) supaya type-checker Swift tidak kehabisan waktu
    private static let netHome: [Double] = [10_240, 1_048_576, 10_485_760]
    private static let netFastPreset: [Double] = [102_400, 10_485_760, 104_857_600]

    var netThresholds: [Double] {
        netFast ? GlyphPrefs.netFastPreset : GlyphPrefs.netHome
    }
}

/// Angka live yang dibutuhkan renderer (dari AppDelegate untuk menu bar, dari LiveMetrics untuk pratinjau)
struct MetricValues {
    var cpu: Double
    var memPercent: Double
    var memUsed: UInt64
    var memTotal: UInt64
    var disk: DiskSnapshot
    var up: Double
    var down: Double
    var bat: BatterySnapshot?

    var diskFreePercent: Double { disk.total > 0 ? Double(disk.free) / Double(disk.total) * 100 : 100 }
}

/// Bagian glyph yang bisa diklik/di-hover. `rects` dalam koordinat gambar (y ke bawah, tinggi 22).
struct GlyphRegion: Equatable {
    let kind: MetricKind
    let rects: [CGRect]

    func contains(_ p: CGPoint) -> Bool { rects.contains { $0.contains(p) } }
}

struct IndicatorRender {
    let image: NSImage
    let regions: [GlyphRegion]
}

// MARK: - Renderer

enum GlyphRenderer {
    static let barHeight: CGFloat = 22
    private static let dim: CGFloat = 0.28
    private static let red = NSColor.systemRed
    private static let orange = NSColor.systemOrange

    /// Level terkuantisasi: hanya perubahan level yang memicu gambar ulang (hemat CPU/WindowServer)
    private struct Levels {
        var cpu: Double = 0         // 0...1, langkah 5%
        var memBars = 0             // 0...4 (batang sinyal) atau 0...5 (garis sejajar)
        var mem: Double = 0         // 0...1, langkah 5%
        var diskFill: Double = 0    // 0...1, langkah 5% (terpakai atau sisa sesuai pengaturan)
        var netLevel = 0            // 0...3
        var bat: Double?            // 0...1, langkah 5%
        var charging = false
        var batWarn = false
        var diskWarn = false
        var cpuWarn = false
    }

    private static func q(_ pct: Double) -> Double { (min(100, max(0, pct)) / 5).rounded() * 5 / 100 }

    /// Jumlah langkah menyala dari pecahan 0...1 (batang sinyal 4, garis sejajar 5, kotak CPU 4)
    private static func steps(_ frac: Double, _ n: Int) -> Int { Int((min(1, max(0, frac)) * Double(n)).rounded()) }

    /// Core CPU yang sedang terpakai (persen CPU × jumlah core logis)
    static func coresUsed(_ v: MetricValues) -> Double {
        min(100, max(0, v.cpu)) / 100 * Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    /// RAM terpakai dalam GB biner (16 GB RAM tampil 16, sama seperti Activity Monitor)
    static func memGB(_ v: MetricValues) -> Double { Double(v.memUsed) / 1_073_741_824.0 }

    /// Angka 1 desimal di bawah 10, bulat di atasnya (contoh 3.2, 12, 128)
    private static func compactNumber(_ x: Double) -> String {
        x < 9.95 ? String(format: "%.1f", x) : String(format: "%.0f", x)
    }

    private static func levels(_ p: GlyphPrefs, _ v: MetricValues) -> Levels {
        var l = Levels()
        l.cpu = q(v.cpu)
        l.mem = q(v.memPercent)
        l.memBars = Int((min(100, max(0, v.memPercent)) / (p.memIcon == .lanes ? 20 : 25)).rounded())
        l.diskFill = q(p.diskShowsFree ? v.diskFreePercent : v.disk.percent)
        let rate: Double
        switch p.netDirection {
        case .down: rate = v.down
        case .up: rate = v.up
        case .total: rate = v.up + v.down
        }
        l.netLevel = p.netThresholds.filter { rate >= $0 }.count
        if let b = v.bat {
            l.bat = q(Double(b.percent))
            l.charging = b.charging || b.onAC
            l.batWarn = p.warnColors && !b.onAC && b.percent < p.warnBattery
        }
        l.diskWarn = p.warnColors && v.diskFreePercent < Double(p.warnDisk)
        l.cpuWarn = p.warnColors && p.warnCPUOn && v.cpu > Double(p.warnCPU)
        return l
    }

    private static func fraction(_ k: MetricKind, _ l: Levels) -> Double {
        switch k {
        case .cpu: return l.cpu
        case .mem: return l.mem
        case .disk: return l.diskFill
        case .bat: return l.bat ?? 0
        case .net: return Double(l.netLevel) / 3
        }
    }

    // MARK: Teks angka, tooltip, aksesibilitas

    static func numberText(_ k: MetricKind, _ p: GlyphPrefs, _ v: MetricValues) -> String {
        switch k {
        case .cpu: return p.cpuShowsNumber ? compactNumber(coresUsed(v)) : String(format: "%.0f%%", v.cpu)
        case .mem: return p.memShowsNumber ? compactNumber(memGB(v)) + "G" : String(format: "%.0f%%", v.memPercent)
        case .disk:
            return p.diskShowsFree
                ? String(format: "%.0fG", Double(v.disk.free) / 1_000_000_000.0)
                : String(format: "%.0f%%", v.disk.percent)
        case .net:
            switch p.netDirection {
            case .down: return fmtRate(v.down, short: true)
            case .up: return fmtRate(v.up, short: true)
            case .total: return fmtRate(v.up + v.down, short: true)
            }
        case .bat: return v.bat.map { "\($0.percent)%" } ?? "–"
        }
    }

    private static func numberTemplate(_ k: MetricKind, _ p: GlyphPrefs) -> String {
        switch k {
        case .net: return "999.9K"
        case .disk: return p.diskShowsFree ? "999G" : "100%"
        case .cpu: return p.cpuShowsNumber ? "99.9" : "100%"
        case .mem: return p.memShowsNumber ? "99.9G" : "100%"
        default: return "100%"
        }
    }

    /// Pusat glyph B: CPU/RAM/Storage digambar sebagai angka (tanpa ikon mini)
    static func centerIsNumber(_ k: MetricKind) -> Bool { k == .cpu || k == .mem || k == .disk }

    /// Angka pusat maksimal 3 karakter supaya muat di dalam cincin (tanpa tanda %)
    static func centerText(_ k: MetricKind, _ p: GlyphPrefs, _ v: MetricValues) -> String {
        switch k {
        case .cpu: return p.cpuShowsNumber ? compactNumber(coresUsed(v)) : String(format: "%.0f", min(100, max(0, v.cpu)))
        case .mem: return p.memShowsNumber ? compactNumber(memGB(v)) : String(format: "%.0f", min(100, max(0, v.memPercent)))
        case .disk:
            guard p.diskShowsFree else { return String(format: "%.0f", min(100, max(0, v.disk.percent))) }
            let gb = Double(v.disk.free) / 1_000_000_000.0
            return gb >= 999.5 ? String(format: "%.0fT", gb / 1000) : String(format: "%.0f", gb)
        default: return ""
        }
    }

    static func tooltip(_ k: MetricKind, _ v: MetricValues) -> String {
        switch k {
        case .cpu:
            return String(format: "CPU %.0f%% · %.1f dari %ld core", v.cpu, coresUsed(v), ProcessInfo.processInfo.activeProcessorCount)
        case .mem:
            return String(format: "RAM %@ / %@ · %.0f%%", formatBytes(Int64(v.memUsed)), formatBytes(Int64(v.memTotal)), v.memPercent)
        case .disk:
            return "\(v.disk.name): \(formatBytes(v.disk.used)) terpakai · sisa \(formatBytes(v.disk.free))"
        case .net:
            return "Jaringan ↓ \(formatNetRate(v.down))   ↑ \(formatNetRate(v.up))"
        case .bat:
            guard let b = v.bat else { return "Baterai tidak terdeteksi" }
            let st = b.charged ? "Terisi penuh" : b.charging ? "Mengisi daya" : b.onAC ? "Terhubung AC" : "Pakai baterai"
            return "Baterai \(b.percent)% · \(st)"
        }
    }

    /// Glyph tidak terbaca VoiceOver, jadi label aksesibilitas berisi angka tepat
    static func accessibilitySummary(_ kinds: [MetricKind], _ v: MetricValues) -> String {
        kinds.map { tooltip($0, v) }.joined(separator: ", ")
    }

    /// Metrik yang tampil pada gaya tertentu (urutan sesuai pengaturan)
    static func visibleKinds(_ p: IndicatorPrefs, _ v: MetricValues) -> [MetricKind] {
        if p.style == .glyphSingle {
            var out = [p.glyph.ring]
            if let c = p.glyph.center { out.append(c) }
            if let d = p.glyph.dots { out.append(d) }
            return out.filter { $0 != .bat || v.bat != nil }
        }
        return p.enabledInOrder.filter { $0 != .bat || v.bat != nil }
    }

    // MARK: Kunci cache

    static func key(_ p: IndicatorPrefs, _ v: MetricValues, dark: Bool) -> String {
        let l = levels(p.glyph, v)
        var parts = [
            p.style.rawValue, dark ? "d" : "l", p.glyph.memIcon.rawValue, p.glyph.netIcon.rawValue, p.glyph.rowLayout.rawValue,
            p.glyph.cpuIcon.rawValue, p.glyph.batIcon.rawValue,
            "\(l.cpu)", "\(l.memBars)", "\(l.mem)", "\(l.diskFill)", "\(l.netLevel)",
            "\(l.bat ?? -1)", "\(l.charging)", "\(l.batWarn)", "\(l.diskWarn)", "\(l.cpuWarn)"
        ]
        for k in visibleKinds(p, v) where p.glyph.numbers.contains(k) {
            parts.append(numberText(k, p.glyph, v))
        }
        if p.style == .glyphSingle, let c = p.glyph.center, centerIsNumber(c) {
            parts.append("c" + centerText(c, p.glyph, v))
        }
        return "g|" + parts.joined(separator: "|")
    }

    // MARK: Render

    static func render(_ p: IndicatorPrefs, _ v: MetricValues, dark: Bool) -> IndicatorRender? {
        let g = p.glyph
        let l = levels(g, v)
        let kinds = visibleKinds(p, v)
        let s: CGFloat = g.small ? 0.82 : 1.0
        let gap: CGFloat = g.tight ? 4 : 7
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: g.small ? 8.5 : 9.5, weight: .semibold)

        // Warna peringatan hanya dipakai bila ada bagian yang benar-benar kritis dan sedang tampil
        let colored: Bool
        if p.style == .glyphSingle {
            colored = (l.batWarn && v.bat != nil) || l.diskWarn || l.cpuWarn
        } else {
            colored = (l.batWarn && kinds.contains(.bat)) || (l.diskWarn && kinds.contains(.disk)) || (l.cpuWarn && kinds.contains(.cpu))
        }
        let ink: NSColor = colored ? (dark ? .white : .black) : .black

        if p.style == .glyphSingle {
            return renderSingle(g, v, l, s: s, numFont: numFont, ink: ink, template: !colored)
        }
        guard !kinds.isEmpty else { return nil }
        if g.rowLayout == .grid {
            return renderGrid(g, v, l, kinds: kinds, s: s, ink: ink, template: !colored)
        }

        // Tata letak baris: glyph (+ angka opsional) berjajar dengan jarak `gap`
        struct Slot { let kind: MetricKind; let x: CGFloat; let glyphW: CGFloat; let text: String?; let textW: CGFloat }
        var slots: [Slot] = []
        var x: CGFloat = 0
        for k in kinds {
            let gw = unitWidth(k, g) * s
            var text: String?
            var tw: CGFloat = 0
            if g.numbers.contains(k) {
                let t = numberText(k, g, v)
                text = t
                tw = 2 + ceil(max(textWidth(t, numFont), textWidth(numberTemplate(k, g), numFont)))
            }
            slots.append(Slot(kind: k, x: x, glyphW: gw, text: text, textW: tw))
            x += gw + tw + gap
        }
        let total = max(1, x - gap)
        let regions = slots.map { sl in
            GlyphRegion(kind: sl.kind, rects: [CGRect(x: sl.x - gap / 2, y: 0, width: sl.glyphW + sl.textW + gap, height: barHeight)])
        }

        let img = NSImage(size: NSSize(width: total, height: barHeight), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for sl in slots {
                Self.unit(ctx, x: sl.x, h: 16, s: s) {
                    Self.drawRowIcon(ctx, sl.kind, g, l, ink: ink)
                }
                if let t = sl.text {
                    Self.drawNumber(t, at: sl.x + sl.glyphW + 2, font: numFont, ink: ink)
                }
            }
            return true
        }
        img.isTemplate = !colored
        return IndicatorRender(image: img, regions: regions)
    }

    /// Glyph A tata letak grid: ikon mini dalam 2 baris (tinggi baris 11 pt). Kolom diisi atas lalu bawah
    /// mengikuti urutan metrik; kolom terakhir yang hanya berisi 1 ikon diletakkan di tengah vertikal.
    private static func renderGrid(_ g: GlyphPrefs, _ v: MetricValues, _ l: Levels, kinds: [MetricKind], s: CGFloat, ink: NSColor, template: Bool) -> IndicatorRender {
        let rowH = barHeight / 2
        let gs = s * 0.62                       // ikon unit 16 → ±10 pt (standar) atau ±8 pt (kecil)
        let gap: CGFloat = g.tight ? 3 : 5
        let font = NSFont.monospacedDigitSystemFont(ofSize: g.small ? 6.5 : 7.5, weight: .semibold)

        struct Cell { let kind: MetricKind; let x: CGFloat; let cy: CGFloat; let band: CGRect; let glyphW: CGFloat; let text: String? }
        var cells: [Cell] = []
        var x: CGFloat = 0
        var i = 0
        while i < kinds.count {
            let col = Array(kinds[i..<min(i + 2, kinds.count)])
            // Lebar kolom = sel terlebar (ikon + angka opsional)
            var widths: [CGFloat] = []
            var texts: [String?] = []
            for k in col {
                let gw = unitWidth(k, g) * gs
                var tw: CGFloat = 0
                var text: String?
                if g.numbers.contains(k) {
                    let t = numberText(k, g, v)
                    text = t
                    tw = 1.5 + ceil(max(textWidth(t, font), textWidth(numberTemplate(k, g), font)))
                }
                widths.append(gw + tw)
                texts.append(text)
            }
            let colW = widths.max() ?? 0
            for (r, k) in col.enumerated() {
                let single = col.count == 1
                let cy = single ? barHeight / 2 : rowH * (CGFloat(r) + 0.5)
                let band = single
                    ? CGRect(x: x - gap / 2, y: 0, width: colW + gap, height: barHeight)
                    : CGRect(x: x - gap / 2, y: rowH * CGFloat(r), width: colW + gap, height: rowH)
                cells.append(Cell(kind: k, x: x, cy: cy, band: band, glyphW: unitWidth(k, g) * gs, text: texts[r]))
            }
            x += colW + gap
            i += 2
        }
        let total = max(1, x - gap)
        let regions = cells.map { GlyphRegion(kind: $0.kind, rects: [$0.band]) }

        let img = NSImage(size: NSSize(width: total, height: barHeight), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for c in cells {
                Self.unit(ctx, x: c.x, top: c.cy - 8 * gs, h: 16, s: gs) {
                    Self.drawRowIcon(ctx, c.kind, g, l, ink: ink)
                }
                if let t = c.text {
                    Self.drawNumber(t, at: c.x + c.glyphW + 1.5, font: font, ink: ink, cy: c.cy)
                }
            }
            return true
        }
        img.isTemplate = template
        return IndicatorRender(image: img, regions: regions)
    }

    /// Ikon satu metrik glyph A di koordinat unit (tinggi 16); dipakai tata letak 1 baris maupun grid
    private static func drawRowIcon(_ ctx: CGContext, _ k: MetricKind, _ g: GlyphPrefs, _ l: Levels, ink: NSColor) {
        switch k {
        case .cpu:
            let accent = l.cpuWarn ? red : ink
            switch g.cpuIcon {
            case .chip: drawChip(ctx, steps(l.cpu, 4), ink: ink, on: accent)
            case .bars: drawBars(ctx, steps(l.cpu, 4), ink: ink, on: accent)
            case .lanes: drawRAM(ctx, steps(l.cpu, 5), ink: ink, on: accent)
            default: drawCPU(ctx, l.cpu, ink: ink, accent: accent)
            }
        case .mem:
            if g.memIcon == .bars { drawBars(ctx, l.memBars, ink: ink) } else { drawRAM(ctx, l.memBars, ink: ink) }
        case .net:
            // Batang sinyal untuk internet: titik menyala = 1 batang, tiap busur = 1 batang lagi
            if g.netIcon == .bars { drawBars(ctx, l.netLevel > 0 ? l.netLevel + 1 : 0, ink: ink) } else { drawNet(ctx, l.netLevel, ink: ink) }
        case .bat:
            let fill = l.batWarn ? red : ink
            let charging = g.bolt && l.charging
            switch g.batIcon {
            case .batV: drawBatteryV(ctx, l.bat ?? 0, ink: ink, fill: fill, charging: charging)
            case .ring: drawBatteryRing(ctx, l.bat ?? 0, ink: ink, fill: fill, charging: charging)
            case .pill: drawPill(ctx, l.bat ?? 0, ink: ink, fill: fill, charging: charging)
            default: drawBattery(ctx, l.bat ?? 0, ink: ink, fill: fill, charging: charging)
            }
        case .disk: drawDisk(ctx, l.diskFill, ink: ink, warn: l.diskWarn ? orange : nil)
        }
    }

    private static func renderSingle(_ g: GlyphPrefs, _ v: MetricValues, _ l: Levels, s: CGFloat, numFont: NSFont, ink: NSColor, template: Bool) -> IndicatorRender {
        let w = 22 * s
        var text: String?
        var tw: CGFloat = 0
        if g.numbers.contains(g.ring) {
            let t = numberText(g.ring, g, v)
            text = t
            tw = 2 + ceil(max(textWidth(t, numFont), textWidth(numberTemplate(g.ring, g), numFont)))
        }

        // Warna cincin mengikuti peringatan metrik yang ditampilkan cincin
        var ringColor = ink
        switch g.ring {
        case .cpu where l.cpuWarn, .bat where l.batWarn: ringColor = red
        case .disk where l.diskWarn: ringColor = orange
        default: break
        }
        let centerKind = (g.center == .bat && v.bat == nil) ? nil : g.center
        // Pusat berupa angka (CPU/RAM/Storage) ikut warna peringatan metriknya
        var centerNumber: String?
        var centerColor = ink
        if let c = centerKind, centerIsNumber(c) {
            centerNumber = centerText(c, g, v)
            if c == .cpu && l.cpuWarn { centerColor = red } else if c == .disk && l.diskWarn { centerColor = orange }
        }
        // Titik peringatan: baterai/disk kritis yang tidak sedang ditampilkan cincin atau pusat
        var warnDot: NSColor?
        if l.batWarn && g.ring != .bat && centerKind != .bat { warnDot = red }
        else if l.diskWarn && g.ring != .disk { warnDot = orange }

        let dotsOn: Int? = g.dots.map { Int((fraction($0, l) * 5).rounded()) }

        // Wilayah klik (koordinat unit 22×22): titik di bawah, pusat di tengah, sisanya cincin
        let oy = (barHeight - 22 * s) / 2
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        var regions: [GlyphRegion] = []
        var dotsKind: MetricKind = g.ring
        if let d = g.dots { dotsKind = d } else if warnDot === red { dotsKind = .bat } else if warnDot != nil { dotsKind = .disk }
        regions.append(GlyphRegion(kind: dotsKind, rects: [r(0, 17, 22, 5)]))
        regions.append(GlyphRegion(kind: centerKind ?? g.ring, rects: [r(6, 3, 10, 12)]))
        var ringRects = [r(0, 0, 6, 17), r(16, 0, 6, 17), r(6, 0, 10, 3), r(6, 15, 10, 2)]
        if tw > 0 { ringRects.append(CGRect(x: w, y: 0, width: tw, height: barHeight)) }
        regions.append(GlyphRegion(kind: g.ring, rects: ringRects))

        let img = NSImage(size: NSSize(width: w + tw, height: barHeight), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            Self.unit(ctx, x: 0, h: 22, s: s) {
                Self.drawCombo(ctx, ring: Self.fraction(g.ring, l), ringColor: ringColor, center: centerKind,
                          netLevel: l.netLevel, bat: l.bat ?? 0, batColor: l.batWarn ? Self.red : ink,
                          dotsOn: dotsOn, warnDot: warnDot, ink: ink)
                if let t = centerNumber { Self.drawCenterNumber(t, color: centerColor) }
            }
            if let t = text { Self.drawNumber(t, at: w + 2, font: numFont, ink: ink) }
            return true
        }
        img.isTemplate = template
        return IndicatorRender(image: img, regions: regions)
    }

    // MARK: Primitif gambar (koordinat unit sama dengan mockup SVG)

    private static func unitWidth(_ k: MetricKind, _ g: GlyphPrefs) -> CGFloat {
        switch k {
        case .cpu, .mem: return 16
        case .net: return g.netIcon == .bars ? 16 : 18
        case .bat:
            switch g.batIcon {
            case .batV: return 12
            case .ring: return 16
            case .pill: return 8
            default: return 27
            }
        case .disk: return 14
        }
    }

    /// `top` nil = ditengah vertikal di menu bar; grid memberi `top` per baris
    private static func unit(_ ctx: CGContext, x: CGFloat, top: CGFloat? = nil, h: CGFloat, s: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: top ?? (barHeight - h * s) / 2)
        ctx.scaleBy(x: s, y: s)
        body()
        ctx.restoreGState()
    }

    /// Busur dari sudut a0 ke a1 (radian, 0 = kanan, bertambah searah jarum jam karena y ke bawah)
    private static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = max(2, Int(abs(a1 - a0) / (.pi / 32)) + 1)
        for i in 0...n {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private static func strokeRing(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, width: CGFloat, frac: Double, ink: NSColor, accent: NSColor) {
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(ink.withAlphaComponent(dim).cgColor)
        ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        guard frac > 0.005 else { return }
        ctx.setStrokeColor(accent.cgColor)
        ctx.addPath(arc(cx, cy, r, -.pi / 2, -.pi / 2 + 2 * .pi * CGFloat(min(1, frac))))
        ctx.strokePath()
    }

    private static func drawCPU(_ ctx: CGContext, _ frac: Double, ink: NSColor, accent: NSColor) {
        strokeRing(ctx, cx: 8, cy: 8, r: 6, width: 2.2, frac: frac, ink: ink, accent: accent)
        ctx.setFillColor(ink.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 5.6, y: 5.6, width: 4.8, height: 4.8), cornerWidth: 1, cornerHeight: 1, transform: nil))
        ctx.fillPath()
    }

    /// RAM: 5 garis tegak sama tinggi yang berdempetan (seperti jalur keping memori); terisi dari kiri
    /// `on` = warna batang yang menyala (bawaan tinta; CPU memakai merah saat peringatan)
    private static func drawRAM(_ ctx: CGContext, _ lanes: Int, ink: NSColor, on: NSColor? = nil) {
        for i in 0..<5 {
            ctx.setFillColor((i < lanes ? (on ?? ink) : ink.withAlphaComponent(dim)).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1 + CGFloat(i) * 2.9, y: 2.5, width: 2.1, height: 11), cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
            ctx.fillPath()
        }
    }

    /// 4 batang sinyal bertingkat (dulu ikon RAM); kini pilihan untuk RAM atau Internet
    private static func drawBars(_ ctx: CGContext, _ bars: Int, ink: NSColor, on: NSColor? = nil) {
        for (i, h) in [CGFloat(4), 7, 10, 13].enumerated() {
            ctx.setFillColor((i < bars ? (on ?? ink) : ink.withAlphaComponent(dim)).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1 + CGFloat(i) * 3.6, y: 15 - h, width: 2.6, height: h), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            ctx.fillPath()
        }
    }

    private static func drawFan(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, radii: [CGFloat], on: Int, width: CGFloat, dot: CGFloat, dotOn: Bool, ink: NSColor) {
        ctx.setFillColor((dotOn ? ink : ink.withAlphaComponent(dim)).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2))
        let a: CGFloat = .pi / 4.2
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        for (i, r) in radii.enumerated() {
            ctx.setStrokeColor((i < on ? ink : ink.withAlphaComponent(dim)).cgColor)
            ctx.addPath(arc(cx, cy, r, -.pi / 2 - a, -.pi / 2 + a))
            ctx.strokePath()
        }
    }

    private static func drawNet(_ ctx: CGContext, _ level: Int, ink: NSColor) {
        drawFan(ctx, cx: 9, cy: 14, radii: [3.2, 6.4, 9.6], on: level, width: 2, dot: 1.6, dotOn: level > 0, ink: ink)
    }

    private static func drawBattery(_ ctx: CGContext, _ frac: Double, ink: NSColor, fill: NSColor, charging: Bool) {
        let outline = ink.withAlphaComponent(0.45)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(outline.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 3, width: 22, height: 10), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
        ctx.setFillColor(outline.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 23.8, y: 6.4, width: 1.6, height: 3.2), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        ctx.fillPath()
        let fw = 18 * CGFloat(min(1, max(0, frac)))
        if fw > 0.5 {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 3, y: 5, width: fw, height: 6), cornerWidth: min(1.5, fw / 2), cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }
        if charging {
            drawBolt(ctx, cx: 12.3, cy: 8, k: 1, ink: ink)
        }
    }

    /// Petir mengisi daya berpusat di (cx, cy) dengan skala k (k = 1: tinggi 11.6 unit).
    /// Sejak 1.9.0 dipakai bersama oleh semua bentuk ikon baterai.
    private static func drawBolt(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, k: CGFloat, ink: NSColor) {
        let pts: [CGPoint] = [
            CGPoint(x: 13.4, y: 2.2), CGPoint(x: 9.4, y: 8.6), CGPoint(x: 12.4, y: 8.6),
            CGPoint(x: 10.8, y: 13.8), CGPoint(x: 15.2, y: 7), CGPoint(x: 12.2, y: 7)
        ].map { CGPoint(x: cx + ($0.x - 12.3) * k, y: cy + ($0.y - 8) * k) }
        let bolt = CGMutablePath()
        bolt.addLines(between: pts)
        bolt.closeSubpath()
        // Lubangi dulu sekeliling petir supaya terbaca di atas isian
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.setLineWidth(1.8 * k)
        ctx.setLineJoin(.round)
        ctx.addPath(bolt)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(ink.cgColor)
        ctx.addPath(bolt)
        ctx.fillPath()
    }

    /// Baterai vertikal (lebar 12 unit): kutub di atas, isian naik dari bawah
    private static func drawBatteryV(_ ctx: CGContext, _ frac: Double, ink: NSColor, fill: NSColor, charging: Bool) {
        let outline = ink.withAlphaComponent(0.45)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(outline.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 2, y: 3, width: 8, height: 12), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
        ctx.strokePath()
        ctx.setFillColor(outline.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 4.4, y: 1, width: 3.2, height: 1.6), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
        ctx.fillPath()
        let fh = 8.8 * CGFloat(min(1, max(0, frac)))
        if fh > 0.5 {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 3.6, y: 13.4 - fh, width: 4.8, height: fh), cornerWidth: 1.2, cornerHeight: min(1.2, fh / 2), transform: nil))
            ctx.fillPath()
        }
        if charging {
            drawBolt(ctx, cx: 6, cy: 9, k: 0.72, ink: ink)
        }
    }

    /// Baterai lingkaran: cincin seperti CPU, petir di tengah saat mengisi daya
    private static func drawBatteryRing(_ ctx: CGContext, _ frac: Double, ink: NSColor, fill: NSColor, charging: Bool) {
        strokeRing(ctx, cx: 8, cy: 8, r: 6, width: 2.2, frac: frac, ink: ink, accent: fill)
        if charging {
            drawBolt(ctx, cx: 8, cy: 8, k: 0.6, ink: ink)
        }
    }

    /// Batang lurus (lebar 8 unit): kapsul tegak redup, isian naik dari bawah
    private static func drawPill(_ ctx: CGContext, _ frac: Double, ink: NSColor, fill: NSColor, charging: Bool) {
        let body = CGPath(roundedRect: CGRect(x: 1.5, y: 1.5, width: 5, height: 13), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.setFillColor(ink.withAlphaComponent(dim).cgColor)
        ctx.addPath(body)
        ctx.fillPath()
        let fh = 13 * CGFloat(min(1, max(0, frac)))
        if fh > 0.3 {
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 1.5, y: 14.5 - fh, width: 5, height: fh))
            ctx.restoreGState()
        }
        if charging {
            drawBolt(ctx, cx: 4, cy: 8, k: 0.62, ink: ink)
        }
    }

    /// Kotak CPU: chip berkaki dengan 4 strip isian yang menyala dari bawah (0...4)
    private static func drawChip(_ ctx: CGContext, _ level: Int, ink: NSColor, on: NSColor) {
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 2.6, y: 2.6, width: 10.8, height: 10.8), cornerWidth: 1.8, cornerHeight: 1.8, transform: nil))
        ctx.strokePath()
        // Kaki chip: 2 di tiap sisi
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        for p in [CGFloat(6), 10] {
            ctx.move(to: CGPoint(x: p, y: 0.6)); ctx.addLine(to: CGPoint(x: p, y: 2))
            ctx.move(to: CGPoint(x: p, y: 14)); ctx.addLine(to: CGPoint(x: p, y: 15.4))
            ctx.move(to: CGPoint(x: 0.6, y: p)); ctx.addLine(to: CGPoint(x: 2, y: p))
            ctx.move(to: CGPoint(x: 14, y: p)); ctx.addLine(to: CGPoint(x: 15.4, y: p))
        }
        ctx.strokePath()
        for i in 0..<4 {
            ctx.setFillColor((i < level ? on : ink.withAlphaComponent(dim)).cgColor)
            let y = 10.7 - CGFloat(i) * 2.1
            ctx.addPath(CGPath(roundedRect: CGRect(x: 4.6, y: y, width: 6.8, height: 1.5), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
            ctx.fillPath()
        }
    }

    private static func diskBody() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 2, y: 3.5))
        p.addQuadCurve(to: CGPoint(x: 12, y: 3.5), control: CGPoint(x: 7, y: 1))
        p.addLine(to: CGPoint(x: 12, y: 12.5))
        p.addQuadCurve(to: CGPoint(x: 2, y: 12.5), control: CGPoint(x: 7, y: 15))
        p.closeSubpath()
        return p
    }

    private static func drawDisk(_ ctx: CGContext, _ frac: Double, ink: NSColor, warn: NSColor?) {
        let body = diskBody()
        let h = 9 * CGFloat(min(1, max(0, frac)))  // isian dari bawah (y 14) sampai paling tinggi y 5, tutup tetap terlihat
        if h > 0.2 {
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.setFillColor((warn ?? ink.withAlphaComponent(0.85)).cgColor)
            ctx.fill(CGRect(x: 0, y: 14 - h, width: 14, height: h + 1))
            ctx.restoreGState()
        }
        let sw: CGFloat = warn != nil ? 2 : 1.2
        ctx.setStrokeColor((warn ?? ink).cgColor)
        ctx.setLineWidth(sw)
        ctx.setLineJoin(.round)
        ctx.addPath(body)
        ctx.strokePath()
        let lid = CGMutablePath()
        lid.move(to: CGPoint(x: 2, y: 3.5))
        lid.addQuadCurve(to: CGPoint(x: 12, y: 3.5), control: CGPoint(x: 7, y: 6))
        ctx.setLineWidth(sw * 0.8)
        ctx.addPath(lid)
        ctx.strokePath()
    }

    private static func drawCombo(_ ctx: CGContext, ring: Double, ringColor: NSColor, center: MetricKind?,
                                  netLevel: Int, bat: Double, batColor: NSColor,
                                  dotsOn: Int?, warnDot: NSColor?, ink: NSColor) {
        strokeRing(ctx, cx: 11, cy: 9, r: 7.6, width: 1.8, frac: ring, ink: ink, accent: ringColor)
        switch center {
        case .net:
            // 3 level internet dipetakan ke 2 busur kecil
            drawFan(ctx, cx: 11, cy: 11.6, radii: [2.4, 4.6], on: min(2, netLevel), width: 1.5, dot: 1.1, dotOn: true, ink: ink)
        case .bat:
            ctx.setLineWidth(1)
            ctx.setStrokeColor(ink.withAlphaComponent(0.6).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 6.5, y: 6.5, width: 9, height: 5), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.strokePath()
            ctx.setFillColor(ink.withAlphaComponent(0.6).cgColor)
            ctx.fill(CGRect(x: 15.7, y: 8.2, width: 0.9, height: 1.6))
            let fw = 6.6 * CGFloat(min(1, max(0, bat)))
            if fw > 0.3 {
                ctx.setFillColor(batColor.cgColor)
                ctx.fill(CGRect(x: 7.7, y: 7.7, width: fw, height: 2.6))
            }
        default:
            break
        }
        if let on = dotsOn {
            for i in 0..<5 {
                var c = i < on ? ink : ink.withAlphaComponent(dim)
                if i == 4, let w = warnDot { c = w }
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: 3 + CGFloat(i) * 4 - 1.25, y: 20.6 - 1.25, width: 2.5, height: 2.5))
            }
        } else if let w = warnDot {
            ctx.setFillColor(w.cgColor)
            ctx.fillEllipse(in: CGRect(x: 11 - 1.25, y: 20.6 - 1.25, width: 2.5, height: 2.5))
        }
    }

    /// Angka kecil di tengah cincin glyph B (koordinat unit 22×22, pusat cincin di 11,9)
    private static func drawCenterNumber(_ t: String, color: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: t.count >= 3 ? 6 : 7.5, weight: .bold)
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (t as NSString).size(withAttributes: attr)
        (t as NSString).draw(at: NSPoint(x: 11 - size.width / 2, y: 9 - size.height / 2), withAttributes: attr)
    }

    /// `cy` = pusat vertikal teks (nil = tengah menu bar; grid memakai pusat barisnya)
    private static func drawNumber(_ t: String, at x: CGFloat, font: NSFont, ink: NSColor, cy: CGFloat? = nil) {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let h = font.ascender - font.descender
        (t as NSString).draw(at: NSPoint(x: x, y: (cy ?? barHeight / 2) - h / 2), withAttributes: attr)
    }
}
