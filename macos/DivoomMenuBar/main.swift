import AVFoundation
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import QuartzCore

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

private let menuSurfaceWidth: CGFloat = 560
private let summaryCardHeight: CGFloat = 110
private let quickHubHeight: CGFloat = 190
private let colorStudioHeight: CGFloat = 246

private enum ColorMotionMode: String, CaseIterable, Codable {
    case solid
    case gradientSweep = "gradient-sweep"
    case paletteSteps = "palette-steps"
    case pulse
    case aurora

    var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradientSweep:
            return "Gradient Sweep"
        case .paletteSteps:
            return "Palette Steps"
        case .pulse:
            return "Pulse"
        case .aurora:
            return "Aurora"
        }
    }

    var shortTitle: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradientSweep:
            return "Sweep"
        case .paletteSteps:
            return "Steps"
        case .pulse:
            return "Pulse"
        case .aurora:
            return "Aurora"
        }
    }

    var summaryPrefix: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradientSweep:
            return "Gradient Sweep"
        case .paletteSteps:
            return "Palette Steps"
        case .pulse:
            return "Pulse Motion"
        case .aurora:
            return "Aurora Motion"
        }
    }
}

private struct SavedColorCombo: Codable, Equatable {
    let id: String
    let name: String
    let mode: ColorMotionMode
    let colors: [String]
}

private enum SavedColorComboStore {
    static let defaultsKey = "dev.kirniy.divoom.saved-color-combos"

    static func load() -> [SavedColorCombo] {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let combos = try? JSONDecoder().decode([SavedColorCombo].self, from: data)
        else {
            return []
        }
        return combos
    }

    static func save(_ combos: [SavedColorCombo]) {
        guard let data = try? JSONEncoder().encode(combos) else {
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private enum AutoRefreshMode {
    case off
    case codex
    case claude
    case pair
    case ipFlag
    case favorites

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .pair:
            return "Codex + Claude"
        case .ipFlag:
            return "IP Flag"
        case .favorites:
            return "Rotate Favorites"
        }
    }

    var feedIdentifier: String? {
        switch self {
        case .off:
            return nil
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .pair:
            return "pair"
        case .ipFlag:
            return "ip-flag"
        case .favorites:
            return nil
        }
    }

    var quickActionKind: QuickActionKind? {
        switch self {
        case .off:
            return nil
        case .codex:
            return .codex
        case .claude:
            return .claude
        case .pair:
            return .pair
        case .ipFlag:
            return .ipFlag
        case .favorites:
            return .favorites
        }
    }
}

private enum CodexBarMetricPreference: String, CaseIterable {
    case primary
    case secondary
    case tertiary

    var title: String {
        rawValue.capitalized
    }
}

private struct CommandSpec {
    let label: String
    let arguments: [String]
    let successSound: FeedbackSoundProfile?
    let playErrorSound: Bool
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

private enum QuickActionKind: String {
    case codex
    case claude
    case pair
    case ipFlag
    case library
    case favorites
    case screenPick
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

private func makeProviderLogoImage(provider: String, size: CGFloat = 16) -> NSImage {
    let assetPath = "/Users/kirniy/dev/divoom/assets/ui-icons/provider-\(provider).png"
    if FileManager.default.fileExists(atPath: assetPath), let image = NSImage(contentsOfFile: assetPath) {
        image.size = NSSize(width: size, height: size)
        return image
    }

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    switch provider {
    case "codex":
        let petalColor = NSColor.systemTeal
        let centers = [
            NSPoint(x: size * 0.50, y: size * 0.20),
            NSPoint(x: size * 0.74, y: size * 0.34),
            NSPoint(x: size * 0.74, y: size * 0.66),
            NSPoint(x: size * 0.50, y: size * 0.80),
            NSPoint(x: size * 0.26, y: size * 0.66),
            NSPoint(x: size * 0.26, y: size * 0.34),
        ]
        for center in centers {
            let rect = NSRect(x: center.x - size * 0.11, y: center.y - size * 0.11, width: size * 0.22, height: size * 0.22)
            let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.06, yRadius: size * 0.06)
            petalColor.setFill()
            path.fill()
        }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.38, y: size * 0.38, width: size * 0.24, height: size * 0.24)).fill()
    case "claude":
        let base = NSColor.systemOrange
        let points = [
            NSPoint(x: size * 0.50, y: size * 0.14),
            NSPoint(x: size * 0.68, y: size * 0.32),
            NSPoint(x: size * 0.86, y: size * 0.50),
            NSPoint(x: size * 0.68, y: size * 0.68),
            NSPoint(x: size * 0.50, y: size * 0.86),
            NSPoint(x: size * 0.32, y: size * 0.68),
            NSPoint(x: size * 0.14, y: size * 0.50),
            NSPoint(x: size * 0.32, y: size * 0.32),
        ]
        for point in points {
            let rect = NSRect(x: point.x - size * 0.08, y: point.y - size * 0.08, width: size * 0.16, height: size * 0.16)
            base.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.40, y: size * 0.40, width: size * 0.20, height: size * 0.20)).fill()
    default:
        let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: provider)
        symbol?.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
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
        NSSize(width: menuSurfaceWidth, height: summaryCardHeight)
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
            widthAnchor.constraint(equalToConstant: menuSurfaceWidth),
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
    var onSendMotion: (([NSColor], ColorMotionMode) -> Void)?
    var onPickScreen: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Color Motion Studio")
    private let captionLabel = NSTextField(labelWithString: "Solid fills, saved combos, gradients, and palette motion.")
    private let modePopUp = NSPopUpButton()
    private let slotCountLabel = NSTextField(labelWithString: "4 colors")
    private let slotCountStepper = NSStepper()
    private let slotPicker = NSPopUpButton()
    private let savedComboPopUp = NSPopUpButton()
    private let saveComboButton = NSButton(title: "Save Combo", target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let hexField = NSTextField(string: "#FF0000")
    private let sendButton = NSButton(title: "Beam Solid", target: nil, action: nil)
    private let pickButton = NSButton(title: "Pick Screen", target: nil, action: nil)
    private let swatchHexes = ["#FF3B30", "#FF9500", "#FFD60A", "#30D158", "#64D2FF", "#0A84FF", "#BF5AF2", "#FF375F"]
    private var slotButtons: [NSButton] = []
    private var paletteColors: [NSColor] = [
        NSColor.systemRed,
        NSColor.systemOrange,
        NSColor.systemYellow,
        NSColor.systemBlue,
        NSColor.systemPurple,
        NSColor.systemGreen,
        NSColor.systemPink,
        NSColor.systemTeal,
        NSColor.systemIndigo,
        NSColor.white,
    ]
    private var visibleSlotCount = 4
    private var activeSlotIndex = 0
    private var savedCombos = SavedColorComboStore.load()

    override var intrinsicContentSize: NSSize {
        NSSize(width: menuSurfaceWidth, height: colorStudioHeight)
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
        if activeSlotIndex >= 0, activeSlotIndex < paletteColors.count {
            paletteColors[activeSlotIndex] = rgb
        }
        syncEditorWithActiveSlot()
        refreshSlotStrip()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 16
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

        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        ColorMotionMode.allCases.forEach { mode in
            modePopUp.addItem(withTitle: mode.title)
            modePopUp.lastItem?.representedObject = mode.rawValue
        }
        modePopUp.selectItem(withTitle: ColorMotionMode.solid.title)
        modePopUp.target = self
        modePopUp.action = #selector(modeChanged)

        slotCountLabel.translatesAutoresizingMaskIntoConstraints = false
        slotCountLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        slotCountLabel.textColor = .secondaryLabelColor

        slotCountStepper.translatesAutoresizingMaskIntoConstraints = false
        slotCountStepper.minValue = 3
        slotCountStepper.maxValue = 10
        slotCountStepper.increment = 1
        slotCountStepper.integerValue = visibleSlotCount
        slotCountStepper.target = self
        slotCountStepper.action = #selector(slotCountChanged)

        slotPicker.translatesAutoresizingMaskIntoConstraints = false
        slotPicker.target = self
        slotPicker.action = #selector(slotPickerChanged)

        savedComboPopUp.translatesAutoresizingMaskIntoConstraints = false
        savedComboPopUp.target = self
        savedComboPopUp.action = #selector(savedComboChanged)

        saveComboButton.translatesAutoresizingMaskIntoConstraints = false
        saveComboButton.bezelStyle = .rounded
        saveComboButton.controlSize = .small
        saveComboButton.image = makeMenuSymbol("square.and.arrow.down", description: "Save Combo")
        saveComboButton.imagePosition = .imageLeading
        saveComboButton.target = self
        saveComboButton.action = #selector(saveComboPressed)

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.color = NSColor.systemRed
        if #available(macOS 13.0, *) {
            colorWell.colorWellStyle = .expanded
        }
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

        let slotStrip = NSStackView()
        slotStrip.orientation = .horizontal
        slotStrip.alignment = .centerY
        slotStrip.spacing = 8
        slotStrip.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<10 {
            let button = NSButton(title: "", target: self, action: #selector(slotButtonPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(rawValue: "slot-\(index)")
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.wantsLayer = true
            button.layer?.cornerRadius = 10
            button.layer?.cornerCurve = .continuous
            button.layer?.borderWidth = 1.5
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 20),
                button.heightAnchor.constraint(equalToConstant: 20),
            ])
            slotButtons.append(button)
            slotStrip.addArrangedSubview(button)
        }

        let swatchesRow = NSStackView()
        swatchesRow.orientation = .horizontal
        swatchesRow.alignment = .centerY
        swatchesRow.spacing = 7
        swatchesRow.translatesAutoresizingMaskIntoConstraints = false
        swatchHexes.forEach { hex in
            swatchesRow.addArrangedSubview(makeSwatchButton(hex: hex))
        }

        let modeRow = NSStackView(views: [modePopUp, slotCountLabel, slotCountStepper, slotPicker])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8
        modeRow.distribution = .fill
        modeRow.translatesAutoresizingMaskIntoConstraints = false

        let comboRow = NSStackView(views: [savedComboPopUp, saveComboButton])
        comboRow.orientation = .horizontal
        comboRow.alignment = .centerY
        comboRow.spacing = 8
        comboRow.translatesAutoresizingMaskIntoConstraints = false

        let controlsRow = NSStackView(views: [colorWell, hexField, pickButton, sendButton])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8
        controlsRow.distribution = .fill
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [titleLabel, captionLabel, modeRow, slotStrip, comboRow, swatchesRow, controlsRow])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: menuSurfaceWidth),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            modePopUp.widthAnchor.constraint(equalToConstant: 148),
            slotPicker.widthAnchor.constraint(equalToConstant: 84),
            savedComboPopUp.widthAnchor.constraint(equalToConstant: 248),
            hexField.widthAnchor.constraint(equalToConstant: 106),
            sendButton.widthAnchor.constraint(equalToConstant: 108),
            pickButton.widthAnchor.constraint(equalToConstant: 104),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        refreshSavedCombos()
        refreshSlotPicker()
        syncEditorWithActiveSlot()
        refreshSlotStrip()
        updateSendButtonTitle()
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
    }

    @objc private func colorWellChanged() {
        setSelectedColor(colorWell.color)
    }

    @objc private func hexSubmitted() {
        applyCurrentHexColor()
    }

    @objc private func sendPressed() {
        let colors = Array(paletteColors.prefix(visibleSlotCount))
        let mode = selectedMode()
        if mode == .solid {
            onSendColor?(colors.first ?? NSColor.systemRed)
        } else {
            onSendMotion?(colors, mode)
        }
    }

    @objc private func pickScreenPressed() {
        onPickScreen?()
    }

    @objc private func modeChanged() {
        updateSendButtonTitle()
        refreshSavedCombos()
    }

    @objc private func slotCountChanged() {
        visibleSlotCount = min(max(slotCountStepper.integerValue, 3), 10)
        if activeSlotIndex >= visibleSlotCount {
            activeSlotIndex = visibleSlotCount - 1
        }
        refreshSlotPicker()
        refreshSlotStrip()
        updateSendButtonTitle()
    }

    @objc private func slotPickerChanged() {
        activeSlotIndex = max(slotPicker.indexOfSelectedItem, 0)
        syncEditorWithActiveSlot()
        refreshSlotStrip()
    }

    @objc private func slotButtonPressed(_ sender: NSButton) {
        guard
            let raw = sender.identifier?.rawValue.replacingOccurrences(of: "slot-", with: ""),
            let index = Int(raw),
            index < visibleSlotCount
        else {
            return
        }
        activeSlotIndex = index
        slotPicker.selectItem(at: index)
        syncEditorWithActiveSlot()
        refreshSlotStrip()
    }

    @objc private func savedComboChanged() {
        let selectedIndex = savedComboPopUp.indexOfSelectedItem - 1
        guard selectedIndex >= 0, selectedIndex < savedCombos.count else {
            return
        }
        let combo = savedCombos[selectedIndex]
        visibleSlotCount = min(max(combo.colors.count, 3), 10)
        slotCountStepper.integerValue = visibleSlotCount
        for (index, hex) in combo.colors.enumerated() where index < paletteColors.count {
            if
                let (red, green, blue) = parseRGBHex(hex)
            {
                paletteColors[index] = NSColor(
                    red: CGFloat(red) / 255.0,
                    green: CGFloat(green) / 255.0,
                    blue: CGFloat(blue) / 255.0,
                    alpha: 1.0
                )
            }
        }
        if let targetItem = modePopUp.itemArray.first(where: { ($0.representedObject as? String) == combo.mode.rawValue }) {
            modePopUp.select(targetItem)
        }
        activeSlotIndex = 0
        refreshSlotPicker()
        syncEditorWithActiveSlot()
        refreshSlotStrip()
        updateSendButtonTitle()
    }

    @objc private func saveComboPressed() {
        let hexes = selectedPaletteHexes()
        guard !hexes.isEmpty else {
            NSSound.beep()
            return
        }

        let mode = selectedMode()
        if let index = savedCombos.firstIndex(where: { $0.colors == hexes && $0.mode == mode }) {
            savedComboPopUp.selectItem(at: index + 1)
            return
        }

        let combo = SavedColorCombo(
            id: UUID().uuidString,
            name: "\(mode.shortTitle) · " + hexes.prefix(3).joined(separator: " · "),
            mode: mode,
            colors: hexes
        )
        savedCombos.insert(combo, at: 0)
        SavedColorComboStore.save(savedCombos)
        refreshSavedCombos(selectedID: combo.id)
    }

    private func applyCurrentHexColor() {
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
    }

    private func selectedMode() -> ColorMotionMode {
        guard
            let rawValue = modePopUp.selectedItem?.representedObject as? String,
            let mode = ColorMotionMode(rawValue: rawValue)
        else {
            return .solid
        }
        return mode
    }

    private func selectedPaletteHexes() -> [String] {
        Array(paletteColors.prefix(visibleSlotCount)).compactMap { hexString(for: $0) }
    }

    private func refreshSavedCombos(selectedID: String? = nil) {
        savedComboPopUp.removeAllItems()
        savedComboPopUp.addItem(withTitle: "Saved Combos")
        savedComboPopUp.lastItem?.representedObject = nil
        for combo in savedCombos {
            savedComboPopUp.addItem(withTitle: combo.name)
            savedComboPopUp.lastItem?.representedObject = combo.id
        }

        if let selectedID, let item = savedComboPopUp.itemArray.first(where: { ($0.representedObject as? String) == selectedID }) {
            savedComboPopUp.select(item)
        } else {
            savedComboPopUp.selectItem(at: 0)
        }
    }

    private func refreshSlotPicker() {
        slotCountLabel.stringValue = "\(visibleSlotCount) colors"
        slotPicker.removeAllItems()
        for index in 0..<visibleSlotCount {
            slotPicker.addItem(withTitle: "Edit \(index + 1)")
        }
        slotPicker.selectItem(at: activeSlotIndex)
    }

    private func refreshSlotStrip() {
        for (index, button) in slotButtons.enumerated() {
            let visible = index < visibleSlotCount
            button.isHidden = !visible
            guard visible else { continue }
            let color = paletteColors[index]
            button.layer?.backgroundColor = color.cgColor
            let isActive = index == activeSlotIndex
            button.layer?.borderColor = (isActive ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.35)).cgColor
            button.layer?.borderWidth = isActive ? 2.2 : 1.2
        }
    }

    private func syncEditorWithActiveSlot() {
        guard activeSlotIndex >= 0, activeSlotIndex < paletteColors.count else {
            return
        }
        let color = paletteColors[activeSlotIndex]
        colorWell.color = color
        hexField.stringValue = hexString(for: color) ?? "#FF0000"
        slotPicker.selectItem(at: activeSlotIndex)
    }

    private func updateSendButtonTitle() {
        sendButton.title = selectedMode() == .solid ? "Beam Solid" : "Beam Motion"
    }
}

