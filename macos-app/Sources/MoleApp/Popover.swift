// MoleApp — Popover menu bar (klik kiri ikon indikator).
// Ringkasan kesehatan + meter live + akses cepat ke fitur Mole CLI.
// Klik kanan ikon tetap membuka menu lengkap (pengaturan indikator, login, update).

import AppKit
import SwiftUI

struct PopoverActions {
    let openTab: (Int?) -> Void
    let openTerminal: () -> Void
    let openMenu: () -> Void
    /// Ikon cog: membuka halaman Pengaturan di dashboard (satu-satunya tempat pengaturan)
    let openSettings: () -> Void
    let checkUpdate: () -> Void
    let quit: () -> Void
}

/// Pengaturan isi popover (1.10.0). Kunci UserDefaults dibaca @AppStorage di popover dan di tab
/// Pengaturan > Popover, jadi keduanya selalu sinkron tanpa notifikasi tambahan.
enum PopoverPrefs {
    static let showHealth = "popShowHealth"
    static let showCPU = "popShowCPU"
    static let showMem = "popShowMem"
    static let showDisk = "popShowDisk"
    static let showNetBat = "popShowNetBat"
    static let showTopCPU = "popShowTopCPU"
    static let topCPUCount = "popTopCPUCount"
    static let showTopMem = "popShowTopMem"
    static let topMemCount = "popTopMemCount"
    static let showQuick = "popShowQuick"
    static let quickItems = "popQuickItems"
    static let quickIconsOnly = "popQuickIconsOnly"

    /// Batas jumlah baris daftar proses
    static let countRange = 1...10
    /// Fitur yang bisa dijadikan tombol akses cepat (Pengaturan sudah ada di ikon cog)
    static let quickCandidates: [Feature] = Feature.allCases.filter { $0 != .settings }
    /// Susunan bawaan sama dengan sebelum 1.10.0
    static let defaultQuick: [Feature] = [.clean, .uninstall, .analyze, .optimize, .purge, .status]
    static let defaultQuickRaw = encodeQuick(defaultQuick)

    static let registeredDefaults: [String: Any] = [
        showHealth: true,
        showCPU: true,
        showMem: true,
        showDisk: true,
        showNetBat: true,
        showTopCPU: true,
        topCPUCount: 3,
        showTopMem: true,
        topMemCount: 3,
        showQuick: true,
        quickItems: defaultQuickRaw,
        quickIconsOnly: false
    ]

    static func encodeQuick(_ items: [Feature]) -> String {
        items.map { String($0.rawValue) }.joined(separator: ",")
    }

    /// Urutan tombol yang aktif; nilai tak dikenal atau ganda dibuang
    static func decodeQuick(_ raw: String) -> [Feature] {
        var out: [Feature] = []
        for part in raw.split(separator: ",") {
            guard let n = Int(part.trimmingCharacters(in: .whitespaces)),
                  let f = Feature(rawValue: n),
                  f != .settings, !out.contains(f) else { continue }
            out.append(f)
        }
        return out
    }

    static func clampCount(_ n: Int) -> Int {
        min(max(n, countRange.lowerBound), countRange.upperBound)
    }

    static func resetDefaults(_ d: UserDefaults = .standard) {
        for k in registeredDefaults.keys { d.removeObject(forKey: k) }
    }
}

/// Daftar proses terberat yang ringkas untuk popover. Jumlah baris selalu `count` (baris kosong
/// diisi tanda pisah) supaya tinggi popover tidak melompat saat data pertama datang.
struct ProcessMiniList: View {
    let title: String
    let symbol: String
    let rows: [TopProcess]
    let count: Int
    let value: (TopProcess) -> String
    let amount: (TopProcess) -> Double
    let tint: (TopProcess) -> Color

