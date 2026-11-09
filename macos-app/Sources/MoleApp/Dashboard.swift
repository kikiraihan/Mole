// MoleApp — Dashboard SwiftUI (jendela utama) untuk seluruh fitur Mole CLI.
// Tema visual "liang tikus tanah": aksen merah muda hidung mole, hijau lumut untuk kondisi sehat,
// amber untuk waspada, merah bara untuk kritis. Angka & judul memakai SF Rounded.
// Semua aksi destruktif tetap lewat Mole CLI: pratinjau (--dry-run) di aplikasi,
// eksekusi yang butuh sudo atau pilihan interaktif dibuka di Terminal.

import AppKit
import SwiftUI

// MARK: - Palet & Tipografi

enum Palette {
    static let nose = Color(red: 0.851, green: 0.400, blue: 0.541)  // #D9668A aksen utama
    static let moss = Color(red: 0.431, green: 0.624, blue: 0.420)  // #6E9F6B sehat
    static let amber = Color(red: 0.878, green: 0.643, blue: 0.227) // #E0A43A waspada
    static let ember = Color(red: 0.851, green: 0.325, blue: 0.310) // #D9534F kritis
    static let loam = Color(red: 0.361, green: 0.290, blue: 0.239)  // #5C4A3D tanah

    static func level(_ pct: Double, warn: Double = 65, crit: Double = 85) -> Color {
        pct >= crit ? ember : (pct >= warn ? amber : moss)
    }

    /// Disk wajar terisi 70%; peringatan baru muncul saat ruang mulai sempit.
    static func diskLevel(_ pct: Double) -> Color {
        level(pct, warn: 80, crit: 90)
    }

