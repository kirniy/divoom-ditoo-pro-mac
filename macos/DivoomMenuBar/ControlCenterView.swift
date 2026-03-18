import SwiftUI

enum ControlCenterAction: String, CaseIterable, Identifiable {
    case bluetooth
    case solidRed
    case solidGreen
    case solidBlue
    case pixelTest
    case signalAnimation
    case codexStatus
    case claudeStatus
    case orbitArt
    case witchSample
    case bunnySample

    var id: String { rawValue }
}

@MainActor
final class ControlCenterState: ObservableObject {
    @Published var lastStatus = "Idle"
    @Published var autoRefresh = "Off"
    @Published var transportSummary = "Direct BLE path to the Ditoo Pro 16x16 RGB display"
}

private struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: ControlCenterAction
    let enabled: Bool
}

struct ControlCenterView: View {
    @ObservedObject var state: ControlCenterState
    let runAction: (ControlCenterAction) -> Void
    let openResearch: () -> Void

    private let quickActions: [QuickAction] = [
        QuickAction(title: "Bluetooth", subtitle: "Refresh and inspect", symbol: "antenna.radiowaves.left.and.right", tint: Color(red: 0.16, green: 0.59, blue: 1.0), action: .bluetooth, enabled: true),
        QuickAction(title: "Pixel Test", subtitle: "Exact 16x16 frame", symbol: "square.grid.3x3.fill", tint: Color(red: 0.28, green: 0.92, blue: 0.55), action: .pixelTest, enabled: true),
        QuickAction(title: "Red Scene", subtitle: "Persistent direct color", symbol: "circle.fill", tint: Color(red: 1.0, green: 0.26, blue: 0.35), action: .solidRed, enabled: true),
        QuickAction(title: "Green Scene", subtitle: "Persistent direct color", symbol: "circle.fill", tint: Color(red: 0.21, green: 0.87, blue: 0.47), action: .solidGreen, enabled: true),
        QuickAction(title: "Blue Scene", subtitle: "Persistent direct color", symbol: "circle.fill", tint: Color(red: 0.23, green: 0.61, blue: 1.0), action: .solidBlue, enabled: true),
    ]

    private let colorScenes: [QuickAction] = [
        QuickAction(title: "Signal Anim", subtitle: "Needs more RE work", symbol: "sparkles", tint: .secondary, action: .signalAnimation, enabled: false),
        QuickAction(title: "Codex", subtitle: "Native status screen", symbol: "brain", tint: .secondary, action: .codexStatus, enabled: false),
        QuickAction(title: "Claude", subtitle: "Native status screen", symbol: "message.fill", tint: .secondary, action: .claudeStatus, enabled: false),
        QuickAction(title: "Orbit Art", subtitle: "Ambient direct render", symbol: "sparkles.square.filled.on.square", tint: .secondary, action: .orbitArt, enabled: false),
        QuickAction(title: "Witch", subtitle: "Vendor file sample", symbol: "wand.and.stars.inverse", tint: .secondary, action: .witchSample, enabled: false),
        QuickAction(title: "Bunny", subtitle: "Vendor file sample", symbol: "hare.fill", tint: .secondary, action: .bunnySample, enabled: false),
    ]