    var body: some View {
        let shown = Array(rows.prefix(count))
        let top = max(0.0001, shown.map(amount).max() ?? 1)
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(0..<count, id: \.self) { i in
                if i < shown.count {
                    let p = shown[i]
                    row(name: p.name, value: value(p), fraction: amount(p) / top, tint: tint(p))
                        .help("\(p.name) (PID \(p.id))")
                } else {
                    row(name: "—", value: "", fraction: 0, tint: .clear)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func row(name: String, value: String, fraction: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(fraction > 0 ? 2 : 0, 56 * CGFloat(min(1, fraction))))
            }
            .frame(width: 56, height: 5)
            Text(value)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(.caption, design: .rounded))
    }
}

struct QuickTile: View {
    let feature: Feature
    /// Mode ringkas (1.10.0): hanya ikon, judul pindah ke tooltip
    var iconsOnly = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.nose)
                if !iconsOnly {
                    Text(feature.title)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity, minHeight: iconsOnly ? 34 : 54)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.09 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(iconsOnly ? "\(feature.title): \(feature.summary)" : feature.summary)
    }
}

struct PopoverView: View {
    @ObservedObject var live = LiveMetrics.shared
    let actions: PopoverActions

    /// Init eksplisit: properti @AppStorage private membuat memberwise init tidak terlihat dari main.swift
    init(actions: PopoverActions) {
        self.actions = actions
    }

    // Isi popover bisa diatur di Pengaturan > Popover (1.10.0)
    @AppStorage(PopoverPrefs.showHealth) private var showHealth = true
    @AppStorage(PopoverPrefs.showCPU) private var showCPU = true
    @AppStorage(PopoverPrefs.showMem) private var showMem = true
    @AppStorage(PopoverPrefs.showDisk) private var showDisk = true
    @AppStorage(PopoverPrefs.showNetBat) private var showNetBat = true
    @AppStorage(PopoverPrefs.showTopCPU) private var showTopCPU = true
    @AppStorage(PopoverPrefs.topCPUCount) private var topCPUCount = 3
    @AppStorage(PopoverPrefs.showTopMem) private var showTopMem = true
    @AppStorage(PopoverPrefs.topMemCount) private var topMemCount = 3
    @AppStorage(PopoverPrefs.showQuick) private var showQuick = true
    @AppStorage(PopoverPrefs.quickItems) private var quickRaw = PopoverPrefs.defaultQuickRaw
    @AppStorage(PopoverPrefs.quickIconsOnly) private var quickIconsOnly = false