    static func health(_ score: Int) -> Color {
        score >= 75 ? moss : (score >= 50 ? amber : ember)
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - JSON Helpers (parsing longgar agar perubahan skema CLI tidak membuat app crash)

func jStr(_ o: Any?, _ k: String) -> String {
    let v = (o as? [String: Any])?[k]
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func jNum(_ o: Any?, _ k: String) -> Double {
    let v = (o as? [String: Any])?[k]
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) ?? 0 }
    return 0
}

func jBool(_ o: Any?, _ k: String) -> Bool {
    ((o as? [String: Any])?[k] as? NSNumber)?.boolValue ?? false
}

func jObj(_ o: Any?, _ k: String) -> [String: Any] {
    ((o as? [String: Any])?[k] as? [String: Any]) ?? [:]
}

func jArr(_ o: Any?, _ k: String) -> [[String: Any]] {
    ((o as? [String: Any])?[k] as? [[String: Any]]) ?? []
}

func confirmAlert(_ title: String, _ info: String, _ ok: String) -> Bool {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = info
    a.alertStyle = .warning
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Batal")
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal() == .alertFirstButtonReturn
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

// MARK: - Live Metrics (dibagi antara indikator menu bar, popover, dan dashboard)

final class LiveMetrics: ObservableObject {
    static let shared = LiveMetrics()

    @Published var cpu: Double = 0
    @Published var memUsed: UInt64 = 0
    @Published var memTotal: UInt64 = 1
    @Published var disk = DiskSnapshot(name: "Macintosh HD", used: 0, free: 0, total: 1)
    @Published var netUp: Double = 0
    @Published var netDown: Double = 0
    @Published var battery: BatterySnapshot?
    @Published var health: Int?
    @Published var healthMsg: String = ""
    @Published var healthLoading = false
    /// Diisi Updater saat ada rilis MoleApp yang lebih baru (ditampilkan di popover)
    @Published var updateVersion: String?

    private var lastHealthAt: Date?

    var memPercent: Double {
        memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100.0 : 0
    }

    func update(cpu: Double, memUsed: UInt64, memTotal: UInt64, disk: DiskSnapshot, netUp: Double, netDown: Double, bat: BatterySnapshot?) {
        self.cpu = cpu
        self.memUsed = memUsed
        self.memTotal = memTotal
        self.disk = disk
        self.netUp = netUp
        self.netDown = netDown
        self.battery = bat
    }

    func applyStatus(_ d: [String: Any]) {
        if d["health_score"] != nil {
            health = Int(jNum(d, "health_score"))
        }
        healthMsg = jStr(d, "health_score_msg")
        lastHealthAt = Date()
    }

    /// Membaca skor kesehatan dari `mo status --json`; dibatasi sekali per menit kecuali dipaksa.
    func refreshHealth(force: Bool = false) {
        if healthLoading { return }
        if !force, let t = lastHealthAt, Date().timeIntervalSince(t) < 60 { return }
        healthLoading = true
        MoleBridge.shared.runJSON(["status", "--json"]) { [weak self] json, _ in
            guard let self else { return }
            self.healthLoading = false
            if let d = json as? [String: Any] { self.applyStatus(d) }
        }
    }
}

// MARK: - Fitur (indeks sama dengan tab lama agar menu bar tetap cocok)

enum Feature: Int, CaseIterable, Identifiable, Hashable {
    case status = 0, clean, uninstall, analyze, optimize, purge, installer, slim, history

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .status: return "Kesehatan"
        case .clean: return "Bersihkan"
        case .uninstall: return "Uninstall"
        case .analyze: return "Analisis Disk"
        case .optimize: return "Optimasi"
        case .purge: return "Purge Proyek"
        case .installer: return "Installer"
        case .slim: return "Slim Apps"
        case .history: return "Riwayat & Alat"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "heart.text.square"
        case .clean: return "sparkles"
        case .uninstall: return "trash"
        case .analyze: return "chart.pie"
        case .optimize: return "bolt.horizontal"
        case .purge: return "shippingbox"
        case .installer: return "externaldrive"
        case .slim: return "scissors"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var summary: String {
        switch self {
        case .status: return "Skor kesehatan, perangkat keras, suhu, baterai, dan proses terberat dari mo status."
        case .clean: return "Cache aplikasi, browser, alat developer, dan log yang aman dibuat ulang."
        case .uninstall: return "Hapus aplikasi beserta sisa file yang terbukti miliknya, dipindah ke Trash."
        case .analyze: return "Lihat folder dan file yang paling banyak memakan ruang."
        case .optimize: return "Perbaiki preferensi rusak, Spotlight, dan layanan macOS dengan tugas terbatas."
        case .purge: return "Artefak build lama: node_modules, target, build, dist, .next, venv, Pods."
        case .installer: return "File .dmg, .pkg, .iso, .xip, dan .zip yang tertinggal setelah instalasi."
        case .slim: return "Buang irisan Intel dari Universal App milik Anda di Apple Silicon."
        case .history: return "Apa saja yang sudah diubah Mole, plus pengaturan Touch ID, whitelist, dan completion."
        }
    }
}

struct FeatureGroup: Identifiable {
    let id: String
    let items: [Feature]

    static let all: [FeatureGroup] = [
        FeatureGroup(id: "Pantau", items: [.status, .analyze, .history]),
        FeatureGroup(id: "Kosongkan ruang", items: [.clean, .purge, .installer, .slim]),
        FeatureGroup(id: "Aplikasi & sistem", items: [.uninstall, .optimize])
    ]
}

// MARK: - Command Runner (output streaming per fitur, tetap ada saat pindah tab)

final class CommandRunner: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var lastExit: Int32?
    @Published var lastCommand = ""
    private var proc: Process?

    func run(_ args: [String]) {
        guard !running else { return }
        running = true
        lastExit = nil
        output = ""
        lastCommand = "mo " + args.joined(separator: " ")
        proc = MoleBridge.shared.stream(args, onOutput: { [weak self] chunk in
            self?.append(chunk)
        }, completion: { [weak self] code in
            guard let self else { return }
            self.running = false
            self.lastExit = code
            self.proc = nil
        })
    }

    func show(_ text: String, title: String) {
        guard !running else { return }
        lastCommand = title
        lastExit = nil
        output = text
    }

    func stop() {
        proc?.terminate()
    }

    private func append(_ chunk: String) {
        output += chunk
        if output.utf8.count > 400_000 {
            output = String(output.suffix(300_000))
        }
    }
}

// MARK: - Store untuk hasil yang mahal (tidak dipindai ulang setiap pindah tab)

struct AppEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let bundleID: String
    let source: String
    let uninstallName: String
    let path: String
    let size: String
}