    private let plannedFeatures: [QuickAction] = [
        QuickAction(title: "Battery", subtitle: "Native Mac telemetry", symbol: "battery.75", tint: .secondary, action: .bluetooth, enabled: false),
        QuickAction(title: "CPU / RAM", subtitle: "Live system card", symbol: "cpu", tint: .secondary, action: .bluetooth, enabled: false),
        QuickAction(title: "Net Speed", subtitle: "Upload / download", symbol: "arrow.up.arrow.down.circle", tint: .secondary, action: .bluetooth, enabled: false),
        QuickAction(title: "App Mirror", subtitle: "Focused app icon", symbol: "app.connected.to.app.below.fill", tint: .secondary, action: .bluetooth, enabled: false),
        QuickAction(title: "OpenClaw", subtitle: "Crab / thinking states", symbol: "ladybug.fill", tint: .secondary, action: .bluetooth, enabled: false),
        QuickAction(title: "Channel Sync", subtitle: "Official content import", symbol: "square.stack.3d.up.fill", tint: .secondary, action: .bluetooth, enabled: false),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.13),
                    Color(red: 0.08, green: 0.12, blue: 0.19),
                    Color(red: 0.05, green: 0.09, blue: 0.15),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    transportCard
                    section(title: "Quick Actions", caption: "Working now")
                    adaptiveGrid(quickActions)
                    section(title: "Native Roadmap", caption: "Visible product shape, not claimed as working")
                    adaptiveGrid(colorScenes)
                    section(title: "Roadmap", caption: "Planned next, not claimed as working")
                    adaptiveGrid(plannedFeatures)
                    footerCard
                }
                .padding(20)
            }
        }
        .frame(minWidth: 430, idealWidth: 460, maxWidth: 500, minHeight: 640, idealHeight: 700)
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            PixelHeroView()

            VStack(alignment: .leading, spacing: 8) {
                Text("Divoom D2 Pro Mac")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Native macOS control for the Ditoo Pro 16x16 RGB display")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                HStack(spacing: 8) {
                    StatusPill(title: "Direct BLE", tint: Color(red: 0.22, green: 0.86, blue: 0.48))
                    StatusPill(title: "16x16 RGB", tint: Color(red: 0.26, green: 0.64, blue: 1.0))
                    StatusPill(title: "Menu Bar", tint: Color(red: 1.0, green: 0.66, blue: 0.24))
                }
            }
            Spacer()
        }
        .padding(18)
        .background(cardBackground(primary: Color(red: 0.12, green: 0.17, blue: 0.29), secondary: Color(red: 0.07, green: 0.1, blue: 0.19)))
    }

    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live Status", systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("Auto \(state.autoRefresh)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text(state.lastStatus)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(state.transportSummary)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(cardBackground(primary: Color(red: 0.11, green: 0.14, blue: 0.21), secondary: Color(red: 0.08, green: 0.1, blue: 0.16)))
    }

    private func section(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(caption)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private func adaptiveGrid(_ actions: [QuickAction]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 122, maximum: 180), spacing: 12)], spacing: 12) {
            ForEach(actions) { item in
                ActionCard(item: item) {
                    if item.enabled {
                        runAction(item.action)
                    }
                }
            }
        }
    }

    private var footerCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Research and reverse engineering stay separate from product UI.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Working controls are enabled. Planned features stay visibly marked as planned.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button(action: openResearch) {
                Label("Notes", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.21, green: 0.55, blue: 1.0))
        }
        .padding(16)
        .background(cardBackground(primary: Color(red: 0.1, green: 0.12, blue: 0.18), secondary: Color(red: 0.07, green: 0.09, blue: 0.15)))
    }

    private func cardBackground(primary: Color, secondary: Color) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 14)
    }
}

private struct ActionCard: View {
    let item: QuickAction
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(item.tint.opacity(item.enabled ? 0.2 : 0.1))
                        .frame(width: 42, height: 42)
                    Image(systemName: item.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(item.enabled ? item.tint : .white.opacity(0.35))
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(item.enabled ? .white : .white.opacity(0.55))
                        if !item.enabled {
                            Text("Soon")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Text(item.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(item.enabled ? 0.66 : 0.42))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(item.enabled ? 0.08 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(item.enabled ? 0.08 : 0.04), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
    }
}

private struct StatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.2), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .foregroundStyle(tint)
    }
}

private struct PixelHeroView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.22, green: 0.55, blue: 1.0),
                            Color(red: 0.55, green: 0.35, blue: 1.0),
                            Color(red: 1.0, green: 0.46, blue: 0.32),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 96, height: 96)

            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 54, height: 38)
                    .overlay(
                        VStack(spacing: 3) {
                            HStack(spacing: 3) {
                                dot(.white)
                                dot(.mint)
                                dot(.white)
                            }
                            HStack(spacing: 3) {
                                dot(.pink)
                                dot(.cyan)
                                dot(.pink)
                            }
                        }
                    )

                HStack(spacing: 8) {
                    Circle().fill(.white.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(.white.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(.white.opacity(0.8)).frame(width: 8, height: 8)
                }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 7, height: 7)
    }
}
