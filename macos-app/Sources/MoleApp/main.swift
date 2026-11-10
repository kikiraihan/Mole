// MoleApp — Menu Bar Indicator + Mac App Dashboard untuk seluruh fitur Mole CLI
// Dibuat dengan Swift + AppKit murni (tanpa dependensi eksternal, kompilasi instan < 3 detik).
// Dashboard & popover memakai SwiftUI (Dashboard.swift, Popover.swift); file ini tetap memegang indikator & bridge CLI.
// Build: ./macos-app/scripts/build.sh

import Cocoa
import IOKit.ps
import ServiceManagement
import SwiftUI

// MARK: - 1. Native Real-Time Metrics Sampler (Menu Bar Indicator ala LiteMonitor)

let hostPort = mach_host_self()

final class CPUSampler {
    private var prev: (UInt32, UInt32, UInt32, UInt32)?

    func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        defer { prev = t }
        guard let p = prev else { return 0 }
        let user = Double(t.0 &- p.0), sys = Double(t.1 &- p.1)
        let idle = Double(t.2 &- p.2), nice = Double(t.3 &- p.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total * 100.0 : 0
    }
}

func sampleMemory() -> (used: UInt64, total: UInt64, percent: Double) {
    let total = ProcessInfo.processInfo.physicalMemory
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, total, 0) }
    let page = UInt64(vm_kernel_page_size)
    let internalPages = UInt64(stats.internal_page_count)
    let purgeable = UInt64(stats.purgeable_count)
    let app = internalPages > purgeable ? internalPages - purgeable : 0
    let used = min((app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page, total)
    let pct = total > 0 ? (Double(used) / Double(total)) * 100.0 : 0
    return (used, total, pct)
}

final class NetSampler {
    private var lastIn: UInt64 = 0, lastOut: UInt64 = 0
    private var lastTime: TimeInterval = 0

    func sample() -> (up: Double, down: Double) {
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let p = ptr {
                let ifa = p.pointee
                if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   String(cString: ifa.ifa_name).hasPrefix("en"),
                   let raw = ifa.ifa_data {
                    let d = raw.assumingMemoryBound(to: if_data.self).pointee
                    inB += UInt64(d.ifi_ibytes)
                    outB += UInt64(d.ifi_obytes)
                }
                ptr = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastIn = inB; lastOut = outB; lastTime = now }
        guard lastTime > 0, now > lastTime else { return (0, 0) }
        let dt = now - lastTime
        let dIn = inB >= lastIn ? Double(inB - lastIn) : 0
        let dOut = outB >= lastOut ? Double(outB - lastOut) : 0
        return (dOut / dt, dIn / dt)
    }
}

struct DiskSnapshot: Equatable {
    let name: String
    let used: Int64
    let free: Int64
    let total: Int64
    var percent: Double { total > 0 ? (Double(used) / Double(total)) * 100.0 : 0 }
}

func sampleDisk() -> DiskSnapshot {
    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let total = v.volumeTotalCapacity,
          let avail = v.volumeAvailableCapacityForImportantUsage else {
        return DiskSnapshot(name: "Macintosh HD", used: 0, free: 0, total: 1)
    }
    let t = Int64(total)
    let f = Int64(avail)
    return DiskSnapshot(name: v.volumeName ?? "Macintosh HD", used: max(0, t - f), free: f, total: t)
}

struct BatterySnapshot: Equatable {
    let percent: Int
    let charging: Bool
    let charged: Bool
    let onAC: Bool
}

func sampleBattery() -> BatterySnapshot? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              (d["Type"] as? String) == "InternalBattery",
              let cur = d["Current Capacity"] as? Int,
              let max = d["Max Capacity"] as? Int, max > 0 else { continue }
        return BatterySnapshot(
            percent: cur * 100 / max,
            charging: d["Is Charging"] as? Bool ?? false,
            charged: d["Is Charged"] as? Bool ?? false,
            onAC: (d["Power Source State"] as? String) == "AC Power"
        )
    }
    return nil
}

// MARK: - 2. Formatters & Helpers

func formatBytes(_ bytes: Int64) -> String {
    let b = Double(max(0, bytes))
    if b >= 1_000_000_000 {
        return String(format: "%.1f GB", b / 1_073_741_824.0)
    } else if b >= 1_000_000 {
        return String(format: "%.1f MB", b / 1_048_576.0)
    } else if b >= 1_000 {
        return String(format: "%.0f KB", b / 1024.0)
    }
    return "\(bytes) B"
}

func formatNetRate(_ bytesPerSec: Double, short: Bool = false) -> String {
    let kb = bytesPerSec / 1024.0
    if kb >= 1024.0 {
        return String(format: short ? "%.1fM" : "%.1f MB/s", kb / 1024.0)
    } else if kb >= 1.0 {
        return String(format: short ? "%.0fK" : "%.0f KB/s", kb)
    }
    return short ? "0K" : "0 KB/s"
}

// Regex dikompilasi sekali saja (sebelumnya dikompilasi ulang untuk setiap potongan output streaming)
private let ansiRegex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07|\\r", options: [])

func stripANSI(_ input: String) -> String {
    guard let regex = ansiRegex else {
        return input
    }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
}

// MARK: - 2b. Render Indikator Menu Bar (disamakan dengan LiteMonitor)
// Digambar sebagai NSImage template: otomatis ikut warna menu bar terang/gelap,
// lebar kolom dikunci pakai template supaya ikon tidak "goyang" saat angka berubah.

func fmtRate(_ b: Double, short: Bool) -> String {
    let k = b / 1024
    if k < 1000 { return String(format: short ? "%.1fK" : "%.1f KB/s", k) }
    return String(format: short ? "%.1fM" : "%.1f MB/s", k / 1024)
}

struct Col { let top: String; let bottom: String; let topIsLabel: Bool; let template: String }
struct CompactItem { let symbol: String; let text: String; let template: String }

func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: f]).width
}