private final class QuickActionTileView: NSControl {
    var onActivate: (() -> Void)?
    var isActive = false {
        didSet {
            updateAppearance()
        }
    }
    var isLoading = false {
        didSet {
            updateAppearance()
        }
    }

    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet {
            updateAppearance()
        }
    }
    private var isPressing = false {
        didSet {
            updateAppearance()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 164, height: 78)
    }

    init(title: String, image: NSImage?, tooltip: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        iconView.image = image
        self.toolTip = tooltip
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shouldActivate = bounds.contains(point)
        isPressing = false
        if shouldActivate {
            onActivate?()
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 10
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)
        iconSlot.addSubview(spinner)

        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 20),
            iconSlot.heightAnchor.constraint(equalToConstant: 20),
            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),
        ])

        let stack = NSStackView(views: [iconSlot, titleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let baseBackground = NSColor.white.withAlphaComponent(isHovering ? 0.28 : 0.20)
        let activeBackground = NSColor.controlAccentColor.withAlphaComponent(isHovering ? 0.25 : 0.19)
        layer?.backgroundColor = (isActive ? activeBackground : baseBackground).cgColor
        layer?.borderColor = (isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.58)
            : NSColor.separatorColor.withAlphaComponent(0.22)).cgColor
        alphaValue = isPressing ? 0.88 : 1.0
        iconView.isHidden = isLoading
        if isLoading {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

private final class QuickActionHubView: NSView {
    var onCodex: (() -> Void)?
    var onClaude: (() -> Void)?
    var onPair: (() -> Void)?
    var onIPFlag: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onFavorites: (() -> Void)?
    var onScreenPick: (() -> Void)?

    var activeAction: QuickActionKind? {
        didSet {
            updateTileAppearance()
        }
    }
    var loadingAction: QuickActionKind? {
        didSet {
            updateTileAppearance()
        }
    }

    private var tiles: [QuickActionKind: QuickActionTileView] = [:]

    override var intrinsicContentSize: NSSize {
        NSSize(width: menuSurfaceWidth, height: quickHubHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        let topRow = NSStackView(views: [
            makeTile(title: "Codex Live", actionID: .codex),
            makeTile(title: "Claude Live", actionID: .claude),
            makeTile(title: "Split Live", actionID: .pair),
        ])
        topRow.orientation = .horizontal
        topRow.spacing = 12
        topRow.distribution = .fillEqually
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [
            makeTile(title: "IP Flag", actionID: .ipFlag),
            makeTile(title: "Library", actionID: .library),
            makeTile(title: "Rotate Favorites", actionID: .favorites),
        ])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        bottomRow.distribution = .fillEqually
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, bottomRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: menuSurfaceWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        updateTileAppearance()
    }

    private func makeTile(title: String, actionID: QuickActionKind) -> QuickActionTileView {
        let tile = QuickActionTileView(title: title, image: image(for: actionID), tooltip: tooltip(for: actionID))
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.onActivate = { [weak self] in
            self?.handleAction(actionID)
        }
        tiles[actionID] = tile
        return tile
    }

    private func image(for actionID: QuickActionKind) -> NSImage? {
        switch actionID {
        case .codex:
            return makeProviderLogoImage(provider: "codex", size: 18)
        case .claude:
            return makeProviderLogoImage(provider: "claude", size: 18)
        case .pair:
            return makeMenuSymbol("square.split.2x1", description: "Split Live")
        case .ipFlag:
            return makeMenuSymbol("flag.2.crossed", description: "IP Flag")
        case .library:
            return makeMenuSymbol("photo.stack", description: "Open Library")
        case .favorites:
            return makeMenuSymbol("arrow.triangle.2.circlepath", description: "Rotate Favorites")
        case .screenPick:
            return makeMenuSymbol("eyedropper.halffull", description: "Pick Color")
        }
    }

    private func tooltip(for actionID: QuickActionKind) -> String {
        switch actionID {
        case .codex:
            return "Start or stop the live Codex feed."
        case .claude:
            return "Start or stop the live Claude feed."
        case .pair:
            return "Start or stop the live Codex + Claude split view."
        case .ipFlag:
            return "Start or stop the live public IP country flag."
        case .library:
            return "Open the native animation library."
        case .favorites:
            return "Start or stop live rotation through your favorited animations."
        case .screenPick:
            return "Sample any color from the screen and beam it."
        }
    }

    private func updateTileAppearance() {
        for (kind, tile) in tiles {
            tile.isActive = kind == activeAction
            tile.isLoading = kind == loadingAction
        }
    }

    private func handleAction(_ actionID: QuickActionKind) {
        switch actionID {
        case .codex:
            onCodex?()
        case .claude:
            onClaude?()
        case .pair:
            onPair?()
        case .ipFlag:
            onIPFlag?()
        case .library:
            onLibrary?()
        case .favorites:
            onFavorites?()
        case .screenPick:
            onScreenPick?()
        }
    }
}

private struct AnimationLibraryItem: Hashable {
    let id: String
    let title: String
    let category: String
    let collection: String
    let relativePath: String
    let fileURL: URL
    let searchText: String
    let duplicateCount: Int
}

private enum AnimationLibraryCatalog {
    static let rootURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/assets/16x16/curated", isDirectory: true)
    static let favoritesDefaultsKey = "dev.kirniy.divoom.animation-library-favorites"

    static func loadItems() -> [AnimationLibraryItem] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }

        var groupedItems: [String: [AnimationLibraryItem]] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "gif" else {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            let parts = relativePath.split(separator: "/").map(String.init)
            let category = parts.first ?? "misc"
            let collection = parts.count > 2 ? parts[1] : (parts.count == 2 ? "root" : "root")
            let title = prettifyAnimationTitle(fileURL.deletingPathExtension().lastPathComponent)
            let id = relativePath
            let searchText = [title, category, collection, relativePath].joined(separator: " ").lowercased()
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                continue
            }
            let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()

            let item =
                AnimationLibraryItem(
                    id: id,
                    title: title,
                    category: category,
                    collection: collection,
                    relativePath: relativePath,
                    fileURL: fileURL,
                    searchText: searchText,
                    duplicateCount: 1
                )
            groupedItems[digest, default: []].append(item)
        }

        let items = groupedItems.values.compactMap { group -> AnimationLibraryItem? in
            guard let canonical = group.max(by: { preferenceScore(for: $0) < preferenceScore(for: $1) }) else {
                return nil
            }
            return AnimationLibraryItem(
                id: canonical.id,
                title: canonical.title,
                category: canonical.category,
                collection: canonical.collection,
                relativePath: canonical.relativePath,
                fileURL: canonical.fileURL,
                searchText: canonical.searchText,
                duplicateCount: group.count
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.category == rhs.category {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
        }
    }

    static func loadFavorites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favoritesDefaultsKey) ?? [])
    }

    static func saveFavorites(_ favorites: Set<String>) {
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: favoritesDefaultsKey)
    }

    static func displayTitle(for value: String) -> String {
        let words = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.split(separator: " ").map { part in
            part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func prettifyAnimationTitle(_ value: String) -> String {
        let pattern = #"[._-]\d{4,}$"#
        let trimmed = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        let cleaned = trimmed.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let squashed = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return squashed.isEmpty ? value : squashed
    }

    private static func preferenceScore(for item: AnimationLibraryItem) -> Int {
        var score = 0
        if !item.relativePath.contains("/textfiles/") {
            score += 20
        }
        if item.collection == "root" {
            score += 8
        }
        if item.category == "pixel-displays" || item.category == "divoom" {
            score += 4
        }
        score -= item.relativePath.count
        return score
    }
}

private func animationCategorySymbolName(_ category: String) -> String {
    switch category {
    case "90s-web":
        return "globe"
    case "retro-os":
        return "desktopcomputer"
    case "weather":
        return "cloud.sun"
    case "space":
        return "sparkles"
    case "cute":
        return "face.smiling"
    case "animals":
        return "pawprint"
    case "gaming":
        return "gamecontroller"
    case "pixel-displays", "divoom":
        return "square.grid.3x3.fill"
    case "emoji":
        return "face.smiling.inverse"
    case "status":
        return "waveform.path.ecg"
    default:
        return "sparkles"
    }
}

private final class AnimatedPreviewSequence: NSObject {
    let frames: [CGImage]
    let keyTimes: [NSNumber]
    let duration: CFTimeInterval

    init?(fileURL: URL) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            return nil
        }

        var collectedFrames: [CGImage] = []
        var frameDurations: [Double] = []

        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            collectedFrames.append(frame)
            frameDurations.append(Self.frameDuration(for: source, index: index))
        }

        guard !collectedFrames.isEmpty else {
            return nil
        }

        let totalDuration = max(frameDurations.reduce(0, +), 0.12)
        var cumulative = 0.0
        let times = frameDurations.map { frameDuration -> NSNumber in
            defer { cumulative += frameDuration }
            return NSNumber(value: cumulative / totalDuration)
        }

        frames = collectedFrames
        keyTimes = times
        duration = totalDuration
    }

    private static func frameDuration(for source: CGImageSource, index: Int) -> Double {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.12
        }

        let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double
        return max(unclamped ?? clamped ?? 0.12, 0.06)
    }
}

