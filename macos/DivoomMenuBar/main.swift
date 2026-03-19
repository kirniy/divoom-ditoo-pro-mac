import AVFoundation
import AppKit
import Darwin
import Foundation

enum AppLog {
    private static let logURL = URL(fileURLWithPath: "/Users/kirniy/Library/Logs/DivoomMenuBar.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        do {
            let directory = logURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logURL)
            }
        } catch {
            NSLog("DivoomMenuBar log write failed: \(error.localizedDescription)")
        }
    }
}

private enum AutoRefreshMode {
    case off
    case codex
    case claude

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

private struct CommandSpec {
    let label: String
    let arguments: [String]
}

private enum FeedbackSoundProfile: String {
    case attention
    case complete
    case colorSet
    case animation
    case error

    var fileName: String {
        switch self {
        case .attention:
            return "hover-sound-low.wav"
        case .complete:
            return "confirm-sound.wav"
        case .colorSet:
            return "confirm-sound.wav"
        case .animation:
            return "pause-sound.wav"
        case .error:
            return "cancel-sound-low.wav"
        }
    }

    var defaultVolume: Float {
        switch self {
        case .attention:
            return 0.10
        case .complete:
            return 0.13
        case .colorSet:
            return 0.12
        case .animation:
            return 0.14
        case .error:
            return 0.09
        }
    }
}

private enum StatusIconState {
    case idle
    case ok
    case error
}

private func makeMenuSymbol(_ symbolName: String, description: String) -> NSImage? {
    let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    return base?.withSymbolConfiguration(configuration)
}

private func makeStatusItemIcon(state: StatusIconState) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.isTemplate = true
    image.lockFocus()

    let frame = NSRect(x: 2, y: 1.5, width: 14, height: 15)
    let body = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
    NSColor.labelColor.withAlphaComponent(0.94).setStroke()
    body.lineWidth = 1.4
    body.stroke()

    let display = NSBezierPath(roundedRect: NSRect(x: 4.2, y: 8.1, width: 9.6, height: 5.1), xRadius: 1.8, yRadius: 1.8)
    NSColor.labelColor.withAlphaComponent(0.14).setFill()
    display.fill()

    for row in 0..<2 {
        for column in 0..<3 {
            let pixelRect = NSRect(
                x: 5.1 + CGFloat(column) * 2.75,
                y: 8.95 + CGFloat(row) * 1.95,
                width: 1.25,
                height: 1.25
            )
            let pixel = NSBezierPath(roundedRect: pixelRect, xRadius: 0.4, yRadius: 0.4)
            let alpha: CGFloat
            switch state {
            case .idle:
                alpha = 0.42
            case .ok:
                alpha = column == 1 ? 0.95 : 0.64
            case .error:
                alpha = row == 0 ? 0.95 : 0.56
            }
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            pixel.fill()
        }
    }

    let knobY = CGFloat(4.3)
    for knobX in [6.2, 9.0, 11.8] {
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: knobY, width: 1.15, height: 1.15))
        NSColor.labelColor.withAlphaComponent(0.72).setFill()
        knob.fill()
    }

    if state == .error {
        let alert = NSBezierPath(ovalIn: NSRect(x: 12.6, y: 12.3, width: 2.5, height: 2.5))
        NSColor.labelColor.setFill()
        alert.fill()
    }

    image.unlockFocus()
    return image
}