/// Mode normal: 2 baris (label di atas, nilai di bawah)
func renderFull(_ cols: [Col]) -> NSImage {
    let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    let gap: CGFloat = 5 // padding tipis antar kolom supaya angka tidak menempel, tetap compact
    let widths = cols.map { c -> CGFloat in
        let tf = c.topIsLabel ? labelFont : valueFont
        return ceil(max(textWidth(c.top, tf), textWidth(c.bottom, valueFont), textWidth(c.template, valueFont)))
    }
    let total = widths.reduce(0, +) + gap * CGFloat(max(cols.count - 1, 0))
    let img = NSImage(size: NSSize(width: max(total, 1), height: 22), flipped: true) { _ in
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        var x: CGFloat = 0
        for (i, c) in cols.enumerated() {
            let topAttr: [NSAttributedString.Key: Any] = [
                .font: c.topIsLabel ? labelFont : valueFont, .foregroundColor: NSColor.black, .paragraphStyle: ps
            ]
            let botAttr: [NSAttributedString.Key: Any] = [
                .font: valueFont, .foregroundColor: NSColor.black, .paragraphStyle: ps
            ]
            (c.top as NSString).draw(in: NSRect(x: x, y: 0, width: widths[i], height: 11), withAttributes: topAttr)
            (c.bottom as NSString).draw(in: NSRect(x: x, y: 10, width: widths[i], height: 12), withAttributes: botAttr)
            x += widths[i] + gap
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Mode ringkas: 1 baris, ikon SF Symbol + angka (paling hemat tempat)
func renderCompact(_ items: [CompactItem]) -> NSImage {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    let icon: CGFloat = 13, iconGap: CGFloat = 2, gap: CGFloat = 6
    let widths = items.map { ceil(max(textWidth($0.text, font), textWidth($0.template, font))) }
    var total: CGFloat = 0
    for w in widths { total += icon + iconGap + w }
    total += gap * CGFloat(max(items.count - 1, 0))
    let img = NSImage(size: NSSize(width: max(total, 1), height: 22), flipped: true) { _ in
        let attr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textH = font.ascender - font.descender
        var x: CGFloat = 0
        for (i, it) in items.enumerated() {
            if let sym = NSImage(systemSymbolName: it.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let sz = sym.size
                let scale = min(icon / max(sz.width, 1), icon / max(sz.height, 1), 1)
                let w = sz.width * scale, h = sz.height * scale
                sym.draw(in: NSRect(x: x + (icon - w) / 2, y: (22 - h) / 2, width: w, height: h))
            }
            x += icon + iconGap
            (it.text as NSString).draw(at: NSPoint(x: x, y: (22 - textH) / 2), withAttributes: attr)
            x += widths[i] + gap
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Pilihan interval update yang ditawarkan menu klik kanan dan tab Pengaturan Indikator
let indicatorIntervals: [Double] = [1.0, 2.0, 5.0]

/// Dikirim tab Pengaturan Indikator setelah mengubah UserDefaults supaya menu bar langsung ikut berubah
extension Notification.Name {
    static let indicatorSettingsChanged = Notification.Name("id.local.moleapp.indicatorSettingsChanged")
}

/// Metrik yang ditampilkan di menu bar (kunci UserDefaults sama dengan versi sebelumnya)
/// plus gaya indikator, urutan, dan pengaturan glyph. Semua kunci hanya dibaca/ditulis di sini.
struct IndicatorPrefs: Equatable {
    var cpu = true, mem = true, disk = true, net = false, bat = false
    var style: IndicatorStyle = .text2
    var order: [MetricKind] = MetricKind.allCases
    var interval: Double = 2.0
    var glyph = GlyphPrefs()

    var compact: Bool { style == .compact }

    func isOn(_ k: MetricKind) -> Bool {
        switch k {
        case .cpu: return cpu
        case .mem: return mem
        case .disk: return disk
        case .net: return net
        case .bat: return bat
        }
    }

    mutating func set(_ k: MetricKind, _ on: Bool) {
        switch k {
        case .cpu: cpu = on
        case .mem: mem = on
        case .disk: disk = on
        case .net: net = on
        case .bat: bat = on
        }
    }

    var enabledInOrder: [MetricKind] { order.filter { isOn($0) } }

    /// Nilai bawaan (didaftarkan AppDelegate; tombol "Kembalikan bawaan" menghapus kunci-kunci ini)
    static let registeredDefaults: [String: Any] = [
        "cpu": true,
        "mem": true,
        "disk": true,
        "net": false,
        "bat": false,
        "interval": 2.0,
        "indicatorStyle": IndicatorStyle.text2.rawValue,
        "indicatorOrder": MetricKind.allCases.map(\.rawValue).joined(separator: ","),
        "glyphRing": MetricKind.cpu.rawValue,
        "glyphCenter": MetricKind.net.rawValue,
        "glyphDots": MetricKind.mem.rawValue,
        "glyphMemIcon": GlyphIcon.lanes.rawValue,
        "glyphNetIcon": GlyphIcon.fan.rawValue,
        "glyphRowLayout": GlyphLayout.single.rawValue,
        "glyphCPUIcon": GlyphIcon.ring.rawValue,
        "glyphBatIcon": GlyphIcon.batH.rawValue,
        "glyphCPUMode": "percent",
        "glyphMemMode": "percent",
        "glyphDiskMode": "used",
        "glyphNetDirection": NetDirection.down.rawValue,
        "glyphNetPreset": "home",
        "glyphBolt": true,
        "glyphNumbers": "",
        "warnColors": true,
        "warnBattery": 20,
        "warnDisk": 10,
        "warnCPUOn": false,
        "warnCPU": 90,
        "glyphSize": "standard",
        "glyphSpacing": "normal",
        "clickRegions": true,
        "regionTooltips": true
    ]

    /// Versi lama menyimpan mode tampilan sebagai `compact` (Bool). Dipanggil sebelum register(defaults:)
    /// supaya hanya nilai yang benar-benar tersimpan yang dibaca.
    static func migrateLegacy(_ d: UserDefaults = .standard) {
        guard d.object(forKey: "indicatorStyle") == nil, d.object(forKey: "compact") != nil else { return }
        d.set((d.bool(forKey: "compact") ? IndicatorStyle.compact : .text2).rawValue, forKey: "indicatorStyle")
        d.removeObject(forKey: "compact")
    }

    private static func kind(_ s: String?) -> MetricKind? { s.flatMap(MetricKind.init(rawValue:)) }

    static func load(_ d: UserDefaults = .standard) -> IndicatorPrefs {
        var p = IndicatorPrefs(
            cpu: d.bool(forKey: "cpu"), mem: d.bool(forKey: "mem"), disk: d.bool(forKey: "disk"),
            net: d.bool(forKey: "net"), bat: d.bool(forKey: "bat")
        )
        p.style = IndicatorStyle(rawValue: d.string(forKey: "indicatorStyle") ?? "") ?? .text2
        // Urutan: buang nilai tak dikenal/ganda, metrik yang hilang ditambahkan di akhir
        var order: [MetricKind] = []
        for k in (d.string(forKey: "indicatorOrder") ?? "").split(separator: ",").compactMap({ MetricKind(rawValue: String($0)) })
        where !order.contains(k) {
            order.append(k)
        }
        p.order = order + MetricKind.allCases.filter { !order.contains($0) }
        p.interval = max(1.0, d.double(forKey: "interval"))

        var g = GlyphPrefs()
        if let r = kind(d.string(forKey: "glyphRing")), GlyphPrefs.ringOptions.contains(r) { g.ring = r }
        g.center = kind(d.string(forKey: "glyphCenter")).flatMap { GlyphPrefs.centerOptions.contains($0) ? $0 : nil }
        g.dots = kind(d.string(forKey: "glyphDots")).flatMap { GlyphPrefs.dotsOptions.contains($0) ? $0 : nil }
        if let i = GlyphIcon(rawValue: d.string(forKey: "glyphMemIcon") ?? ""), GlyphPrefs.memIconOptions.contains(i) { g.memIcon = i }
        if let i = GlyphIcon(rawValue: d.string(forKey: "glyphNetIcon") ?? ""), GlyphPrefs.netIconOptions.contains(i) { g.netIcon = i }
        g.rowLayout = GlyphLayout(rawValue: d.string(forKey: "glyphRowLayout") ?? "") ?? .single
        if let i = GlyphIcon(rawValue: d.string(forKey: "glyphCPUIcon") ?? ""), GlyphPrefs.cpuIconOptions.contains(i) { g.cpuIcon = i }
        if let i = GlyphIcon(rawValue: d.string(forKey: "glyphBatIcon") ?? ""), GlyphPrefs.batIconOptions.contains(i) { g.batIcon = i }
        g.cpuShowsNumber = d.string(forKey: "glyphCPUMode") == "number"
        g.memShowsNumber = d.string(forKey: "glyphMemMode") == "number"
        g.diskShowsFree = d.string(forKey: "glyphDiskMode") == "free"
        g.netDirection = NetDirection(rawValue: d.string(forKey: "glyphNetDirection") ?? "") ?? .down
        g.netFast = d.string(forKey: "glyphNetPreset") == "fast"
        g.bolt = d.bool(forKey: "glyphBolt")
        g.numbers = Set((d.string(forKey: "glyphNumbers") ?? "").split(separator: ",").compactMap { MetricKind(rawValue: String($0)) })
        g.warnColors = d.bool(forKey: "warnColors")
        g.warnBattery = min(50, max(5, d.integer(forKey: "warnBattery")))
        g.warnDisk = min(30, max(1, d.integer(forKey: "warnDisk")))
        g.warnCPUOn = d.bool(forKey: "warnCPUOn")
        g.warnCPU = min(100, max(50, d.integer(forKey: "warnCPU")))
        g.small = d.string(forKey: "glyphSize") == "small"
        g.tight = d.string(forKey: "glyphSpacing") == "tight"
        g.clickRegions = d.bool(forKey: "clickRegions")
        g.tooltips = d.bool(forKey: "regionTooltips")
        p.glyph = g
        return p
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(cpu, forKey: "cpu")
        d.set(mem, forKey: "mem")
        d.set(disk, forKey: "disk")
        d.set(net, forKey: "net")
        d.set(bat, forKey: "bat")
        d.set(interval, forKey: "interval")
        d.set(style.rawValue, forKey: "indicatorStyle")
        d.set(order.map(\.rawValue).joined(separator: ","), forKey: "indicatorOrder")
        d.set(glyph.ring.rawValue, forKey: "glyphRing")
        d.set(glyph.center?.rawValue ?? "none", forKey: "glyphCenter")
        d.set(glyph.dots?.rawValue ?? "none", forKey: "glyphDots")
        d.set(glyph.memIcon.rawValue, forKey: "glyphMemIcon")
        d.set(glyph.netIcon.rawValue, forKey: "glyphNetIcon")
        d.set(glyph.rowLayout.rawValue, forKey: "glyphRowLayout")
        d.set(glyph.cpuIcon.rawValue, forKey: "glyphCPUIcon")
        d.set(glyph.batIcon.rawValue, forKey: "glyphBatIcon")
        d.set(glyph.cpuShowsNumber ? "number" : "percent", forKey: "glyphCPUMode")
        d.set(glyph.memShowsNumber ? "number" : "percent", forKey: "glyphMemMode")
        d.set(glyph.diskShowsFree ? "free" : "used", forKey: "glyphDiskMode")
        d.set(glyph.netDirection.rawValue, forKey: "glyphNetDirection")
        d.set(glyph.netFast ? "fast" : "home", forKey: "glyphNetPreset")
        d.set(glyph.bolt, forKey: "glyphBolt")
        d.set(MetricKind.allCases.filter { glyph.numbers.contains($0) }.map(\.rawValue).joined(separator: ","), forKey: "glyphNumbers")
        d.set(glyph.warnColors, forKey: "warnColors")
        d.set(glyph.warnBattery, forKey: "warnBattery")
        d.set(glyph.warnDisk, forKey: "warnDisk")
        d.set(glyph.warnCPUOn, forKey: "warnCPUOn")
        d.set(glyph.warnCPU, forKey: "warnCPU")
        d.set(glyph.small ? "small" : "standard", forKey: "glyphSize")
        d.set(glyph.tight ? "tight" : "normal", forKey: "glyphSpacing")
        d.set(glyph.clickRegions, forKey: "clickRegions")
        d.set(glyph.tooltips, forKey: "regionTooltips")
    }
}

/// Isi indikator: kolom (mode 2 baris), item (mode ringkas), dan `key` teks yang tampil.
/// `key` dipakai untuk melewati render ulang gambar saat angka di menu bar tidak berubah.
/// Gaya glyph (A/B) digambar GlyphRenderer; `key`-nya berisi level terkuantisasi, bukan angka mentah.
struct IndicatorLayout {
    let cols: [Col]
    let items: [CompactItem]
    let compact: Bool
    let key: String
    let prefs: IndicatorPrefs
    let values: MetricValues
    let dark: Bool

    var isEmpty: Bool { prefs.style == .glyphSingle ? false : cols.isEmpty }

    init(_ p: IndicatorPrefs, _ v: MetricValues, dark: Bool = false) {
        var cols: [Col] = []
        var items: [CompactItem] = []

        // Kolom dibangun mengikuti urutan dari Pengaturan
        for k in p.enabledInOrder {
            switch k {
            case .cpu:
                let val = String(format: "%.0f%%", v.cpu)
                cols.append(Col(top: "CPU", bottom: val, topIsLabel: true, template: "99%"))
                items.append(CompactItem(symbol: "cpu", text: val, template: "99%"))
            case .mem:
                let val = String(format: "%.0f%%", v.memPercent)
                cols.append(Col(top: "RAM", bottom: val, topIsLabel: true, template: "99%"))
                items.append(CompactItem(symbol: "memorychip", text: val, template: "99%"))
            case .disk:
                // sisa ruang dalam GB desimal, sama seperti Finder
                let val = String(format: "%.0fGB", Double(v.disk.free) / 1_000_000_000.0)
                cols.append(Col(top: "SSD", bottom: val, topIsLabel: true, template: ""))
                items.append(CompactItem(symbol: "internaldrive", text: val, template: ""))
            case .net:
                let upS = fmtRate(v.up, short: true), dn = fmtRate(v.down, short: true)
                cols.append(Col(top: "↑" + upS, bottom: "↓" + dn, topIsLabel: false, template: "↓999.9K"))
                items.append(CompactItem(symbol: "arrow.up.arrow.down", text: "↓" + dn, template: "↓99.9K"))
            case .bat:
                guard let b = v.bat else { continue }
                let val = (b.onAC ? "⚡" : "") + "\(b.percent)%"
                cols.append(Col(top: "BAT", bottom: val, topIsLabel: true, template: "⚡99%"))
                items.append(CompactItem(
                    symbol: b.onAC ? "battery.100.bolt" : "battery.100",
                    text: "\(b.percent)%",
                    template: "99%"
                ))
            }
        }

        self.cols = cols
        self.items = items
        self.compact = p.compact
        self.prefs = p
        self.values = v
        self.dark = dark
        switch p.style {
        case .compact:
            key = "c|" + items.map { $0.symbol + ":" + $0.text }.joined(separator: "|")
        case .text2:
            key = "f|" + cols.map { $0.top + "/" + $0.bottom }.joined(separator: "|")
        case .glyphRow, .glyphSingle:
            key = GlyphRenderer.key(p, v, dark: dark)
        }
    }

    /// nil kalau semua metrik dimatikan (pemanggil menampilkan ikon aplikasi)
    func render() -> IndicatorRender? {
        switch prefs.style {
        case .glyphRow, .glyphSingle:
            return GlyphRenderer.render(prefs, values, dark: dark)
        case .text2, .compact:
            guard !cols.isEmpty else { return nil }
            return IndicatorRender(image: compact ? renderCompact(items) : renderFull(cols), regions: [])
        }
    }
}

// MARK: - 3. Mole CLI Runner Bridge

final class MoleBridge {
    static let shared = MoleBridge()

    var moleExecutablePath: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("mole-cli/mole").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let devPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("mole").path
        if FileManager.default.isExecutableFile(atPath: devPath) {
            return devPath
        }
        for c in ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", "/opt/homebrew/bin/mole", "/usr/local/bin/mole"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "mole"
    }

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Versi Mole CLI yang dibundle (dibaca dari baris VERSION= di skrip `mole`).
    var cliVersion: String {
        guard let text = try? String(contentsOfFile: moleExecutablePath, encoding: .utf8) else { return "?" }
        for line in text.split(separator: "\n").prefix(200) where line.hasPrefix("VERSION=") {
            return line.dropFirst("VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return "?"
    }

    /// Process dasar: tanpa warna, PATH standar, stdin /dev/null agar CLI selalu masuk mode non-interaktif.
    private func makeProcess(_ execPath: String, _ args: [String]) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [execPath] + args

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        let stdPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = stdPath + ":" + (env["PATH"] ?? "")
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        return proc
    }

    /// Membaca stderr di thread terpisah supaya pipe tidak penuh dan proses tidak macet.
    private func drainConcurrently(_ handle: FileHandle) -> () -> Data {
        final class Box { var data = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            group.leave()
        }
        return {
            group.wait()
            return box.data
        }
    }

    /// Menjalankan perintah ber-output JSON: hanya stdout yang di-parse, stderr dikembalikan sebagai pesan.
    func runJSON(_ args: [String], completion: @escaping (Any?, String) -> Void) {
        let execPath = moleExecutablePath
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = self.makeProcess(execPath, args)
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    completion(nil, "Gagal menjalankan Mole CLI: \(error.localizedDescription)")
                }
                return
            }
            let errData = self.drainConcurrently(errPipe.fileHandleForReading)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = stripANSI(String(decoding: errData(), as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            proc.waitUntilExit()
            let json = try? JSONSerialization.jsonObject(with: outData, options: [.fragmentsAllowed])
            DispatchQueue.main.async {
                completion(json, errText)
            }
        }
    }

    /// Menjalankan perintah dan mengalirkan output (stdout + stderr) per potongan ke UI.
    @discardableResult
    func stream(_ args: [String], onOutput: @escaping (String) -> Void, completion: @escaping (Int32) -> Void) -> Process? {
        let proc = makeProcess(moleExecutablePath, args)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let reader = pipe.fileHandleForReading
        // Satu antrean serial menjaga urutan potongan output dan sinyal selesai.
        let queue = DispatchQueue(label: "id.local.moleapp.stream")
        reader.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = stripANSI(String(decoding: d, as: UTF8.self))
            queue.async { DispatchQueue.main.async { onOutput(text) } }
        }
        proc.terminationHandler = { p in
            queue.async {
                reader.readabilityHandler = nil
                let rest = reader.readDataToEndOfFile()
                let tail = rest.isEmpty ? "" : stripANSI(String(decoding: rest, as: UTF8.self))
                DispatchQueue.main.async {
                    if !tail.isEmpty { onOutput(tail) }
                    completion(p.terminationStatus)
                }
            }
        }
        do {
            try proc.run()
        } catch {
            reader.readabilityHandler = nil
            onOutput("Gagal menjalankan Mole CLI: \(error.localizedDescription)")
            completion(-1)
            return nil
        }
        return proc
    }

    func runCommand(_ args: [String], completion: @escaping (Int32, String) -> Void) {
        let execPath = moleExecutablePath
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = self.makeProcess(execPath, args)

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do {
                try proc.run()
            } catch {
                DispatchQueue.main.async {
                    completion(-1, "Gagal menjalankan Mole CLI: \(error.localizedDescription)")
                }
                return
            }

            let errReader = self.drainConcurrently(errPipe.fileHandleForReading)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errReader()
            proc.waitUntilExit()

            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            let text = stripANSI(outStr + (errStr.isEmpty ? "" : "\n" + errStr))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            DispatchQueue.main.async {
                completion(proc.terminationStatus, text)
            }
        }
    }

    func openInTerminal(_ subcommand: String) {
        let execQuoted = "'" + moleExecutablePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let fullCmd = subcommand.isEmpty ? execQuoted : "\(execQuoted) \(subcommand)"
        let escaped = fullCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

// MARK: - 4. Auto-Updater (pola mac-os-lite-monitor / PasteLAN)
// Cek diam-diam saat app dibuka lalu sehari sekali. "Update sekarang" mengunduh MoleApp.zip,
// memverifikasi isinya, lalu menukar .app setelah MoleApp keluar (versi lama dicadangkan dulu)
// dan membukanya lagi. Pengaturan (UserDefaults) tetap tersimpan.

final class Updater: NSObject {
    let repo = "kikiraihan/mole"
    let appName = "MoleApp"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: URL?, page: URL)
    var latest: Release?
    var timer: Timer?

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// "app-v1.2.0" lebih baru dari "1.1.0"? (awalan app-v / v diabaikan)
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s
            if t.hasPrefix("app-") { t.removeFirst(4) }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
                .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    var hasUpdate: Bool { latest.map { Updater.isNewer($0.version, than: Updater.current) } ?? false }

    override init() {
        super.init()
        menuItem.target = self
    }

    /// Cek diam-diam saat aplikasi dibuka lalu sehari sekali; kalau ada versi baru, judul menu berubah
    func start() {
        check { [weak self] _ in self?.refreshMenu() }
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check { _ in self?.refreshMenu() }
        }
        t.tolerance = 3600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshMenu() {
        menuItem.isEnabled = true
        if let l = latest, hasUpdate {
            menuItem.title = "Update tersedia: \(l.version)…"
            LiveMetrics.shared.updateVersion = l.version
        } else {
            menuItem.title = "Cek pembaruan…"
            LiveMetrics.shared.updateVersion = nil
        }
    }

    /// Ambil rilis MoleApp terbaru. Daftar rilis difilter ke tag app-v* (bukan releases/latest),
    /// karena repo yang sama juga bisa berisi rilis Mole CLI (V*).
    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var found: Release?
            if let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in list {
                    guard let tag = item["tag_name"] as? String, tag.hasPrefix("app-v"),
                          (item["draft"] as? Bool) != true, (item["prerelease"] as? Bool) != true,
                          let page = (item["html_url"] as? String).flatMap({ URL(string: $0) }) else { continue }
                    let assets = item["assets"] as? [[String: Any]] ?? []
                    let zipURL = (assets.first { ($0["name"] as? String) == "\(self.appName).zip" }?["browser_download_url"] as? String)
                        .flatMap { URL(string: $0) }
                    if found == nil || Updater.isNewer(tag, than: found!.version) {
                        found = (tag, zipURL, page)
                    }
                }
            }
            DispatchQueue.main.async {
                if let found { self.latest = found }
                done(found != nil)
            }
        }.resume()
    }

    @objc func checkNow() {
        menuItem.title = "Mengecek pembaruan…"
        menuItem.isEnabled = false
        check { [weak self] ok in
            guard let self else { return }
            self.refreshMenu()
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Gagal mengecek pembaruan"
                a.informativeText = "Periksa koneksi internet, lalu coba lagi.\nVersi terpasang: v\(Updater.current)"
                a.runModal()
                return
            }
            guard self.hasUpdate else {
                a.messageText = "MoleApp sudah versi terbaru"
                a.informativeText = "Versi terpasang: v\(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "MoleApp \(l.version) tersedia"
            a.informativeText = "Versi terpasang: v\(Updater.current).\n\nMoleApp akan ditutup, diganti versi baru (termasuk Mole CLI di dalamnya), lalu dibuka lagi. Pengaturan tetap tersimpan."
            a.addButton(withTitle: "Update sekarang")
            a.addButton(withTitle: "Lihat rilis")
            a.addButton(withTitle: "Nanti")
            switch a.runModal() {
            case .alertFirstButtonReturn: self.install(l)
            case .alertSecondButtonReturn: NSWorkspace.shared.open(l.page)
            default: break
            }
        }
    }

    /// Unduh .zip rilis, ekstrak, verifikasi, lalu ganti .app lama setelah aplikasi ini keluar
    func install(_ l: Release) {
        let dest = Bundle.main.bundleURL
        // tanpa file .zip, bukan .app, atau folder tidak bisa ditulis → unduh manual dari halaman rilis
        guard let zip = l.zip, dest.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(l.page)
            return
        }
        menuItem.title = "Mengunduh \(l.version)…"
        menuItem.isEnabled = false
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("\(self.appName)-update-\(UUID().uuidString)")
            let zipFile = work.appendingPathComponent("update.zip")
            let newApp = work.appendingPathComponent("\(self.appName).app")
            var problem: String?
            if let tmp {
                do {
                    // file sementara dihapus setelah handler ini selesai → pindahkan sekarang
                    try fm.createDirectory(at: work, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zipFile)
                    let unzip = Process()
                    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzip.arguments = ["-x", "-k", zipFile.path, work.path]
                    try unzip.run()
                    unzip.waitUntilExit()
                    if unzip.terminationStatus != 0 || !fm.fileExists(atPath: newApp.path) {
                        problem = "File rilis tidak berisi \(self.appName).app."
                    } else if Bundle(url: newApp)?.bundleIdentifier != Bundle.main.bundleIdentifier {
                        // tolak bundle lain yang menyamar sebagai MoleApp
                        problem = "Bundle di file rilis bukan MoleApp (bundle ID berbeda)."
                    }
                } catch {
                    problem = error.localizedDescription
                }
            } else {
                problem = err?.localizedDescription ?? "Unduhan gagal."
            }
            DispatchQueue.main.async {
                if let problem { return self.fail(problem, l.page) }
                // skrip kecil: tunggu aplikasi ini keluar, tukar .app (lama dicadangkan dulu), lalu buka lagi
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                if mv "$3" "$4"; then
                  if mv "$2" "$3"; then rm -rf "$4"; else mv "$4" "$3"; fi
                fi
                /usr/bin/xattr -cr "$3" 2>/dev/null
                /usr/bin/open "$3"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script, "sh", String(getpid()), newApp.path, dest.path,
                               work.appendingPathComponent("old.app").path]
                do {
                    try p.run()
                } catch {
                    return self.fail(error.localizedDescription, l.page)
                }
                NSApp.terminate(nil)
            }
        }.resume()
    }

    func fail(_ msg: String, _ page: URL) {
        refreshMenu()
        let a = NSAlert()
        a.messageText = "Update gagal"
        a.informativeText = "\(msg)\n\nHalaman rilis akan dibuka supaya Anda bisa mengunduh manual."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        NSWorkspace.shared.open(page)
    }
}