private enum AnimationPreviewCache {
    static let sequences = NSCache<NSString, AnimatedPreviewSequence>()

    static func sequence(for fileURL: URL) -> AnimatedPreviewSequence? {
        let key = fileURL.path as NSString
        if let cached = sequences.object(forKey: key) {
            return cached
        }
        guard let sequence = AnimatedPreviewSequence(fileURL: fileURL) else {
            return nil
        }
        sequences.setObject(sequence, forKey: key)
        return sequence
    }
}

private final class PixelArtAnimationView: NSView {
    private let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = min(bounds.width, bounds.height) < 90 ? 10 : 14
        let availableSide = max(min(bounds.width, bounds.height) - inset * 2, 16)
        let quantizedSide = max(floor(availableSide / 16) * 16, 16)
        let origin = NSPoint(
            x: floor((bounds.width - quantizedSide) / 2.0),
            y: floor((bounds.height - quantizedSide) / 2.0)
        )
        imageLayer.frame = NSRect(origin: origin, size: NSSize(width: quantizedSide, height: quantizedSide)).integral
        updateContentsScale()
    }

    func setFileURL(_ fileURL: URL?) {
        imageLayer.removeAnimation(forKey: "pixelFrames")
        guard let fileURL, let sequence = AnimationPreviewCache.sequence(for: fileURL) else {
            imageLayer.contents = nil
            return
        }

        imageLayer.contents = sequence.frames.first
        guard sequence.frames.count > 1 else {
            return
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sequence.frames
        animation.keyTimes = sequence.keyTimes
        animation.duration = sequence.duration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        imageLayer.add(animation, forKey: "pixelFrames")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.allowsEdgeAntialiasing = false
        layer?.addSublayer(imageLayer)
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        imageLayer.contentsScale = scale
    }
}

private final class HoverActionPreviewView: NSView {
    enum Style {
        case compact
        case hero
    }

    let previewView = PixelArtAnimationView()

    private let overlayView = NSVisualEffectView()
    private let overlayButton = NSButton(title: "", target: nil, action: nil)
    private let overlayLabel = NSTextField(labelWithString: "Beam")
    private var trackingAreaHandle: NSTrackingArea?
    private let style: Style
    private var isHovering = false
    private var hasContent = false

    var onPrimaryAction: (() -> Void)?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.style = .compact
        super.init(coder: coder)
        setup()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaHandle {
            removeTrackingArea(trackingAreaHandle)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaHandle = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateOverlay(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateOverlay(animated: true)
    }

    func setFileURL(_ fileURL: URL?) {
        hasContent = fileURL != nil
        previewView.setFileURL(fileURL)
        updateOverlay(animated: false)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        previewView.translatesAutoresizingMaskIntoConstraints = false

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.material = .hudWindow
        overlayView.blendingMode = .withinWindow
        overlayView.state = .active
        overlayView.wantsLayer = true
        overlayView.layer?.cornerCurve = .continuous
        overlayView.layer?.borderWidth = 1
        overlayView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        overlayView.layer?.shadowOpacity = 0.18
        overlayView.layer?.shadowRadius = 16
        overlayView.layer?.shadowOffset = NSSize(width: 0, height: -2)
        overlayView.alphaValue = 0

        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.isBordered = false
        overlayButton.imagePosition = .imageOnly
        overlayButton.contentTintColor = .white
        overlayButton.target = self
        overlayButton.action = #selector(triggerPrimaryAction)

        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayLabel.font = .systemFont(ofSize: style == .hero ? 12 : 11, weight: .semibold)
        overlayLabel.textColor = .white.withAlphaComponent(0.96)
        overlayLabel.alignment = .center
        overlayLabel.isHidden = style == .compact

        let overlayStack = NSStackView(views: style == .hero ? [overlayButton, overlayLabel] : [overlayButton])
        overlayStack.orientation = .vertical
        overlayStack.alignment = .centerX
        overlayStack.spacing = style == .hero ? 4 : 0
        overlayStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewView)
        addSubview(overlayView)
        overlayView.addSubview(overlayStack)

        let iconPointSize: CGFloat = style == .hero ? 32 : 20
        let symbolWeight: NSFont.Weight = style == .hero ? .bold : .semibold
        overlayButton.image = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "Beam to Ditoo"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: symbolWeight))

        let overlaySide: CGFloat = style == .hero ? 102 : 58
        overlayView.layer?.cornerRadius = style == .hero ? 28 : 20

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: topAnchor),
            previewView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlayView.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlayView.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlayView.widthAnchor.constraint(equalToConstant: overlaySide),
            overlayView.heightAnchor.constraint(equalToConstant: style == .hero ? 84 : overlaySide),

            overlayStack.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            overlayStack.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
        ])
    }

    @objc private func triggerPrimaryAction() {
        guard hasContent else {
            NSSound.beep()
            return
        }
        onPrimaryAction?()
    }

    private func updateOverlay(animated: Bool) {
        let targetAlpha: CGFloat = hasContent && isHovering ? 1.0 : 0.0
        let updates = { self.overlayView.animator().alphaValue = targetAlpha }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                updates()
            }
        } else {
            overlayView.alphaValue = targetAlpha
        }
    }
}