private final class MenuSummaryView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Ditoo Pro 16x16 RGB")
    private let connectionLabel = NSTextField(labelWithString: "Connection: scanning...")
    private let actionLabel = NSTextField(labelWithString: "Last action: idle")
    private let refreshLabel = NSTextField(labelWithString: "Automation: Off")

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 106)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(state: StatusIconState, connection: String, action: String, refresh: String) {
        iconView.image = makeStatusItemIcon(state: state)
        connectionLabel.stringValue = connection
        actionLabel.stringValue = action
        refreshLabel.stringValue = refresh
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = makeStatusItemIcon(state: .idle)
        iconView.imageScaling = .scaleNone

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        connectionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        connectionLabel.textColor = .secondaryLabelColor
        connectionLabel.lineBreakMode = .byTruncatingTail

        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        actionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        actionLabel.textColor = .labelColor
        actionLabel.lineBreakMode = .byTruncatingTail

        refreshLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshLabel.font = .systemFont(ofSize: 11, weight: .regular)
        refreshLabel.textColor = .secondaryLabelColor
        refreshLabel.lineBreakMode = .byTruncatingTail

        let headerStack = NSStackView(views: [titleLabel, connectionLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconView, headerStack])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [topRow, actionLabel, refreshLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
}

private final class ColorStudioView: NSView {
    var onSendColor: ((NSColor) -> Void)?
    var onPickScreen: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Solid Color Studio")
    private let captionLabel = NSTextField(labelWithString: "Wheel, hex, and screen pick.")
    private let colorWell = NSColorWell()
    private let hexField = NSTextField(string: "#FF0000")
    private let sendButton = NSButton(title: "Send Color", target: nil, action: nil)
    private let pickButton = NSButton(title: "Pick Screen", target: nil, action: nil)
    private let swatchHexes = ["#FF3B30", "#FF9500", "#FFD60A", "#30D158", "#64D2FF", "#0A84FF", "#BF5AF2", "#FF375F"]

    override var intrinsicContentSize: NSSize {
        NSSize(width: 356, height: 136)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setSelectedColor(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return
        }
        colorWell.color = rgb
        if let hex = hexString(for: rgb) {
            hexField.stringValue = hex
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.color = NSColor.systemRed
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)

        hexField.translatesAutoresizingMaskIntoConstraints = false
        hexField.placeholderString = "#247CFF"
        hexField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hexField.focusRingType = .none
        hexField.target = self
        hexField.action = #selector(hexSubmitted)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        pickButton.translatesAutoresizingMaskIntoConstraints = false
        pickButton.bezelStyle = .rounded
        pickButton.controlSize = .small
        pickButton.target = self
        pickButton.action = #selector(pickScreenPressed)
        pickButton.setContentHuggingPriority(.required, for: .horizontal)
        pickButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let swatchesRow = NSStackView()
        swatchesRow.orientation = .horizontal
        swatchesRow.alignment = .centerY
        swatchesRow.spacing = 7
        swatchesRow.translatesAutoresizingMaskIntoConstraints = false
        swatchHexes.forEach { hex in
            swatchesRow.addArrangedSubview(makeSwatchButton(hex: hex))
        }

        let controlsRow = NSStackView(views: [colorWell, hexField, sendButton, pickButton])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8
        controlsRow.distribution = .fill
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [titleLabel, captionLabel, swatchesRow, controlsRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 356),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            hexField.widthAnchor.constraint(equalToConstant: 98),
            sendButton.widthAnchor.constraint(equalToConstant: 92),
            pickButton.widthAnchor.constraint(equalToConstant: 104),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func makeSwatchButton(hex: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(swatchPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(rawValue: hex)
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        button.layer?.cornerCurve = .continuous
        button.layer?.borderWidth = 1
        button.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        if let (red, green, blue) = parseRGBHex(hex) {
            button.layer?.backgroundColor = NSColor(
                red: CGFloat(red) / 255.0,
                green: CGFloat(green) / 255.0,
                blue: CGFloat(blue) / 255.0,
                alpha: 1.0
            ).cgColor
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    @objc private func swatchPressed(_ sender: NSButton) {
        guard
            let hex = sender.identifier?.rawValue,
            let (red, green, blue) = parseRGBHex(hex)
        else {
            return
        }
        let color = NSColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1.0
        )
        setSelectedColor(color)
        onSendColor?(color)
    }

    @objc private func colorWellChanged() {
        setSelectedColor(colorWell.color)
        onSendColor?(colorWell.color)
    }

    @objc private func hexSubmitted() {
        sendCurrentHexColor()
    }

    @objc private func sendPressed() {
        sendCurrentHexColor()
    }

    @objc private func pickScreenPressed() {
        onPickScreen?()
    }

    private func sendCurrentHexColor() {
        guard
            let (red, green, blue) = parseRGBHex(hexField.stringValue)
        else {
            NSSound.beep()
            return
        }
        let color = NSColor(
            red: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: 1.0
        )
        setSelectedColor(color)
        onSendColor?(color)
    }
}

@MainActor
private protocol CommandRunnerDelegate: AnyObject {
    func commandDidFinish(label: String, success: Bool, output: String)
}

private final class CommandRunner {
    private let executableURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/bin/divoom-display")
    weak var delegate: CommandRunnerDelegate?

    func run(_ spec: CommandSpec) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = self?.executableURL
            process.arguments = spec.arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let combined = [stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")

                Task { @MainActor [weak self] in
                    self?.delegate?.commandDidFinish(
                        label: spec.label,
                        success: process.terminationStatus == 0,
                        output: combined
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.delegate?.commandDidFinish(
                        label: spec.label,
                        success: false,
                        output: error.localizedDescription
                    )
                }
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, CommandRunnerDelegate {
    private let runner = CommandRunner()
    private let bluetoothDiagnostics = BluetoothDiagnostics()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let summaryCard = MenuSummaryView(frame: NSRect(x: 0, y: 0, width: 320, height: 106))
    private let summaryCardItem = NSMenuItem()
    private let colorStudioView = ColorStudioView(frame: NSRect(x: 0, y: 0, width: 356, height: 136))
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var autoCodexItem = NSMenuItem()
    private var autoClaudeItem = NSMenuItem()
    private var timer: Timer?
    private var ipcTimer: Timer?
    private var ipcBusy = false
    private var autoRefreshMode: AutoRefreshMode = .off
    private var statusIconState: StatusIconState = .idle
    private var colorSampler: NSColorSampler?
    private var feedbackPlayer: AVAudioPlayer?
    private var connectionSummary = "Connection: scanning..."
    private var connectionDetails: String?
    private var lastActionSummary = "idle"
    private var lastActionDetails: String?
    private var lastActionSuccess = true
    private var lastActionDate: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner.delegate = self
        bluetoothDiagnostics.statusHandler = { [weak self] summary, details in
            self?.updateConnectionStatus(summary: summary, details: details)
        }
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        configureStatusItem()
        configureIPC()
        AppLog.write("applicationDidFinishLaunching")
        bluetoothDiagnostics.requestAccessAndScan()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        ipcTimer?.invalidate()
    }

    func commandDidFinish(label: String, success: Bool, output: String) {
        updateActionStatus(summary: label, success: success, details: output)
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = ""
            button.image = makeStatusItemIcon(state: statusIconState)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "Divoom Ditoo Pro 16x16 RGB display"
        }
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.removeAllItems()
        summaryCardItem.isEnabled = false
        summaryCardItem.view = summaryCard
        menu.addItem(summaryCardItem)
        menu.addItem(.separator())

        let connectionMenu = NSMenu(title: "Connection")
        connectionMenu.addItem(makeSectionHeader("Transport"))
        connectionMenu.addItem(makeItem("Request Bluetooth Access", action: #selector(requestBluetoothAccess), symbolName: "dot.radiowaves.left.and.right"))
        connectionMenu.addItem(makeItem("Run Bluetooth Diagnostics", action: #selector(runBluetoothDiagnostics), symbolName: "antenna.radiowaves.left.and.right"))
        connectionMenu.addItem(.separator())
        connectionMenu.addItem(makeSectionHeader("Device"))
        connectionMenu.addItem(makeItem("Probe Volume", action: #selector(runNativeVolumeProbe), symbolName: "speaker.wave.2"))

        let displayMenu = NSMenu(title: "Display")
        let colorStudioItem = NSMenuItem()
        colorStudioItem.isEnabled = false
        colorStudioItem.view = colorStudioView
        colorStudioView.onSendColor = { [weak self] color in
            self?.sendSelectedSceneColor(color, source: "Color studio")
        }
        colorStudioView.onPickScreen = { [weak self] in
            self?.pickScreenColor()
        }
        displayMenu.addItem(colorStudioItem)
        displayMenu.addItem(.separator())
        displayMenu.addItem(makeSectionHeader("Core"))
        displayMenu.addItem(makeItem("Solid Red", action: #selector(runNativeSolidRed), symbolName: "lightspectrum.horizontal"))
        displayMenu.addItem(makeItem("Purity Red", action: #selector(runNativePurityRed), symbolName: "flashlight.on.fill"))
        displayMenu.addItem(makeItem("Pixel Badge Test", action: #selector(runNativePixelTest), symbolName: "square.grid.3x3.fill"))
        displayMenu.addItem(.separator())
        displayMenu.addItem(makeSectionHeader("Telemetry"))
        displayMenu.addItem(makeItem("Battery Panel", action: #selector(runNativeBatteryStatus), symbolName: "battery.75"))
        displayMenu.addItem(makeItem("System Panel", action: #selector(runNativeSystemStatus), symbolName: "cpu"))
        displayMenu.addItem(makeItem("Network Panel", action: #selector(runNativeNetworkStatus), symbolName: "arrow.up.arrow.down.circle"))

        let motionMenu = NSMenu(title: "Motion")
        motionMenu.addItem(makeSectionHeader("Animations"))
        motionMenu.addItem(makeItem("Signal Sweep Loop", action: #selector(runNativeAnimationSample), symbolName: "sparkles"))
        motionMenu.addItem(makeItem("Doom Fire Loop", action: #selector(runNativeUploadDoomFire), symbolName: "flame.fill"))
        motionMenu.addItem(makeItem("Nyan Cat", action: #selector(runNativeUploadNyan), symbolName: "star"))
        motionMenu.addItem(makeItem("Bunny Hop", action: #selector(runNativeUploadBunny), symbolName: "hare"))
        motionMenu.addItem(.separator())
        motionMenu.addItem(makeSectionHeader("Ambient"))
        motionMenu.addItem(makeItem("Animated Monitor", action: #selector(runNativeAnimatedMonitor), symbolName: "waveform.path.ecg"))
        motionMenu.addItem(makeItem("Analog Clock", action: #selector(runNativeClockFace), symbolName: "clock"))
        motionMenu.addItem(makeItem("Animated Clock", action: #selector(runNativeAnimatedClock), symbolName: "clock.arrow.2.circlepath"))
        motionMenu.addItem(makeItem("Pomodoro Timer", action: #selector(runNativePomodoroTimer), symbolName: "timer"))

        let feedsMenu = NSMenu(title: "Feeds")
        feedsMenu.addItem(makeSectionHeader("Status"))
        feedsMenu.addItem(makeItem("Codex Status", action: #selector(pushCodexStatus), symbolName: "brain"))
        feedsMenu.addItem(makeItem("Claude Status", action: #selector(pushClaudeStatus), symbolName: "message"))
        feedsMenu.addItem(.separator())
        feedsMenu.addItem(makeSectionHeader("Samples"))
        feedsMenu.addItem(makeItem("Orbit Art", action: #selector(pushOrbitArt), symbolName: "sparkles.square.filled.on.square"))
        feedsMenu.addItem(makeItem("Doom Fire Sample", action: #selector(pushDoomFireSample), symbolName: "flame.fill"))
        feedsMenu.addItem(makeItem("Bunny Sample", action: #selector(pushBunnySample), symbolName: "hare"))

        let audioMenu = NSMenu(title: "Audio")
        audioMenu.addItem(makeSectionHeader("Speaker"))
        audioMenu.addItem(makeItem("Attention Chime", action: #selector(playAttentionSound), symbolName: "bell.badge"))
        audioMenu.addItem(makeItem("Completion Chime", action: #selector(playCompletionSound), symbolName: "checkmark.circle"))

        let automationMenu = NSMenu(title: "Automation")
        automationMenu.addItem(makeSectionHeader("Auto Refresh"))
        autoCodexItem = makeItem("Codex Every 60s", action: #selector(toggleAutoCodex), symbolName: "arrow.clockwise")
        autoClaudeItem = makeItem("Claude Every 60s", action: #selector(toggleAutoClaude), symbolName: "arrow.clockwise.circle")
        automationMenu.addItem(autoCodexItem)
        automationMenu.addItem(autoClaudeItem)

        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(makeSectionHeader("Workspace"))
        toolsMenu.addItem(makeItem("Open Research Notes", action: #selector(openResearch), symbolName: "doc.text.magnifyingglass"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(makeSectionHeader("App"))
        toolsMenu.addItem(makeItem("Quit", action: #selector(quitApp), keyEquivalent: "q", symbolName: "power"))

        menu.addItem(makeSubmenuItem("Connection", symbolName: "dot.radiowaves.left.and.right", submenu: connectionMenu))
        menu.addItem(makeSubmenuItem("Display", symbolName: "lightspectrum.horizontal", submenu: displayMenu))
        menu.addItem(makeSubmenuItem("Motion", symbolName: "sparkles", submenu: motionMenu))
        menu.addItem(makeSubmenuItem("Feeds", symbolName: "brain", submenu: feedsMenu))
        menu.addItem(makeSubmenuItem("Audio", symbolName: "speaker.wave.2.fill", submenu: audioMenu))
        menu.addItem(makeSubmenuItem("Automation", symbolName: "arrow.trianglehead.2.clockwise.rotate.90", submenu: automationMenu))
        menu.addItem(.separator())
        menu.addItem(makeSubmenuItem("Tools", symbolName: "slider.horizontal.3", submenu: toolsMenu))
        updateAutoRefreshUI()
        refreshSummaryCard()
    }

    private func configureIPC() {
        ensureIPCDirectories()
        ipcTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainIPCQueue()
            }
        }
        ipcTimer?.tolerance = 0.12
    }

    private func makeItem(_ title: String, action: Selector, keyEquivalent: String = "", symbolName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbolName {
            item.image = makeMenuSymbol(symbolName, description: title)
        }
        return item
    }

    private func makeSubmenuItem(_ title: String, symbolName: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = makeMenuSymbol(symbolName, description: title)
        item.submenu = submenu
        return item
    }

    private func makeSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ]
        )
        return item
    }

    private func run(label: String, arguments: [String]) {
        runner.run(CommandSpec(label: label, arguments: arguments))
    }

    private func feedbackSoundURL(for profile: FeedbackSoundProfile) -> URL {
        URL(fileURLWithPath: "/Users/kirniy/dev/divoom/assets/sounds/openpeon-cute-minimal/\(profile.fileName)")
    }

    private func playFeedbackSound(_ profile: FeedbackSoundProfile) {
        let url = feedbackSoundURL(for: profile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLog.write("playFeedbackSound missing path=\(url.path)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = profile.defaultVolume
            player.prepareToPlay()
            player.play()
            feedbackPlayer = player
            AppLog.write("playFeedbackSound profile=\(profile.rawValue) volume=\(profile.defaultVolume) path=\(url.path)")
        } catch {
            AppLog.write("playFeedbackSound failed profile=\(profile.rawValue) error=\(error.localizedDescription)")
        }
    }

    private func handleNativeActionResult(
        _ result: NativeActionResult,
        summary: String? = nil,
        successSound: FeedbackSoundProfile? = nil
    ) {
        let resolvedSummary = summary ?? result.summary
        updateActionStatus(summary: resolvedSummary, success: result.success, details: result.details)
        if result.success {
            if let successSound {
                playFeedbackSound(successSound)
            }
        } else {
            playFeedbackSound(.error)
        }
    }

    private func updateActionStatus(summary: String, success: Bool, details: String?) {
        let prefix = success ? "OK" : "ERR"
        let time = timestampFormatter.string(from: Date())
        lastActionSummary = summary
        lastActionSuccess = success
        lastActionDetails = details
        lastActionDate = Date()
        let detailText = details?.isEmpty == false ? details! : "(no details)"
        AppLog.write("\(prefix) \(summary)\n\(detailText)")
        statusIconState = success ? .ok : .error
        refreshSummaryCard()
        updateStatusItemButton(summary: "\(prefix) \(summary) at \(time)", details: details)
    }

    private func updateConnectionStatus(summary: String, details: String?) {
        connectionSummary = summary
        connectionDetails = details
        if lastActionDate == nil {
            if summary.localizedCaseInsensitiveContains("denied")
                || summary.localizedCaseInsensitiveContains("not granted")
                || summary.localizedCaseInsensitiveContains("failed")
            {
                statusIconState = .error
            } else if summary.localizedCaseInsensitiveContains("ready")
                || summary.localizedCaseInsensitiveContains("finished")
                || summary.localizedCaseInsensitiveContains("powered on")
            {
                statusIconState = .ok
            }
        }
        refreshSummaryCard()
        updateStatusItemButton(summary: summary, details: details)
    }

    private func refreshSummaryCard() {
        let actionPrefix = lastActionSuccess ? "OK" : "ERR"
        let actionText: String
        if let lastActionDate {
            actionText = "Last action: \(actionPrefix) \(lastActionSummary) at \(timestampFormatter.string(from: lastActionDate))"
        } else {
            actionText = "Last action: idle"
        }
        summaryCard.update(
            state: statusIconState,
            connection: connectionSummary,
            action: actionText,
            refresh: "Automation: \(autoRefreshDescription())"
        )
    }

    private func updateStatusItemButton(summary: String, details: String?) {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.image = makeStatusItemIcon(state: statusIconState)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        let detailLine = details?.isEmpty == false ? details! : summary
        let tooltip = [
            "Ditoo Pro 16x16 RGB",
            connectionSummary,
            detailLine,
        ].joined(separator: "\n")
        button.toolTip = tooltip
    }

    private func setAutoRefreshMode(_ mode: AutoRefreshMode) {
        autoRefreshMode = mode
        timer?.invalidate()
        timer = nil

        guard mode != .off else {
            updateAutoRefreshUI()
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.autoRefreshMode {
                case .codex:
                    self.pushCodexStatus()
                case .claude:
                    self.pushClaudeStatus()
                case .off:
                    break
                }
            }
        }

        updateAutoRefreshUI()
    }

    private func updateAutoRefreshUI() {
        autoCodexItem.state = autoRefreshMode == .codex ? .on : .off
        autoClaudeItem.state = autoRefreshMode == .claude ? .on : .off
        refreshSummaryCard()
    }

    private func autoRefreshDescription() -> String {
        switch autoRefreshMode {
        case .off:
            return "Off"
        case .codex:
            return "Codex every 60s"
        case .claude:
            return "Claude every 60s"
        }
    }

    private func drainIPCQueue() {
        guard !ipcBusy else {
            return
        }

        ensureIPCDirectories()
        let requestURLs = (try? FileManager.default.contentsOfDirectory(
            at: ipcRequestsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let pending = requestURLs
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if leftDate == rightDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return leftDate < rightDate
            }

        guard let requestURL = pending.first else {
            return
        }

        ipcBusy = true
        handleIPCRequest(at: requestURL)
    }

    private func handleIPCRequest(at requestURL: URL) {
        let processingURL = requestURL.deletingPathExtension().appendingPathExtension("processing")

        do {
            if FileManager.default.fileExists(atPath: processingURL.path) {
                try FileManager.default.removeItem(at: processingURL)
            }
            try FileManager.default.moveItem(at: requestURL, to: processingURL)

            let data = try Data(contentsOf: processingURL)
            let request = try JSONDecoder().decode(IPCRequestPayload.self, from: data)
            guard let mode = HeadlessMode(rawValue: request.mode) else {
                writeIPCResult(
                    IPCResultPayload(
                        id: request.id,
                        success: false,
                        exitCode: 2,
                        summary: "IPC action failed",
                        details: "Unknown mode: \(request.mode)",
                        finishedAt: ISO8601DateFormatter().string(from: Date())
                    )
                )
                try? FileManager.default.removeItem(at: processingURL)
                ipcBusy = false
                return
            }

            let invocation = HeadlessInvocation(mode: mode, parameter: request.parameter)
            AppLog.write("IPC request id=\(request.id) mode=\(request.mode) parameter=\(request.parameter ?? "<nil>")")

            performIPCInvocation(invocation) { [weak self] result in
                guard let self else { return }
                self.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
                self.writeIPCResult(
                    IPCResultPayload(
                        id: request.id,
                        success: result.success,
                        exitCode: result.success ? 0 : 1,
                        summary: result.summary,
                        details: result.details,
                        finishedAt: ISO8601DateFormatter().string(from: Date())
                    )
                )
                try? FileManager.default.removeItem(at: processingURL)
                self.ipcBusy = false
            }
        } catch {
            AppLog.write("IPC handling failed \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: processingURL)
            ipcBusy = false
        }
    }

    private func performIPCInvocation(_ invocation: HeadlessInvocation, completion: @escaping (NativeActionResult) -> Void) {
        switch invocation.mode {
        case .diagnostics:
            bluetoothDiagnostics.refreshStatus(reason: "IPC diagnostics")
            completion(
                NativeActionResult(
                    success: true,
                    summary: "IPC diagnostics complete",
                    details: "Bluetooth diagnostics refresh triggered from the running Divoom Menu Bar app."
                )
            )
        case .nativeProbe:
            bluetoothDiagnostics.runNativeVolumeProbe(completion: completion)
        case .nativeSolidRed:
            bluetoothDiagnostics.runNativeSolidRed(completion: completion)
        case .nativeSceneColor:
            guard
                let parameter = invocation.parameter,
                let (red, green, blue) = parseRGBHex(parameter)
            else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "IPC scene color failed",
                        details: "Expected RRGGBB or #RRGGBB for scene color."
                    )
                )
                return
            }
            bluetoothDiagnostics.runNativeBLESolidColor(
                red: red,
                green: green,
                blue: blue,
                brightness: 0x64,
                threeModeType: 0x00,
                completion: completion
            )
        case .nativePurityRed:
            bluetoothDiagnostics.runNativeBLEPurityRed(completion: completion)
        case .nativePurityColor:
            guard
                let parameter = invocation.parameter,
                let (red, green, blue) = parseRGBHex(parameter)
            else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "IPC purity color failed",
                        details: "Expected RRGGBB or #RRGGBB for purity color."
                    )
                )
                return
            }
            bluetoothDiagnostics.runNativeBLEPurityColor(red: red, green: green, blue: blue, completion: completion)
        case .nativeLightMode:
            guard let parameter = invocation.parameter, let rawValue = UInt8(parameter) else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "IPC light mode failed",
                        details: "Expected a mode byte between 0 and 255."
                    )
                )
                return
            }
            bluetoothDiagnostics.runNativeBLESolidColor(
                red: 0xff,
                green: 0x00,
                blue: 0x00,
                brightness: 0x64,
                threeModeType: rawValue,
                completion: completion
            )
        case .nativePixelTest:
            bluetoothDiagnostics.runNativeBLEPixelBadgeTest(completion: completion)
        case .nativeBatteryStatus:
            bluetoothDiagnostics.runNativeBLEBatteryStatus(completion: completion)
        case .nativeSystemStatus:
            bluetoothDiagnostics.runNativeBLESystemStatus(completion: completion)
        case .nativeNetworkStatus:
            bluetoothDiagnostics.runNativeBLENetworkStatus(completion: completion)
        case .nativeAnimationSample:
            bluetoothDiagnostics.runNativeBLEObviousAnimationSample(completion: completion)
        case .nativeSample:
            bluetoothDiagnostics.runNativeBLEAnimationSample(completion: completion)
        case .nativeAnimationUpload:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "IPC animation upload failed",
                        details: "Expected a file path parameter for animation upload."
                    )
                )
                return
            }
            bluetoothDiagnostics.runNativeBLEDivoom16Animation(
                path: parameter,
                label: "ipc-animation-upload",
                completion: completion
            )
        case .nativeAnimatedMonitor:
            bluetoothDiagnostics.runNativeBLEAnimatedSystemMonitor(completion: completion)
        case .nativeClockFace:
            bluetoothDiagnostics.runNativeBLEClockFace(completion: completion)
        case .nativeAnimatedClock:
            bluetoothDiagnostics.runNativeBLEAnimatedClockFace(completion: completion)
        case .nativePomodoroTimer:
            let minutes = Int(invocation.parameter ?? "25") ?? 25
            bluetoothDiagnostics.runNativeBLEPomodoroTimer(minutes: minutes, completion: completion)
        case .nativeSendGIF:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                completion(NativeActionResult(
                    success: false,
                    summary: "IPC send-gif failed",
                    details: "Expected a .divoom16 file path parameter."
                ))
                return
            }
            bluetoothDiagnostics.runNativeBLESendGIF(path: parameter, completion: completion)
        case .nativeAnimationVerify:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                completion(NativeActionResult(
                    success: false,
                    summary: "IPC animation-verify failed",
                    details: "Expected a .divoom16 file path parameter."
                ))
                return
            }
            bluetoothDiagnostics.runNativeBLEAnimationVerify(path: parameter, completion: completion)
        case .nativeAnimationUploadOldMode:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                completion(NativeActionResult(
                    success: false,
                    summary: "IPC animation-upload-oldmode failed",
                    details: "Expected a .divoom16 file path parameter."
                ))
                return
            }
            bluetoothDiagnostics.runNativeBLEAnimationUploadOldMode(path: parameter, completion: completion)
        }
    }

    private func writeIPCResult(_ result: IPCResultPayload) {
        ensureIPCDirectories()
        let resultURL = ipcResultsURL.appendingPathComponent("\(result.id).json")
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: resultURL, options: .atomic)
        } catch {
            AppLog.write("writeIPCResult failed \(error.localizedDescription)")
        }
    }

    @objc private func pushCodexStatus() {
        run(label: "Codex status", arguments: ["send-status", "--provider", "codex", "--terminate"])
    }

    @objc private func pushClaudeStatus() {
        run(label: "Claude status", arguments: ["send-status", "--provider", "claude", "--terminate"])
    }

    @objc private func pushOrbitArt() {
        run(label: "Orbit art", arguments: ["send-art", "--style", "orbit", "--seed", "17", "--terminate"])
    }

    @objc private func pushDoomFireSample() {
        run(
            label: "Doom Fire sample",
            arguments: [
                "send-divoom16",
                "/Users/kirniy/dev/divoom/assets/16x16/generated/doom_fire.divoom16",
                "--terminate",
            ]
        )
    }

    @objc private func pushBunnySample() {
        run(
            label: "Bunny sample",
            arguments: [
                "send-divoom16",
                "/Users/kirniy/dev/divoom/andreas-js/images/bunny.divoom16",
                "--terminate",
            ]
        )
    }

    @objc private func playAttentionSound() {
        run(label: "Attention sound", arguments: ["play-sound", "--profile", "attention"])
    }

    @objc private func playCompletionSound() {
        run(label: "Completion sound", arguments: ["play-sound", "--profile", "complete"])
    }

    @objc private func requestBluetoothAccess() {
        bluetoothDiagnostics.requestAccessAndScan()
    }

    @objc private func runBluetoothDiagnostics() {
        bluetoothDiagnostics.refreshStatus(reason: "Manual Bluetooth diagnostics")
    }

    @objc private func runNativeVolumeProbe() {
        bluetoothDiagnostics.runNativeVolumeProbe { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeSolidRed() {
        bluetoothDiagnostics.runNativeSolidRed { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, successSound: .colorSet)
            }
        }
    }

    @objc private func runNativePurityRed() {
        bluetoothDiagnostics.runNativeBLEPurityRed { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, successSound: .colorSet)
            }
        }
    }

    @objc private func runNativePixelTest() {
        bluetoothDiagnostics.runNativeBLEPixelBadgeTest { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeBatteryStatus() {
        bluetoothDiagnostics.runNativeBLEBatteryStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeSystemStatus() {
        bluetoothDiagnostics.runNativeBLESystemStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeNetworkStatus() {
        bluetoothDiagnostics.runNativeBLENetworkStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeAnimationSample() {
        bluetoothDiagnostics.runNativeBLEObviousAnimationSample { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Signal Sweep Loop", successSound: .animation)
            }
        }
    }

    @objc private func runNativeUploadDoomFire() {
        bluetoothDiagnostics.runNativeBLESendGIF(
            path: "/Users/kirniy/dev/divoom/assets/16x16/generated/menu_fire.divoom16",
            loopCount: 0
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Doom Fire Loop", successSound: .animation)
            }
        }
    }

    @objc private func runNativeUploadNyan() {
        bluetoothDiagnostics.runNativeBLESendGIF(
            path: "/Users/kirniy/dev/divoom/assets/16x16/generated/menu_nyan.divoom16",
            loopCount: 0
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Nyan Cat", successSound: .animation)
            }
        }
    }

    @objc private func runNativeUploadBunny() {
        bluetoothDiagnostics.runNativeBLESendGIF(
            path: "/Users/kirniy/dev/divoom/assets/16x16/generated/menu_bunny.divoom16",
            loopCount: 0
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Bunny Hop", successSound: .animation)
            }
        }
    }

    @objc private func runNativeAnimatedMonitor() {
        bluetoothDiagnostics.runNativeBLEAnimatedSystemMonitor { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, successSound: .animation)
            }
        }
    }

    @objc private func runNativeClockFace() {
        bluetoothDiagnostics.runNativeBLEClockFace { [weak self] result in
            DispatchQueue.main.async {
                self?.updateActionStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeAnimatedClock() {
        bluetoothDiagnostics.runNativeBLEAnimatedClockFace { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, successSound: .animation)
            }
        }
    }

    @objc private func runNativePomodoroTimer() {
        bluetoothDiagnostics.runNativeBLEPomodoroTimer { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, successSound: .animation)
            }
        }
    }

    private func sendSelectedSceneColor(_ color: NSColor, source: String) {
        guard
            let rgbColor = color.usingColorSpace(.deviceRGB),
            let (red, green, blue) = rgbComponents(from: rgbColor)
        else {
            updateActionStatus(
                summary: "Solid color failed",
                success: false,
                details: "Could not convert the selected color into RGB components."
            )
            return
        }

        let colorHex = hexString(for: rgbColor) ?? "#000000"
        bluetoothDiagnostics.runNativeBLESolidColor(
            red: red,
            green: green,
            blue: blue,
            brightness: 0x64,
            threeModeType: 0x00
        ) { [weak self] result in
            DispatchQueue.main.async {
                let details = [result.details, "source=\(source)", "hex=\(colorHex)"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                self?.updateActionStatus(
                    summary: "Solid color \(colorHex)",
                    success: result.success,
                    details: details
                )
                if result.success {
                    self?.playFeedbackSound(.colorSet)
                } else {
                    self?.playFeedbackSound(.error)
                }
            }
        }
    }

    private func pickScreenColor() {
        NSApp.activate(ignoringOtherApps: true)
        let sampler = NSColorSampler()
        colorSampler = sampler
        sampler.show { [weak self] color in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.colorSampler = nil
                guard let color else {
                    self.updateActionStatus(
                        summary: "Screen color picker cancelled",
                        success: true,
                        details: "No screen color was selected."
                    )
                    return
                }
                self.colorStudioView.setSelectedColor(color)
                self.sendSelectedSceneColor(color, source: "Screen sampler")
            }
        }
    }

    @objc private func toggleAutoCodex() {
        setAutoRefreshMode(autoRefreshMode == .codex ? .off : .codex)
    }

    @objc private func toggleAutoClaude() {
        setAutoRefreshMode(autoRefreshMode == .claude ? .off : .claude)
    }

    @objc private func openResearch() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/kirniy/dev/divoom/RESEARCH.md"))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private enum HeadlessMode: String {
    case diagnostics = "--headless-diagnostics"
    case nativeProbe = "--headless-native-probe"
    case nativeSolidRed = "--headless-native-solid-red"
    case nativeSceneColor = "--headless-native-scene-color"
    case nativePurityRed = "--headless-native-purity-red"
    case nativePurityColor = "--headless-native-purity-color"
    case nativeLightMode = "--headless-native-light-mode"
    case nativePixelTest = "--headless-native-pixel-test"
    case nativeBatteryStatus = "--headless-native-battery-status"
    case nativeSystemStatus = "--headless-native-system-status"
    case nativeNetworkStatus = "--headless-native-network-status"
    case nativeAnimationSample = "--headless-native-animation-sample"
    case nativeSample = "--headless-native-sample"
    case nativeAnimationUpload = "--headless-native-animation-upload"
    case nativeAnimatedMonitor = "--headless-native-animated-monitor"
    case nativeClockFace = "--headless-native-clock-face"
    case nativeAnimatedClock = "--headless-native-animated-clock"
    case nativePomodoroTimer = "--headless-native-pomodoro-timer"
    case nativeSendGIF = "--headless-native-send-gif"
    case nativeAnimationVerify = "--headless-native-animation-verify"
    case nativeAnimationUploadOldMode = "--headless-native-animation-upload-oldmode"
}

private struct HeadlessInvocation {
    let mode: HeadlessMode
    let parameter: String?

    static func from(arguments: [String]) -> HeadlessInvocation? {
        guard
            let first = arguments.first,
            let mode = HeadlessMode(rawValue: first)
        else {
            return nil
        }
        return HeadlessInvocation(mode: mode, parameter: arguments.dropFirst().first)
    }
}

private let ipcRootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("divoom-menubar-ipc", isDirectory: true)
private let ipcRequestsURL = ipcRootURL.appendingPathComponent("requests", isDirectory: true)
private let ipcResultsURL = ipcRootURL.appendingPathComponent("results", isDirectory: true)

private struct IPCRequestPayload: Codable {
    let id: String
    let mode: String
    let parameter: String?
    let createdAt: String
}

private struct IPCResultPayload: Codable {
    let id: String
    let success: Bool
    let exitCode: Int32
    let summary: String
    let details: String
    let finishedAt: String
}

private func ensureIPCDirectories() {
    try? FileManager.default.createDirectory(at: ipcRequestsURL, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: ipcResultsURL, withIntermediateDirectories: true)
}

private func parseRGBHex(_ value: String) -> (UInt8, UInt8, UInt8)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard hex.count == 6, let packed = UInt32(hex, radix: 16) else {
        return nil
    }
    let red = UInt8((packed >> 16) & 0xff)
    let green = UInt8((packed >> 8) & 0xff)
    let blue = UInt8(packed & 0xff)
    return (red, green, blue)
}

private func rgbComponents(from color: NSColor) -> (UInt8, UInt8, UInt8)? {
    guard let rgb = color.usingColorSpace(.deviceRGB) else {
        return nil
    }
    let red = UInt8(max(0, min(255, Int(round(rgb.redComponent * 255.0)))))
    let green = UInt8(max(0, min(255, Int(round(rgb.greenComponent * 255.0)))))
    let blue = UInt8(max(0, min(255, Int(round(rgb.blueComponent * 255.0)))))
    return (red, green, blue)
}

private func hexString(for color: NSColor) -> String? {
    guard let (red, green, blue) = rgbComponents(from: color) else {
        return nil
    }
    return String(format: "#%02X%02X%02X", red, green, blue)
}

private final class HeadlessRunner {
    private let bluetoothDiagnostics = BluetoothDiagnostics()
    private let invocation: HeadlessInvocation
    private var exitCode: Int32 = 0
    private var finished = false

    init(invocation: HeadlessInvocation) {
        self.invocation = invocation
    }

    func start() {
        AppLog.write("HeadlessRunner.start mode=\(invocation.mode.rawValue) parameter=\(invocation.parameter ?? "<nil>")")
        bluetoothDiagnostics.statusHandler = { summary, details in
            let output = [summary, details].compactMap { $0 }.joined(separator: "\n")
            FileHandle.standardOutput.write(Data((output + "\n").utf8))
            AppLog.write("HeadlessRunner.status\n\(output)")
        }

        bluetoothDiagnostics.requestAccessAndScan()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 14) { [weak self] in
            self?.runAction()
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 32) { [weak self] in
            self?.finish(code: 2, message: "HeadlessRunner timeout")
        }
    }

    func runLoop() -> Never {
        RunLoop.main.run()
        fatalError("RunLoop.main.run() unexpectedly returned")
    }

    private func runAction() {
        AppLog.write("HeadlessRunner.runAction mode=\(invocation.mode.rawValue) parameter=\(invocation.parameter ?? "<nil>")")
        switch invocation.mode {
        case .diagnostics:
            bluetoothDiagnostics.refreshStatus(reason: "Headless diagnostics")
            finish(code: 0, message: "Headless diagnostics complete")
        case .nativeProbe:
            bluetoothDiagnostics.runNativeVolumeProbe { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeSolidRed:
            bluetoothDiagnostics.runNativeSolidRed { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeSceneColor:
            guard
                let parameter = invocation.parameter,
                let (red, green, blue) = parseRGBHex(parameter)
            else {
                finish(code: 2, message: "Expected RRGGBB or #RRGGBB after --headless-native-scene-color")
                return
            }
            bluetoothDiagnostics.runNativeBLESolidColor(
                red: red,
                green: green,
                blue: blue,
                brightness: 0x64,
                threeModeType: 0x00
            ) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativePurityRed:
            bluetoothDiagnostics.runNativeBLEPurityRed { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativePurityColor:
            guard
                let parameter = invocation.parameter,
                let (red, green, blue) = parseRGBHex(parameter)
            else {
                finish(code: 2, message: "Expected RRGGBB or #RRGGBB after --headless-native-purity-color")
                return
            }
            bluetoothDiagnostics.runNativeBLEPurityColor(
                red: red,
                green: green,
                blue: blue
            ) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeLightMode:
            guard
                let parameter = invocation.parameter,
                let rawValue = UInt8(parameter)
            else {
                finish(code: 2, message: "Expected mode byte 0-255 after --headless-native-light-mode")
                return
            }
            bluetoothDiagnostics.runNativeBLESolidColor(
                red: 0xff,
                green: 0x00,
                blue: 0x00,
                brightness: 0x64,
                threeModeType: rawValue
            ) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativePixelTest:
            bluetoothDiagnostics.runNativeBLEPixelBadgeTest { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeBatteryStatus:
            bluetoothDiagnostics.runNativeBLEBatteryStatus { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeSystemStatus:
            bluetoothDiagnostics.runNativeBLESystemStatus { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeNetworkStatus:
            bluetoothDiagnostics.runNativeBLENetworkStatus { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimationSample:
            bluetoothDiagnostics.runNativeBLEObviousAnimationSample { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeSample:
            bluetoothDiagnostics.runNativeBLEAnimationSample { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimationUpload:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                finish(code: 2, message: "Expected a file path after --headless-native-animation-upload")
                return
            }
            bluetoothDiagnostics.runNativeBLEDivoom16Animation(
                path: parameter,
                label: "headless-animation-upload"
            ) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimatedMonitor:
            bluetoothDiagnostics.runNativeBLEAnimatedSystemMonitor { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeClockFace:
            bluetoothDiagnostics.runNativeBLEClockFace { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimatedClock:
            bluetoothDiagnostics.runNativeBLEAnimatedClockFace { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativePomodoroTimer:
            let minutes = Int(invocation.parameter ?? "25") ?? 25
            bluetoothDiagnostics.runNativeBLEPomodoroTimer(minutes: minutes) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeSendGIF:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                finish(code: 2, message: "Expected a .divoom16 file path after --headless-native-send-gif")
                return
            }
            bluetoothDiagnostics.runNativeBLESendGIF(path: parameter) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimationVerify:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                finish(code: 2, message: "Expected a .divoom16 file path after --headless-native-animation-verify")
                return
            }
            bluetoothDiagnostics.runNativeBLEAnimationVerify(path: parameter) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeAnimationUploadOldMode:
            guard let parameter = invocation.parameter, !parameter.isEmpty else {
                finish(code: 2, message: "Expected a .divoom16 file path after --headless-native-animation-upload-oldmode")
                return
            }
            bluetoothDiagnostics.runNativeBLEAnimationUploadOldMode(path: parameter) { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        }
    }

    private func format(_ result: NativeActionResult) -> String {
        [result.summary, result.details].joined(separator: "\n")
    }

    private func finish(code: Int32, message: String) {
        guard !finished else {
            return
        }
        finished = true
        exitCode = code
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
        AppLog.write("HeadlessRunner.finish code=\(code)\n\(message)")
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
            exit(self.exitCode)
        }
    }
}

@main
private struct DivoomMenuBarApp {
    static func main() {
        if let invocation = HeadlessInvocation.from(arguments: Array(CommandLine.arguments.dropFirst())) {
            let runner = HeadlessRunner(invocation: invocation)
            runner.start()
            runner.runLoop()
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