// MARK: - 5. Mac App Dashboard Window Controller (SwiftUI, lihat Dashboard.swift)
// Antarmuka lama berbasis tab segmented + konsol teks diganti dengan dashboard SwiftUI bersidebar.
// API publik (window, show(tab:), updateLiveBanner) dipertahankan agar AppDelegate tetap sama.

final class DashboardWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model = DashboardModel()
    /// Dipanggil setiap dashboard ditampilkan, supaya metrik live langsung segar walau
    /// indikator berhenti mengirim data ke SwiftUI selama jendela tertutup.
    var onShow: (() -> Void)?

    /// Benar hanya saat jendela benar-benar terlihat (tidak tertutup, diminimalkan, atau tertimpa penuh).
    var isOnScreen: Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "MoleApp"
        window.subtitle = "v\(MoleBridge.shared.version), Mole CLI v\(MoleBridge.shared.cliVersion)"
        window.contentViewController = NSHostingController(rootView: DashboardRoot(model: model))
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.minSize = NSSize(width: 880, height: 580)
        window.setFrameAutosaveName("MoleAppDashboard")
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // Jendela muncul lagi (dari minimize / tertimpa jendela lain) → segarkan metrik tanpa menunggu tick
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isOnScreen { onShow?() }
    }

    func show(tab: Int? = nil) {
        if let tab, let feature = Feature(rawValue: tab) {
            model.selection = feature
        }
        let wasAccessory = NSApp.activationPolicy() != .regular
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Pindah dari .accessory ke .regular: menu bar aplikasi kadang baru muncul/bisa diklik setelah
        // aktivasi berikutnya, jadi aktifkan sekali lagi setelah run loop berputar
        if wasAccessory {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
        onShow?()
    }

    func updateLiveBanner(cpu: Double, memUsed: UInt64, memTotal: UInt64, disk: DiskSnapshot, netUp: Double, netDown: Double, bat: BatterySnapshot?) {
        LiveMetrics.shared.update(cpu: cpu, memUsed: memUsed, memTotal: memTotal, disk: disk, netUp: netUp, netDown: netDown, bat: bat)
    }
}