private final class HeaderStatChipView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")

    init(symbolName: String, text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 999
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor

        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = .secondaryLabelColor

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        textLabel.textColor = .secondaryLabelColor
        textLabel.stringValue = text

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String, symbolName: String? = nil) {
        textLabel.stringValue = text
        if let symbolName {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)?.withSymbolConfiguration(configuration)
        }
    }
}

private enum AnimationLibraryDisplayMode: Int {
    case grid = 0
    case list = 1
}

private final class AnimationLibraryCollectionItem: NSCollectionViewItem {
    private let glassView = NSVisualEffectView()
    private let previewView = HoverActionPreviewView(style: .compact)
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaIconView = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton(title: "", target: nil, action: nil)
    private let duplicateChip = HeaderStatChipView(symbolName: "square.on.square", text: "2x")
    private var currentItem: AnimationLibraryItem?
    private var gridConstraints: [NSLayoutConstraint] = []
    private var listConstraints: [NSLayoutConstraint] = []
    private var currentDisplayMode: AnimationLibraryDisplayMode = .grid

    var onToggleFavorite: ((AnimationLibraryItem) -> Void)?
    var onBeam: ((AnimationLibraryItem) -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        buildUI()
    }

    override var isSelected: Bool {
        didSet {
            updateSelectionAppearance()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewView.setFileURL(nil)
    }

    func configure(item: AnimationLibraryItem, isFavorite: Bool, displayMode: AnimationLibraryDisplayMode) {
        currentItem = item
        currentDisplayMode = displayMode
        titleLabel.stringValue = item.title
        let collectionTitle = item.collection == "root" ? "Root" : AnimationLibraryCatalog.displayTitle(for: item.collection)
        metaIconView.image = makeMenuSymbol(animationCategorySymbolName(item.category), description: item.category)
        metaLabel.stringValue = "\(AnimationLibraryCatalog.displayTitle(for: item.category)) · \(collectionTitle)"
        pathLabel.stringValue = item.relativePath
        previewView.setFileURL(item.fileURL)
        previewView.onPrimaryAction = { [weak self] in
            guard let self, let currentItem = self.currentItem else { return }
            self.onBeam?(currentItem)
        }
        duplicateChip.isHidden = item.duplicateCount <= 1
        if item.duplicateCount > 1 {
            duplicateChip.update(text: "\(item.duplicateCount)x", symbolName: "square.on.square")
        }
        updateFavoriteAppearance(isFavorite: isFavorite)
        applyDisplayMode(displayMode)
        updateSelectionAppearance()
    }

    @objc private func toggleFavorite() {
        guard let currentItem else {
            return
        }
        onToggleFavorite?(currentItem)
    }

    private func buildUI() {
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.material = .popover
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 22
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.borderWidth = 1
        glassView.layer?.shadowOpacity = 0.10
        glassView.layer?.shadowRadius = 18
        glassView.layer?.shadowOffset = NSSize(width: 0, height: -2)

        previewView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        metaIconView.translatesAutoresizingMaskIntoConstraints = false
        metaIconView.contentTintColor = .secondaryLabelColor

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11, weight: .medium)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .regularSquare
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.contentTintColor = .systemOrange

        duplicateChip.translatesAutoresizingMaskIntoConstraints = false
        duplicateChip.isHidden = true

        let metaRow = NSStackView(views: [metaIconView, metaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, metaRow, pathLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(glassView)
        glassView.addSubview(previewView)
        glassView.addSubview(textStack)
        glassView.addSubview(favoriteButton)
        glassView.addSubview(duplicateChip)

        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: view.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            favoriteButton.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 12),
            favoriteButton.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -12),
            favoriteButton.widthAnchor.constraint(equalToConstant: 28),
            favoriteButton.heightAnchor.constraint(equalToConstant: 28),

            metaIconView.widthAnchor.constraint(equalToConstant: 14),
            metaIconView.heightAnchor.constraint(equalToConstant: 14),

            duplicateChip.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 12),
            duplicateChip.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 12),
        ])

        gridConstraints = [
            previewView.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 16),
            previewView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 16),
            previewView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -16),
            previewView.heightAnchor.constraint(equalToConstant: 138),

            textStack.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 16),
            textStack.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 12),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: glassView.bottomAnchor, constant: -16),
        ]

        listConstraints = [
            previewView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 14),
            previewView.centerYAnchor.constraint(equalTo: glassView.centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 72),
            previewView.heightAnchor.constraint(equalToConstant: 72),

            textStack.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: -14),
            textStack.centerYAnchor.constraint(equalTo: glassView.centerYAnchor),
        ]

        applyDisplayMode(.grid)
    }

    private func applyDisplayMode(_ displayMode: AnimationLibraryDisplayMode) {
        switch displayMode {
        case .grid:
            NSLayoutConstraint.deactivate(listConstraints)
            NSLayoutConstraint.activate(gridConstraints)
            pathLabel.isHidden = true
        case .list:
            NSLayoutConstraint.deactivate(gridConstraints)
            NSLayoutConstraint.activate(listConstraints)
            pathLabel.isHidden = false
        }
    }

    private func updateFavoriteAppearance(isFavorite: Bool) {
        let symbol = isFavorite ? "star.fill" : "star"
        favoriteButton.image = makeMenuSymbol(symbol, description: "Favorite")
        favoriteButton.toolTip = isFavorite ? "Remove from favorites" : "Add to favorites"
    }

    private func updateSelectionAppearance() {
        let accentColor = isSelected ? NSColor.systemBlue.withAlphaComponent(0.42) : NSColor.separatorColor.withAlphaComponent(0.22)
        glassView.layer?.borderColor = accentColor.cgColor
        glassView.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.16)).cgColor
    }
}

