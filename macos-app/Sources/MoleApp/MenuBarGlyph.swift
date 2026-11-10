// MoleApp — Ikon gabungan menu bar ala Apple (lihat macos-app/_tech_debt/combined-menubar-glyph.md).
// Varian A (glyph baris): RAM = 4 batang sinyal, Internet = kipas 3 busur, Baterai = isian,
// Storage = silinder berisi, CPU = cincin. Varian B (glyph tunggal): cincin + pusat + 5 titik,
// isi tiap slot bisa dipilih di Pengaturan.
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
        case .glyphRow: return "Bentuk per metrik berjajar, ±80 pt"
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
    // Cara membaca metrik
    var diskShowsFree = false
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
    static let centerOptions: [MetricKind] = [.net, .bat]
    static let dotsOptions: [MetricKind] = [.mem, .cpu, .disk]

    /// Ambang busur internet (byte/detik): Rumahan 10 KB/s · 1 MB/s · 10 MB/s, Cepat 100 KB/s · 10 MB/s · 100 MB/s
    var netThresholds: [Double] {
        netFast ? [100 * 1024, 10 * 1_048_576, 100 * 1_048_576] : [10 * 1024, 1_048_576, 10 * 1_048_576]
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
        var memBars = 0             // 0...4
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

    private static func levels(_ p: GlyphPrefs, _ v: MetricValues) -> Levels {
        var l = Levels()
        l.cpu = q(v.cpu)
        l.mem = q(v.memPercent)
        l.memBars = Int((min(100, max(0, v.memPercent)) / 25).rounded())
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
        case .cpu: return String(format: "%.0f%%", v.cpu)
        case .mem: return String(format: "%.0f%%", v.memPercent)
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
        default: return "100%"
        }
    }

    static func tooltip(_ k: MetricKind, _ v: MetricValues) -> String {
        switch k {
        case .cpu:
            return String(format: "CPU %.0f%%", v.cpu)
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
            p.style.rawValue, dark ? "d" : "l",
            "\(l.cpu)", "\(l.memBars)", "\(l.mem)", "\(l.diskFill)", "\(l.netLevel)",
            "\(l.bat ?? -1)", "\(l.charging)", "\(l.batWarn)", "\(l.diskWarn)", "\(l.cpuWarn)"
        ]
        for k in visibleKinds(p, v) where p.glyph.numbers.contains(k) {
            parts.append(numberText(k, p.glyph, v))
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

        // Tata letak baris: glyph (+ angka opsional) berjajar dengan jarak `gap`
        struct Slot { let kind: MetricKind; let x: CGFloat; let glyphW: CGFloat; let text: String?; let textW: CGFloat }
        var slots: [Slot] = []
        var x: CGFloat = 0
        for k in kinds {
            let gw = unitWidth(k) * s
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
                    switch sl.kind {
                    case .cpu: Self.drawCPU(ctx, l.cpu, ink: ink, accent: l.cpuWarn ? Self.red : ink)
                    case .mem: Self.drawRAM(ctx, l.memBars, ink: ink)
                    case .net: Self.drawNet(ctx, l.netLevel, ink: ink)
                    case .bat: Self.drawBattery(ctx, l.bat ?? 0, ink: ink, fill: l.batWarn ? Self.red : ink, charging: g.bolt && l.charging)
                    case .disk: Self.drawDisk(ctx, l.diskFill, ink: ink, warn: l.diskWarn ? Self.orange : nil)
                    }
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
            }
            if let t = text { Self.drawNumber(t, at: w + 2, font: numFont, ink: ink) }
            return true
        }
        img.isTemplate = template
        return IndicatorRender(image: img, regions: regions)
    }

    // MARK: Primitif gambar (koordinat unit sama dengan mockup SVG)

    private static func unitWidth(_ k: MetricKind) -> CGFloat {
        switch k {
        case .cpu, .mem: return 16
        case .net: return 18
        case .bat: return 27
        case .disk: return 14
        }
    }

    private static func unit(_ ctx: CGContext, x: CGFloat, h: CGFloat, s: CGFloat, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: (barHeight - h * s) / 2)
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

    private static func drawRAM(_ ctx: CGContext, _ bars: Int, ink: NSColor) {
        for (i, h) in [CGFloat(4), 7, 10, 13].enumerated() {
            ctx.setFillColor((i < bars ? ink : ink.withAlphaComponent(dim)).cgColor)
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
            let bolt = CGMutablePath()
            bolt.addLines(between: [
                CGPoint(x: 13.4, y: 2.2), CGPoint(x: 9.4, y: 8.6), CGPoint(x: 12.4, y: 8.6),
                CGPoint(x: 10.8, y: 13.8), CGPoint(x: 15.2, y: 7), CGPoint(x: 12.2, y: 7)
            ])
            bolt.closeSubpath()
            // Lubangi dulu sekeliling petir supaya terbaca di atas isian
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(1.8)
            ctx.setLineJoin(.round)
            ctx.addPath(bolt)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setFillColor(ink.cgColor)
            ctx.addPath(bolt)
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

    private static func drawNumber(_ t: String, at x: CGFloat, font: NSFont, ink: NSColor) {
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let h = font.ascender - font.descender
        (t as NSString).draw(at: NSPoint(x: x, y: (barHeight - h) / 2), withAttributes: attr)
    }
}
