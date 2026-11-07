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
    guard let regex = try? NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07|\\r", options: []) else {
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
            if l.version == "app-v\(Updater.current)" {
                a.messageText = "MoleApp sudah versi terbaru"
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

// MARK: - 5. Mac App Dashboard Window Controller (SwiftUI, lihat Dashboard.swift)
// Antarmuka lama berbasis tab segmented + konsol teks diganti dengan dashboard SwiftUI bersidebar.
// API publik (window, show(tab:), updateLiveBanner) dipertahankan agar AppDelegate tetap sama.

final class DashboardWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let model = DashboardModel()

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

    func show(tab: Int? = nil) {
        if let tab, let feature = Feature(rawValue: tab) {
            model.selection = feature
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLiveBanner(cpu: Double, memUsed: UInt64, memTotal: UInt64, disk: DiskSnapshot, netUp: Double, netDown: Double, bat: BatterySnapshot?) {
        LiveMetrics.shared.update(cpu: cpu, memUsed: memUsed, memTotal: memTotal, disk: disk, netUp: netUp, netDown: netDown, bat: bat)
    }
}

// MARK: - 6. Menu Bar Indicator AppDelegate (Ala LiteMonitor + Mole Quick Actions)

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    let updater = Updater()
    lazy var dashboard = DashboardWindowController()

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
            quit: { NSApp.terminate(nil) }
        )
        p.contentViewController = NSHostingController(rootView: PopoverView(actions: actions))
        return p
    }()

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

        // Klik kiri: popover ringkas; klik kanan (atau Control-klik): menu lengkap
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        buildMenu()

        _ = cpuSampler.sample()
        _ = netSampler.sample()
        tick()
        startTimer()

        LiveMetrics.shared.refreshHealth(force: true)

        if CommandLine.arguments.contains("--dashboard") {
            dashboard.show(tab: 0)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        tick()
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
        LiveMetrics.shared.update(cpu: cpuPct, memUsed: mem.used, memTotal: mem.total, disk: disk, netUp: rate.up, netDown: rate.down, bat: bat)
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