final class UninstallStore: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var error = ""
    var loaded = false

    func load() {
        guard !loading else { return }
        loading = true
        error = ""
        MoleBridge.shared.runJSON(["uninstall", "--list"]) { [weak self] json, err in
            guard let self else { return }
            self.loading = false
            self.loaded = true
            guard let list = json as? [[String: Any]] else {
                self.error = err.isEmpty ? "Daftar aplikasi tidak bisa dibaca dari mo uninstall --list." : err
                return
            }
            self.apps = list.map {
                AppEntry(
                    name: jStr($0, "name"),
                    bundleID: jStr($0, "bundle_id"),
                    source: jStr($0, "source"),
                    uninstallName: jStr($0, "uninstall_name"),
                    path: jStr($0, "path"),
                    size: jStr($0, "size")
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

struct AnalyzeEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let size: Int64
    let isDir: Bool
    let cleanable: Bool
    let insight: Bool
}

final class AnalyzeStore: ObservableObject {
    @Published var path = NSHomeDirectory()
    @Published var entries: [AnalyzeEntry] = []
    @Published var largeFiles: [AnalyzeEntry] = []
    @Published var total: Int64 = 0
    @Published var partial = false
    @Published var loading = false
    @Published var error = ""
    @Published var back: [String] = []
    var scannedPath = ""

    func scan(_ target: String?, pushHistory: Bool = true) {
        guard !loading else { return }
        let trimmed = (target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pushHistory, !scannedPath.isEmpty, scannedPath != trimmed { back.append(scannedPath) }
        loading = true
        error = ""
        var args = ["analyze", "--json"]
        if !trimmed.isEmpty { args.append(trimmed) }
        if !trimmed.isEmpty { path = trimmed }
        MoleBridge.shared.runJSON(args) { [weak self] json, err in
            guard let self else { return }
            self.loading = false
            guard let d = json as? [String: Any] else {
                self.error = err.isEmpty ? "Hasil mo analyze --json tidak bisa dibaca." : err
                return
            }
            self.scannedPath = trimmed.isEmpty ? jStr(d, "path") : trimmed
            if trimmed.isEmpty { self.path = jStr(d, "path") }
            self.total = Int64(jNum(d, "total_size"))
            self.partial = jStr(d, "scan_status") == "partial"
            self.entries = jArr(d, "entries").map {
                AnalyzeEntry(
                    name: jStr($0, "name"), path: jStr($0, "path"), size: Int64(jNum($0, "size")),
                    isDir: jBool($0, "is_dir"), cleanable: jBool($0, "cleanable"), insight: jBool($0, "insight")
                )
            }
            .sorted { $0.size > $1.size }
            self.largeFiles = jArr(d, "large_files").map {
                AnalyzeEntry(
                    name: jStr($0, "name"), path: jStr($0, "path"), size: Int64(jNum($0, "size")),
                    isDir: false, cleanable: false, insight: false
                )
            }
        }
    }

    func goBack() {
        guard let prev = back.popLast() else { return }
        scan(prev, pushHistory: false)
    }
}

final class DashboardModel: ObservableObject {
    @Published var selection: Feature? = .status
    let uninstall = UninstallStore()
    let analyze = AnalyzeStore()
    private var runners: [Feature: CommandRunner] = [:]

    func runner(_ f: Feature) -> CommandRunner {
        if let r = runners[f] { return r }
        let r = CommandRunner()
        runners[f] = r
        return r
    }
}

// MARK: - Komponen UI

struct HealthRing: View {
    let score: Int?
    var size: CGFloat = 120
    var line: CGFloat = 12
    var caption = true

    var body: some View {
        let s = score ?? 0
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle()
                .trim(from: 0, to: CGFloat(min(100, max(0, s))) / 100.0)
                .stroke(Palette.health(s), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: s)
            VStack(spacing: 0) {
                Text(score.map { String($0) } ?? "–")
                    .font(.rounded(size * 0.34, .bold))
                    .monospacedDigit()
                if caption {
                    Text("dari 100")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Skor kesehatan \(score.map { String($0) } ?? "belum ada")")
    }
}

struct Meter: View {
    let label: String
    let value: String
    let fraction: Double
    var tint: Color = Palette.moss

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, g.size.width * CGFloat(min(1, max(0, fraction)))))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Panel<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        )
    }
}

struct PageHeader<Actions: View>: View {
    let feature: Feature
    let actions: Actions

    init(_ feature: Feature, @ViewBuilder actions: () -> Actions) {
        self.feature = feature
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.nose))
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(.rounded(22, .bold))
                    Text(feature.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) { actions }
        }
    }
}

struct ExitBadge: View {
    let code: Int32

