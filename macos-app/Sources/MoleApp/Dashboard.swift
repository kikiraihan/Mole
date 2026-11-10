// MoleApp — Dashboard SwiftUI (jendela utama) untuk seluruh fitur Mole CLI.
// Tema visual "liang tikus tanah": aksen merah muda hidung mole, hijau lumut untuk kondisi sehat,
// amber untuk waspada, merah bara untuk kritis. Angka & judul memakai SF Rounded.
// Semua aksi destruktif tetap lewat Mole CLI: pratinjau (--dry-run) di aplikasi,
// eksekusi yang butuh sudo atau pilihan interaktif dibuka di Terminal.

import AppKit
import ServiceManagement
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

/// Mengubah teks ukuran dari mo uninstall --list ("769.4MB", "4KB", "1.2 GB") menjadi byte untuk pengurutan.
func parseSizeText(_ text: String) -> Int64 {
    let s = text.uppercased().replacingOccurrences(of: " ", with: "")
    let units: [(String, Double)] = [("TB", 1_099_511_627_776), ("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1024), ("B", 1)]
    for (suffix, mult) in units where s.hasSuffix(suffix) {
        if let v = Double(s.dropLast(suffix.count)) { return Int64(v * mult) }
    }
    return Int64(Double(s) ?? 0)
}

// MARK: - Tong Sampah
// ~/.Trash dilindungi TCC: tanpa Full Disk Access, status-go membaca 0 B walau Trash berisi.
// Urutan: baca langsung (jika MoleApp punya Full Disk Access), lalu tanya Finder lewat AppleScript.

struct TrashInfo {
    enum Source { case direct, finder, unavailable }
    var bytes: Int64 = 0
    var items = 0
    var source: Source = .unavailable
    /// Jumlah item yang ukurannya tidak bisa dihitung Finder (hasil jadi batas bawah).
    var unmeasured = 0
}

enum TrashProbe {
    static func measure(completion: @escaping (TrashInfo) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let info = direct() ?? finder() ?? TrashInfo()
            DispatchQueue.main.async { completion(info) }
        }
    }

    private static func direct() -> TrashInfo? {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        guard let top = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        let deadline = Date().addingTimeInterval(4)
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let url as URL in e {
                if Date() > deadline { break }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            }
        }
        return TrashInfo(bytes: total, items: top.filter { $0 != ".DS_Store" }.count, source: .direct)
    }

    /// Finder menghitung Trash semua volume. Pertama kali macOS meminta izin Automation untuk Finder.
    /// Finder mengembalikan `missing value` untuk ukuran folder/paket yang belum pernah ia hitung,
    /// jadi coba `size`, lalu `physical size`, lalu jumlahkan file di dalamnya, dan ulangi sekali
    /// setelah jeda karena Finder menghitung ukuran folder di latar belakang.
    private static func finder() -> TrashInfo? {
        guard var info = runFinderScript() else { return nil }
        if info.items > 0 && (info.bytes == 0 || info.unmeasured > 0) {
            Thread.sleep(forTimeInterval: 1.5)
            if let again = runFinderScript(), again.bytes >= info.bytes { info = again }
        }
        return info
    }

    private static func runFinderScript() -> TrashInfo? {
        let script = """
        on sumList(L)
            set acc to 0
            repeat with v in L
                try
                    set x to contents of v
                    if x is not missing value then set acc to acc + x
                end try
            end repeat
            return acc
        end sumList

        tell application "Finder"
            set n to count of items of trash
            set t to 0
            set unknown to 0
            repeat with i in (items of trash)
                set s to missing value
                try
                    set s to size of i
                end try
                if s is missing value then
                    try
                        set s to physical size of i
                    end try
                end if
                if s is missing value then
                    try
                        set s to my sumList(size of every file of entire contents of i)
                        if s is 0 then set s to missing value
                    end try
                end if
                if s is missing value then
                    set unknown to unknown + 1
                else
                    set t to t + s
                end if
            end repeat
            return (n as text) & "|" & (t as text) & "|" & (unknown as text)
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        // Trash yang sangat besar bisa membuat Finder lama menjawab; hentikan setelah 30 detik.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        let parts = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|")
        guard parts.count == 3, let n = Int(parts[0]) else { return nil }
        // AppleScript bisa menulis angka besar sebagai 1.2345E+9, dan memakai koma desimal di locale Indonesia
        let bytes = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        return TrashInfo(bytes: Int64(bytes), items: n, source: .finder, unmeasured: Int(parts[2]) ?? 0)
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Proses dengan RAM terbanyak
// top_processes dari mo status diurutkan menurut CPU, jadi daftar RAM dibaca langsung dari ps (-m = urut memori).

struct MemProcess: Identifiable {
    let id: Int
    let name: String
    let rssBytes: Int64
    let percent: Double
}

enum MemProcessSampler {
    static func top(_ limit: Int = 8, completion: @escaping ([MemProcess]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-Acmo", "pid=,rss=,pmem=,comm="]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = FileHandle.nullDevice
            var result: [MemProcess] = []
            if (try? proc.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    guard f.count == 4, let pid = Int(f[0]), let rss = Int64(f[1]) else { continue }
                    result.append(MemProcess(id: pid, name: String(f[3]), rssBytes: rss * 1024, percent: Double(f[2]) ?? 0))
                }
                // ps -m sudah mengurutkan, tetapi urutkan ulang agar tidak bergantung pada versi ps
                result.sort { $0.rssBytes > $1.rssBytes }
            }
            let top = Array(result.prefix(limit))
            DispatchQueue.main.async { completion(top) }
        }
    }
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
    /// Bagian yang diklik di glyph menu bar (disorot di popover); nil = klik biasa
    @Published var focus: MetricKind?

    private var lastHealthAt: Date?

    var memPercent: Double {
        memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100.0 : 0
    }

    func update(cpu: Double, memUsed: UInt64, memTotal: UInt64, disk: DiskSnapshot, netUp: Double, netDown: Double, bat: BatterySnapshot?) {
        // Hanya tulis nilai yang berubah: setiap set @Published memicu SwiftUI menghitung ulang view
        if self.cpu != cpu { self.cpu = cpu }
        if self.memUsed != memUsed { self.memUsed = memUsed }
        if self.memTotal != memTotal { self.memTotal = memTotal }
        if self.disk != disk { self.disk = disk }
        if self.netUp != netUp { self.netUp = netUp }
        if self.netDown != netDown { self.netDown = netDown }
        if self.battery != bat { self.battery = bat }
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
    case status = 0, clean, uninstall, analyze, optimize, purge, installer, slim, history, settings

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
        case .settings: return "Pengaturan"
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
        case .settings: return "slider.horizontal.3"
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
        case .settings: return "Semua pengaturan MoleApp: indikator menu bar, glyph, interaksi, dan buka saat login."
        }
    }
}

struct FeatureGroup: Identifiable {
    let id: String
    let items: [Feature]

    static let all: [FeatureGroup] = [
        FeatureGroup(id: "Pantau", items: [.status, .analyze, .history]),
        FeatureGroup(id: "Kosongkan ruang", items: [.clean, .purge, .installer, .slim]),
        FeatureGroup(id: "Aplikasi & sistem", items: [.uninstall, .optimize]),
        FeatureGroup(id: "Pengaturan", items: [.settings])
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
    /// Ukuran dalam byte, diturunkan dari teks size untuk pengurutan.
    var sizeBytes: Int64 { parseSizeText(size) }
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
        case .settings:
            IndicatorSettingsView()
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
    @State private var trash: TrashInfo?
    @State private var memProcs: [MemProcess] = []

    private func load() {
        loading = true
        error = ""
        TrashProbe.measure { trash = $0 }
        MemProcessSampler.top { memProcs = $0 }
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
                    memoryProcesses
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
                trashContent(statusBytes: Int64(jNum(d, "trash_size")))
            }
        }
    }

    private func processes(_ d: [String: Any]) -> some View {
        let procs = Array(jArr(d, "top_processes").prefix(10))
        let maxCPU = max(1, procs.map { jNum($0, "cpu") }.max() ?? 1)
        return Panel("Proses terberat (CPU)", symbol: "list.bullet.rectangle") {
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

    @ViewBuilder
    private func trashContent(statusBytes: Int64) -> some View {
        // mo status mengembalikan 0 B jika ~/.Trash tidak bisa dibaca, jadi utamakan hasil TrashProbe.
        if let t = trash, t.source != .unavailable {
            Text((t.source == .finder && t.unmeasured > 0 ? "≥ " : "") + formatBytes(max(t.bytes, statusBytes)))
                .font(.rounded(18, .semibold))
            Text(t.source == .finder ? "\(t.items) item, dihitung lewat Finder" : "\(t.items) item")
                .font(.caption).foregroundStyle(.secondary)
            if t.source == .finder && t.unmeasured > 0 {
                Text("Ukuran \(t.unmeasured) item belum bisa dihitung Finder, jadi angka di atas batas bawah. Beri Full Disk Access agar akurat.")
                    .font(.caption).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Buka pengaturan Full Disk Access") { TrashProbe.openFullDiskAccessSettings() }
                    .controlSize(.small)
            }
            Text("Kosongkan Trash di Finder untuk benar-benar membebaskan ruang.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Buka Trash") {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
            }
            .controlSize(.small)
        } else if trash == nil {
            Text(statusBytes > 0 ? formatBytes(statusBytes) : "Menghitung…")
                .font(.rounded(18, .semibold))
        } else if statusBytes > 0 {
            Text(formatBytes(statusBytes))
                .font(.rounded(18, .semibold))
            Text("Kosongkan Trash di Finder untuk benar-benar membebaskan ruang.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Tidak bisa dibaca")
                .font(.rounded(18, .semibold))
                .foregroundStyle(Palette.amber)
            Text("macOS melindungi Trash. Beri MoleApp Full Disk Access, atau izinkan MoleApp mengontrol Finder, lalu tekan Segarkan.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Buka pengaturan Full Disk Access") { TrashProbe.openFullDiskAccessSettings() }
                .controlSize(.small)
        }
    }

    private var memoryProcesses: some View {
        let maxRSS = max(1, memProcs.first?.rssBytes ?? 1)
        return Panel("Proses terberat (RAM)", symbol: "memorychip") {
            if memProcs.isEmpty {
                Text("Tidak ada data proses.").foregroundStyle(.secondary)
            }
            ForEach(memProcs) { p in
                HStack(spacing: 10) {
                    Text(p.name).lineLimit(1).frame(width: 200, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Palette.level(p.percent, warn: 10, crit: 20).opacity(0.85))
                            .frame(width: max(2, g.size.width * CGFloat(Double(p.rssBytes) / Double(maxRSS))))
                    }
                    .frame(height: 6)
                    Text(formatBytes(p.rssBytes))
                        .font(.system(.callout, design: .rounded)).monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                    Text(String(format: "%.1f%%", p.percent))
                        .font(.system(.callout, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                .help("PID \(p.id)")
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
    // Urutan daftar: "name" atau "size", diingat antar sesi
    @AppStorage("uninstallSortKey") private var sortKey = "name"
    @AppStorage("uninstallSortAscending") private var sortAscending = true

    private var filtered: [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? store.apps : store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
        return base.sorted { a, b in
            if sortKey == "size" {
                let (x, y) = (a.sizeBytes, b.sizeBytes)
                if x != y { return sortAscending ? x < y : x > y }
            } else {
                let r = a.name.localizedCaseInsensitiveCompare(b.name)
                if r != .orderedSame { return sortAscending ? r == .orderedAscending : r == .orderedDescending }
            }
            return a.path < b.path
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
                    HStack(spacing: 8) {
                        Picker("Urutkan", selection: $sortKey) {
                            Text("Nama").tag("name")
                            Text("Ukuran").tag("size")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Button {
                            sortAscending.toggle()
                        } label: {
                            Label(
                                sortAscending ? (sortKey == "size" ? "Terkecil" : "A–Z") : (sortKey == "size" ? "Terbesar" : "Z–A"),
                                systemImage: sortAscending ? "arrow.up" : "arrow.down"
                            )
                        }
                        .help(sortAscending ? "Naik (asc). Klik untuk turun (desc)." : "Turun (desc). Klik untuk naik (asc).")
                        Spacer(minLength: 0)
                    }
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

// MARK: - Pengaturan Indikator
// Pengaturan yang sama dengan menu klik kanan (kunci UserDefaults sama), jadi keduanya selalu sinkron.
// Setiap perubahan dikirim lewat .indicatorSettingsChanged supaya AppDelegate langsung menggambar ulang menu bar.
// Sejak 1.6.0 halaman ini menjadi satu-satunya tempat pengaturan (menu klik kanan dan ikon cog di popover
// membuka halaman ini), dibagi per tab: Indikator, Glyph, Interaksi, Umum.

/// Sumber tunggal pengaturan untuk halaman Pengaturan: setiap perubahan disimpan ke UserDefaults
/// lalu dikabarkan ke AppDelegate.
final class IndicatorSettingsStore: ObservableObject {
    static let shared = IndicatorSettingsStore()

    @Published var prefs: IndicatorPrefs {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            NotificationCenter.default.post(name: .indicatorSettingsChanged, object: nil)
        }
    }

    private init() {
        prefs = IndicatorPrefs.load()
    }

    func resetDefaults() {
        let d = UserDefaults.standard
        for k in IndicatorPrefs.registeredDefaults.keys { d.removeObject(forKey: k) }
        // load() membaca nilai bawaan yang didaftarkan AppDelegate
        prefs = IndicatorPrefs.load(d)
        NotificationCenter.default.post(name: .indicatorSettingsChanged, object: nil)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case indicator, glyph, interaction, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .indicator: return "Indikator"
        case .glyph: return "Glyph"
        case .interaction: return "Interaksi"
        case .general: return "Umum"
        }
    }
}

struct IndicatorSettingsView: View {
    @ObservedObject var live = LiveMetrics.shared
    @ObservedObject var store = IndicatorSettingsStore.shared
    @AppStorage("settingsTab") private var tab: SettingsTab = .indicator
    @AppStorage("settingsAdvanced") private var showAdvanced = false
    @State private var loginOn = false
    @Environment(\.colorScheme) private var scheme

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginOn },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    let a = NSAlert()
                    a.messageText = "Gagal mengatur 'Buka saat login'"
                    a.informativeText = "Pastikan MoleApp.app berada di folder /Applications.\n\n\(error.localizedDescription)"
                    a.runModal()
                }
                loginOn = SMAppService.mainApp.status == .enabled
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(.settings) {
                    Button {
                        store.resetDefaults()
                    } label: {
                        Label("Kembalikan bawaan", systemImage: "arrow.uturn.backward")
                    }
                }

                Picker("", selection: $tab) {
                    ForEach(SettingsTab.allCases) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                if tab != .general {
                    Panel("Pratinjau menu bar", symbol: "menubar.rectangle") {
                        preview
                    }
                }

                switch tab {
                case .indicator: indicatorTab
                case .glyph: glyphTab
                case .interaction: interactionTab
                case .general: generalTab
                }
            }
            .padding(24)
        }
        .onAppear { loginOn = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Tab Indikator

    private var indicatorTab: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                Panel("Gaya tampilan", symbol: "textformat.size") {
                    Picker("", selection: $store.prefs.style) {
                        ForEach(IndicatorStyle.allCases) { st in
                            Text("\(st.title) — \(st.detail)").tag(st)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                Panel("Interval update", symbol: "timer") {
                    Picker("", selection: $store.prefs.interval) {
                        ForEach(indicatorIntervals, id: \.self) { s in
                            Text("\(Int(s)) detik").tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Note(text: "Interval lebih panjang lebih hemat CPU dan baterai. Disk dibaca tiap 15 update, baterai tiap 5 update.")
                }
            }

            Panel("Tampilkan di menu bar & urutan", symbol: "checklist") {
                ForEach(Array(store.prefs.order.enumerated()), id: \.element) { i, k in
                    metricRow(k, index: i)
                }
                if store.prefs.bat && live.battery == nil {
                    Note(text: "Baterai internal tidak terdeteksi, jadi metrik ini tidak tampil di Mac ini.", symbol: "exclamationmark.circle")
                }
                if store.prefs.style == .glyphSingle {
                    Note(text: "Glyph tunggal (B) memakai isi slot di tab Glyph, bukan daftar ini.")
                }
            }
        }
    }

    private func metricRow(_ k: MetricKind, index: Int) -> some View {
        HStack(spacing: 6) {
            Label(k.title, systemImage: k.symbol)
            Spacer()
            Button { move(k, -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Pindah ke kiri")
            Button { move(k, 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == store.prefs.order.count - 1)
                .help("Pindah ke kanan")
            Toggle("", isOn: Binding(get: { store.prefs.isOn(k) }, set: { store.prefs.set(k, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func move(_ k: MetricKind, _ d: Int) {
        var o = store.prefs.order
        guard let i = o.firstIndex(of: k), o.indices.contains(i + d) else { return }
        o.swapAt(i, i + d)
        store.prefs.order = o
    }

    // MARK: Tab Glyph

    private var glyphTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.prefs.style.isGlyph {
                Note(text: "Pengaturan ini berlaku untuk gaya Glyph baris (A) dan Glyph tunggal (B). Pilih gayanya di tab Indikator.", symbol: "info.circle")
            }
            HStack(alignment: .top, spacing: 16) {
                Panel("Glyph tunggal (B): isi slot", symbol: "circle.dotted") {
                    Picker("Cincin", selection: $store.prefs.glyph.ring) {
                        ForEach(GlyphPrefs.ringOptions) { k in Text(k.short).tag(k) }
                    }
                    Picker("Pusat", selection: $store.prefs.glyph.center) {
                        ForEach(GlyphPrefs.centerOptions) { k in Text(k.short).tag(Optional(k)) }
                        Text("Kosong").tag(MetricKind?.none)
                    }
                    Picker("Titik", selection: $store.prefs.glyph.dots) {
                        ForEach(GlyphPrefs.dotsOptions) { k in Text(k.short).tag(Optional(k)) }
                        Text("Kosong").tag(MetricKind?.none)
                    }
                    Note(text: "Cincin = panjang busur, pusat = busur internet atau baterai mini, titik = 5 titik terisi.")
                }
                Panel("Warna peringatan", symbol: "exclamationmark.triangle") {
                    Toggle("Warnai bagian yang kritis", isOn: $store.prefs.glyph.warnColors)
                        .toggleStyle(.switch)
                    Note(text: "Mati = ikon murni monokrom seperti ikon sistem. Hidup = hanya bagian kritis yang diwarnai (baterai merah, disk oranye). Ambangnya ada di Lanjutan.")
                }
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        Panel("Cara membaca metrik", symbol: "ruler") {
                            Picker("Isian storage", selection: $store.prefs.glyph.diskShowsFree) {
                                Text("% terpakai").tag(false)
                                Text("% sisa").tag(true)
                            }
                            Picker("Arah internet", selection: $store.prefs.glyph.netDirection) {
                                ForEach(NetDirection.allCases) { d in Text(d.title).tag(d) }
                            }
                            Picker("Ambang busur", selection: $store.prefs.glyph.netFast) {
                                Text("Rumahan (10 KB/s · 1 MB/s · 10 MB/s)").tag(false)
                                Text("Cepat (100 KB/s · 10 MB/s · 100 MB/s)").tag(true)
                            }
                            Toggle("Petir saat mengisi daya", isOn: $store.prefs.glyph.bolt)
                        }
                        Panel("Angka di samping glyph", symbol: "number") {
                            ForEach(MetricKind.allCases) { k in
                                Toggle(k.title, isOn: numberBinding(k))
                            }
                            Note(text: "Pada glyph tunggal (B), angka hanya tampil untuk metrik di cincin.")
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Panel("Ambang peringatan", symbol: "dial.medium") {
                            Stepper(value: $store.prefs.glyph.warnBattery, in: 5...50, step: 5) {
                                Text("Baterai merah di bawah \(store.prefs.glyph.warnBattery)%")
                            }
                            Stepper(value: $store.prefs.glyph.warnDisk, in: 1...30, step: 1) {
                                Text("Disk oranye bila sisa di bawah \(store.prefs.glyph.warnDisk)%")
                            }
                            Toggle("Peringatan CPU tinggi", isOn: $store.prefs.glyph.warnCPUOn)
                            Stepper(value: $store.prefs.glyph.warnCPU, in: 50...100, step: 5) {
                                Text("CPU merah di atas \(store.prefs.glyph.warnCPU)%")
                            }
                            .disabled(!store.prefs.glyph.warnCPUOn)
                        }
                        .disabled(!store.prefs.glyph.warnColors)
                        Panel("Ukuran", symbol: "arrow.up.left.and.arrow.down.right") {
                            Picker("Ukuran glyph", selection: $store.prefs.glyph.small) {
                                Text("Standar").tag(false)
                                Text("Kecil").tag(true)
                            }
                            .pickerStyle(.segmented)
                            Picker("Jarak antar glyph", selection: $store.prefs.glyph.tight) {
                                Text("Normal").tag(false)
                                Text("Rapat").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Lanjutan").font(.headline)
            }
        }
    }

    private func numberBinding(_ k: MetricKind) -> Binding<Bool> {
        Binding(
            get: { store.prefs.glyph.numbers.contains(k) },
            set: { on in
                if on { store.prefs.glyph.numbers.insert(k) } else { store.prefs.glyph.numbers.remove(k) }
            }
        )
    }

    // MARK: Tab Interaksi

    private var interactionTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.prefs.style.isGlyph {
                Note(text: "Klik dan tooltip per bagian hanya berlaku untuk gaya glyph. Pada gaya teks, klik kiri selalu membuka popover biasa.", symbol: "info.circle")
            }
            Panel("Klik & hover di menu bar", symbol: "cursorarrow.click") {
                Toggle("Klik per bagian membuka popover di bagian itu", isOn: $store.prefs.glyph.clickRegions)
                    .toggleStyle(.switch)
                Toggle("Tooltip angka tepat saat kursor di atas bagian", isOn: $store.prefs.glyph.tooltips)
                    .toggleStyle(.switch)
                Note(text: "Klik kanan (atau Control-klik) tetap membuka menu: dashboard, fitur Mole CLI, Pengaturan, pembaruan, dan keluar.")
            }
        }
    }

    // MARK: Tab Umum

    private var generalTab: some View {
        Panel("Umum", symbol: "gearshape") {
            Toggle("Buka saat login", isOn: loginBinding)
                .toggleStyle(.switch)
            Note(text: "Pembaruan MoleApp dicek otomatis saat dibuka lalu sehari sekali; cek manual ada di menu klik kanan.")
        }
    }

    // MARK: Pratinjau

    /// Gambar indikator memakai renderer yang sama dengan menu bar, dengan angka live saat ini
    private var preview: some View {
        let values = MetricValues(
            cpu: live.cpu, memPercent: live.memPercent, memUsed: live.memUsed, memTotal: live.memTotal,
            disk: live.disk, up: live.netUp, down: live.netDown, bat: live.battery
        )
        let layout = IndicatorLayout(store.prefs, values, dark: scheme == .dark)
        let rendered = layout.render()
        let img = rendered?.image
            ?? NSImage(systemSymbolName: "sparkles.rectangle.stack.fill", accessibilityDescription: "MoleApp")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Image(nsImage: img)
                    .renderingMode(img.isTemplate || rendered == nil ? .template : .original)
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            if layout.isEmpty {
                Note(text: "Semua metrik dimatikan: menu bar hanya menampilkan ikon MoleApp.")
            }
        }
    }
}
