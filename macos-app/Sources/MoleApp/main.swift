// MoleApp — Menu Bar Indicator + Mac App Dashboard untuk seluruh fitur Mole CLI
// Dibuat dengan Swift + AppKit murni (tanpa dependensi eksternal, kompilasi instan < 3 detik).
// Build: ./macos-app/scripts/build.sh

import Cocoa
import IOKit.ps
import ServiceManagement

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

struct DiskSnapshot {
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

struct BatterySnapshot {
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

func stripANSI(_ input: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]|\\r", options: []) else {
        return input
    }
    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
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

    func runCommand(_ args: [String], completion: @escaping (Int32, String) -> Void) {
        let execPath = moleExecutablePath
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [execPath] + args

            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            let stdPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = stdPath + ":" + (env["PATH"] ?? "")
            proc.environment = env

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

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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

final class Updater: NSObject {
    let repo = "kikiraihan/mole"
    let appName = "MoleApp"
    let menuItem = NSMenuItem(title: "Cek pembaruan…", action: #selector(Updater.checkNow), keyEquivalent: "")
    typealias Release = (version: String, zip: URL?, page: URL)
    var latest: Release?

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    override init() {
        super.init()
        menuItem.target = self
    }

    func check(_ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases") else { return done(false) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var found: Release?
            if let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in list {
                    guard let tag = item["tag_name"] as? String,
                          let pageStr = item["html_url"] as? String,
                          let page = URL(string: pageStr) else { continue }
                    let assets = item["assets"] as? [[String: Any]] ?? []
                    let zipURL = (assets.first { ($0["name"] as? String) == "MoleApp.zip" }?["browser_download_url"] as? String)
                        .flatMap { URL(string: $0) }
                    if tag.hasPrefix("app-v") || zipURL != nil {
                        found = (tag, zipURL, page)
                        break
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
            self.menuItem.title = "Cek pembaruan…"
            self.menuItem.isEnabled = true
            let a = NSAlert()
            NSApp.activate(ignoringOtherApps: true)
            guard ok, let l = self.latest else {
                a.messageText = "Belum ada rilis baru atau gagal mengecek"
                a.informativeText = "Versi terpasang: v\(Updater.current)"
                a.runModal()
                return
            }
            a.messageText = "Rilis terbaru di GitHub: \(l.version)"
            a.informativeText = "Versi terpasang: v\(Updater.current)\nKlik 'Buka Halaman Rilis' untuk mengunduh MoleApp.zip terbaru."
            a.addButton(withTitle: "Buka Halaman Rilis")
            a.addButton(withTitle: "Tutup")
            if a.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(l.page)
            }
        }
    }
}

// MARK: - 5. Mac App Dashboard Window Controller (Pure AppKit Split/Tab Interface)

final class DashboardWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let sidebarSegment = NSSegmentedControl()
    private let statusHeaderLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionStack = NSStackView()
    private let pathField = NSTextField()
    private let outputTextView = NSTextView()
    private let spinner = NSProgressIndicator()

    private var currentTab: Int = 0

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "MoleApp v\(MoleBridge.shared.version) — macOS Cleaner, Uninstaller, Analyzer & System Monitor"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupUI()
        selectTab(0)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func show(tab: Int? = nil) {
        if let tab {
            sidebarSegment.selectedSegment = tab
            selectTab(tab)
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let content = window.contentView else { return }

        // Top Live Metrics Banner
        statusHeaderLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        statusHeaderLabel.textColor = .labelColor
        statusHeaderLabel.translatesAutoresizingMaskIntoConstraints = false

        // Feature Tabs (All 9 Mole CLI features)
        let titles = [
            "1. Status",
            "2. Clean",
            "3. Uninstall",
            "4. Analyze",
            "5. Optimize",
            "6. Purge",
            "7. Installer",
            "8. Slim",
            "9. History & Tools"
        ]
        sidebarSegment.segmentCount = titles.count
        for (i, t) in titles.enumerated() {
            sidebarSegment.setLabel(t, forSegment: i)
        }
        sidebarSegment.segmentStyle = .rounded
        sidebarSegment.target = self
        sidebarSegment.action = #selector(tabChanged(_:))
        sidebarSegment.selectedSegment = 0
        sidebarSegment.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle description
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Action Buttons Toolbar
        actionStack.orientation = .horizontal
        actionStack.spacing = 8
        actionStack.alignment = .centerY
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        // Optional Path / Filter Input
        pathField.placeholderString = "Path direktori atau nama aplikasi (opsional)..."
        pathField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.stringValue = NSHomeDirectory()
        pathField.translatesAutoresizingMaskIntoConstraints = false

        // Progress Spinner
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable Monospace Output Console
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outputTextView.textContainerInset = NSSize(width: 10, height: 10)
        outputTextView.autoresizingMask = [.width, .height]
        scroll.documentView = outputTextView

        content.addSubview(statusHeaderLabel)
        content.addSubview(sidebarSegment)
        content.addSubview(subtitleLabel)
        content.addSubview(actionStack)
        content.addSubview(pathField)
        content.addSubview(spinner)
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            statusHeaderLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            statusHeaderLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            statusHeaderLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10),

            spinner.centerYAnchor.constraint(equalTo: statusHeaderLabel.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            sidebarSegment.topAnchor.constraint(equalTo: statusHeaderLabel.bottomAnchor, constant: 10),
            sidebarSegment.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            sidebarSegment.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: sidebarSegment.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            subtitleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            actionStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            actionStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            pathField.topAnchor.constraint(equalTo: actionStack.bottomAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            pathField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    func updateLiveBanner(cpu: Double, memUsed: UInt64, memTotal: UInt64, disk: DiskSnapshot, netUp: Double, netDown: Double, bat: BatterySnapshot?) {
        let memPct = memTotal > 0 ? (Double(memUsed) / Double(memTotal) * 100.0) : 0
        var text = String(
            format: "⚡ CPU: %.1f%%   │   🧠 RAM: %@ / %@ (%.0f%%)   │   💾 %@: %@ bebas (%.0f%%)   │   🌐 ↓ %@  ↑ %@",
            cpu,
            formatBytes(Int64(memUsed)),
            formatBytes(Int64(memTotal)),
            memPct,
            disk.name,
            formatBytes(disk.free),
            disk.percent,
            formatNetRate(netDown),
            formatNetRate(netUp)
        )
        if let b = bat {
            text += "   │   🔋 \(b.percent)%"
        }
        statusHeaderLabel.stringValue = text
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
    }

    private func makeButton(_ title: String, action: Selector, prominent: Bool = false) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        if prominent {
            btn.keyEquivalent = "\r"
        }
        return btn
    }

    func selectTab(_ index: Int) {
        currentTab = index
        for v in actionStack.arrangedSubviews {
            actionStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        switch index {
        case 0: // Status
            subtitleLabel.stringValue = "Status & Monitor (`mo status --json`): Skor kesehatan Mac, proses tertinggi, sensor suhu, daya & baterai."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("Refresh Snapshot (`mo status --json`)", action: #selector(runStatusJSON), prominent: true))
            actionStack.addArrangedSubview(makeButton("Buka Live TUI (`mo status` di Terminal)", action: #selector(openStatusTUI)))
            actionStack.addArrangedSubview(makeButton("Buka Activity Monitor", action: #selector(openActivityMonitor)))
            runStatusJSON()

        case 1: // Clean
            subtitleLabel.stringValue = "Deep Clean (`mo clean`): Pratinjau (`--dry-run`) dan bersihkan cache aplikasi, browser, developer tools & sistem."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("1. Preview (`mo clean --dry-run`)", action: #selector(runCleanDryRun), prominent: true))
            actionStack.addArrangedSubview(makeButton("Lihat Daftar Kandidat (`clean-list.txt`)", action: #selector(showCleanCandidates)))
            actionStack.addArrangedSubview(makeButton("2. Jalankan Clean User-Level (`mo clean`)", action: #selector(runCleanExecute)))
            actionStack.addArrangedSubview(makeButton("Full Clean + Sudo di Terminal", action: #selector(openCleanTerminal)))
            if outputTextView.string.isEmpty { runCleanDryRun() }

        case 2: // Uninstall
            subtitleLabel.stringValue = "Uninstall Apps (`mo uninstall`): Inventaris aplikasi terinstal (`--list`), preview sisa file (`--dry-run`), dan hapus ke Trash."
            pathField.isHidden = false
            pathField.placeholderString = "Ketik uninstall_name aplikasi untuk Preview (mis. Slack, CCleaner)..."
            if pathField.stringValue == NSHomeDirectory() { pathField.stringValue = "" }
            actionStack.addArrangedSubview(makeButton("Muat Daftar Aplikasi (`mo uninstall --list`)", action: #selector(runUninstallList), prominent: true))
            actionStack.addArrangedSubview(makeButton("Preview Aplikasi (`mo uninstall --dry-run <nama>`)", action: #selector(runUninstallPreview)))
            actionStack.addArrangedSubview(makeButton("Interactive Uninstaller di Terminal (`mo uninstall`)", action: #selector(openUninstallTerminal)))
            runUninstallList()

        case 3: // Analyze
            subtitleLabel.stringValue = "Disk Analyzer (`mo analyze --json`): Pindai ukuran direktori & file terbesar, atau buka TUI penjelajah disk interaktif."
            pathField.isHidden = false
            pathField.placeholderString = "Path direktori yang ingin dianalisis (mis. /Users/nama)..."
            if pathField.stringValue.isEmpty { pathField.stringValue = NSHomeDirectory() }
            actionStack.addArrangedSubview(makeButton("Scan Path (`mo analyze --json <path>`)", action: #selector(runAnalyzePath), prominent: true))
            actionStack.addArrangedSubview(makeButton("Scan Overview Mesin (`mo analyze --json`)", action: #selector(runAnalyzeOverview)))
            actionStack.addArrangedSubview(makeButton("Buka Interactive Disk Explorer (`mo analyze` di Terminal)", action: #selector(openAnalyzeTerminal)))
            runAnalyzePath()

        case 4: // Optimize
            subtitleLabel.stringValue = "Optimize System (`mo optimize`): Perbaiki preferensi rusak, bersihkan aturan Spotlight yatim, dan segarkan layanan macOS."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("1. Preview (`mo optimize --dry-run`)", action: #selector(runOptimizeDryRun), prominent: true))
            actionStack.addArrangedSubview(makeButton("2. Jalankan Optimize User-Level (`mo optimize`)", action: #selector(runOptimizeExecute)))
            actionStack.addArrangedSubview(makeButton("Optimize + Sudo di Terminal", action: #selector(openOptimizeTerminal)))
            runOptimizeDryRun()

        case 5: // Purge
            subtitleLabel.stringValue = "Project Purge (`mo purge`): Bersihkan artefak build proyek (`node_modules`, `target`, `build`, `dist`, `.next`, `venv`, `Pods`)."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("1. Preview Kandidat (`mo purge --dry-run`)", action: #selector(runPurgeDryRun), prominent: true))
            actionStack.addArrangedSubview(makeButton("2. Hapus Kandidat (`mo purge --yes`)", action: #selector(runPurgeYes)))
            actionStack.addArrangedSubview(makeButton("Pilih Proyek di Terminal (`mo purge`)", action: #selector(openPurgeTerminal)))
            actionStack.addArrangedSubview(makeButton("Atur Folder Proyek (`mo purge --paths`)", action: #selector(openPurgePathsTerminal)))
            runPurgeDryRun()

        case 6: // Installer
            subtitleLabel.stringValue = "Installer Cleanup (`mo installer`): Temukan file installer `.dmg`, `.pkg`, `.iso`, `.xip`, `.zip` di Downloads, Desktop, Homebrew, dll."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("1. Pindai Installer (`mo installer --dry-run`)", action: #selector(runInstallerDryRun), prominent: true))
            actionStack.addArrangedSubview(makeButton("2. Pilih & Hapus Installer di Terminal (`mo installer`)", action: #selector(openInstallerTerminal)))
            runInstallerDryRun()

        case 7: // Slim
            subtitleLabel.stringValue = "Slim Universal Apps (`mo slim`): Hapus arsitektur Intel (`x86_64`) dari Universal Apps di Apple Silicon dengan verifikasi Gatekeeper."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("1. Pindai Universal Apps (`mo slim --dry-run`)", action: #selector(runSlimDryRun), prominent: true))
            actionStack.addArrangedSubview(makeButton("2. Pilih Aplikasi di Terminal (`mo slim`)", action: #selector(openSlimTerminal)))
            runSlimDryRun()

        case 8: // History & Tools
            subtitleLabel.stringValue = "Audit History (`mo history`) & Konfigurasi (`mo touchid`, `mo completion`, `--whitelist`)."
            pathField.isHidden = true
            actionStack.addArrangedSubview(makeButton("Riwayat Operasi (`mo history`)", action: #selector(runHistoryText), prominent: true))
            actionStack.addArrangedSubview(makeButton("Riwayat JSON (`mo history --json`)", action: #selector(runHistoryJSON)))
            actionStack.addArrangedSubview(makeButton("Touch ID Sudo (`mo touchid`)", action: #selector(openTouchIDTerminal)))
            actionStack.addArrangedSubview(makeButton("Clean Whitelist (`mo clean --whitelist`)", action: #selector(openWhitelistTerminal)))
            actionStack.addArrangedSubview(makeButton("Shell Completion (`mo completion`)", action: #selector(openCompletionTerminal)))
            runHistoryText()

        default:
            break
        }
    }

    private func executeCLI(_ args: [String], title: String) {
        spinner.startAnimation(nil)
        outputTextView.string = "▶ Menjalankan: mo \(args.joined(separator: " "))\n⏳ Mohon tunggu...\n"
        MoleBridge.shared.runCommand(args) { [weak self] code, out in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            let header = "=== \(title) (exit: \(code)) ===\n\n"
            self.outputTextView.string = header + (out.isEmpty ? "(Tidak ada output)" : out)
        }
    }

    // MARK: - Button Actions

    @objc func runStatusJSON() { executeCLI(["status", "--json"], title: "mo status --json") }
    @objc func openStatusTUI() { MoleBridge.shared.openInTerminal("status") }
    @objc func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc func runCleanDryRun() { executeCLI(["clean", "--dry-run"], title: "mo clean --dry-run") }
    @objc func showCleanCandidates() {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/mole/clean-list.txt")
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            outputTextView.string = "=== Daftar Kandidat Clean (~/.config/mole/clean-list.txt) ===\n\n" + text
        } else {
            outputTextView.string = "File ~/.config/mole/clean-list.txt belum tersedia. Jalankan '1. Preview (mo clean --dry-run)' terlebih dahulu."
        }
    }
    @objc func runCleanExecute() {
        let a = NSAlert()
        a.messageText = "Jalankan Pembersihan (`mo clean`)?"
        a.informativeText = "Mole akan menghapus cache user-level sesuai daftar pratinjau."
        a.addButton(withTitle: "Bersihkan Sekarang")
        a.addButton(withTitle: "Batal")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            executeCLI(["clean"], title: "mo clean")
        }
    }
    @objc func openCleanTerminal() { MoleBridge.shared.openInTerminal("clean") }

    @objc func runUninstallList() { executeCLI(["uninstall", "--list"], title: "mo uninstall --list") }
    @objc func runUninstallPreview() {
        let target = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            outputTextView.string = "Masukkan nama aplikasi di kolom input di atas terlebih dahulu (lihat nilai `uninstall_name` dari `mo uninstall --list`), lalu klik Preview."
            return
        }
        executeCLI(["uninstall", "--dry-run", target], title: "mo uninstall --dry-run \(target)")
    }
    @objc func openUninstallTerminal() {
        let target = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            MoleBridge.shared.openInTerminal("uninstall")
        } else {
            let safe = target.replacingOccurrences(of: "'", with: "'\\''")
            MoleBridge.shared.openInTerminal("uninstall '\(safe)'")
        }
    }

    @objc func runAnalyzePath() {
        let target = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            executeCLI(["analyze", "--json"], title: "mo analyze --json")
        } else {
            executeCLI(["analyze", "--json", target], title: "mo analyze --json \(target)")
        }
    }
    @objc func runAnalyzeOverview() { executeCLI(["analyze", "--json"], title: "mo analyze --json (Overview)") }
    @objc func openAnalyzeTerminal() {
        let target = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            MoleBridge.shared.openInTerminal("analyze")
        } else {
            let safe = target.replacingOccurrences(of: "'", with: "'\\''")
            MoleBridge.shared.openInTerminal("analyze '\(safe)'")
        }
    }

    @objc func runOptimizeDryRun() { executeCLI(["optimize", "--dry-run"], title: "mo optimize --dry-run") }
    @objc func runOptimizeExecute() { executeCLI(["optimize"], title: "mo optimize") }
    @objc func openOptimizeTerminal() { MoleBridge.shared.openInTerminal("optimize") }

    @objc func runPurgeDryRun() { executeCLI(["purge", "--dry-run"], title: "mo purge --dry-run") }
    @objc func runPurgeYes() {
        let a = NSAlert()
        a.messageText = "Hapus Semua Kandidat Purge (`mo purge --yes`)?"
        a.informativeText = "Mole akan menghapus artefak build proyek yang tidak aktif (>7 hari) sesuai daftar pratinjau."
        a.addButton(withTitle: "Hapus Kandidat")
        a.addButton(withTitle: "Batal")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn {
            executeCLI(["purge", "--yes"], title: "mo purge --yes")
        }
    }
    @objc func openPurgeTerminal() { MoleBridge.shared.openInTerminal("purge") }
    @objc func openPurgePathsTerminal() { MoleBridge.shared.openInTerminal("purge --paths") }

    @objc func runInstallerDryRun() { executeCLI(["installer", "--dry-run"], title: "mo installer --dry-run") }
    @objc func openInstallerTerminal() { MoleBridge.shared.openInTerminal("installer") }

    @objc func runSlimDryRun() { executeCLI(["slim", "--dry-run"], title: "mo slim --dry-run") }
    @objc func openSlimTerminal() { MoleBridge.shared.openInTerminal("slim") }

    @objc func runHistoryText() { executeCLI(["history", "--limit", "50"], title: "mo history --limit 50") }
    @objc func runHistoryJSON() { executeCLI(["history", "--json", "--limit", "50"], title: "mo history --json --limit 50") }
    @objc func openTouchIDTerminal() { MoleBridge.shared.openInTerminal("touchid") }
    @objc func openWhitelistTerminal() { MoleBridge.shared.openInTerminal("clean --whitelist") }
    @objc func openCompletionTerminal() { MoleBridge.shared.openInTerminal("completion") }
}

// MARK: - 6. Menu Bar Indicator AppDelegate (Ala LiteMonitor + Mole Quick Actions)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    let updater = Updater()
    lazy var dashboard = DashboardWindowController()

    private let cpuSampler = CPUSampler()
    private let netSampler = NetSampler()
    private var timer: Timer?

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

    private var metricItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private let compactItem = NSMenuItem(title: "Mode ringkas (1 baris)", action: #selector(toggleCompact), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Buka saat login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            "cpu": true,
            "mem": true,
            "disk": true,
            "net": false,
            "bat": false,
            "compact": true,
            "interval": 2.0
        ])

        statusItem.menu = menu
        menu.delegate = self
        buildMenu()

        _ = cpuSampler.sample()
        _ = netSampler.sample()
        tick()
        startTimer()

        if CommandLine.arguments.contains("--dashboard") {
            dashboard.show(tab: 0)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let sec = max(1.0, defaults.double(forKey: "interval"))
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
        disk = sampleDisk()
        bat = sampleBattery()
        updateBar()
        updateRows()
        if dashboard.window.isVisible {
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
        btn.image = renderIcon()
        btn.imagePosition = .imageLeading

        let showCPU = defaults.bool(forKey: "cpu")
        let showMem = defaults.bool(forKey: "mem")
        let showDisk = defaults.bool(forKey: "disk")
        let showNet = defaults.bool(forKey: "net")
        let showBat = defaults.bool(forKey: "bat")
        let compact = defaults.bool(forKey: "compact")

        let freeGB = Double(disk.free) / 1_073_741_824.0

        if compact {
            var parts: [String] = []
            if showCPU { parts.append(String(format: "%.0f%%", cpuPct)) }
            if showMem { parts.append(String(format: "M:%.0f%%", mem.percent)) }
            if showDisk { parts.append(String(format: "%.0fG", freeGB)) }
            if showNet { parts.append("↓\(formatNetRate(rate.down, short: true))") }
            if showBat, let b = bat { parts.append("\(b.percent)%") }
            let text = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            btn.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        } else {
            var top: [String] = []
            var bot: [String] = []
            if showCPU { top.append(String(format: "CPU %2.0f%%", cpuPct)) }
            if showMem { top.append(String(format: "RAM %2.0f%%", mem.percent)) }
            if showDisk { bot.append(String(format: "SSD %.0fG", freeGB)) }
            if showNet { bot.append("↓\(formatNetRate(rate.down, short: true))") }
            if showBat, let b = bat { bot.append("🔋\(b.percent)%") }
            if top.isEmpty { top = bot; bot = [] }
            let l1 = top.isEmpty ? "" : " " + top.joined(separator: "  ")
            let l2 = bot.isEmpty ? "" : " " + bot.joined(separator: "  ")
            let full = l2.isEmpty ? l1 : "\(l1)\n\(l2)"
            let style = NSMutableParagraphStyle()
            style.maximumLineHeight = 10
            style.minimumLineHeight = 10
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .medium)
            btn.attributedTitle = NSAttributedString(
                string: full,
                attributes: [.font: font, .paragraphStyle: style, .baselineOffset: l2.isEmpty ? 0 : -3]
            )
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
            ("🕓 Audit History & Tools (`mo history`)", 8, "9")
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

        // Submenu: Tampilkan di Menu Bar (seperti LiteMonitor)
        let showMenu = NSMenu()
        for (title, key) in [
            ("CPU", "cpu"),
            ("Memori (RAM)", "mem"),
            ("Sisa SSD", "disk"),
            ("Kecepatan Jaringan", "net"),
            ("Baterai", "bat")
        ] {
            let it = NSMenuItem(title: title, action: #selector(toggleMetric(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            showMenu.addItem(it)
            metricItems.append(it)
        }
        let showItem = NSMenuItem(title: "Tampilkan di menu bar", action: nil, keyEquivalent: "")
        showItem.submenu = showMenu
        menu.addItem(showItem)

        compactItem.target = self
        menu.addItem(compactItem)

        // Submenu: Interval Update
        let intMenu = NSMenu()
        for s in [1.0, 2.0, 5.0] {
            let it = NSMenuItem(title: "\(Int(s)) detik", action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s
            intMenu.addItem(it)
            intervalItems.append(it)
        }
        let intItem = NSMenuItem(title: "Interval update", action: nil, keyEquivalent: "")
        intItem.submenu = intMenu
        menu.addItem(intItem)

        loginItem.target = self
        menu.addItem(loginItem)
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

    private func updateChecks() {
        for it in metricItems {
            let key = it.representedObject as? String ?? ""
            it.state = defaults.bool(forKey: key) ? .on : .off
        }
        compactItem.state = defaults.bool(forKey: "compact") ? .on : .off
        let cur = defaults.double(forKey: "interval")
        for it in intervalItems {
            it.state = ((it.representedObject as? Double) == cur) ? .on : .off
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        tick()
        updateChecks()
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

    @objc private func openInteractiveCLI() {
        MoleBridge.shared.openInTerminal("")
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        updateChecks()
        updateBar()
    }

    @objc private func toggleCompact() {
        defaults.set(!defaults.bool(forKey: "compact"), forKey: "compact")
        updateChecks()
        updateBar()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        defaults.set(v, forKey: "interval")
        updateChecks()
        startTimer()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Gagal mengatur 'Buka saat login'"
            a.informativeText = "Pastikan MoleApp.app berada di folder /Applications.\n\n\(error.localizedDescription)"
            a.runModal()
        }
        updateChecks()
    }

    @objc private func uninstallSelf() {
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