// MARK: - 6. Menu Bar Indicator AppDelegate (Ala LiteMonitor + Mole Quick Actions)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSViewToolTipOwner {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    let updater = Updater()
    // Dashboard baru dibuat saat pertama kali dibuka (dulu ikut terbuat di tick pertama karena
    // tick() membaca dashboard.window, sehingga seluruh view SwiftUI menetap di memori sejak start)
    private var dashboardLoaded = false
    lazy var dashboard: DashboardWindowController = {
        let d = DashboardWindowController()
        d.onShow = { [weak self] in self?.pushLive() }
        self.dashboardLoaded = true
        return d
    }()

    // Popover ringkas untuk klik kiri (klik kanan tetap membuka menu lengkap)
    lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let actions = PopoverActions(
            openTab: { [weak self] tab in
                guard let self else { return }
                self.popover.performClose(nil)
                if let tab {
                    self.dashboard.show(tab: tab)
                } else {
                    self.dashboard.show(tab: nil)
                }
            },
            openTerminal: { [weak self] in
                self?.popover.performClose(nil)
                MoleBridge.shared.openInTerminal("")
            },
            openMenu: { [weak self] in
                self?.popover.performClose(nil)
                self?.showMenu()
            },
            openSettings: { [weak self] in
                guard let self else { return }
                self.popover.performClose(nil)
                self.dashboard.show(tab: Feature.settings.rawValue)
            },
            checkUpdate: { [weak self] in
                guard let self else { return }
                self.popover.performClose(nil)
                self.updater.checkNow()
            },
            quit: { NSApp.terminate(nil) }
        )
        p.contentViewController = NSHostingController(rootView: PopoverView(actions: actions))
        self.popoverLoaded = true
        return p
    }()
    private var popoverLoaded = false

    private let cpuSampler = CPUSampler()
    private let netSampler = NetSampler()
    private var timer: Timer?
    private var tickCount = 0
    private var menuIsOpen = false
    /// Teks indikator terakhir yang digambar; sama → gambar NSImage lama dipakai lagi
    private var lastBarKey: String?
    /// Pengaturan indikator di-cache; dibaca ulang hanya saat Pengaturan berubah (bukan tiap tick)
    private var prefs = IndicatorPrefs()
    /// Bagian glyph yang bisa diklik/di-hover (koordinat gambar) dan ukuran gambar terakhir
    private var regions: [GlyphRegion] = []
    private var barImageSize: NSSize = .zero

    private var cpuPct: Double = 0
    private var mem: (used: UInt64, total: UInt64, percent: Double) = (0, 1, 0)
    private var rate: (up: Double, down: Double) = (0, 0)
    private var disk: DiskSnapshot = sampleDisk()
    private var bat: BatterySnapshot? = sampleBattery()

    // Live Menu Rows
    private let cpuRow = NSMenuItem(title: "CPU: —", action: nil, keyEquivalent: "")
    private let memRow = NSMenuItem(title: "Memori: —", action: nil, keyEquivalent: "")
    private let diskRow = NSMenuItem(title: "Disk: —", action: nil, keyEquivalent: "")
    private let netRow = NSMenuItem(title: "Jaringan: —", action: nil, keyEquivalent: "")
    private let batRow = NSMenuItem(title: "Baterai: —", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `compact` lama → `indicatorStyle`; harus sebelum register supaya hanya nilai tersimpan yang dibaca
        IndicatorPrefs.migrateLegacy(defaults)
        defaults.register(defaults: IndicatorPrefs.registeredDefaults)
        prefs = IndicatorPrefs.load(defaults)

        // Klik kiri: popover ringkas; klik kanan (atau Control-klik): menu lengkap
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        buildMenu()
        // Menu bar aplikasi (di samping logo Apple) yang tampil saat dashboard terbuka
        buildMainMenu()

        // Perubahan dari tab Pengaturan Indikator di dashboard
        NotificationCenter.default.addObserver(
            self, selector: #selector(indicatorSettingsChanged),
            name: .indicatorSettingsChanged, object: nil
        )

        _ = cpuSampler.sample()
        _ = netSampler.sample()
        tick()
        startTimer()

        LiveMetrics.shared.refreshHealth(force: true)
        updater.start()

        if CommandLine.arguments.contains("--dashboard") {
            dashboard.show(tab: 0)
        }
        // --dashboard-delay N: buka dashboard N detik setelah start, meniru membuka dashboard
        // belakangan setelah timer berjalan (dipakai smoke test CI)
        if let i = CommandLine.arguments.firstIndex(of: "--dashboard-delay"),
           i + 1 < CommandLine.arguments.count, let sec = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                self?.dashboard.show(tab: nil)
            }
        }
        // --popover: buka popover saat start (dipakai smoke test CI untuk tangkapan layar)
        if CommandLine.arguments.contains("--popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            // Klik per bagian (gaya glyph): posisi klik menentukan bagian popover yang disorot
            var focus: MetricKind?
            if prefs.style.isGlyph, prefs.glyph.clickRegions, let e = event {
                focus = region(at: sender.convert(e.locationInWindow, from: nil), in: sender)
            }
            togglePopover(focus: focus)
        }
    }

    /// Titik di tombol status → koordinat gambar (y ke bawah, gambar berada di tengah tombol) → bagian glyph
    private func region(at p: NSPoint, in view: NSView) -> MetricKind? {
        let b = view.bounds
        let ox = (b.width - barImageSize.width) / 2
        let oy = (b.height - barImageSize.height) / 2
        let pt = CGPoint(x: p.x - ox, y: (view.isFlipped ? p.y : b.height - p.y) - oy)
        return regions.first { $0.contains(pt) }?.kind
    }

    /// Tooltip per bagian: satu persegi tooltip per bagian glyph, teksnya diminta saat akan tampil
    /// supaya angkanya selalu terbaru.
    private func refreshToolTips() {
        guard let btn = statusItem.button else { return }
        btn.removeAllToolTips()
        guard prefs.style.isGlyph, prefs.glyph.tooltips, !regions.isEmpty else { return }
        let b = btn.bounds
        let ox = (b.width - barImageSize.width) / 2
        let oy = (b.height - barImageSize.height) / 2
        for r in regions {
            for rect in r.rects {
                let y = btn.isFlipped ? oy + rect.minY : b.height - (oy + rect.maxY)
                btn.addToolTip(NSRect(x: ox + rect.minX, y: y, width: rect.width, height: rect.height), owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let k = region(at: point, in: view) else { return "" }
        return GlyphRenderer.tooltip(k, metricValues())
    }

    private func metricValues() -> MetricValues {
        MetricValues(cpu: cpuPct, memPercent: mem.percent, memUsed: mem.used, memTotal: mem.total,
                     disk: disk, up: rate.up, down: rate.down, bat: bat)
    }

    private func togglePopover(focus: MetricKind? = nil) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        LiveMetrics.shared.focus = focus
        tick()
        pushLive()
        LiveMetrics.shared.refreshHealth()
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Lepas menu lagi agar klik kiri berikutnya kembali membuka popover
        if menu === self.menu {
            statusItem.menu = nil
            menuIsOpen = false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let sec = prefs.interval
        let t = Timer(timeInterval: sec, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = sec * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        cpuPct = cpuSampler.sample()
        mem = sampleMemory()
        rate = netSampler.sample()
        // disk & baterai jarang berubah → diambil lebih jarang (sampleDisk memanggil CacheDelete, cukup mahal)
        if tickCount % 15 == 0 { disk = sampleDisk() }
        if tickCount % 5 == 0 { bat = sampleBattery() }
        tickCount += 1
        updateBar()
        // Baris menu klik kanan hanya diperbarui saat menunya terbuka (menuWillOpen juga memanggil tick)
        if menuIsOpen { updateRows() }
        // Metrik live untuk SwiftUI hanya dikirim saat popover atau dashboard terlihat;
        // dulu dikirim dua kali per tick (LiveMetrics + updateLiveBanner) walau semua jendela tertutup.
        let popoverVisible = popoverLoaded && popover.isShown
        let dashboardVisible = dashboardLoaded && dashboard.isOnScreen
        if popoverVisible || dashboardVisible {
            pushLive()
        }
    }

    /// Kirim metrik terakhir ke LiveMetrics (popover, sidebar dashboard, tab Pengaturan Indikator)
    private func pushLive() {
        LiveMetrics.shared.update(cpu: cpuPct, memUsed: mem.used, memTotal: mem.total, disk: disk, netUp: rate.up, netDown: rate.down, bat: bat)
    }

    private func renderIcon() -> NSImage {
        let img = NSImage(systemSymbolName: "sparkles.rectangle.stack.fill", accessibilityDescription: "MoleApp")
            ?? NSImage(systemSymbolName: "cpu", accessibilityDescription: "MoleApp")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        img.isTemplate = true
        return img
    }

    private func updateBar() {
        guard let btn = statusItem.button else { return }

        // Isi kolom kini dibangun IndicatorLayout (dipakai juga oleh pratinjau di tab Pengaturan Indikator)
        // Gaya glyph dengan warna peringatan bukan template, jadi tinta mengikuti tampilan menu bar
        let dark = btn.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let layout = IndicatorLayout(prefs, metricValues(), dark: dark)
        // Angka sama dengan tick sebelumnya → tidak perlu menggambar ulang NSImage
        // (render teks + SF Symbol adalah pekerjaan termahal tiap tick)
        guard layout.key != lastBarKey else { return }
        lastBarKey = layout.key

        // Tampilan indikator disamakan dengan LiteMonitor: gambar kolom tanpa ikon aplikasi
        btn.title = ""
        btn.imagePosition = .imageOnly

        let oldRegions = regions, oldSize = barImageSize
        if let r = layout.render() {
            btn.image = r.image
            regions = r.regions
            barImageSize = r.image.size
        } else {
            // semua metrik dimatikan → tampilkan ikon kecil saja supaya popover/menu tetap bisa dibuka
            btn.image = renderIcon()
            regions = []
            barImageSize = .zero
        }
        if prefs.style.isGlyph {
            btn.setAccessibilityLabel(GlyphRenderer.accessibilitySummary(GlyphRenderer.visibleKinds(prefs, metricValues()), metricValues()))
        } else {
            btn.setAccessibilityLabel("MoleApp")
        }
        // Persegi tooltip dipasang ulang setelah tombol menyesuaikan lebar gambar baru
        if regions != oldRegions || barImageSize != oldSize {
            DispatchQueue.main.async { [weak self] in self?.refreshToolTips() }
        }
    }

    private func buildMenu() {
        let header = NSMenuItem(title: "MoleApp v\(MoleBridge.shared.version) — System Indicator & Cleaner", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for row in [cpuRow, memRow, diskRow, netRow, batRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())

        // Open Full Dashboard Window
        let openDash = NSMenuItem(title: "Buka MoleApp Dashboard…", action: #selector(openDashboardMain), keyEquivalent: "d")
        openDash.target = self
        menu.addItem(openDash)

        // Submenu: Fitur Cepat Mole CLI
        let moleMenu = NSMenu()
        let features: [(String, Int, String)] = [
            ("📊 Status & Health Monitor (`mo status`)", 0, "1"),
            ("✨ Deep Clean Cache (`mo clean`)", 1, "2"),
            ("🗑 Uninstall Aplikasi (`mo uninstall`)", 2, "3"),
            ("🥧 Disk Analyzer (`mo analyze`)", 3, "4"),
            ("⚡ Optimize System (`mo optimize`)", 4, "5"),
            ("📦 Project Artifact Purge (`mo purge`)", 5, "6"),
            ("💿 Installer Cleanup (`mo installer`)", 6, "7"),
            ("✂️ Slim Universal Apps (`mo slim`)", 7, "8"),
            ("🕓 Audit History & Tools (`mo history`)", 8, "9"),
            ("⚙️ Pengaturan", Feature.settings.rawValue, "0")
        ]
        for (label, tabIdx, key) in features {
            let item = NSMenuItem(title: label, action: #selector(openDashboardTab(_:)), keyEquivalent: key)
            item.target = self
            item.tag = tabIdx
            moleMenu.addItem(item)
        }
        moleMenu.addItem(.separator())
        let tuiItem = NSMenuItem(title: "🖥 Buka Menu Interaktif `mo` di Terminal…", action: #selector(openInteractiveCLI), keyEquivalent: "t")
        tuiItem.target = self
        moleMenu.addItem(tuiItem)

        let moleSubItem = NSMenuItem(title: "Fitur Mole CLI", action: nil, keyEquivalent: "")
        moleSubItem.submenu = moleMenu
        menu.addItem(moleSubItem)

        menu.addItem(.separator())

        // Semua pengaturan (indikator, glyph, interaksi, buka saat login) ada di satu halaman
        // Pengaturan di dashboard, supaya tidak ada dua tempat yang bisa membingungkan
        let settingsItem = NSMenuItem(title: "Pengaturan…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        menu.addItem(updater.menuItem)
        let un = NSMenuItem(title: "Uninstall MoleApp…", action: #selector(uninstallSelf), keyEquivalent: "")
        un.target = self
        menu.addItem(un)
        menu.addItem(NSMenuItem(title: "Keluar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func updateRows() {
        cpuRow.title = String(format: "CPU: %.1f%%", cpuPct)
        memRow.title = String(format: "Memori: %@ dari %@ (%.0f%%)", formatBytes(Int64(mem.used)), formatBytes(Int64(mem.total)), mem.percent)
        diskRow.title = String(format: "%@: %@ terpakai — sisa %@", disk.name, formatBytes(disk.used), formatBytes(disk.free))
        netRow.title = "Jaringan: ↑ \(formatNetRate(rate.up))   ↓ \(formatNetRate(rate.down))"
        if let b = bat {
            let st = b.charged ? "Terisi penuh" : b.charging ? "Mengisi daya" : b.onAC ? "Terhubung AC" : "Pakai baterai"
            batRow.title = "Baterai: \(b.percent)% — \(st)"
            batRow.isHidden = false
        } else {
            batRow.isHidden = true
        }
    }

    /// Menu bar aplikasi saat dashboard terbuka (activation policy .regular). ⌘Q hanya menutup jendela
    /// dashboard supaya indikator menu bar tetap jalan; keluar sepenuhnya memakai ⌥⌘Q.
    /// Saat dashboard tertutup aplikasi kembali .accessory, jadi menu ini tidak terlihat.
    private func buildMainMenu() {
        let main = NSMenu()

        // Menu aplikasi
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Tentang MoleApp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Pengaturan…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Sembunyikan MoleApp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Sembunyikan Lainnya", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Tampilkan Semua", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let closeDash = NSMenuItem(title: "Tutup Dashboard", action: #selector(closeDashboard), keyEquivalent: "q")
        closeDash.target = self
        appMenu.addItem(closeDash)
        let quitAll = NSMenuItem(title: "Keluar dari MoleApp (indikator juga)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitAll.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(quitAll)
        let appItem = NSMenuItem(title: "MoleApp", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Menu Edit: supaya ⌘C/⌘V/⌘A/⌘Z berfungsi di kolom teks dashboard (pencarian, whitelist)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Urungkan", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Ulangi", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Potong", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Salin", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Tempel", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Pilih Semua", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        // Menu Fitur: lompat ke halaman dashboard (⌘1…⌘9, ⌘0 = Pengaturan seperti menu klik kanan)
        let featureMenu = NSMenu(title: "Fitur")
        for f in Feature.allCases {
            let key = f == .settings ? "0" : (f.rawValue < 9 ? String(f.rawValue + 1) : "")
            let item = NSMenuItem(title: f.title, action: #selector(openDashboardTab(_:)), keyEquivalent: key)
            item.target = self
            item.tag = f.rawValue
            featureMenu.addItem(item)
        }
        featureMenu.addItem(.separator())
        let tui = NSMenuItem(title: "Menu Interaktif mo di Terminal…", action: #selector(openInteractiveCLI), keyEquivalent: "t")
        tui.target = self
        featureMenu.addItem(tui)
        let featureItem = NSMenuItem(title: "Fitur", action: nil, keyEquivalent: "")
        featureItem.submenu = featureMenu
        main.addItem(featureItem)

        // Menu Jendela
        let win = NSMenu(title: "Jendela")
        win.addItem(NSMenuItem(title: "Minimalkan", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        win.addItem(NSMenuItem(title: "Perbesar", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        win.addItem(NSMenuItem(title: "Tutup Jendela", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let winItem = NSMenuItem(title: "Jendela", action: nil, keyEquivalent: "")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// ⌘Q di menu aplikasi: tutup jendela dashboard saja (windowWillClose mengembalikan ke .accessory)
    @objc private func closeDashboard() {
        guard dashboardLoaded else { return }
        dashboard.window.performClose(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { menuIsOpen = true }
        tick()
    }

    // MARK: - Menu Actions

    @objc private func openDashboardMain() {
        dashboard.show(tab: nil)
        dashboard.updateLiveBanner(
            cpu: cpuPct,
            memUsed: mem.used,
            memTotal: mem.total,
            disk: disk,
            netUp: rate.up,
            netDown: rate.down,
            bat: bat
        )
    }

    @objc private func openDashboardTab(_ sender: NSMenuItem) {
        dashboard.show(tab: sender.tag)
        dashboard.updateLiveBanner(
            cpu: cpuPct,
            memUsed: mem.used,
            memTotal: mem.total,
            disk: disk,
            netUp: rate.up,
            netDown: rate.down,
            bat: bat
        )
    }

    @objc func openInteractiveCLI() {
        MoleBridge.shared.openInTerminal("")
    }

    @objc private func openSettings() {
        dashboard.show(tab: Feature.settings.rawValue)
    }

    /// Halaman Pengaturan mengubah UserDefaults → baca ulang pengaturan, gambar ulang, dan sesuaikan interval timer
    @objc private func indicatorSettingsChanged() {
        prefs = IndicatorPrefs.load(defaults)
        lastBarKey = nil
        updateBar()
        refreshToolTips()
        if timer?.timeInterval != prefs.interval { startTimer() }
    }

    /// Juga dipanggil tab Aplikasi di halaman Pengaturan
    @objc func uninstallSelf() {
        let a = NSAlert()
        a.messageText = "Uninstall MoleApp?"
        a.informativeText = "MoleApp akan dihapus dari 'Buka saat login', pengaturannya dihapus, lalu MoleApp.app dipindahkan ke Tong Sampah."
        a.alertStyle = .warning
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Batal")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        timer?.invalidate()
        try? SMAppService.mainApp.unregister()
        if let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
            defaults.synchronize()
        }
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension == "app" {
            try? FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
        }
        NSApp.terminate(nil)
    }
}

// MARK: - 7. Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