@MainActor
private final class AnimationLibraryWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let onSend: (AnimationLibraryItem) -> Void
    private let onReveal: (AnimationLibraryItem) -> Void

    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Animation Library")
    private let summaryLabel = NSTextField(labelWithString: "Native Swift picker with direct Ditoo beam.")
    private let assetChip = HeaderStatChipView(symbolName: "sparkles", text: "0 curated")
    private let categoryChip = HeaderStatChipView(symbolName: "square.grid.3x3.fill", text: "0 categories")
    private let favoriteChip = HeaderStatChipView(symbolName: "star.fill", text: "0 favorites")
    private let resultsLabel = NSTextField(labelWithString: "0 visible")
    private let searchField = NSSearchField()
    private let categoryPopUp = NSPopUpButton()
    private let displayModeControl = NSSegmentedControl(labels: ["Grid", "List"], trackingMode: .selectOne, target: nil, action: nil)
    private let favoritesOnlyButton = NSButton(title: "Favorites", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let flowLayout = NSCollectionViewFlowLayout()
    private let collectionView = NSCollectionView()
    private let collectionScrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No animations match the current filters.")
    private let inspectorView = NSVisualEffectView()
    private let detailPreviewView = HoverActionPreviewView(style: .hero)
    private let detailTitleLabel = NSTextField(labelWithString: "Select an animation")
    private let detailMetaLabel = NSTextField(labelWithString: "Pick something excellent, then send it straight to the Ditoo.")
    private let detailCategoryChip = HeaderStatChipView(symbolName: "sparkles", text: "Category")
    private let detailCollectionChip = HeaderStatChipView(symbolName: "folder", text: "Collection")
    private let detailDuplicateChip = HeaderStatChipView(symbolName: "square.on.square", text: "Unique")
    private let detailPathLabel = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton(title: "Beam to Ditoo", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "Favorite", target: nil, action: nil)

    private var allItems: [AnimationLibraryItem] = []
    private var filteredItems: [AnimationLibraryItem] = []
    private var favorites = AnimationLibraryCatalog.loadFavorites()
    private var selectedCategory = "all"
    private var selectedItemID: String?
    private var displayMode: AnimationLibraryDisplayMode = .grid

    init(onSend: @escaping (AnimationLibraryItem) -> Void, onReveal: @escaping (AnimationLibraryItem) -> Void) {
        self.onSend = onSend
        self.onReveal = onReveal

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Animation Library"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 980, height: 680)

        super.init(window: panel)
        panel.delegate = self
        buildUI(in: panel)
        reloadLibrary()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showLibrary() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        updateCollectionLayout()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("AnimationLibraryCollectionItem")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
        guard let collectionItem = item as? AnimationLibraryCollectionItem else {
            return item
        }

        let animation = filteredItems[indexPath.item]
        collectionItem.configure(item: animation, isFavorite: favorites.contains(animation.id), displayMode: displayMode)
        collectionItem.onToggleFavorite = { [weak self] selectedAnimation in
            self?.toggleFavorite(selectedAnimation)
        }
        collectionItem.onBeam = { [weak self] selectedAnimation in
            guard let self else { return }
            if let index = self.filteredItems.firstIndex(where: { $0.id == selectedAnimation.id }) {
                self.selectItem(at: index)
            }
            self.triggerSend(for: selectedAnimation)
        }
        return collectionItem
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item < filteredItems.count else {
            return
        }
        selectedItemID = filteredItems[indexPath.item].id
        updateDetailPanel()
    }

    private func buildUI(in panel: NSPanel) {
        guard let contentView = panel.contentView else {
            return
        }

        let rootView = NSVisualEffectView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.material = .underWindowBackground
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        contentView.addSubview(rootView)

        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        let headerSymbolConfig = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        headerIconView.image = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: "Animation Library")?.withSymbolConfiguration(headerSymbolConfig)
        headerIconView.contentTintColor = .systemOrange

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        summaryLabel.textColor = .secondaryLabelColor

        resultsLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        resultsLabel.textColor = .secondaryLabelColor

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search nyan, bunny, weather, retro, cute…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true

        categoryPopUp.translatesAutoresizingMaskIntoConstraints = false
        categoryPopUp.target = self
        categoryPopUp.action = #selector(categoryChanged)

        displayModeControl.translatesAutoresizingMaskIntoConstraints = false
        displayModeControl.selectedSegment = AnimationLibraryDisplayMode.grid.rawValue
        displayModeControl.target = self
        displayModeControl.action = #selector(displayModeChanged)

        favoritesOnlyButton.translatesAutoresizingMaskIntoConstraints = false
        favoritesOnlyButton.setButtonType(.toggle)
        favoritesOnlyButton.bezelStyle = .rounded
        favoritesOnlyButton.image = makeMenuSymbol("star", description: "Favorites")
        favoritesOnlyButton.imagePosition = .imageLeading
        favoritesOnlyButton.target = self
        favoritesOnlyButton.action = #selector(toggleFavoritesOnly)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .rounded
        refreshButton.image = makeMenuSymbol("arrow.clockwise", description: "Refresh")
        refreshButton.imagePosition = .imageLeading
        refreshButton.target = self
        refreshButton.action = #selector(refreshLibrary)

        let titleRow = NSStackView(views: [headerIconView, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let chipRow = NSStackView(views: [assetChip, categoryChip, favoriteChip])
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 8
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [titleRow, summaryLabel, chipRow])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let toolbarStack = NSStackView(views: [searchField, categoryPopUp, displayModeControl, favoritesOnlyButton, refreshButton, resultsLabel])
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 10
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false

        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let browserPane = NSView()
        browserPane.translatesAutoresizingMaskIntoConstraints = false

        collectionScrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionScrollView.hasVerticalScroller = true
        collectionScrollView.drawsBackground = false

        flowLayout.sectionInset = NSEdgeInsets(top: 6, left: 4, bottom: 24, right: 4)
        flowLayout.minimumInteritemSpacing = 14
        flowLayout.minimumLineSpacing = 14

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(AnimationLibraryCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("AnimationLibraryCollectionItem"))
        collectionScrollView.documentView = collectionView

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        browserPane.addSubview(collectionScrollView)
        browserPane.addSubview(emptyLabel)

        inspectorView.translatesAutoresizingMaskIntoConstraints = false
        inspectorView.material = .menu
        inspectorView.blendingMode = .withinWindow
        inspectorView.state = .active
        inspectorView.wantsLayer = true
        inspectorView.layer?.cornerRadius = 24
        inspectorView.layer?.cornerCurve = .continuous
        inspectorView.layer?.borderWidth = 1
        inspectorView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor

        detailPreviewView.translatesAutoresizingMaskIntoConstraints = false
        detailPreviewView.onPrimaryAction = { [weak self] in
            guard let self, let item = self.currentSelectedItem else { return }
            self.triggerSend(for: item)
        }

        detailTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailTitleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        detailTitleLabel.lineBreakMode = .byTruncatingTail

        detailMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        detailMetaLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailMetaLabel.textColor = .secondaryLabelColor

        detailPathLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailPathLabel.textColor = .secondaryLabelColor
        detailPathLabel.maximumNumberOfLines = 3
        detailPathLabel.lineBreakMode = .byTruncatingMiddle

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .rounded
        sendButton.bezelColor = NSColor.systemBlue.withAlphaComponent(0.92)
        sendButton.contentTintColor = .white
        sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
        sendButton.imagePosition = .imageLeading
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendSelectedItem)

        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.bezelStyle = .rounded
        revealButton.image = makeMenuSymbol("folder", description: "Reveal in Finder")
        revealButton.imagePosition = .imageLeading
        revealButton.target = self
        revealButton.action = #selector(revealSelectedItem)

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.bezelStyle = .rounded
        favoriteButton.image = makeMenuSymbol("star", description: "Favorite")
        favoriteButton.imagePosition = .imageLeading
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavoriteForSelectedItem)

        let secondaryButtons = NSStackView(views: [revealButton, favoriteButton])
        secondaryButtons.orientation = .horizontal
        secondaryButtons.alignment = .centerY
        secondaryButtons.spacing = 10
        secondaryButtons.distribution = .fillEqually
        secondaryButtons.translatesAutoresizingMaskIntoConstraints = false

        let inspectorButtons = NSStackView(views: [sendButton, secondaryButtons])
        inspectorButtons.orientation = .vertical
        inspectorButtons.alignment = .leading
        inspectorButtons.spacing = 10
        inspectorButtons.translatesAutoresizingMaskIntoConstraints = false

        let inspectorChipRow = NSStackView(views: [detailCategoryChip, detailCollectionChip, detailDuplicateChip])
        inspectorChipRow.orientation = .horizontal
        inspectorChipRow.alignment = .centerY
        inspectorChipRow.spacing = 8
        inspectorChipRow.translatesAutoresizingMaskIntoConstraints = false

        let inspectorText = NSStackView(views: [detailTitleLabel, detailMetaLabel, inspectorChipRow, detailPathLabel, inspectorButtons])
        inspectorText.orientation = .vertical
        inspectorText.alignment = .leading
        inspectorText.spacing = 10
        inspectorText.translatesAutoresizingMaskIntoConstraints = false

        inspectorView.addSubview(detailPreviewView)
        inspectorView.addSubview(inspectorText)

        splitView.addArrangedSubview(browserPane)
        splitView.addArrangedSubview(inspectorView)

        rootView.addSubview(headerStack)
        rootView.addSubview(toolbarStack)
        rootView.addSubview(splitView)

        let safeGuide = rootView.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            headerStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 22),
            headerStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -22),
            headerStack.topAnchor.constraint(equalTo: safeGuide.topAnchor, constant: 18),

            toolbarStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 22),
            toolbarStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -22),
            toolbarStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            categoryPopUp.widthAnchor.constraint(equalToConstant: 170),
            displayModeControl.widthAnchor.constraint(equalToConstant: 120),

            splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 22),
            splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -22),
            splitView.topAnchor.constraint(equalTo: toolbarStack.bottomAnchor, constant: 16),
            splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -22),

            collectionScrollView.leadingAnchor.constraint(equalTo: browserPane.leadingAnchor),
            collectionScrollView.trailingAnchor.constraint(equalTo: browserPane.trailingAnchor),
            collectionScrollView.topAnchor.constraint(equalTo: browserPane.topAnchor),
            collectionScrollView.bottomAnchor.constraint(equalTo: browserPane.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: browserPane.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: browserPane.centerYAnchor),

            inspectorView.widthAnchor.constraint(equalToConstant: 320),

            detailPreviewView.topAnchor.constraint(equalTo: inspectorView.topAnchor, constant: 18),
            detailPreviewView.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            detailPreviewView.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            detailPreviewView.heightAnchor.constraint(equalToConstant: 250),

            inspectorText.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            inspectorText.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            inspectorText.topAnchor.constraint(equalTo: detailPreviewView.bottomAnchor, constant: 16),

            sendButton.widthAnchor.constraint(equalTo: inspectorText.widthAnchor),
            secondaryButtons.widthAnchor.constraint(equalTo: inspectorText.widthAnchor),
        ])

        updateDetailPanel()
        updateCollectionLayout()
    }

    @objc private func searchChanged() {
        applyFilters()
    }

    @objc private func categoryChanged() {
        selectedCategory = (categoryPopUp.selectedItem?.representedObject as? String) ?? "all"
        applyFilters()
    }

    @objc private func displayModeChanged() {
        displayMode = AnimationLibraryDisplayMode(rawValue: displayModeControl.selectedSegment) ?? .grid
        updateCollectionLayout()
        collectionView.reloadData()
    }

    @objc private func toggleFavoritesOnly() {
        applyFilters()
    }

    @objc private func refreshLibrary() {
        reloadLibrary()
    }

    @objc private func sendSelectedItem() {
        guard let currentSelectedItem else {
            NSSound.beep()
            return
        }
        triggerSend(for: currentSelectedItem)
    }

    @objc private func revealSelectedItem() {
        guard let currentSelectedItem else {
            NSSound.beep()
            return
        }
        onReveal(currentSelectedItem)
    }

    @objc private func toggleFavoriteForSelectedItem() {
        guard let currentSelectedItem else {
            NSSound.beep()
            return
        }
        toggleFavorite(currentSelectedItem)
    }

    private var currentSelectedItem: AnimationLibraryItem? {
        guard let selectedItemID else {
            return nil
        }
        return filteredItems.first(where: { $0.id == selectedItemID }) ?? allItems.first(where: { $0.id == selectedItemID })
    }

    private func reloadLibrary() {
        summaryLabel.stringValue = "Loading curated animation library…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = AnimationLibraryCatalog.loadItems()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.allItems = items
                self.rebuildCategoryMenu()
                self.applyFilters()
            }
        }
    }

    private func rebuildCategoryMenu() {
        let previousCategory = selectedCategory
        let categories = Array(Set(allItems.map(\.category))).sorted()
        categoryPopUp.removeAllItems()
        categoryPopUp.addItem(withTitle: "All Categories")
        categoryPopUp.lastItem?.representedObject = "all"
        categoryPopUp.lastItem?.image = makeMenuSymbol("square.grid.3x3.fill", description: "All Categories")
        for category in categories {
            categoryPopUp.addItem(withTitle: AnimationLibraryCatalog.displayTitle(for: category))
            categoryPopUp.lastItem?.representedObject = category
            categoryPopUp.lastItem?.image = makeMenuSymbol(animationCategorySymbolName(category), description: category)
        }

        let targetCategory = previousCategory != "all" && categories.contains(previousCategory) ? previousCategory : "all"
        selectedCategory = targetCategory
        if let item = categoryPopUp.itemArray.first(where: { ($0.representedObject as? String) == targetCategory }) {
            categoryPopUp.select(item)
        } else {
            categoryPopUp.selectItem(at: 0)
        }
    }

    private func applyFilters() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favoritesOnly = favoritesOnlyButton.state == .on
        let preservedSelectionID = selectedItemID

        filteredItems = allItems.filter { item in
            if selectedCategory != "all" && item.category != selectedCategory {
                return false
            }
            if favoritesOnly && !favorites.contains(item.id) {
                return false
            }
            if !query.isEmpty && !item.searchText.contains(query) {
                return false
            }
            return true
        }

        collectionView.reloadData()
        emptyLabel.isHidden = !filteredItems.isEmpty
        summaryLabel.stringValue = "Native Swift picker with crisp previews and direct Ditoo beam."
        updateHeaderChips()
        resultsLabel.stringValue = "\(filteredItems.count) visible"

        if let preservedSelectionID, let index = filteredItems.firstIndex(where: { $0.id == preservedSelectionID }) {
            selectItem(at: index)
        } else if let firstIndex = filteredItems.indices.first {
            selectItem(at: firstIndex)
        } else {
            collectionView.deselectAll(nil)
            selectedItemID = nil
            updateDetailPanel()
        }
    }

    private func selectItem(at index: Int) {
        guard index >= 0, index < filteredItems.count else {
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.selectItems(at: [indexPath], scrollPosition: [])
        selectedItemID = filteredItems[index].id
        updateDetailPanel()
    }

    private func updateCollectionLayout() {
        let contentWidth = collectionScrollView.contentSize.width
        switch displayMode {
        case .grid:
            let targetCardWidth: CGFloat = 196
            let spacing: CGFloat = 16
            let columns = max(Int((contentWidth + spacing) / (targetCardWidth + spacing)), 2)
            let totalSpacing = CGFloat(max(columns - 1, 0)) * spacing
            let width = floor((contentWidth - totalSpacing - 8) / CGFloat(columns))
            flowLayout.itemSize = NSSize(width: max(width, 168), height: max(width, 168) + 74)
            flowLayout.minimumInteritemSpacing = spacing
            flowLayout.minimumLineSpacing = spacing
        case .list:
            flowLayout.itemSize = NSSize(width: max(contentWidth - 8, 420), height: 96)
            flowLayout.minimumInteritemSpacing = 0
            flowLayout.minimumLineSpacing = 10
        }
        flowLayout.invalidateLayout()
    }

    private func triggerSend(for item: AnimationLibraryItem) {
        sendButton.title = "Beaming…"
        sendButton.image = makeMenuSymbol("bolt.circle.fill", description: "Beaming")
        sendButton.isEnabled = false
        resultsLabel.stringValue = "Beaming \(item.title)…"
        onSend(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.sendButton.title = "Beam to Ditoo"
            self.sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
            self.sendButton.isEnabled = self.currentSelectedItem != nil
            self.resultsLabel.stringValue = "\(self.filteredItems.count) visible"
        }
    }

    private func updateDetailPanel() {
        guard let item = currentSelectedItem else {
            detailPreviewView.setFileURL(nil)
            detailTitleLabel.stringValue = "Select an animation"
            detailMetaLabel.stringValue = "Pick something excellent, then send it straight to the Ditoo."
            detailCategoryChip.update(text: "Category", symbolName: "sparkles")
            detailCollectionChip.update(text: "Collection", symbolName: "folder")
            detailDuplicateChip.update(text: "Unique", symbolName: "square.on.square")
            detailPathLabel.stringValue = ""
            sendButton.isEnabled = false
            revealButton.isEnabled = false
            favoriteButton.isEnabled = false
            favoriteButton.title = "Favorite"
            return
        }

        let collectionTitle = item.collection == "root" ? "Root" : AnimationLibraryCatalog.displayTitle(for: item.collection)
        detailPreviewView.setFileURL(item.fileURL)
        detailTitleLabel.stringValue = item.title
        detailMetaLabel.stringValue = "\(AnimationLibraryCatalog.displayTitle(for: item.category)) · \(collectionTitle)"
        detailCategoryChip.update(text: AnimationLibraryCatalog.displayTitle(for: item.category), symbolName: animationCategorySymbolName(item.category))
        detailCollectionChip.update(text: collectionTitle, symbolName: item.collection == "root" ? "shippingbox" : "folder")
        detailDuplicateChip.update(text: item.duplicateCount > 1 ? "\(item.duplicateCount) dupes" : "Unique", symbolName: "square.on.square")
        detailPathLabel.stringValue = item.relativePath
        sendButton.isEnabled = true
        sendButton.title = "Beam to Ditoo"
        sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
        revealButton.isEnabled = true
        favoriteButton.isEnabled = true
        favoriteButton.title = favorites.contains(item.id) ? "Unfavorite" : "Favorite"
        favoriteButton.image = makeMenuSymbol(favorites.contains(item.id) ? "star.fill" : "star", description: "Favorite")
    }

    private func toggleFavorite(_ item: AnimationLibraryItem) {
        if favorites.contains(item.id) {
            favorites.remove(item.id)
        } else {
            favorites.insert(item.id)
        }
        AnimationLibraryCatalog.saveFavorites(favorites)
        collectionView.reloadData()
        updateDetailPanel()
        updateHeaderChips()
    }

    private func updateHeaderChips() {
        assetChip.update(text: "\(allItems.count) curated")
        categoryChip.update(text: "\(Set(allItems.map(\.category)).count) categories")
        favoriteChip.update(text: "\(favorites.count) favorites")
    }
}

