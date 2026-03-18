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
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var statusLine = NSMenuItem(title: "Last action: idle", action: nil, keyEquivalent: "")
    private var refreshLine = NSMenuItem(title: "Auto refresh: Off", action: nil, keyEquivalent: "")
    private var autoCodexItem = NSMenuItem()
    private var autoClaudeItem = NSMenuItem()
    private var timer: Timer?
    private var ipcTimer: Timer?
    private var ipcBusy = false
    private var autoRefreshMode: AutoRefreshMode = .off
    private var statusIconState: StatusIconState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        runner.delegate = self
        bluetoothDiagnostics.statusHandler = { [weak self] summary, details in
            self?.updateStatus(summary: summary, success: true, details: details)
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
        updateStatus(summary: label, success: success, details: output)
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
        let titleLine = NSMenuItem(title: "Ditoo Pro 16x16 RGB", action: nil, keyEquivalent: "")
        titleLine.isEnabled = false
        statusLine.isEnabled = false
        refreshLine.isEnabled = false

        menu.addItem(titleLine)
        menu.addItem(statusLine)
        menu.addItem(refreshLine)
        menu.addItem(.separator())

        menu.addItem(makeItem("Request Bluetooth Access", action: #selector(requestBluetoothAccess), symbolName: "dot.radiowaves.left.and.right"))
        menu.addItem(makeItem("Run Bluetooth Diagnostics", action: #selector(runBluetoothDiagnostics), symbolName: "antenna.radiowaves.left.and.right"))
        menu.addItem(makeItem("Native Probe Volume", action: #selector(runNativeVolumeProbe), symbolName: "speaker.wave.2"))
        menu.addItem(makeItem("Native Send Solid Red", action: #selector(runNativeSolidRed), symbolName: "lightspectrum.horizontal"))
        menu.addItem(makeItem("Native Send Purity Red", action: #selector(runNativePurityRed), symbolName: "flashlight.on.fill"))
        menu.addItem(makeItem("Native Send Pixel Test", action: #selector(runNativePixelTest), symbolName: "square.grid.3x3.fill"))
        menu.addItem(makeItem("Native Show Battery", action: #selector(runNativeBatteryStatus), symbolName: "battery.75"))
        menu.addItem(makeItem("Native Show System", action: #selector(runNativeSystemStatus), symbolName: "cpu"))
        menu.addItem(makeItem("Native Show Network", action: #selector(runNativeNetworkStatus), symbolName: "arrow.up.arrow.down.circle"))
        menu.addItem(makeItem("Native Send Signal Animation", action: #selector(runNativeAnimationSample), symbolName: "sparkles"))
        menu.addItem(.separator())

        menu.addItem(makeItem("Push Codex Status", action: #selector(pushCodexStatus), symbolName: "brain"))
        menu.addItem(makeItem("Push Claude Status", action: #selector(pushClaudeStatus), symbolName: "message"))
        menu.addItem(makeItem("Push Orbit Art", action: #selector(pushOrbitArt), symbolName: "sparkles.square.filled.on.square"))
        menu.addItem(makeItem("Push Witch Sample", action: #selector(pushWitchSample), symbolName: "wand.and.stars"))
        menu.addItem(makeItem("Push Bunny Sample", action: #selector(pushBunnySample), symbolName: "hare"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Play Attention Sound", action: #selector(playAttentionSound), symbolName: "bell.badge"))
        menu.addItem(makeItem("Play Completion Sound", action: #selector(playCompletionSound), symbolName: "checkmark.circle"))
        menu.addItem(.separator())

        autoCodexItem = makeItem("Auto Refresh Codex (60s)", action: #selector(toggleAutoCodex), symbolName: "arrow.clockwise")
        autoClaudeItem = makeItem("Auto Refresh Claude (60s)", action: #selector(toggleAutoClaude), symbolName: "arrow.clockwise.circle")
        menu.addItem(autoCodexItem)
        menu.addItem(autoClaudeItem)
        updateAutoRefreshUI()

        menu.addItem(.separator())
        menu.addItem(makeItem("Open Research Notes", action: #selector(openResearch), symbolName: "doc.text.magnifyingglass"))
        menu.addItem(makeItem("Quit", action: #selector(quitApp), keyEquivalent: "q", symbolName: "power"))
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

    private func run(label: String, arguments: [String]) {
        runner.run(CommandSpec(label: label, arguments: arguments))
    }

    private func updateStatus(summary: String, success: Bool, details: String?) {
        let prefix = success ? "OK" : "ERR"
        let time = timestampFormatter.string(from: Date())
        statusLine.title = "Last action: \(prefix) \(summary) at \(time)"
        let detailText = details?.isEmpty == false ? details! : "(no details)"
        AppLog.write("\(prefix) \(summary)\n\(detailText)")
        statusIconState = success ? .ok : .error
        updateStatusItemButton(summary: summary, details: details)
    }

    private func updateStatusItemButton(summary: String, details: String?) {
        guard let button = statusItem.button else {
            return
        }
        button.title = ""
        button.image = makeStatusItemIcon(state: statusIconState)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = details?.isEmpty == false ? details : summary
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
        refreshLine.title = "Auto refresh: \(autoRefreshMode.title)"
        autoCodexItem.state = autoRefreshMode == .codex ? .on : .off
        autoClaudeItem.state = autoRefreshMode == .claude ? .on : .off
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
                self.updateStatus(summary: result.summary, success: result.success, details: result.details)
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

    @objc private func pushWitchSample() {
        run(
            label: "Witch sample",
            arguments: [
                "send-divoom16",
                "/Users/kirniy/dev/divoom/andreas-js/images/witch.divoom16",
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
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeSolidRed() {
        bluetoothDiagnostics.runNativeSolidRed { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativePurityRed() {
        bluetoothDiagnostics.runNativeBLEPurityRed { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativePixelTest() {
        bluetoothDiagnostics.runNativeBLEPixelBadgeTest { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeBatteryStatus() {
        bluetoothDiagnostics.runNativeBLEBatteryStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeSystemStatus() {
        bluetoothDiagnostics.runNativeBLESystemStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeNetworkStatus() {
        bluetoothDiagnostics.runNativeBLENetworkStatus { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
            }
        }
    }

    @objc private func runNativeAnimationSample() {
        bluetoothDiagnostics.runNativeBLEObviousAnimationSample { [weak self] result in
            DispatchQueue.main.async {
                self?.updateStatus(summary: result.summary, success: result.success, details: result.details)
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