    private var quick: [Feature] { PopoverPrefs.decodeQuick(quickRaw) }
    private var hasMeters: Bool { showCPU || showMem || showDisk || showNetBat }
    private var hasProcs: Bool { showTopCPU || showTopMem }
    private var hasQuick: Bool { showQuick && !quick.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showHealth {
                header
            }

            if hasMeters {
                meters
            }

            if hasProcs {
                if showHealth || hasMeters { Divider() }
                processes
            }

            if hasQuick {
                if showHealth || hasMeters || hasProcs { Divider() }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: quickIconsOnly ? 6 : 3), spacing: 8) {
                    ForEach(quick) { f in
                        QuickTile(feature: f, iconsOnly: quickIconsOnly) { actions.openTab(f.rawValue) }
                    }
                }
            }

            if showHealth || hasMeters || hasProcs || hasQuick {
                Divider()
            }

            if let v = live.updateVersion {
                Button(action: actions.checkUpdate) {
                    Label("Update tersedia: \(v)", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.nose)
                .help("Unduh dan pasang versi baru MoleApp")
            }

            HStack(spacing: 12) {
                Button("Buka dashboard") { actions.openTab(nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.nose)
                Spacer()
                Button(action: actions.openTerminal) { Image(systemName: "terminal") }
                    .buttonStyle(.borderless)
                    .help("Menu interaktif mo di Terminal")
                Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Buka Pengaturan di dashboard")
                Button(action: actions.quit) { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Keluar dari MoleApp")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HealthRing(score: live.health, size: 62, line: 7, caption: false)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mole").font(.rounded(17, .bold))
                Text(healthLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                live.refreshHealth(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(live.healthLoading)
            .help("Hitung ulang skor kesehatan")
        }
    }

    private var meters: some View {
        VStack(spacing: 5) {
            if showCPU {
                Meter(label: "CPU", value: String(format: "%.0f%%", live.cpu), fraction: live.cpu / 100, tint: Palette.level(live.cpu))
                    .metricFocus(live.focus == .cpu)
            }
            if showMem {
                Meter(
                    label: "Memori",
                    value: "\(formatBytes(Int64(live.memUsed))) / \(formatBytes(Int64(live.memTotal)))",
                    fraction: live.memPercent / 100,
                    tint: Palette.level(live.memPercent)
                )
                .metricFocus(live.focus == .mem)
            }
            if showDisk {
                Meter(
                    label: live.disk.name,
                    value: "\(formatBytes(live.disk.free)) sisa",
                    fraction: live.disk.percent / 100,
                    tint: Palette.diskLevel(live.disk.percent)
                )
                .metricFocus(live.focus == .disk)
            }
            if showNetBat {
                HStack {
                    HStack {
                        Label(formatNetRate(live.netDown), systemImage: "arrow.down")
                        Spacer()
                        Label(formatNetRate(live.netUp), systemImage: "arrow.up")
                    }
                    .metricFocus(live.focus == .net)
                    if let b = live.battery {
                        Spacer()
                        Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                            .metricFocus(live.focus == .bat)
                    }
                }
                .font(.system(.caption, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Proses terberat dibaca dari ps oleh LiveMetrics.refreshProcesses() selama popover terbuka
    private var processes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showTopCPU {
                ProcessMiniList(
                    title: "Proses terberat · CPU",
                    symbol: "cpu",
                    rows: live.topCPU,
                    count: PopoverPrefs.clampCount(topCPUCount),
                    value: { String(format: "%.1f%%", $0.cpu) },
                    amount: { $0.cpu },
                    tint: { Palette.level($0.cpu) }
                )
            }
            if showTopMem {
                ProcessMiniList(
                    title: "Proses terberat · RAM",
                    symbol: "memorychip",
                    rows: live.topMem,
                    count: PopoverPrefs.clampCount(topMemCount),
                    value: { formatBytes($0.rssBytes) },
                    amount: { Double($0.rssBytes) },
                    tint: { Palette.level($0.memPercent, warn: 10, crit: 20) }
                )
            }
        }
    }

    private var healthLine: String {
        if live.healthLoading && live.health == nil { return "Membaca kesehatan Mac…" }
        if !live.healthMsg.isEmpty { return live.healthMsg }
        return live.health == nil ? "Skor kesehatan belum tersedia." : "Skor kesehatan dari mo status."
    }
}

// MARK: - Pengaturan > Popover (1.10.0)
// Dipasang di dalam Form tab Popover di halaman Pengaturan. Memakai kunci @AppStorage yang sama dengan
// PopoverView, jadi popover yang sedang terbuka langsung ikut berubah.

struct PopoverSettingsSections: View {
    @AppStorage(PopoverPrefs.showHealth) private var showHealth = true
    @AppStorage(PopoverPrefs.showCPU) private var showCPU = true
    @AppStorage(PopoverPrefs.showMem) private var showMem = true
    @AppStorage(PopoverPrefs.showDisk) private var showDisk = true
    @AppStorage(PopoverPrefs.showNetBat) private var showNetBat = true
    @AppStorage(PopoverPrefs.showTopCPU) private var showTopCPU = true
    @AppStorage(PopoverPrefs.topCPUCount) private var topCPUCount = 3
    @AppStorage(PopoverPrefs.showTopMem) private var showTopMem = true
    @AppStorage(PopoverPrefs.topMemCount) private var topMemCount = 3
    @AppStorage(PopoverPrefs.showQuick) private var showQuick = true
    @AppStorage(PopoverPrefs.quickItems) private var quickRaw = PopoverPrefs.defaultQuickRaw
    @AppStorage(PopoverPrefs.quickIconsOnly) private var quickIconsOnly = false

    private var quick: [Feature] { PopoverPrefs.decodeQuick(quickRaw) }
    /// Tombol aktif sesuai urutannya, lalu sisanya (nonaktif) dalam urutan sidebar
    private var quickRows: [Feature] { quick + PopoverPrefs.quickCandidates.filter { !quick.contains($0) } }

    init() {}

    var body: some View {
        Section {
            Toggle("Skor kesehatan", isOn: $showHealth)
            Toggle("CPU", isOn: $showCPU)
            Toggle("Memori", isOn: $showMem)
            Toggle("Disk", isOn: $showDisk)
            Toggle("Jaringan & baterai", isOn: $showNetBat)
        } header: {
            Text("Ringkasan")
        } footer: {
            note("Skor kesehatan dibaca dari mo status; bila disembunyikan, popover tidak menjalankannya sama sekali.")
        }

        Section {
            Toggle("Proses terberat menurut CPU", isOn: $showTopCPU)
            Stepper(value: countBinding($topCPUCount), in: PopoverPrefs.countRange) {
                Text("Jumlah baris CPU: \(PopoverPrefs.clampCount(topCPUCount))")
            }
            .disabled(!showTopCPU)
            Toggle("Proses terberat menurut RAM", isOn: $showTopMem)
            Stepper(value: countBinding($topMemCount), in: PopoverPrefs.countRange) {
                Text("Jumlah baris RAM: \(PopoverPrefs.clampCount(topMemCount))")
            }
            .disabled(!showTopMem)
        } header: {
            Text("Proses terberat")
        } footer: {
            note("Dibaca dari ps setiap interval update, hanya selama popover terbuka. Persen CPU per proses bisa di atas 100% untuk proses yang memakai banyak core. Daftar lengkap ada di halaman Kesehatan.")
        }

        Section {
            Toggle("Tampilkan tombol akses cepat", isOn: $showQuick)
            Picker("Gaya tombol", selection: $quickIconsOnly) {
                Text("Ikon + teks").tag(false)
                Text("Ikon saja").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!showQuick)
            ForEach(Array(quickRows.enumerated()), id: \.element) { i, f in
                quickRow(f, index: i)
            }
            .disabled(!showQuick)
        } header: {
            Text("Akses cepat")
        } footer: {
            note("Ikon + teks = 3 kolom, ikon saja = 6 kolom (judul tampil sebagai tooltip). Panah mengatur urutan tombol yang aktif.")
        }
    }

    private func note(_ t: String) -> some View {
        Text(t)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Nilai lama di luar rentang (mis. diubah lewat defaults write) dijepit ke 1...10
    private func countBinding(_ b: Binding<Int>) -> Binding<Int> {
        Binding(get: { PopoverPrefs.clampCount(b.wrappedValue) }, set: { b.wrappedValue = PopoverPrefs.clampCount($0) })
    }

    private func quickRow(_ f: Feature, index: Int) -> some View {
        let on = quick.contains(f)
        return HStack(spacing: 6) {
            Label(f.title, systemImage: f.symbol)
            Spacer()
            Button { moveQuick(f, -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!on || index == 0)
                .help("Pindah lebih awal")
            Button { moveQuick(f, 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(!on || index >= quick.count - 1)
                .help("Pindah lebih akhir")
            Toggle("", isOn: Binding(get: { on }, set: { setQuick(f, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func setQuick(_ f: Feature, _ on: Bool) {
        var q = quick
        if on {
            if !q.contains(f) { q.append(f) }
        } else {
            q.removeAll { $0 == f }
        }
        quickRaw = PopoverPrefs.encodeQuick(q)
    }

    private func moveQuick(_ f: Feature, _ d: Int) {
        var q = quick
        guard let i = q.firstIndex(of: f), q.indices.contains(i + d) else { return }
        q.swapAt(i, i + d)
        quickRaw = PopoverPrefs.encodeQuick(q)
    }
}

extension View {
    /// Sorotan bagian popover yang dibuka lewat klik per bagian di glyph menu bar.
    /// Padding selalu dipasang supaya tata letak tidak bergeser saat sorotan berpindah.
    func metricFocus(_ on: Bool) -> some View {
        padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.nose.opacity(on ? 0.14 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Palette.nose.opacity(on ? 0.55 : 0), lineWidth: 1)
            )
    }
}