@MainActor
private protocol CommandRunnerDelegate: AnyObject {
    func commandDidFinish(spec: CommandSpec, success: Bool, output: String)
}

private final class CommandRunner {
    private let executableURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/bin/divoom-display")
    weak var delegate: CommandRunnerDelegate?

    func run(_ spec: CommandSpec, completion: (@MainActor (Bool, String) -> Void)? = nil) {
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
                    let success = process.terminationStatus == 0
                    completion?(success, combined)
                    self?.delegate?.commandDidFinish(spec: spec, success: success, output: combined)
                }
            } catch {
                Task { @MainActor [weak self] in
                    completion?(false, error.localizedDescription)
                    self?.delegate?.commandDidFinish(spec: spec, success: false, output: error.localizedDescription)
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
    private let curatedAnimationsURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/assets/16x16/curated", isDirectory: true)
    private let recentAnimationDefaultsKey = "dev.kirniy.divoom.recent-library-animations"
    private let favoriteRotationIndexDefaultsKey = "dev.kirniy.divoom.favorite-rotation-index"
    private let summaryCard = MenuSummaryView(frame: NSRect(x: 0, y: 0, width: menuSurfaceWidth, height: summaryCardHeight))
    private let summaryCardItem = NSMenuItem()
    private let quickActionHub = QuickActionHubView(frame: NSRect(x: 0, y: 0, width: menuSurfaceWidth, height: quickHubHeight))
    private let quickActionHubItem = NSMenuItem()
    private let colorStudioView = ColorStudioView(frame: NSRect(x: 0, y: 0, width: menuSurfaceWidth, height: colorStudioHeight))
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private var autoCodexItem = NSMenuItem()
    private var autoClaudeItem = NSMenuItem()
    private var autoPairItem = NSMenuItem()
    private var autoIPFlagItem = NSMenuItem()
    private var autoFavoritesItem = NSMenuItem()
    private var codexBarShowUsedItem = NSMenuItem()
    private var codexBarShowRemainingItem = NSMenuItem()
    private var codexMetricItems: [CodexBarMetricPreference: NSMenuItem] = [:]
    private var claudeMetricItems: [CodexBarMetricPreference: NSMenuItem] = [:]
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
    private var animationLibraryController: AnimationLibraryWindowController?
    private var recentAnimationRelativePaths = UserDefaults.standard.stringArray(forKey: "dev.kirniy.divoom.recent-library-animations") ?? []

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

    func commandDidFinish(spec: CommandSpec, success: Bool, output: String) {
        updateActionStatus(summary: spec.label, success: success, details: output)
        if success {
            if let successSound = spec.successSound {
                playFeedbackSound(successSound)
            }
        } else if spec.playErrorSound {
            playFeedbackSound(.error)
        }
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
        quickActionHubItem.isEnabled = false
        quickActionHubItem.view = quickActionHub
        quickActionHub.onCodex = { [weak self] in self?.toggleAutoCodex() }
        quickActionHub.onClaude = { [weak self] in self?.toggleAutoClaude() }
        quickActionHub.onPair = { [weak self] in self?.toggleAutoPair() }
        quickActionHub.onIPFlag = { [weak self] in self?.toggleAutoIPFlag() }
        quickActionHub.onLibrary = { [weak self] in self?.openAnimationLibrary() }
        quickActionHub.onFavorites = { [weak self] in self?.toggleAutoFavorites() }
        menu.addItem(quickActionHubItem)
        menu.addItem(.separator())

        let studioMenu = NSMenu(title: "Studio")
        let colorStudioItem = NSMenuItem()
        colorStudioItem.isEnabled = false
        colorStudioItem.view = colorStudioView
        colorStudioView.onSendColor = { [weak self] color in
            self?.sendSelectedSceneColor(color, source: "Color studio")
        }
        colorStudioView.onSendMotion = { [weak self] colors, mode in
            self?.sendColorMotion(colors, mode: mode)
        }
        colorStudioView.onPickScreen = { [weak self] in
            self?.pickScreenColorForStudio()
        }
        studioMenu.addItem(colorStudioItem)
        studioMenu.addItem(.separator())
        studioMenu.addItem(makeSectionHeader("Beam"))
        studioMenu.addItem(makeItem("Solid Red", action: #selector(runNativeSolidRed), symbolName: "lightspectrum.horizontal"))
        studioMenu.addItem(makeItem("Purity Red", action: #selector(runNativePurityRed), symbolName: "flashlight.on.fill"))
        studioMenu.addItem(makeItem("Pixel Badge Test", action: #selector(runNativePixelTest), symbolName: "square.grid.3x3.fill"))
        studioMenu.addItem(.separator())
        studioMenu.addItem(makeSectionHeader("Motion"))
        studioMenu.addItem(makeItem("Signal Sweep Loop", action: #selector(runNativeAnimationSample), symbolName: "sparkles"))
        studioMenu.addItem(makeItem("Doom Fire Loop", action: #selector(runNativeUploadDoomFire), symbolName: "flame.fill"))
        studioMenu.addItem(makeItem("Nyan Cat", action: #selector(runNativeUploadNyan), symbolName: "star"))
        studioMenu.addItem(makeItem("Bunny Hop", action: #selector(runNativeUploadBunny), symbolName: "hare"))
        studioMenu.addItem(makeRecentAnimationsMenuItem())
        studioMenu.addItem(.separator())
        studioMenu.addItem(makeSectionHeader("Library"))
        studioMenu.addItem(makeItem("Open Animation Library", action: #selector(openAnimationLibrary), symbolName: "photo.stack"))
        studioMenu.addItem(makeItem("Reveal Curated Folder", action: #selector(revealCuratedAnimations), symbolName: "folder"))

        let liveMenu = NSMenu(title: "Live")
        liveMenu.addItem(makeSectionHeader("Sources"))
        autoCodexItem = makeItem("Codex", action: #selector(toggleAutoCodex), symbolName: "brain")
        autoClaudeItem = makeItem("Claude", action: #selector(toggleAutoClaude), symbolName: "message")
        autoPairItem = makeItem("Codex + Claude", action: #selector(toggleAutoPair), symbolName: "rectangle.split.2x1")
        autoIPFlagItem = makeItem("IP Flag", action: #selector(toggleAutoIPFlag), symbolName: "flag.2.crossed")
        autoFavoritesItem = makeItem("Rotate Favorites", action: #selector(toggleAutoFavorites), symbolName: "arrow.triangle.2.circlepath")
        liveMenu.addItem(autoCodexItem)
        liveMenu.addItem(autoClaudeItem)
        liveMenu.addItem(autoPairItem)
        liveMenu.addItem(autoIPFlagItem)
        liveMenu.addItem(autoFavoritesItem)
        liveMenu.addItem(.separator())
        liveMenu.addItem(makeSectionHeader("CodexBar Sync"))
        let usageModeMenu = NSMenu(title: "Usage Mode")
        let showUsed = codexBarPreferences().showUsed
        codexBarShowUsedItem = makeItem("Show Used", action: #selector(setCodexBarShowUsed), symbolName: "chart.bar.fill")
        codexBarShowRemainingItem = makeItem("Show Remaining", action: #selector(setCodexBarShowRemaining), symbolName: "arrow.uturn.backward.circle")
        codexBarShowUsedItem.state = showUsed ? .on : .off
        codexBarShowRemainingItem.state = showUsed ? .off : .on
        usageModeMenu.addItem(codexBarShowUsedItem)
        usageModeMenu.addItem(codexBarShowRemainingItem)
        liveMenu.addItem(makeSubmenuItem("Usage Mode", symbolName: "dial.medium", submenu: usageModeMenu))
        liveMenu.addItem(makeCodexBarMetricMenu(title: "Codex Metric", symbolName: "brain", provider: "codex", action: #selector(setCodexMetricPreference(_:))))
        liveMenu.addItem(makeCodexBarMetricMenu(title: "Claude Metric", symbolName: "message", provider: "claude", action: #selector(setClaudeMetricPreference(_:))))
        liveMenu.addItem(.separator())
        liveMenu.addItem(makeSectionHeader("Extras"))
        liveMenu.addItem(makeItem("OpenClaw Crab", action: #selector(pushOpenClawCrab), symbolName: "ladybug"))
        liveMenu.addItem(makeItem("Codex Pixel Art", action: #selector(pushOrbitArt), symbolName: "sparkles.square.filled.on.square"))

        let deviceMenu = NSMenu(title: "Device")
        deviceMenu.addItem(makeSectionHeader("Bluetooth"))
        deviceMenu.addItem(makeItem("Request Bluetooth Access", action: #selector(requestBluetoothAccess), symbolName: "dot.radiowaves.left.and.right"))
        deviceMenu.addItem(makeItem("Run Bluetooth Diagnostics", action: #selector(runBluetoothDiagnostics), symbolName: "antenna.radiowaves.left.and.right"))
        deviceMenu.addItem(makeItem("Probe Volume", action: #selector(runNativeVolumeProbe), symbolName: "speaker.wave.2"))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(makeSectionHeader("Ambient"))
        deviceMenu.addItem(makeItem("Battery Panel", action: #selector(runNativeBatteryStatus), symbolName: "battery.75"))
        deviceMenu.addItem(makeItem("System Panel", action: #selector(runNativeSystemStatus), symbolName: "cpu"))
        deviceMenu.addItem(makeItem("Network Panel", action: #selector(runNativeNetworkStatus), symbolName: "arrow.up.arrow.down.circle"))
        deviceMenu.addItem(makeItem("Animated Monitor", action: #selector(runNativeAnimatedMonitor), symbolName: "waveform.path.ecg"))
        deviceMenu.addItem(makeItem("Analog Clock", action: #selector(runNativeClockFace), symbolName: "clock"))
        deviceMenu.addItem(makeItem("Animated Clock", action: #selector(runNativeAnimatedClock), symbolName: "clock.arrow.2.circlepath"))
        deviceMenu.addItem(makeItem("Pomodoro Timer", action: #selector(runNativePomodoroTimer), symbolName: "timer"))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(makeSectionHeader("Feedback"))
        deviceMenu.addItem(makeItem("Attention Chime", action: #selector(playAttentionSound), symbolName: "bell.badge"))
        deviceMenu.addItem(makeItem("Completion Chime", action: #selector(playCompletionSound), symbolName: "checkmark.circle"))

        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(makeSectionHeader("Workspace"))
        toolsMenu.addItem(makeItem("Open Research Notes", action: #selector(openResearch), symbolName: "doc.text.magnifyingglass"))
        toolsMenu.addItem(makeItem("Open OpenClaw Notes", action: #selector(openOpenClawNotes), symbolName: "doc.richtext"))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(makeSectionHeader("App"))
        toolsMenu.addItem(makeItem("Quit", action: #selector(quitApp), keyEquivalent: "q", symbolName: "power"))

        menu.addItem(makeSubmenuItem("Studio", symbolName: "wand.and.stars", submenu: studioMenu))
        menu.addItem(makeSubmenuItem("Live", symbolName: "brain", submenu: liveMenu))
        menu.addItem(makeSubmenuItem("Device", symbolName: "dot.radiowaves.left.and.right", submenu: deviceMenu))
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

    private func codexBarPreferences() -> (metrics: [String: String], showUsed: Bool) {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.steipete.codexbar") ?? [:]
        let metrics = (domain["menuBarMetricPreferences"] as? [String: String]) ?? [:]
        let showUsed = domain["usageBarsShowUsed"] as? Bool ?? true
        return (metrics, showUsed)
    }

    private func mutateCodexBarPreferences(_ mutate: (inout [String: Any]) -> Void) {
        var domain = UserDefaults.standard.persistentDomain(forName: "com.steipete.codexbar") ?? [:]
        mutate(&domain)
        UserDefaults.standard.setPersistentDomain(domain, forName: "com.steipete.codexbar")
        configureMenu()
    }

    private func makeCodexBarMetricMenu(
        title: String,
        symbolName: String,
        provider: String,
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        let currentMetric = codexBarPreferences().metrics[provider] ?? "primary"
        var items: [CodexBarMetricPreference: NSMenuItem] = [:]

        for metric in CodexBarMetricPreference.allCases {
            let item = makeItem(metric.title, action: action, symbolName: nil)
            item.representedObject = metric.rawValue
            item.state = currentMetric == metric.rawValue ? .on : .off
            submenu.addItem(item)
            items[metric] = item
        }

        if provider == "codex" {
            codexMetricItems = items
        } else if provider == "claude" {
            claudeMetricItems = items
        }

        return makeSubmenuItem(title, symbolName: symbolName, submenu: submenu)
    }

    private func makeRecentAnimationsMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "Recent Picks")
        let recentPaths = Array(recentAnimationRelativePaths.prefix(8))

        if recentPaths.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent sends yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for relativePath in recentPaths {
                let title = prettifyRecentAnimationTitle(relativePath)
                let item = NSMenuItem(title: title, action: #selector(sendRecentAnimation(_:)), keyEquivalent: "")
                item.target = self
                item.image = makeMenuSymbol("clock.arrow.circlepath", description: title)
                item.representedObject = relativePath
                submenu.addItem(item)
            }
        }

        return makeSubmenuItem("Recent Picks", symbolName: "clock.arrow.circlepath", submenu: submenu)
    }

    private func prettifyRecentAnimationTitle(_ relativePath: String) -> String {
        let fileName = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        let cleaned = fileName.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        let title = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? fileName : title
    }

    private func recordRecentAnimation(relativePath: String) {
        recentAnimationRelativePaths.removeAll(where: { $0 == relativePath })
        recentAnimationRelativePaths.insert(relativePath, at: 0)
        recentAnimationRelativePaths = Array(recentAnimationRelativePaths.prefix(8))
        UserDefaults.standard.set(recentAnimationRelativePaths, forKey: recentAnimationDefaultsKey)
        configureMenu()
    }

    private func run(
        label: String,
        arguments: [String],
        successSound: FeedbackSoundProfile? = nil,
        playErrorSound: Bool = true,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        runner.run(
            CommandSpec(
                label: label,
                arguments: arguments,
                successSound: successSound,
                playErrorSound: playErrorSound
            ),
            completion: completion
        )
    }

    private func runRenderedFeed(
        label: String,
        feed: String,
        successSound: FeedbackSoundProfile? = nil,
        playErrorSound: Bool = true,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/bin/divoom-display")
            process.arguments = ["render-feed", "--feed", feed]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    Task { @MainActor [weak self] in
                        self?.updateActionStatus(summary: label, success: false, details: stderr.isEmpty ? stdout : stderr)
                        if playErrorSound {
                            self?.playFeedbackSound(.error)
                        }
                        completion?(false, stderr.isEmpty ? stdout : stderr)
                    }
                    return
                }

                guard
                    let data = stdout.data(using: .utf8),
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let outputPath = payload["output"] as? String
                else {
                    Task { @MainActor [weak self] in
                        self?.updateActionStatus(summary: label, success: false, details: "Renderer did not return a usable output path.")
                        if playErrorSound {
                            self?.playFeedbackSound(.error)
                        }
                        completion?(false, "Renderer did not return a usable output path.")
                    }
                    return
                }

                let resolvedLabel = (payload["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (payload["label"] as? String ?? label)
                    : label

                Task { @MainActor [weak self] in
                    self?.run(
                        label: resolvedLabel,
                        arguments: ["native-headless", "send-gif", "--path", outputPath],
                        successSound: successSound,
                        playErrorSound: playErrorSound,
                        completion: completion
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.updateActionStatus(summary: label, success: false, details: error.localizedDescription)
                    if playErrorSound {
                        self?.playFeedbackSound(.error)
                    }
                    completion?(false, error.localizedDescription)
                }
            }
        }
    }

    private func launchDetachedShellCommand(_ command: String, summary: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
            updateActionStatus(summary: summary, success: true, details: command)
        } catch {
            updateActionStatus(summary: summary, success: false, details: error.localizedDescription)
        }
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
                if self.autoRefreshMode != .off {
                    self.refreshLiveFeed(self.autoRefreshMode)
                }
            }
        }

        updateAutoRefreshUI()
    }

    private func updateAutoRefreshUI() {
        autoCodexItem.state = autoRefreshMode == .codex ? .on : .off
        autoClaudeItem.state = autoRefreshMode == .claude ? .on : .off
        autoPairItem.state = autoRefreshMode == .pair ? .on : .off
        autoIPFlagItem.state = autoRefreshMode == .ipFlag ? .on : .off
        autoFavoritesItem.state = autoRefreshMode == .favorites ? .on : .off
        quickActionHub.activeAction = autoRefreshMode.quickActionKind
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
        case .pair:
            return "Codex + Claude every 60s"
        case .ipFlag:
            return "IP Flag every 60s"
        case .favorites:
            return "Rotate Favorites every 60s"
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
        runRenderedFeed(label: "Codex", feed: "codex", successSound: .animation)
    }

    @objc private func pushClaudeStatus() {
        runRenderedFeed(label: "Claude", feed: "claude", successSound: .animation)
    }

    @objc private func pushSplitAgentStatus() {
        runRenderedFeed(label: "Codex + Claude", feed: "pair", successSound: .animation)
    }

    @objc private func pushCurrentIPFlag() {
        runRenderedFeed(label: "IP Flag", feed: "ip-flag", successSound: .animation)
    }

    @objc private func pushOpenClawCrab() {
        run(
            label: "OpenClaw crab",
            arguments: [
                "native-headless",
                "send-gif",
                "--path",
                "/Users/kirniy/dev/divoom/assets/16x16/curated/pixel-displays/soniccrabe.gif",
            ],
            successSound: .animation
        )
    }

    @objc private func pushOrbitArt() {
        run(label: "Orbit art", arguments: ["send-art", "--style", "orbit", "--seed", "17", "--terminate"], successSound: .animation)
    }

    @objc private func pushDoomFireSample() {
        run(
            label: "Doom Fire sample",
            arguments: [
                "send-divoom16",
                "/Users/kirniy/dev/divoom/assets/16x16/generated/doom_fire.divoom16",
                "--terminate",
            ],
            successSound: .animation
        )
    }

    @objc private func pushBunnySample() {
        run(
            label: "Bunny sample",
            arguments: [
                "send-divoom16",
                "/Users/kirniy/dev/divoom/andreas-js/images/bunny.divoom16",
                "--terminate",
            ],
            successSound: .animation
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

    private func pickScreenColorForStudio() {
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
                self.updateActionStatus(
                    summary: "Screen color sampled",
                    success: true,
                    details: hexString(for: color) ?? "Unknown color"
                )
            }
        }
    }

    private func sendColorMotion(_ colors: [NSColor], mode: ColorMotionMode) {
        let hexes = colors.compactMap { hexString(for: $0) }
        guard !hexes.isEmpty else {
            updateActionStatus(
                summary: "Color motion failed",
                success: false,
                details: "No valid colors were selected."
            )
            return
        }

        if mode == .solid {
            sendSelectedSceneColor(colors.first ?? NSColor.systemRed, source: "Color motion studio")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/Users/kirniy/dev/divoom/bin/divoom-display")
            process.arguments = ["render-palette", "--mode", mode.rawValue]
            for hex in hexes {
                process.arguments?.append(contentsOf: ["--color", hex])
            }
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                guard process.terminationStatus == 0 else {
                    Task { @MainActor [weak self] in
                        self?.updateActionStatus(
                            summary: "\(mode.summaryPrefix) failed",
                            success: false,
                            details: stderr.isEmpty ? stdout : stderr
                        )
                    }
                    return
                }

                guard
                    let data = stdout.data(using: .utf8),
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let outputPath = payload["output"] as? String
                else {
                    Task { @MainActor [weak self] in
                        self?.updateActionStatus(
                            summary: "\(mode.summaryPrefix) failed",
                            success: false,
                            details: "Renderer did not return a usable output path."
                        )
                    }
                    return
                }

                let renderedLabel = (payload["label"] as? String) ?? mode.summaryPrefix
                Task { @MainActor [weak self] in
                    self?.run(
                        label: renderedLabel,
                        arguments: ["native-headless", "send-gif", "--path", outputPath],
                        successSound: .animation
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.updateActionStatus(
                        summary: "\(mode.summaryPrefix) failed",
                        success: false,
                        details: error.localizedDescription
                    )
                }
            }
        }
    }

    private func beamAnimationFile(
        _ fileURL: URL,
        label: String,
        successSound: FeedbackSoundProfile? = .animation,
        playErrorSound: Bool = true,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        run(
            label: label,
            arguments: ["native-headless", "send-gif", "--path", fileURL.path],
            successSound: successSound,
            playErrorSound: playErrorSound,
            completion: completion
        )
    }

    private func currentFavoriteAnimationItems() -> [AnimationLibraryItem] {
        let favorites = AnimationLibraryCatalog.loadFavorites()
        guard !favorites.isEmpty else {
            return []
        }
        return AnimationLibraryCatalog.loadItems().filter { favorites.contains($0.id) }
    }

    private func beamNextFavorite(
        playActivationSound: Bool,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        let items = currentFavoriteAnimationItems()
        guard !items.isEmpty else {
            updateActionStatus(
                summary: "Rotate Favorites unavailable",
                success: false,
                details: "Favorite some animations in the library first."
            )
            completion?(false, "Favorite some animations in the library first.")
            return
        }

        let currentIndex = UserDefaults.standard.integer(forKey: favoriteRotationIndexDefaultsKey)
        let item = items[currentIndex % items.count]
        UserDefaults.standard.set((currentIndex + 1) % items.count, forKey: favoriteRotationIndexDefaultsKey)
        recordRecentAnimation(relativePath: item.relativePath)
        beamAnimationFile(
            item.fileURL,
            label: "Favorites \(item.title)",
            successSound: playActivationSound ? .animation : nil,
            playErrorSound: playActivationSound,
            completion: completion
        )
    }

    @objc private func toggleAutoCodex() {
        toggleLiveFeed(.codex)
    }

    @objc private func toggleAutoClaude() {
        toggleLiveFeed(.claude)
    }

    @objc private func toggleAutoPair() {
        toggleLiveFeed(.pair)
    }

    @objc private func toggleAutoIPFlag() {
        toggleLiveFeed(.ipFlag)
    }

    @objc private func toggleAutoFavorites() {
        toggleLiveFeed(.favorites)
    }

    @objc private func setCodexBarShowUsed() {
        mutateCodexBarPreferences { domain in
            domain["usageBarsShowUsed"] = true
        }
        updateActionStatus(
            summary: "CodexBar sync set to used",
            success: true,
            details: "Ditoo feeds will now follow CodexBar's used percentages."
        )
    }

    @objc private func setCodexBarShowRemaining() {
        mutateCodexBarPreferences { domain in
            domain["usageBarsShowUsed"] = false
        }
        updateActionStatus(
            summary: "CodexBar sync set to remaining",
            success: true,
            details: "Ditoo feeds will now follow CodexBar's remaining percentages."
        )
    }

    @objc private func setCodexMetricPreference(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        mutateCodexBarPreferences { domain in
            var metrics = (domain["menuBarMetricPreferences"] as? [String: String]) ?? [:]
            metrics["codex"] = rawValue
            domain["menuBarMetricPreferences"] = metrics
        }
        updateActionStatus(
            summary: "Codex metric set to \(rawValue)",
            success: true,
            details: "Ditoo feeds now follow CodexBar's codex metric = \(rawValue)."
        )
    }

    @objc private func setClaudeMetricPreference(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        mutateCodexBarPreferences { domain in
            var metrics = (domain["menuBarMetricPreferences"] as? [String: String]) ?? [:]
            metrics["claude"] = rawValue
            domain["menuBarMetricPreferences"] = metrics
        }
        updateActionStatus(
            summary: "Claude metric set to \(rawValue)",
            success: true,
            details: "Ditoo feeds now follow CodexBar's claude metric = \(rawValue)."
        )
    }

    @objc private func openAnimationLibrary() {
        let controller = ensureAnimationLibraryController()
        controller.showLibrary()
    }

    @objc private func revealCuratedAnimations() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: curatedAnimationsURL.path)
        updateActionStatus(
            summary: "Revealed curated animations",
            success: true,
            details: curatedAnimationsURL.path
        )
    }

    @objc private func sendRecentAnimation(_ sender: NSMenuItem) {
        guard let relativePath = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        let animationURL = curatedAnimationsURL.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: animationURL.path) else {
            updateActionStatus(
                summary: "Recent animation missing",
                success: false,
                details: animationURL.path
            )
            return
        }

        recordRecentAnimation(relativePath: relativePath)
        beamAnimationFile(animationURL, label: sender.title, successSound: .animation)
    }

    @objc private func openResearch() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/kirniy/dev/divoom/RESEARCH.md"))
    }

    @objc private func openOpenClawDashboard() {
        launchDetachedShellCommand("openclaw dashboard >/tmp/divoom-openclaw-dashboard.log 2>&1 &", summary: "Opened OpenClaw dashboard")
    }

    @objc private func openOpenClawNotes() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/kirniy/dev/divoom/OPENCLAW_INTEGRATION.md"))
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func toggleLiveFeed(_ mode: AutoRefreshMode) {
        if autoRefreshMode == mode {
            setAutoRefreshMode(.off)
            quickActionHub.loadingAction = nil
            updateActionStatus(
                summary: "Live \(mode.title) stopped",
                success: true,
                details: "Automatic refresh disabled."
            )
            return
        }

        if mode == .favorites {
            setAutoRefreshMode(.off)
            quickActionHub.loadingAction = mode.quickActionKind
            beamNextFavorite(playActivationSound: true) { [weak self] success, _ in
                guard let self else { return }
                self.quickActionHub.loadingAction = nil
                guard success else { return }
                self.setAutoRefreshMode(.favorites)
            }
            return
        }

        guard let feed = mode.feedIdentifier else {
            return
        }

        setAutoRefreshMode(.off)
        quickActionHub.loadingAction = mode.quickActionKind
        runRenderedFeed(
            label: mode.title,
            feed: feed,
            successSound: .animation,
            playErrorSound: true
        ) { [weak self] success, _ in
            guard let self else { return }
            self.quickActionHub.loadingAction = nil
            guard success else { return }
            self.setAutoRefreshMode(mode)
        }
    }

    private func refreshLiveFeed(_ mode: AutoRefreshMode) {
        if mode == .favorites {
            beamNextFavorite(playActivationSound: false)
            return
        }
        guard let feed = mode.feedIdentifier else {
            return
        }
        runRenderedFeed(
            label: mode.title,
            feed: feed,
            successSound: nil,
            playErrorSound: false
        )
    }

    private func ensureAnimationLibraryController() -> AnimationLibraryWindowController {
        if let animationLibraryController {
            return animationLibraryController
        }
        let controller = AnimationLibraryWindowController(
            onSend: { [weak self] item in
                self?.recordRecentAnimation(relativePath: item.relativePath)
                self?.beamAnimationFile(item.fileURL, label: "Library \(item.title)", successSound: .animation)
            },
            onReveal: { [weak self] item in
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
                self?.updateActionStatus(
                    summary: "Revealed animation",
                    success: true,
                    details: item.fileURL.path
                )
            }
        )
        animationLibraryController = controller
        return controller
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