    var body: some View {
        let ok = code == 0
        Label(ok ? "Selesai" : "Keluar dengan kode \(code)", systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(ok ? Palette.moss : Palette.ember)
    }
}

struct Note: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ConsoleView: View {
    @ObservedObject var runner: CommandRunner
    var placeholder = "Belum ada output. Mulai dengan pratinjau."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if runner.running { ProgressView().controlSize(.small) }
                Text(runner.lastCommand.isEmpty ? "Konsol" : runner.lastCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let code = runner.lastExit { ExitBadge(code: code) }
                if runner.running {
                    Button("Hentikan") { runner.stop() }.controlSize(.small)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.output, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Salin output")
                .disabled(runner.output.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(runner.output.isEmpty ? placeholder : runner.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(runner.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Color.clear.frame(height: 1).id("console-bottom")
                    }
                }
                .onChange(of: runner.output) { _ in
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

struct SidebarLive: View {
    @ObservedObject var live = LiveMetrics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Meter(label: "CPU", value: String(format: "%.0f%%", live.cpu), fraction: live.cpu / 100, tint: Palette.level(live.cpu))
            Meter(label: "RAM", value: String(format: "%.0f%%", live.memPercent), fraction: live.memPercent / 100, tint: Palette.level(live.memPercent))
            Meter(label: "Disk", value: "\(formatBytes(live.disk.free)) sisa", fraction: live.disk.percent / 100, tint: Palette.diskLevel(live.disk.percent))
        }
        .padding(12)
    }
}

// MARK: - Root Dashboard

struct DashboardRoot: View {
    @ObservedObject var model: DashboardModel

    // Sidebar dibuat dengan HStack biasa, bukan NavigationSplitView: di macOS 26.3 dashboard
    // pernah tampil kosong (bingkai tergambar, isi tidak) meski SwiftUI tetap menghitung layout.
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(FeatureGroup.all) { group in
                    Section(group.id) {
                        ForEach(group.items) { f in
                            Label(f.title, systemImage: f.symbol).tag(f)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { SidebarLive() }
            .frame(width: 215)

            Divider()

            detail(for: model.selection ?? .status)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(Palette.nose)
        .frame(minWidth: 880, minHeight: 580)
    }

    @ViewBuilder
    private func detail(for f: Feature) -> some View {
        switch f {
        case .status:
            StatusView()
        case .uninstall:
            UninstallView(store: model.uninstall, runner: model.runner(.uninstall))
        case .analyze:
            AnalyzeView(store: model.analyze)
        case .history:
            HistoryView()
        default:
            CommandFeatureView(feature: f, spec: CommandSpec.make(f), runner: model.runner(f))
                .id(f)
        }
    }
}

// MARK: - Status

struct StatusView: View {
    @ObservedObject var live = LiveMetrics.shared
    @State private var data: [String: Any]?
    @State private var loading = false
    @State private var error = ""

    private func load() {
        loading = true
        error = ""
        MoleBridge.shared.runJSON(["status", "--json"]) { json, err in
            loading = false
            if let d = json as? [String: Any] {
                data = d
                live.applyStatus(d)
            } else {
                error = err.isEmpty ? "Output mo status --json tidak bisa dibaca." : err
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(.status) {
                    Button(action: load) {
                        Label("Segarkan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                    Button("Pantau langsung di Terminal") { MoleBridge.shared.openInTerminal("status") }
                    Button("Activity Monitor") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                }

                if let d = data {
                    hero(d)
                    panels(d)
                    processes(d)
                } else if loading {
                    ProgressView("Membaca kondisi Mac…").frame(maxWidth: .infinity, minHeight: 200)
                } else if !error.isEmpty {
                    Note(text: error, symbol: "exclamationmark.triangle", tint: Palette.ember)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .onAppear { if data == nil { load() } }
    }

    private func hero(_ d: [String: Any]) -> some View {
        let hw = jObj(d, "hardware")
        let score = d["health_score"] != nil ? Int(jNum(d, "health_score")) : nil
        return HStack(alignment: .center, spacing: 24) {
            HealthRing(score: score, size: 132, line: 13)
            VStack(alignment: .leading, spacing: 6) {
                Text(jStr(d, "health_score_msg").isEmpty ? "Skor kesehatan Mac" : jStr(d, "health_score_msg"))
                    .font(.rounded(20, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text([jStr(hw, "model"), jStr(hw, "cpu_model")].filter { !$0.isEmpty }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Text([jStr(hw, "os_version"), jStr(hw, "total_ram"), jStr(hw, "disk_size")].filter { !$0.isEmpty }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                if !jStr(d, "uptime").isEmpty {
                    Text("Menyala \(jStr(d, "uptime")), \(Int(jNum(d, "procs"))) proses")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func panels(_ d: [String: Any]) -> some View {
        let cpu = jObj(d, "cpu")
        let mem = jObj(d, "memory")
        let thermal = jObj(d, "thermal")
        let disks = jArr(d, "disks")
        let batteries = jArr(d, "batteries")
        let cpuUsage = jNum(cpu, "usage")
        let memPct = jNum(mem, "used_percent")
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            Panel("Prosesor", symbol: "cpu") {
                Meter(label: "Pemakaian", value: String(format: "%.0f%%", cpuUsage), fraction: cpuUsage / 100, tint: Palette.level(cpuUsage))
                Text(String(format: "Beban %.2f, %.2f, %.2f", jNum(cpu, "load1"), jNum(cpu, "load5"), jNum(cpu, "load15")))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(Int(jNum(cpu, "logical_cpu"))) inti logis")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Panel("Memori", symbol: "memorychip") {
                Meter(
                    label: "Terpakai",
                    value: "\(formatBytes(Int64(jNum(mem, "used")))) / \(formatBytes(Int64(jNum(mem, "total"))))",
                    fraction: memPct / 100,
                    tint: Palette.level(memPct)
                )
                Text("Tekanan: \(jStr(mem, "pressure").isEmpty ? "–" : jStr(mem, "pressure"))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Swap \(formatBytes(Int64(jNum(mem, "swap_used")))) dari \(formatBytes(Int64(jNum(mem, "swap_total"))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(disks.enumerated()), id: \.offset) { _, disk in
                let pct = jNum(disk, "used_percent")
                Panel(jBool(disk, "external") ? "Disk eksternal" : "Disk", symbol: "internaldrive") {
                    Meter(
                        label: jStr(disk, "mount"),
                        value: "\(formatBytes(Int64(jNum(disk, "used")))) / \(formatBytes(Int64(jNum(disk, "total"))))",
                        fraction: pct / 100,
                        tint: Palette.diskLevel(pct)
                    )
                    Text("Sisa \(formatBytes(Int64(jNum(disk, "total") - jNum(disk, "used")))), \(jStr(disk, "fstype"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(batteries.enumerated()), id: \.offset) { _, b in
                let pct = jNum(b, "percent")
                Panel("Baterai", symbol: "battery.75") {
                    Meter(label: jStr(b, "status"), value: String(format: "%.0f%%", pct), fraction: pct / 100, tint: pct < 20 ? Palette.ember : Palette.moss)
                    Text("Kesehatan \(jStr(b, "health")), kapasitas \(Int(jNum(b, "capacity")))%, \(Int(jNum(b, "cycle_count"))) siklus")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel("Suhu & daya", symbol: "thermometer.medium") {
                let t = jNum(thermal, "cpu_temp")
                Text(t > 0 ? String(format: "CPU %.0f°C", t) : "Suhu CPU tidak tersedia")
                    .font(.rounded(18, .semibold))
                    .foregroundStyle(t >= 90 ? Palette.ember : (t >= 75 ? Palette.amber : .primary))
                if jNum(thermal, "fan_count") > 0 {
                    Text("Kipas \(Int(jNum(thermal, "fan_speed"))) RPM").font(.caption).foregroundStyle(.secondary)
                }
                if jNum(thermal, "system_power") > 0 {
                    Text(String(format: "Daya sistem %.1f W", jNum(thermal, "system_power"))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Panel("Tong Sampah", symbol: "trash") {
                Text(formatBytes(Int64(jNum(d, "trash_size"))))
                    .font(.rounded(18, .semibold))
                Text("Kosongkan Trash di Finder untuk benar-benar membebaskan ruang.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func processes(_ d: [String: Any]) -> some View {
        let procs = Array(jArr(d, "top_processes").prefix(10))
        let maxCPU = max(1, procs.map { jNum($0, "cpu") }.max() ?? 1)
        return Panel("Proses terberat", symbol: "list.bullet.rectangle") {
            if procs.isEmpty {
                Text("Tidak ada data proses.").foregroundStyle(.secondary)
            }
            ForEach(Array(procs.enumerated()), id: \.offset) { _, p in
                let c = jNum(p, "cpu")
                HStack(spacing: 10) {
                    Text(jStr(p, "name")).lineLimit(1).frame(width: 200, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Palette.level(c).opacity(0.85))
                            .frame(width: max(2, g.size.width * CGFloat(c / maxCPU)))
                    }
                    .frame(height: 6)
                    Text(String(format: "%.1f%%", c))
                        .font(.system(.callout, design: .rounded)).monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                    Text(jNum(p, "memory_bytes") > 0 ? formatBytes(Int64(jNum(p, "memory_bytes"))) : String(format: "%.1f%%", jNum(p, "memory")))
                        .font(.system(.callout, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Fitur berbasis perintah (Clean, Optimize, Purge, Installer, Slim)

struct ExtraAction {
    let label: String
    let symbol: String
    let action: (CommandRunner) -> Void
}

struct CommandSpec {
    let preview: [String]
    let previewLabel: String
    let run: [String]?
    let runLabel: String
    let confirmTitle: String
    let confirmInfo: String
    let terminal: String
    let terminalLabel: String
    let extras: [ExtraAction]
    let note: String

    static func make(_ f: Feature) -> CommandSpec {
        switch f {
        case .clean:
            return CommandSpec(
                preview: ["clean", "--dry-run"], previewLabel: "Pratinjau",
                run: ["clean"], runLabel: "Bersihkan level pengguna",
                confirmTitle: "Bersihkan cache sekarang?",
                confirmInfo: "Mole menghapus cache level pengguna sesuai pratinjau. Bagian sistem dilewati karena butuh sudo; gunakan Terminal untuk itu.",
                terminal: "clean", terminalLabel: "Bersih penuh di Terminal",
                extras: [
                    ExtraAction(label: "Daftar kandidat", symbol: "list.bullet") { runner in
                        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/mole/clean-list.txt")
                        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                            runner.show(text, title: "~/.config/mole/clean-list.txt")
                        } else {
                            runner.show("Daftar kandidat belum ada. Jalankan pratinjau dulu.", title: "~/.config/mole/clean-list.txt")
                        }
                    },
                    ExtraAction(label: "Atur whitelist", symbol: "lock.shield") { _ in
                        MoleBridge.shared.openInTerminal("clean --whitelist")
                    }
                ],
                note: "Pembersihan sistem butuh kata sandi admin, jadi dijalankan di Terminal agar sudo bisa bertanya."
            )
        case .optimize:
            return CommandSpec(
                preview: ["optimize", "--dry-run"], previewLabel: "Pratinjau",
                run: ["optimize"], runLabel: "Jalankan optimasi",
                confirmTitle: "Jalankan optimasi?",
                confirmInfo: "Mole menjalankan tugas pemeliharaan level pengguna dari pratinjau. Tugas yang butuh sudo dilewati.",
                terminal: "optimize", terminalLabel: "Optimasi penuh di Terminal",
                extras: [
                    ExtraAction(label: "Atur whitelist", symbol: "lock.shield") { _ in
                        MoleBridge.shared.openInTerminal("optimize --whitelist")
                    }
                ],
                note: "Setiap tugas dijelaskan di pratinjau sebelum ada yang diubah."
            )
        case .purge:
            return CommandSpec(
                preview: ["purge", "--dry-run"], previewLabel: "Pratinjau",
                run: ["purge", "--yes"], runLabel: "Hapus semua kandidat",
                confirmTitle: "Hapus semua artefak build di pratinjau?",
                confirmInfo: "Mole menghapus artefak build proyek yang tidak aktif. Artefak bisa dibuat ulang dengan build berikutnya.",
                terminal: "purge", terminalLabel: "Pilih proyek di Terminal",
                extras: [
                    ExtraAction(label: "Atur folder proyek", symbol: "folder.badge.gearshape") { _ in
                        MoleBridge.shared.openInTerminal("purge --paths")
                    }
                ],
                note: "Ingin memilih satu per satu? Gunakan Terminal untuk daftar interaktif."
            )
        case .installer:
            return CommandSpec(
                preview: ["installer", "--dry-run"], previewLabel: "Pindai installer",
                run: nil, runLabel: "",
                confirmTitle: "", confirmInfo: "",
                terminal: "installer", terminalLabel: "Pilih & hapus di Terminal",
                extras: [],
                note: "Menghapus installer selalu lewat pilihan interaktif di Terminal."
            )
        default:
            return CommandSpec(
                preview: ["slim", "--dry-run"], previewLabel: "Pindai Universal App",
                run: nil, runLabel: "",
                confirmTitle: "", confirmInfo: "",
                terminal: "slim", terminalLabel: "Pilih aplikasi di Terminal",
                extras: [],
                note: "Hanya untuk Apple Silicon. Mole memverifikasi tanda tangan aplikasi setelah dirampingkan."
            )
        }
    }
}

struct CommandFeatureView: View {
    let feature: Feature
    let spec: CommandSpec
    @ObservedObject var runner: CommandRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(feature) {
                Button {
                    runner.run(spec.preview)
                } label: {
                    Label(spec.previewLabel, systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.running)

                if let run = spec.run {
                    Button(spec.runLabel) {
                        if confirmAlert(spec.confirmTitle, spec.confirmInfo, spec.runLabel) {
                            runner.run(run)
                        }
                    }
                    .disabled(runner.running)
                }

                Button {
                    MoleBridge.shared.openInTerminal(spec.terminal)
                } label: {
                    Label(spec.terminalLabel, systemImage: "terminal")
                }

                ForEach(Array(spec.extras.enumerated()), id: \.offset) { _, extra in
                    Button {
                        extra.action(runner)
                    } label: {
                        Label(extra.label, systemImage: extra.symbol)
                    }
                    .disabled(runner.running)
                }
            }
            Note(text: spec.note)
            ConsoleView(runner: runner)
        }
        .padding(24)
        .onAppear {
            if runner.output.isEmpty && !runner.running && runner.lastExit == nil {
                runner.run(spec.preview)
            }
        }
    }
}

// MARK: - Uninstall

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(_ path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

struct UninstallView: View {
    @ObservedObject var store: UninstallStore
    @ObservedObject var runner: CommandRunner
    @State private var query = ""
    @State private var selection: String?

    private var filtered: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.apps }
        return store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    private var selected: AppEntry? {
        store.apps.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.uninstall) {
                Button {
                    store.load()
                } label: {
                    Label("Muat ulang daftar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.loading)
                Button {
                    MoleBridge.shared.openInTerminal("uninstall")
                } label: {
                    Label("Uninstaller interaktif di Terminal", systemImage: "terminal")
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Cari nama atau bundle ID", text: $query)
                        .textFieldStyle(.roundedBorder)
                    if store.loading {
                        ProgressView("Memindai aplikasi…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !store.error.isEmpty {
                        Note(text: store.error, symbol: "exclamationmark.triangle", tint: Palette.ember)
                        Spacer()
                    } else {
                        List(filtered, selection: $selection) { app in
                            HStack(spacing: 10) {
                                Image(nsImage: IconCache.shared.icon(app.path))
                                    .resizable()
                                    .frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).lineLimit(1)
                                    Text(app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(app.size).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.inset)
                        Text("\(filtered.count) aplikasi").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

                VStack(alignment: .leading, spacing: 12) {
                    if let app = selected {
                        detail(app)
                    } else {
                        Note(text: "Pilih aplikasi di kiri untuk melihat sisa file yang akan ikut dihapus.", symbol: "hand.point.left")
                    }
                    ConsoleView(runner: runner, placeholder: "Pratinjau sisa file tampil di sini.")
                }
            }
        }
        .padding(24)
        .onAppear { if !store.loaded { store.load() } }
    }

    private func detail(_ app: AppEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: IconCache.shared.icon(app.path))
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.rounded(19, .bold))
                        if app.source == "Homebrew" {
                            Text("Homebrew")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Palette.amber.opacity(0.2)))
                        }
                    }
                    Text(app.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("Ukuran \(app.size)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    runner.run(["uninstall", "--dry-run", app.uninstallName])
                } label: {
                    Label("Pratinjau sisa file", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.running)
                Button("Uninstall di Terminal…") {
                    if confirmAlert(
                        "Uninstall \(app.name)?",
                        "Terminal akan membuka mo uninstall untuk aplikasi ini. Mole menampilkan daftar file dan meminta konfirmasi sekali lagi sebelum memindahkannya ke Trash.",
                        "Buka Terminal"
                    ) {
                        MoleBridge.shared.openInTerminal("uninstall \(shellQuote(app.uninstallName))")
                    }
                }
                Button("Tampilkan di Finder") { revealInFinder(app.path) }
            }
        }
    }
}

// MARK: - Analyze

struct AnalyzeView: View {
    @ObservedObject var store: AnalyzeStore

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.path)
        if panel.runModal() == .OK, let url = panel.url {
            store.scan(url.path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.analyze) {
                Button {
                    store.scan(store.path)
                } label: {
                    Label("Pindai", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.loading)
                Button("Pilih folder…", action: chooseFolder).disabled(store.loading)
                Button("Ringkasan Mac") { store.scan(nil) }.disabled(store.loading)
                Button {
                    MoleBridge.shared.openInTerminal("analyze \(shellQuote(store.path))")
                } label: {
                    Label("Penjelajah interaktif di Terminal", systemImage: "terminal")
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(store.back.isEmpty || store.loading)
                .help("Kembali")
                TextField("Path folder", text: $store.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { store.scan(store.path) }
            }

            if store.loading {
                ProgressView("Mengukur folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.error.isEmpty {
                Note(text: store.error, symbol: "exclamationmark.triangle", tint: Palette.ember)
                Spacer()
            } else if store.entries.isEmpty && store.largeFiles.isEmpty {
                Note(text: "Pilih folder lalu tekan Pindai. Klik dua kali folder di hasil untuk masuk lebih dalam.", symbol: "chart.pie")
                Spacer()
            } else {
                results
            }
        }
        .padding(24)
    }

    private var results: some View {
        let maxSize = max(1, store.entries.first?.size ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(formatBytes(store.total)).font(.rounded(26, .bold))
                Text("di \(store.scannedPath)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if store.partial {
                    Text("Sebagian").font(.caption.weight(.medium)).foregroundStyle(Palette.amber)
                        .help("Sebagian folder tidak bisa dibaca atau waktu pemindaian habis.")
                }
            }
            List {
                Section("Isi folder") {
                    ForEach(store.entries) { e in
                        HStack(spacing: 10) {
                            Image(systemName: e.isDir ? "folder.fill" : "doc")
                                .foregroundStyle(e.isDir ? Palette.loam : .secondary)
                                .frame(width: 18)
                            Text(e.name).lineLimit(1).frame(minWidth: 160, alignment: .leading)
                            if e.cleanable {
                                Text("Cache, aman dibersihkan")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Palette.moss)
                            }
                            GeometryReader { g in
                                Capsule()
                                    .fill(e.cleanable ? Palette.moss : Palette.nose.opacity(0.8))
                                    .frame(width: max(2, g.size.width * CGFloat(Double(e.size) / Double(maxSize))))
                            }
                            .frame(height: 6)
                            Text(formatBytes(e.size))
                                .font(.system(.callout, design: .rounded)).monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if e.isDir { store.scan(e.path) } }
                        .contextMenu {
                            if e.isDir { Button("Pindai folder ini") { store.scan(e.path) } }
                            Button("Tampilkan di Finder") { revealInFinder(e.path) }
                            Button("Salin path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.path, forType: .string)
                            }
                        }
                    }
                }
                if !store.largeFiles.isEmpty {
                    Section("File terbesar") {
                        ForEach(store.largeFiles) { f in
                            HStack {
                                Image(systemName: "doc.fill").foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name).lineLimit(1)
                                    Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(formatBytes(f.size)).font(.system(.callout, design: .rounded)).monospacedDigit()
                            }
                            .contextMenu {
                                Button("Tampilkan di Finder") { revealInFinder(f.path) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Note(text: "Menghapus dari sini sengaja tidak tersedia. Gunakan penjelajah interaktif di Terminal agar setiap penghapusan tercatat di riwayat Mole.")
        }
    }
}

// MARK: - Riwayat & Alat

struct HistoryView: View {
    @State private var sessions: [[String: Any]] = []
    @State private var deletions: [[String: Any]] = []
    @State private var loading = false
    @State private var error = ""
    @State private var tab = 0
    @State private var loaded = false

    private func load() {
        loading = true
        error = ""
        MoleBridge.shared.runJSON(["history", "--json", "--limit", "100"]) { json, err in
            loading = false
            loaded = true
            guard let d = json as? [String: Any] else {
                error = err.isEmpty ? "Output mo history --json tidak bisa dibaca." : err
                return
            }
            sessions = jArr(d, "sessions")
            deletions = jArr(d, "deletions")
        }
    }

    private func openConfig(_ rel: String) {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(rel)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(.history) {
                Button {
                    load()
                } label: {
                    Label("Segarkan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
                Button("Riwayat di Terminal") { MoleBridge.shared.openInTerminal("history") }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $tab) {
                        Text("Sesi (\(sessions.count))").tag(0)
                        Text("File diubah (\(deletions.count))").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !error.isEmpty {
                        Note(text: error, symbol: "exclamationmark.triangle", tint: Palette.ember)
                        Spacer()
                    } else if tab == 0 {
                        sessionList
                    } else {
                        deletionList
                    }
                }
                tools.frame(width: 260)
            }
        }
        .padding(24)
        .onAppear { if !loaded { load() } }
    }

    private var sessionList: some View {
        List {
            if sessions.isEmpty {
                Text("Belum ada sesi. Riwayat muncul setelah Mole membersihkan atau mengubah sesuatu.").foregroundStyle(.secondary)
            }
            ForEach(Array(sessions.enumerated()), id: \.offset) { _, s in
                let actions = jObj(s, "actions")
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: jStr(s, "command").hasSuffix("dry-run") ? "eye" : "checkmark.seal")
                        .foregroundStyle(jStr(s, "command").hasSuffix("dry-run") ? Color.secondary : Palette.moss)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("mo \(jStr(s, "command"))").font(.system(.body, design: .monospaced))
                        Text(jStr(s, "started_at")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(jStr(s, "size").isEmpty ? "–" : jStr(s, "size")).font(.system(.body, design: .rounded)).monospacedDigit()
                        Text("\(Int(jNum(actions, "trashed"))) ke Trash, \(Int(jNum(actions, "removed"))) dihapus, \(Int(jNum(actions, "failed"))) gagal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
    }

    private var deletionList: some View {
        List {
            if deletions.isEmpty {
                Text("Belum ada file yang dihapus atau dipindah ke Trash.").foregroundStyle(.secondary)
            }
            ForEach(Array(deletions.enumerated()), id: \.offset) { _, del in
                let path = jStr(del, "path")
                HStack(spacing: 10) {
                    Image(systemName: jStr(del, "mode").lowercased().contains("trash") ? "trash" : "xmark.bin")
                        .foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Text("\(jStr(del, "timestamp")), \(jStr(del, "mode")), \(jStr(del, "status"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if jNum(del, "size_kb") > 0 {
                        Text(formatBytes(Int64(jNum(del, "size_kb") * 1024))).font(.caption).monospacedDigit()
                    }
                }
                .contextMenu {
                    Button("Salin path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel("Alat", symbol: "wrench.and.screwdriver") {
                toolButton("Touch ID untuk sudo", "touchid") { MoleBridge.shared.openInTerminal("touchid") }
                toolButton("Shell completion", "chevron.left.forwardslash.chevron.right") { MoleBridge.shared.openInTerminal("completion") }
                toolButton("Whitelist clean", "lock.shield") { MoleBridge.shared.openInTerminal("clean --whitelist") }
                toolButton("Whitelist optimize", "lock.shield") { MoleBridge.shared.openInTerminal("optimize --whitelist") }
                toolButton("Folder proyek purge", "folder.badge.gearshape") { MoleBridge.shared.openInTerminal("purge --paths") }
            }
            Panel("Folder", symbol: "folder") {
                toolButton("Konfigurasi Mole", "gearshape") { openConfig(".config/mole") }
                toolButton("Log operasi", "doc.text.magnifyingglass") { openConfig("Library/Logs/mole") }
            }
            Text("Mole CLI v\(MoleBridge.shared.cliVersion)")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func toolButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }
}
