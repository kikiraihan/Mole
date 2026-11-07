// MoleApp — Popover menu bar (klik kiri ikon indikator).
// Ringkasan kesehatan + meter live + akses cepat ke fitur Mole CLI.
// Klik kanan ikon tetap membuka menu lengkap (pengaturan indikator, login, update).

import AppKit
import SwiftUI

struct PopoverActions {
    let openTab: (Int?) -> Void
    let openTerminal: () -> Void
    let openMenu: () -> Void
    let quit: () -> Void
}

struct QuickTile: View {
    let feature: Feature
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.nose)
                Text(feature.title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hover ? 0.09 : 0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(feature.summary)
    }
}

struct PopoverView: View {
    @ObservedObject var live = LiveMetrics.shared
    let actions: PopoverActions

    private let quick: [Feature] = [.clean, .uninstall, .analyze, .optimize, .purge, .status]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(spacing: 9) {
                Meter(label: "CPU", value: String(format: "%.0f%%", live.cpu), fraction: live.cpu / 100, tint: Palette.level(live.cpu))
                Meter(
                    label: "Memori",
                    value: "\(formatBytes(Int64(live.memUsed))) / \(formatBytes(Int64(live.memTotal)))",
                    fraction: live.memPercent / 100,
                    tint: Palette.level(live.memPercent)
                )
                Meter(
                    label: live.disk.name,
                    value: "\(formatBytes(live.disk.free)) sisa",
                    fraction: live.disk.percent / 100,
                    tint: Palette.diskLevel(live.disk.percent)
                )
                HStack {
                    Label(formatNetRate(live.netDown), systemImage: "arrow.down")
                    Spacer()
                    Label(formatNetRate(live.netUp), systemImage: "arrow.up")
                    if let b = live.battery {
                        Spacer()
                        Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : "battery.75")
                    }
                }
                .font(.system(.caption, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }

            Divider()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(quick) { f in
                    QuickTile(feature: f) { actions.openTab(f.rawValue) }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Buka dashboard") { actions.openTab(nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.nose)
                Spacer()
                Button(action: actions.openTerminal) { Image(systemName: "terminal") }
                    .buttonStyle(.borderless)
                    .help("Menu interaktif mo di Terminal")
                Button(action: actions.openMenu) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Pengaturan indikator")
                Button(action: actions.quit) { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Keluar dari MoleApp")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var healthLine: String {
        if live.healthLoading && live.health == nil { return "Membaca kesehatan Mac…" }
        if !live.healthMsg.isEmpty { return live.healthMsg }
        return live.health == nil ? "Skor kesehatan belum tersedia." : "Skor kesehatan dari mo status."
    }
}
