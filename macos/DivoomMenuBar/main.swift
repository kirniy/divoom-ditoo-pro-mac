import AVFoundation
import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import LocalAuthentication
import QuartzCore
import Security
import ServiceManagement

enum AppLog {
    static let fileURL = URL(fileURLWithPath: "/Users/kirniy/Library/Logs/DivoomMenuBar.log")

    static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let data = Data(line.utf8)

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            NSLog("DivoomMenuBar log write failed: \(error.localizedDescription)")
        }
    }
}

private let rootMenuSurfaceWidth: CGFloat = 352
private let studioMenuSurfaceWidth: CGFloat = 368
private let summaryCardHeight: CGFloat = 132
private let quickHubHeight: CGFloat = 228
private let colorStudioHeight: CGFloat = 246
private let cloudLibraryEnabledDefaultsKey = "dev.kirniy.divoom.cloud-library-enabled"
private let cloudSyncOnLaunchDefaultsKey = "dev.kirniy.divoom.cloud-sync-on-launch"
private let cloudAutoSyncEnabledDefaultsKey = "dev.kirniy.divoom.cloud-auto-sync-enabled"
private let cloudEmailHintDefaultsKey = "dev.kirniy.divoom.cloud-email-hint"
private let cloudManifestURL = divoomRepoURL(".cache/divoom-cloud/manifest.json")
private let divoomCloudKeychainService = "dev.kirniy.divoom.ditoo-pro-mac.cloud"
private let divoomCloudEmailAccount = "email"
private let divoomCloudPasswordAccount = "password"
private let divoomCloudInternetPasswordServers = [
    "divoom-gz.com",
    "app.divoom-gz.com",
    "appin.divoom-gz.com",
    "appusa.divoom-gz.com",
    "m.divoom-gz.com",
]

private enum DivoomCloudKeychain {
    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: divoomCloudKeychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private static func trustedApplicationList() -> [SecTrustedApplication] {
        var trusted: [SecTrustedApplication] = []

        func appendTrustedApplication(for path: String?) {
            var app: SecTrustedApplication?
            let status = path.map { SecTrustedApplicationCreateFromPath($0, &app) }
                ?? SecTrustedApplicationCreateFromPath(nil, &app)
            guard status == errSecSuccess, let app else {
                return
            }
            trusted.append(app)
        }

        appendTrustedApplication(for: Bundle.main.bundlePath)
        appendTrustedApplication(for: nil)
        return trusted
    }

    private static func trustedAccess(account: String) -> SecAccess? {
        let trustedApplications = trustedApplicationList()
        guard !trustedApplications.isEmpty else {
            return nil
        }

        var access: SecAccess?
        let status = SecAccessCreate(
            "Divoom Cloud \(account)" as CFString,
            trustedApplications as CFArray,
            &access
        )
        guard status == errSecSuccess else {
            return nil
        }
        return access
    }

    static func read(account: String, allowInteraction: Bool = false) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrLabel as String] = "Divoom Cloud \(account)"
        if let access = trustedAccess(account: account) {
            addQuery[kSecAttrAccess as String] = access
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    static func delete(account: String) {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
    }
}

private struct DivoomCloudCredentials {
    enum Source: Equatable {
        case appKeychain
        case syncedInternetPassword(String)
    }

    let email: String
    let password: String
    let source: Source
}

@discardableResult
private func persistDivoomCloudCredentials(email: String, password: String) -> Bool {
    let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedEmail.isEmpty, !password.isEmpty else {
        DivoomCloudCredentialResolver.cacheAppKeychainCredentials(email: "", password: "")
        return false
    }

    let emailSaved = DivoomCloudKeychain.write(trimmedEmail, account: divoomCloudEmailAccount)
    let passwordSaved = DivoomCloudKeychain.write(password, account: divoomCloudPasswordAccount)
    if emailSaved && passwordSaved {
        DivoomCloudCredentialResolver.cacheAppKeychainCredentials(email: trimmedEmail, password: password)
    }
    return emailSaved && passwordSaved
}

private struct DivoomCloudCredentialHint {
    let email: String
    let server: String
}

private enum DivoomCloudCredentialResolver {
    private static var localCredentialsCache: DivoomCloudCredentials?
    private static var localCredentialsResolved = false
    private static var passiveSyncedCredentialsCache: DivoomCloudCredentials?
    private static var passiveSyncedCredentialsResolved = false
    private static var passiveSyncedHintCache: DivoomCloudCredentialHint?
    private static var passiveSyncedHintResolved = false

    static func passiveLocalCredentialHint() -> String? {
        let email = UserDefaults.standard.string(forKey: cloudEmailHintDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email, !email.isEmpty else {
            return nil
        }
        return email
    }

    static func setPassiveLocalCredentialHint(_ email: String?) {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: cloudEmailHintDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: cloudEmailHintDefaultsKey)
        }
    }

    static func appKeychainCredentials(forceRefresh: Bool = false, allowInteraction: Bool = false) -> DivoomCloudCredentials? {
        if !forceRefresh && localCredentialsResolved {
            return localCredentialsCache
        }

        let email = resolveLocalCredentialEmail(allowInteraction: allowInteraction)
        let password = DivoomCloudKeychain.read(account: divoomCloudPasswordAccount, allowInteraction: allowInteraction)
        guard let email, !email.isEmpty, let password, !password.isEmpty else {
            return nil
        }

        let credentials = DivoomCloudCredentials(email: email, password: password, source: .appKeychain)
        localCredentialsCache = credentials
        localCredentialsResolved = true
        setPassiveLocalCredentialHint(email)
        return credentials
    }

    static func cacheAppKeychainCredentials(email: String, password: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            localCredentialsCache = nil
            localCredentialsResolved = false
            setPassiveLocalCredentialHint(nil)
            return
        }

        localCredentialsCache = DivoomCloudCredentials(
            email: trimmedEmail,
            password: password,
            source: .appKeychain
        )
        localCredentialsResolved = true
        setPassiveLocalCredentialHint(trimmedEmail)
    }

    static func resetPassiveCaches() {
        localCredentialsCache = nil
        localCredentialsResolved = false
        passiveSyncedCredentialsCache = nil
        passiveSyncedCredentialsResolved = false
        passiveSyncedHintCache = nil
        passiveSyncedHintResolved = false
    }

    private static func resolveLocalCredentialEmail(allowInteraction: Bool = false) -> String? {
        if let email = passiveLocalCredentialHint() {
            return email
        }
        guard let email = DivoomCloudKeychain.read(account: divoomCloudEmailAccount, allowInteraction: allowInteraction)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else {
            return nil
        }
        setPassiveLocalCredentialHint(email)
        return email
    }

    static func syncedInternetPasswordHint() -> DivoomCloudCredentialHint? {
        if passiveSyncedHintResolved {
            return passiveSyncedHintCache
        }

        for server in divoomCloudInternetPasswordServers {
            if let hint = readInternetPasswordHint(server: server) {
                passiveSyncedHintCache = hint
                passiveSyncedHintResolved = true
                return hint
            }
        }

        passiveSyncedHintResolved = true
        passiveSyncedHintCache = nil
        return nil
    }

    static func syncedInternetPasswordCredentials(
        allowInteraction: Bool = false,
        forceRefresh: Bool = false
    ) -> DivoomCloudCredentials? {
        if !allowInteraction && !forceRefresh && passiveSyncedCredentialsResolved {
            return passiveSyncedCredentialsCache
        }

        let servers: [String]
        if let hintedServer = syncedInternetPasswordHint()?.server {
            servers = [hintedServer]
        } else {
            servers = divoomCloudInternetPasswordServers
        }

        for server in servers {
            if let credentials = readInternetPassword(server: server, allowInteraction: allowInteraction) {
                passiveSyncedCredentialsCache = credentials
                passiveSyncedCredentialsResolved = true
                passiveSyncedHintCache = DivoomCloudCredentialHint(email: credentials.email, server: server)
                passiveSyncedHintResolved = true
                return credentials
            }
        }

        if !allowInteraction {
            passiveSyncedCredentialsResolved = true
            passiveSyncedCredentialsCache = nil
        }
        return nil
    }

    static func bestAvailableCredentials(allowInteraction: Bool = false) -> DivoomCloudCredentials? {
        appKeychainCredentials(forceRefresh: allowInteraction, allowInteraction: allowInteraction)
    }

    private static func readInternetPassword(server: String, allowInteraction: Bool) -> DivoomCloudCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              !account.isEmpty,
              let data = attributes[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else {
            return nil
        }

        return DivoomCloudCredentials(
            email: account,
            password: password,
            source: .syncedInternetPassword(server)
        )
    }

    private static func readInternetPasswordHint(server: String) -> DivoomCloudCredentialHint? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if #unavailable(macOS 11.0) {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              !account.isEmpty
        else {
            return nil
        }

        return DivoomCloudCredentialHint(email: account, server: server)
    }
}

private enum FavoritesPlaybackOption: Int, CaseIterable {
    case once = 1
    case twice = 2
    case thrice = 3
    case four = 4
    case eight = 8
    case infinite = 0

    var title: String {
        switch self {
        case .once:
            return "Once"
        case .twice:
            return "Twice"
        case .thrice:
            return "3 Loops"
        case .four:
            return "4 Loops"
        case .eight:
            return "8 Loops"
        case .infinite:
            return "Infinite"
        }
    }
}

private enum ColorMotionMode: String, CaseIterable, Codable {
    case solid
    case gradientSweep = "gradient-sweep"
    case ribbonWave = "ribbon-wave"
    case diamondBloom = "diamond-bloom"
    case paletteSteps = "palette-steps"
    case checkerShift = "checker-shift"
    case pulse
    case aurora

    var title: String {
        switch self {
        case .solid:
            return "Solid"
        case .gradientSweep:
            return "Gradient Sweep"
        case .ribbonWave:
            return "Ribbon Wave"
        case .diamondBloom:
            return "Diamond Bloom"
        case .paletteSteps:
            return "Palette Steps"
        case .checkerShift:
            return "Checker Shift"
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
        case .ribbonWave:
            return "Ribbon"
        case .diamondBloom:
            return "Bloom"
        case .paletteSteps:
            return "Steps"
        case .checkerShift:
            return "Checker"
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
        case .ribbonWave:
            return "Ribbon Wave"
        case .diamondBloom:
            return "Diamond Bloom"
        case .paletteSteps:
            return "Palette Steps"
        case .checkerShift:
            return "Checker Shift"
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

private struct DivoomCloudManifestEntry: Decodable {
    let source: String
    let scope: String
    let sort: String
    let category: String
    let cloud_classify: Int
    let collection: String
    let gallery_id: Int
    let file_id: String
    let file_name: String
    let likes: Int
    let views: Int
    let shares: Int
    let comments: Int
    let country: String
    let user_name: String
    let user_id: Int?
    let clock_id: Int?
    let item_id: Int?
    let date: String
    let file_type: Int
    let is_liked: Bool
    let relative_path: String
}

private struct DivoomCloudStoreClassifyEntry: Decodable {
    let classify_id: Int
    let classify_name: String
    let name: String
    let title: String
    let image_id: String
    let sort_order: Int
}

private struct DivoomCloudPlaylistEntry: Decodable {
    let owner: String
    let target_user_id: Int?
    let play_id: Int
    let play_name: String
    let name: String
    let gallery_id: Int
    let cover_file_id: String
    let image_file_id: String
    let likes: Int
    let views: Int
    let file_count: Int
}

private struct DivoomCloudManifest: Decodable {
    let generatedAt: String
    let source: String
    let outputRoot: String
    let itemCount: Int
    let categories: [String]
    let includesAlbums: Bool
    let sorts: [String]?
    let searchQueries: [String]?
    let storeEndpoint: String?
    let storeFlag: Int?
    let storeClassifyId: Int?
    let storeClassify: [DivoomCloudStoreClassifyEntry]?
    let myPlaylists: [DivoomCloudPlaylistEntry]?
    let someonePlaylists: [DivoomCloudPlaylistEntry]?
    let items: [DivoomCloudManifestEntry]
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

private struct SummaryChipSpec {
    let text: String
    let symbolName: String
    let accentColor: NSColor?

    init(text: String, symbolName: String, accentColor: NSColor? = nil) {
        self.text = text
        self.symbolName = symbolName
        self.accentColor = accentColor
    }
}

private struct ConnectionFacts {
    var authorizationPending = false
    var authorizationDenied = false
    var lightReady = false
    var lightConnected = false
    var lightConnecting = false
    var lightVisible = false
    var lightIdle = false
    var scanInProgress = false
    var scanFinished = false
    var classicAudioVisible = false

    var audioOnly: Bool {
        classicAudioVisible && !lightVisible && !lightConnecting && !lightReady
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

private func providerIconResourceURL(named baseName: String) -> URL? {
    if let bundled = Bundle.main.url(forResource: baseName, withExtension: "svg") {
        return bundled
    }

    let repoResource = divoomRepoRootURL().appendingPathComponent("macos/DivoomMenuBar/Resources/\(baseName).svg")
    if FileManager.default.fileExists(atPath: repoResource.path) {
        return repoResource
    }

    let installedCodexBar = URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Resources/\(baseName).svg")
    if FileManager.default.fileExists(atPath: installedCodexBar.path) {
        return installedCodexBar
    }

    return nil
}

private func divoomRepoRootURL() -> URL {
    if
        let configuredRoot = Bundle.main.object(forInfoDictionaryKey: "DivoomRepoRoot") as? String,
        !configuredRoot.isEmpty
    {
        return URL(fileURLWithPath: configuredRoot, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func divoomRepoURL(_ relativePath: String, isDirectory: Bool = false) -> URL {
    divoomRepoRootURL().appendingPathComponent(relativePath, isDirectory: isDirectory)
}

private func makeProviderLogoImage(provider: String, size: CGFloat = 16) -> NSImage? {
    let baseName = "ProviderIcon-\(provider)"
    guard let url = providerIconResourceURL(named: baseName),
          let image = NSImage(contentsOf: url)
    else {
        return nil
    }

    image.size = NSSize(width: size, height: size)
    image.isTemplate = true
    return image
}

private func providerTileTintColor(_ provider: String) -> NSColor {
    switch provider {
    case "codex":
        return NSColor(calibratedRed: 0.02, green: 0.72, blue: 0.79, alpha: 1.0)
    case "claude":
        return NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.13, alpha: 1.0)
    default:
        return .secondaryLabelColor
    }
}

private final class SummaryPillView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let textLabel = NSTextField(labelWithString: "")

    init(text: String, symbolName: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .menu
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 999
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: text
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        textLabel.textColor = .secondaryLabelColor
        textLabel.stringValue = text

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(text: String, symbolName: String, accentColor: NSColor? = nil) {
        textLabel.stringValue = text
        textLabel.textColor = accentColor ?? .secondaryLabelColor
        iconView.contentTintColor = accentColor ?? .secondaryLabelColor
        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: text
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        layer?.borderColor = (accentColor ?? NSColor.separatorColor).withAlphaComponent(0.18).cgColor
    }
}

private final class PixelShaderBackdropView: NSView {
    enum Palette {
        case idle
        case ok
        case error
        case library
    }

    var palette: Palette = .idle {
        didSet { needsDisplay = true }
    }

    var activityBoost: CGFloat = 0.72 {
        didSet { needsDisplay = true }
    }

    private var phase: CGFloat = 0
    private var timer: Timer?

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.22
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let colors = paletteColors()
        let columns = max(10, Int(bounds.width / 32))
        let rows = max(4, Int(bounds.height / 24))
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let wave = (sin(CGFloat(column) * 0.58 + CGFloat(row) * 0.94 + phase) + 1) / 2
                let fade = 0.22 + pow(CGFloat(column) / CGFloat(max(columns - 1, 1)), 1.35) * 0.78
                let glow = colors.0.blended(withFraction: wave * 0.72, of: colors.1) ?? colors.1
                let alpha = (0.010 + wave * 0.045) * fade * activityBoost
                let rect = NSRect(
                    x: CGFloat(column) * cellWidth + cellWidth * 0.24,
                    y: CGFloat(row) * cellHeight + cellHeight * 0.26,
                    width: cellWidth * 0.44,
                    height: cellHeight * 0.40
                )
                let pixel = NSBezierPath(roundedRect: rect, xRadius: 3.8, yRadius: 3.8)
                glow.withAlphaComponent(alpha).setFill()
                pixel.fill()
            }
        }

        let beamX = ((phase.truncatingRemainder(dividingBy: .pi * 2)) / (.pi * 2)) * (bounds.width + 64) - 32
        let beamRect = NSRect(x: beamX, y: 6, width: 18, height: max(0, bounds.height - 12))
        let beamPath = NSBezierPath(roundedRect: beamRect, xRadius: 10, yRadius: 10)
        (colors.2 ?? colors.1).withAlphaComponent(0.024 * activityBoost).setFill()
        beamPath.fill()
    }

    private func paletteColors() -> (NSColor, NSColor, NSColor?) {
        switch palette {
        case .idle:
            return (
                NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.64, alpha: 1),
                NSColor(calibratedRed: 0.68, green: 0.78, blue: 0.92, alpha: 1),
                NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1)
            )
        case .ok:
            return (
                NSColor(calibratedRed: 0.12, green: 0.74, blue: 0.72, alpha: 1),
                NSColor(calibratedRed: 0.33, green: 0.93, blue: 0.88, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.58, blue: 1.0, alpha: 1)
            )
        case .error:
            return (
                NSColor(calibratedRed: 0.94, green: 0.45, blue: 0.21, alpha: 1),
                NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.4, alpha: 1),
                NSColor(calibratedRed: 0.99, green: 0.32, blue: 0.38, alpha: 1)
            )
        case .library:
            return (
                NSColor(calibratedRed: 0.26, green: 0.63, blue: 1.0, alpha: 1),
                NSColor(calibratedRed: 0.92, green: 0.46, blue: 0.2, alpha: 1),
                NSColor(calibratedRed: 0.76, green: 0.58, blue: 1.0, alpha: 1)
            )
        }
    }
}

private final class MenuSummaryView: NSView {
    private let glassView = NSVisualEffectView()
    private let backdropView = PixelShaderBackdropView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Divoom Ditoo Pro Mac")
    private let subtitleLabel = NSTextField(labelWithString: "Beam-ready desk display")
    private let headlineLabel = NSTextField(labelWithString: "Beam a favorite, open the library, or start a live feed.")
    private let supportTopLabel = NSTextField(labelWithString: "Cloud, favorites, and live feeds stay one click away.")
    private let supportBottomLabel = NSTextField(labelWithString: "Swap lanes instantly without restarting the app.")
    private let chipViews: [SummaryPillView] = [
        SummaryPillView(text: "Ready", symbolName: "dot.radiowaves.left.and.right"),
        SummaryPillView(text: "Manual", symbolName: "hand.tap"),
    ]
    private let chipRow = NSStackView()
    private var supportingLines: [String] = ["Open Library for curated picks, cloud search, playlists, and favorites."]
    private var rotatingIndex = 0
    private var rotatingTimer: Timer?

    override var intrinsicContentSize: NSSize {
        NSSize(width: rootMenuSurfaceWidth, height: summaryCardHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            rotatingTimer?.invalidate()
            rotatingTimer = nil
            return
        }
        guard rotatingTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 4.2, repeats: true) { [weak self] _ in
            self?.advanceRotatingLine()
        }
        RunLoop.main.add(timer, forMode: .common)
        rotatingTimer = timer
    }

    func update(
        state: StatusIconState,
        subtitle: String,
        headline: String,
        rotatingLines: [String],
        chips: [SummaryChipSpec]
    ) {
        iconView.image = makeStatusItemIcon(state: state)
        subtitleLabel.stringValue = subtitle
        headlineLabel.stringValue = headline
        headlineLabel.textColor = state == .error ? .systemOrange : .labelColor
        backdropView.palette = {
            switch state {
            case .idle: return .idle
            case .ok: return .ok
            case .error: return .error
            }
        }()
        backdropView.activityBoost = chips.contains(where: { $0.accentColor != nil }) ? 0.22 : 0.14
        updateRotatingLines(rotatingLines)
        updateChips(chips)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.material = .menu
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 20
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.borderWidth = 1
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.palette = .idle
        backdropView.activityBoost = 0.14

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = makeStatusItemIcon(state: .idle)
        iconView.imageScaling = .scaleNone

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        headlineLabel.translatesAutoresizingMaskIntoConstraints = false
        headlineLabel.font = .systemFont(ofSize: 15.5, weight: .bold)
        headlineLabel.textColor = .labelColor
        headlineLabel.lineBreakMode = .byWordWrapping
        headlineLabel.maximumNumberOfLines = 1

        supportTopLabel.translatesAutoresizingMaskIntoConstraints = false
        supportTopLabel.font = .systemFont(ofSize: 11, weight: .regular)
        supportTopLabel.textColor = .secondaryLabelColor
        supportTopLabel.lineBreakMode = .byWordWrapping
        supportTopLabel.maximumNumberOfLines = 1

        supportBottomLabel.translatesAutoresizingMaskIntoConstraints = false
        supportBottomLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        supportBottomLabel.textColor = .secondaryLabelColor
        supportBottomLabel.lineBreakMode = .byWordWrapping
        supportBottomLabel.maximumNumberOfLines = 1

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let iconStack = NSStackView(views: [iconView, headerStack])
        iconStack.orientation = .horizontal
        iconStack.alignment = .centerY
        iconStack.spacing = 8
        iconStack.translatesAutoresizingMaskIntoConstraints = false

        chipRow.setContentHuggingPriority(.required, for: .horizontal)
        chipRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [iconStack, spacer, chipRow])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10
        topRow.translatesAutoresizingMaskIntoConstraints = false

        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipViews.forEach { chipRow.addArrangedSubview($0) }

        supportBottomLabel.isHidden = true

        let contentStack = NSStackView(views: [topRow, headlineLabel, supportTopLabel])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassView)
        addSubview(backdropView)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rootMenuSurfaceWidth),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func updateRotatingLines(_ lines: [String]) {
        let sanitized = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        supportingLines = sanitized.isEmpty ? ["Open Library for curated, favorite, playlist, and cloud picks."] : sanitized
        rotatingIndex = min(rotatingIndex, max(supportingLines.count - 1, 0))
        applyRotatingLine(animated: false)
    }

    private func advanceRotatingLine() {
        guard supportingLines.count > 1 else { return }
        rotatingIndex = (rotatingIndex + 1) % supportingLines.count
        applyRotatingLine(animated: true)
    }

    private func applyRotatingLine(animated: Bool) {
        let firstLine = supportingLines.indices.contains(rotatingIndex)
            ? supportingLines[rotatingIndex]
            : (supportingLines.first ?? "")
        let secondIndex = supportingLines.isEmpty ? 0 : (rotatingIndex + 1) % supportingLines.count
        let secondLine = supportingLines.indices.contains(secondIndex)
            ? supportingLines[secondIndex]
            : ""

        guard animated else {
            supportTopLabel.stringValue = firstLine
            supportBottomLabel.stringValue = secondLine == firstLine ? "" : secondLine
            supportBottomLabel.isHidden = supportBottomLabel.stringValue.isEmpty
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            supportTopLabel.animator().alphaValue = 0.42
            supportBottomLabel.animator().alphaValue = 0.42
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.supportTopLabel.stringValue = firstLine
            self.supportBottomLabel.stringValue = secondLine == firstLine ? "" : secondLine
            self.supportBottomLabel.isHidden = self.supportBottomLabel.stringValue.isEmpty
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.supportTopLabel.animator().alphaValue = 1.0
                self.supportBottomLabel.animator().alphaValue = 1.0
            }
        }
    }

    private func updateChips(_ chips: [SummaryChipSpec]) {
        for (index, chipView) in chipViews.enumerated() {
            guard index < chips.count else {
                chipView.isHidden = true
                continue
            }
            let chip = chips[index]
            chipView.isHidden = false
            chipView.update(
                text: chip.text,
                symbolName: chip.symbolName,
                accentColor: chip.accentColor
            )
        }
    }
}

private final class ColorStudioView: NSView {
    var onSendColor: ((NSColor) -> Void)?
    var onSendAmbientColor: ((NSColor) -> Void)?
    var onSendMotion: (([NSColor], ColorMotionMode) -> Void)?
    var onPickScreen: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Color Motion Studio")
    private let captionLabel = NSTextField(labelWithString: "Build animated palette waves, blooms, ribbons, and gradients.")
    private let modePopUp = NSPopUpButton()
    private let slotCountLabel = NSTextField(labelWithString: "4 colors")
    private let slotCountStepper = NSStepper()
    private let slotPicker = NSPopUpButton()
    private let savedComboPopUp = NSPopUpButton()
    private let saveComboButton = NSButton(title: "Save Combo", target: nil, action: nil)
    private let glassView = NSVisualEffectView()
    private let colorWell = NSColorWell()
    private let hexField = NSTextField(string: "#FF0000")
    private let ambientButton = NSButton(title: "Set Ambient", target: nil, action: nil)
    private let sendButton = NSButton(title: "Beam Motion", target: nil, action: nil)
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
    private let visibleModes: [ColorMotionMode] = [.gradientSweep, .ribbonWave, .diamondBloom, .paletteSteps, .checkerShift, .pulse, .aurora]

    override var intrinsicContentSize: NSSize {
        NSSize(width: studioMenuSurfaceWidth, height: colorStudioHeight)
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
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.material = .menu
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 18
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.borderWidth = 1
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingTail

        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        visibleModes.forEach { mode in
            modePopUp.addItem(withTitle: mode.title)
            modePopUp.lastItem?.representedObject = mode.rawValue
        }
        modePopUp.selectItem(withTitle: ColorMotionMode.gradientSweep.title)
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

        ambientButton.translatesAutoresizingMaskIntoConstraints = false
        ambientButton.bezelStyle = .rounded
        ambientButton.controlSize = .small
        ambientButton.target = self
        ambientButton.action = #selector(ambientPressed)
        ambientButton.setContentHuggingPriority(.required, for: .horizontal)
        ambientButton.setContentCompressionResistancePriority(.required, for: .horizontal)

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

        let controlsRow = NSStackView(views: [colorWell, hexField, pickButton, ambientButton, sendButton])
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

        addSubview(glassView)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: studioMenuSurfaceWidth),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
            modePopUp.widthAnchor.constraint(equalToConstant: 148),
            slotPicker.widthAnchor.constraint(equalToConstant: 84),
            savedComboPopUp.widthAnchor.constraint(equalToConstant: 230),
            hexField.widthAnchor.constraint(equalToConstant: 92),
            ambientButton.widthAnchor.constraint(equalToConstant: 104),
            sendButton.widthAnchor.constraint(equalToConstant: 102),
            pickButton.widthAnchor.constraint(equalToConstant: 96),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
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
        onSendMotion?(colors, selectedMode())
    }

    @objc private func ambientPressed() {
        onSendAmbientColor?(colorWell.color)
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
        let targetMode = combo.mode == .solid ? ColorMotionMode.gradientSweep : combo.mode
        if let targetItem = modePopUp.itemArray.first(where: { ($0.representedObject as? String) == targetMode.rawValue }) {
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
            return .gradientSweep
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
        sendButton.title = "Beam Motion"
    }
}

private final class QuickActionTileView: NSControl {
    var onActivate: (() -> Void)?
    var iconTintColor: NSColor = .secondaryLabelColor {
        didSet {
            updateAppearance()
        }
    }
    var badgeFillColor: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.58) {
        didSet {
            updateAppearance()
        }
    }
    var usesOriginalIconColors = false {
        didSet {
            updateAppearance()
        }
    }
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

    private let backgroundView = NSVisualEffectView()
    private let badgeView = NSView()
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
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
        NSSize(width: 102, height: 86)
    }

    init(title: String, subtitle: String, image: NSImage?, tooltip: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        iconView.image = image
        self.toolTip = tooltip
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setSubtitle(_ value: String) {
        subtitleLabel.stringValue = value
        subtitleLabel.isHidden = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.07).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 18
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = iconTintColor

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 16
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.borderWidth = 1

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 9.5, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.isHidden = subtitleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        addSubview(backgroundView)
        addSubview(badgeView)
        badgeView.addSubview(iconView)
        badgeView.addSubview(spinner)
        let labelStack = NSStackView(views: [titleLabel, subtitleLabel])
        labelStack.orientation = .vertical
        labelStack.alignment = .centerX
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [badgeView, labelStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            badgeView.widthAnchor.constraint(equalToConstant: 36),
            badgeView.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualToConstant: 18),
            iconView.heightAnchor.constraint(lessThanOrEqualToConstant: 18),
            spinner.centerXAnchor.constraint(equalTo: badgeView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let activeBorderColor = NSColor.controlAccentColor.withAlphaComponent(0.88)
        let inactiveBorderColor = NSColor.separatorColor.withAlphaComponent(0.18)
        backgroundView.layer?.borderWidth = isActive ? 1.4 : 1.0
        backgroundView.layer?.borderColor = (isActive ? activeBorderColor : inactiveBorderColor).cgColor
        backgroundView.alphaValue = isActive ? 1.0 : (isHovering ? 0.992 : 0.96)
        backgroundView.layer?.backgroundColor = (isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.white.withAlphaComponent(isHovering ? 0.038 : 0.018)).cgColor
        badgeView.layer?.backgroundColor = (isActive
            ? badgeFillColor.blended(withFraction: 0.12, of: .white) ?? badgeFillColor
            : badgeFillColor).cgColor
        badgeView.layer?.borderColor = (usesOriginalIconColors
            ? badgeFillColor.withAlphaComponent(isActive ? 1.0 : 0.78)
            : (isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.62)
                : NSColor.separatorColor.withAlphaComponent(isHovering ? 0.34 : 0.22))).cgColor
        badgeView.layer?.shadowColor = badgeFillColor.withAlphaComponent(isActive ? 0.42 : 0.16).cgColor
        badgeView.layer?.shadowOpacity = 1
        badgeView.layer?.shadowRadius = isActive ? 16 : 8
        badgeView.layer?.shadowOffset = NSSize(width: 0, height: -2)
        iconView.contentTintColor = usesOriginalIconColors ? nil : iconTintColor
        titleLabel.textColor = isActive ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.95)
        subtitleLabel.textColor = isActive
            ? NSColor.secondaryLabelColor.withAlphaComponent(0.94)
            : NSColor.secondaryLabelColor.withAlphaComponent(isHovering ? 0.90 : 0.80)
        let shouldShowSubtitle = !subtitleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isActive || isLoading)
        subtitleLabel.isHidden = !shouldShowSubtitle
        alphaValue = isPressing ? 0.9 : 1.0
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

    private let glassView = NSVisualEffectView()
    private let codexTile = QuickActionTileView(
        title: "Codex Live",
        subtitle: "Usage feed",
        image: makeProviderLogoImage(provider: "codex", size: 18),
        tooltip: "Start the native live Codex feed on the Ditoo."
    )
    private let claudeTile = QuickActionTileView(
        title: "Claude Live",
        subtitle: "Usage feed",
        image: makeProviderLogoImage(provider: "claude", size: 18),
        tooltip: "Start the native live Claude feed on the Ditoo."
    )
    private let splitTile = QuickActionTileView(
        title: "Split Live",
        subtitle: "Both agents",
        image: makeMenuSymbol("rectangle.split.2x1", description: "Split Live"),
        tooltip: "Show Codex and Claude together on the Ditoo."
    )
    private let ipFlagTile = QuickActionTileView(
        title: "IP Flag",
        subtitle: "Live country",
        image: makeMenuSymbol("flag.2.crossed", description: "IP Flag"),
        tooltip: "Track the current public-IP country flag on the Ditoo."
    )
    private let libraryTile = QuickActionTileView(
        title: "Library",
        subtitle: "Open browser",
        image: makeMenuSymbol("photo.stack", description: "Library"),
        tooltip: "Open the native animation library."
    )
    private let favoritesTile = QuickActionTileView(
        title: "Rotate Favorites",
        subtitle: "Loop favorites",
        image: makeMenuSymbol("arrow.triangle.2.circlepath", description: "Rotate Favorites"),
        tooltip: "Rotate through the current favorites set."
    )
    private let pickColorButton = NSButton(title: "Pick Color", target: nil, action: nil)
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Tap a tile to beam now.")

    override var intrinsicContentSize: NSSize {
        NSSize(width: rootMenuSurfaceWidth, height: quickHubHeight)
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
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.14).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -4)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.material = .menu
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 22
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.borderWidth = 1
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.14).cgColor

        configureTile(codexTile, tintColor: providerTileTintColor("codex"), action: #selector(openCodex))
        configureTile(claudeTile, tintColor: providerTileTintColor("claude"), action: #selector(openClaude))
        configureTile(splitTile, tintColor: NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.95, alpha: 1.0), action: #selector(openSplit))
        configureTile(ipFlagTile, tintColor: NSColor(calibratedRed: 0.82, green: 0.80, blue: 0.97, alpha: 1.0), action: #selector(openIPFlag))
        configureTile(libraryTile, tintColor: NSColor(calibratedRed: 0.78, green: 0.93, blue: 0.95, alpha: 1.0), action: #selector(openLibrary))
        configureTile(favoritesTile, tintColor: NSColor(calibratedRed: 0.97, green: 0.83, blue: 0.88, alpha: 1.0), action: #selector(toggleFavorites))

        pickColorButton.translatesAutoresizingMaskIntoConstraints = false
        pickColorButton.bezelStyle = .rounded
        pickColorButton.controlSize = .regular
        pickColorButton.font = .systemFont(ofSize: 12, weight: .semibold)
        pickColorButton.image = makeMenuSymbol("eyedropper.halffull", description: "Pick Color")
        pickColorButton.imagePosition = .imageLeading
        pickColorButton.target = self
        pickColorButton.action = #selector(pickColor)

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        let topRow = NSStackView(views: [codexTile, claudeTile, splitTile])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.spacing = 8
        topRow.distribution = .fillEqually
        topRow.translatesAutoresizingMaskIntoConstraints = false

        let bottomRow = NSStackView(views: [ipFlagTile, libraryTile, favoritesTile])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .top
        bottomRow.spacing = 8
        bottomRow.distribution = .fillEqually
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let statusRow = NSStackView(views: [statusSpinner, statusLabel, spacer, pickColorButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [topRow, bottomRow, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: rootMenuSurfaceWidth),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        updateTileAppearance()
    }

    private func configureTile(_ tile: QuickActionTileView, tintColor: NSColor, action: Selector) {
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.iconTintColor = .white
        tile.badgeFillColor = tintColor
        tile.onActivate = { [weak self] in
            self?.perform(action)
        }
    }

    private func updateTileAppearance() {
        codexTile.isActive = activeAction == .codex
        claudeTile.isActive = activeAction == .claude
        splitTile.isActive = activeAction == .pair
        ipFlagTile.isActive = activeAction == .ipFlag
        libraryTile.isActive = activeAction == .library
        favoritesTile.isActive = activeAction == .favorites

        codexTile.isLoading = loadingAction == .codex
        claudeTile.isLoading = loadingAction == .claude
        splitTile.isLoading = loadingAction == .pair
        ipFlagTile.isLoading = loadingAction == .ipFlag
        libraryTile.isLoading = loadingAction == .library
        favoritesTile.isLoading = loadingAction == .favorites

        let isLoading = loadingAction != nil
        pickColorButton.isEnabled = !isLoading
        pickColorButton.contentTintColor = activeAction == .screenPick ? .controlAccentColor : .labelColor

        if let loadingAction {
            statusSpinner.startAnimation(nil)
            statusLabel.stringValue = statusText(for: loadingAction, loading: true)
            return
        }

        statusSpinner.stopAnimation(nil)
        if let activeAction {
            statusLabel.stringValue = statusText(for: activeAction, loading: false)
        } else {
            statusLabel.stringValue = "Choose a live view, open the library, or rotate favorites."
        }
    }

    private func statusText(for actionID: QuickActionKind, loading: Bool) -> String {
        switch actionID {
        case .codex:
            return loading ? "Starting Codex live…" : "Codex live is active."
        case .claude:
            return loading ? "Starting Claude live…" : "Claude live is active."
        case .pair:
            return loading ? "Starting split live…" : "Split live is active."
        case .ipFlag:
            return loading ? "Starting IP flag live…" : "The current public-IP country flag is live."
        case .favorites:
            return loading ? "Starting favorites rotation…" : "Favorites rotation is active."
        case .library:
            return "The native animation library is open."
        case .screenPick:
            return loading ? "Sampling a screen color…" : "Pick a color anywhere on screen and beam it."
        }
    }

    @objc private func openCodex() {
        onCodex?()
    }

    @objc private func openClaude() {
        onClaude?()
    }

    @objc private func openSplit() {
        onPair?()
    }

    @objc private func openIPFlag() {
        onIPFlag?()
    }

    @objc private func openLibrary() {
        onLibrary?()
    }

    @objc private func toggleFavorites() {
        onFavorites?()
    }

    @objc private func pickColor() {
        onScreenPick?()
    }
}

private struct AnimationLibraryItem: Hashable {
    let id: String
    let source: String
    let scope: String
    let sort: String
    let title: String
    let category: String
    let cloudClassify: Int
    let collection: String
    let relativePath: String
    let fileURL: URL
    let searchText: String
    let duplicateCount: Int
    let likes: Int
    let views: Int
    let galleryID: Int
    let fileType: Int
    let clockID: Int
    let itemID: Int
    let userID: Int
    let date: String
    let isLiked: Bool
}

private enum AnimationLibraryCatalog {
    static let favoritesDefaultsKey = "dev.kirniy.divoom.animation-library-favorites"

    static func roots() -> [(source: String, url: URL)] {
        var values: [(source: String, url: URL)] = [
            ("curated", divoomRepoURL("assets/16x16/curated", isDirectory: true)),
        ]
        let cloudEnabled = UserDefaults.standard.object(forKey: cloudLibraryEnabledDefaultsKey) as? Bool ?? true
        if cloudEnabled {
            values.append(("divoom-cloud", divoomRepoURL("assets/16x16/divoom-cloud", isDirectory: true)))
        }
        return values
    }

    static func loadItems() -> [AnimationLibraryItem] {
        var groupedItems: [String: [AnimationLibraryItem]] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let cloudManifestLookup = loadCloudManifestLookup()

        for root in roots() {
            guard FileManager.default.fileExists(atPath: root.url.path) else {
                continue
            }

            let enumerator = FileManager.default.enumerator(
                at: root.url,
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

                let relativeWithinRoot = fileURL.path.replacingOccurrences(of: root.url.path + "/", with: "")
                let parts = relativeWithinRoot.split(separator: "/").map(String.init)
                let category = parts.first ?? "misc"
                let collection = parts.count > 2 ? parts[1] : (parts.count == 2 ? "root" : "root")
                let title = prettifyAnimationTitle(fileURL.deletingPathExtension().lastPathComponent)
                let relativePath = "\(root.source)/\(relativeWithinRoot)"
                let id = "\(root.source):\(relativeWithinRoot)"
                let cloudMetadata = cloudManifestLookup[relativePath]
                let scope = cloudMetadata?.scope ?? (root.source == "divoom-cloud" ? "cloud" : "local")
                let sort = cloudMetadata?.sort ?? (root.source == "divoom-cloud" ? "cloud" : "local")
                let likes = cloudMetadata?.likes ?? 0
                let views = cloudMetadata?.views ?? 0
                let searchText = [
                    title,
                    root.source,
                    category,
                    collection,
                    scope,
                    sort,
                    relativePath,
                    cloudMetadata?.user_name ?? "",
                    cloudMetadata?.country ?? "",
                    cloudMetadata?.date ?? "",
                ].joined(separator: " ").lowercased()
                guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                    continue
                }
                let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()

                let item = AnimationLibraryItem(
                    id: id,
                    source: root.source,
                    scope: scope,
                    sort: sort,
                    title: title,
                    category: category,
                    cloudClassify: cloudMetadata?.cloud_classify ?? 0,
                    collection: collection,
                    relativePath: relativePath,
                    fileURL: fileURL,
                    searchText: searchText,
                    duplicateCount: 1,
                    likes: likes,
                    views: views,
                    galleryID: cloudMetadata?.gallery_id ?? 0,
                    fileType: cloudMetadata?.file_type ?? 0,
                    clockID: cloudMetadata?.clock_id ?? 0,
                    itemID: cloudMetadata?.item_id ?? 0,
                    userID: cloudMetadata?.user_id ?? 0,
                    date: cloudMetadata?.date ?? "",
                    isLiked: cloudMetadata?.is_liked ?? false
                )
                groupedItems[digest, default: []].append(item)
            }
        }

        let items = groupedItems.values.compactMap { group -> AnimationLibraryItem? in
            guard let canonical = group.max(by: { preferenceScore(for: $0) < preferenceScore(for: $1) }) else {
                return nil
            }
            return AnimationLibraryItem(
                id: canonical.id,
                source: canonical.source,
                scope: canonical.scope,
                sort: canonical.sort,
                title: canonical.title,
                category: canonical.category,
                cloudClassify: canonical.cloudClassify,
                collection: canonical.collection,
                relativePath: canonical.relativePath,
                fileURL: canonical.fileURL,
                searchText: canonical.searchText,
                duplicateCount: group.count,
                likes: canonical.likes,
                views: canonical.views,
                galleryID: canonical.galleryID,
                fileType: canonical.fileType,
                clockID: canonical.clockID,
                itemID: canonical.itemID,
                userID: canonical.userID,
                date: canonical.date,
                isLiked: canonical.isLiked
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.category == rhs.category {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
        }
    }

    static func loadFavorites(resolvingAgainst items: [AnimationLibraryItem] = []) -> Set<String> {
        let stored = Set(UserDefaults.standard.stringArray(forKey: favoritesDefaultsKey) ?? [])
        guard !items.isEmpty else {
            return stored
        }
        let migrated = migratedStoredFavorites(from: stored, availableItems: items)
        if migrated != stored {
            saveFavorites(migrated)
        }
        return resolvedFavorites(from: migrated, availableItems: items)
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

    static func displaySourceTitle(for value: String) -> String {
        switch value {
        case "divoom-cloud":
            return "Divoom Cloud"
        case "curated":
            return "Curated"
        default:
            return displayTitle(for: value)
        }
    }

    static func displayScopeTitle(for value: String) -> String {
        switch value {
        case "local":
            return "Curated"
        case "cloud":
            return "Cloud Feed"
        case "category":
            return "Categories"
        case "search":
            return "Cloud Search"
        case "liked":
            return "Cloud Likes"
        case "playlist":
            return "Cloud Playlists"
        case "store":
            return "Store Channels"
        default:
            return displayTitle(for: value)
        }
    }

    static func displayCollectionTitle(for value: String) -> String {
        switch value {
        case "root":
            return "Main Set"
        default:
            return displayTitle(for: value)
        }
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
        if item.source == "divoom-cloud" {
            score += 5
        }
        if item.category == "pixel-displays" || item.category == "divoom" {
            score += 4
        }
        score += min(item.likes, 2000) / 20
        score += min(item.views, 5000) / 120
        score -= item.relativePath.count
        return score
    }

    private static func resolvedFavorites(
        from storedFavorites: Set<String>,
        availableItems: [AnimationLibraryItem]
    ) -> Set<String> {
        Set(storedFavorites.compactMap { resolveFavoriteID($0, availableItems: availableItems) })
    }

    private static func migratedStoredFavorites(
        from storedFavorites: Set<String>,
        availableItems: [AnimationLibraryItem]
    ) -> Set<String> {
        Set(storedFavorites.map { resolveFavoriteID($0, availableItems: availableItems) ?? $0 })
    }

    private static func resolveFavoriteID(
        _ favoriteID: String,
        availableItems: [AnimationLibraryItem]
    ) -> String? {
        let idLookup = Dictionary(uniqueKeysWithValues: availableItems.map { ($0.id, $0.id) })
        if let exact = idLookup[favoriteID] {
            return exact
        }

        let relativeLookup = Dictionary(uniqueKeysWithValues: availableItems.map { ($0.relativePath, $0.id) })
        if let relativeMatch = relativeLookup[favoriteID] {
            return relativeMatch
        }

        if let curatedMatch = relativeLookup["curated/\(favoriteID)"] {
            return curatedMatch
        }

        if let cloudMatch = relativeLookup["divoom-cloud/\(favoriteID)"] {
            return cloudMatch
        }

        if let separator = favoriteID.firstIndex(of: ":") {
            let pathLike = favoriteID[..<separator] + "/" + favoriteID[favoriteID.index(after: separator)...]
            if let id = relativeLookup[String(pathLike)] {
                return id
            }
        }

        let lastPathComponent = URL(fileURLWithPath: favoriteID).lastPathComponent.lowercased()
        let basenameMatches = availableItems.filter { $0.fileURL.lastPathComponent.lowercased() == lastPathComponent }
        if basenameMatches.count == 1 {
            return basenameMatches[0].id
        }

        return nil
    }

    private static func loadCloudManifestLookup() -> [String: DivoomCloudManifestEntry] {
        guard let manifest = loadCloudManifest() else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: manifest.items.map { entry in
            ("divoom-cloud/\(entry.relative_path)", entry)
        })
    }

    static func loadCloudManifest() -> DivoomCloudManifest? {
        guard let data = try? Data(contentsOf: cloudManifestURL) else {
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(DivoomCloudManifest.self, from: data) else {
            return nil
        }
        return manifest
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
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.20).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor

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
        overlayView.layer?.backgroundColor = NSColor.black.withAlphaComponent(style == .hero ? 0.18 : 0.14).cgColor
        overlayView.layer?.borderColor = NSColor.white.withAlphaComponent(style == .hero ? 0.18 : 0.12).cgColor
        overlayView.layer?.shadowOpacity = 0.14
        overlayView.layer?.shadowRadius = 14
        overlayView.layer?.shadowOffset = NSSize(width: 0, height: -4)
        overlayView.alphaValue = 0

        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.isBordered = false
        overlayButton.imagePosition = .imageOnly
        overlayButton.contentTintColor = .white
        overlayButton.target = self
        overlayButton.action = #selector(triggerPrimaryAction)

        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayLabel.font = .systemFont(ofSize: style == .hero ? 11.5 : 10.5, weight: .semibold)
        overlayLabel.textColor = .white.withAlphaComponent(0.96)
        overlayLabel.alignment = .center
        overlayLabel.stringValue = style == .hero ? "Beam to Ditoo" : "Beam"
        overlayLabel.isHidden = style == .compact

        let overlayStack = NSStackView(views: style == .hero ? [overlayButton, overlayLabel] : [overlayButton])
        overlayStack.orientation = .horizontal
        overlayStack.alignment = .centerY
        overlayStack.spacing = style == .hero ? 8 : 0
        overlayStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(previewView)
        addSubview(overlayView)
        overlayView.addSubview(overlayStack)

        let iconPointSize: CGFloat = style == .hero ? 32 : 20
        let symbolWeight: NSFont.Weight = style == .hero ? .bold : .semibold
        overlayButton.image = NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "Beam"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: symbolWeight))

        overlayView.layer?.cornerRadius = style == .hero ? 18 : 14

        let overlayConstraints: [NSLayoutConstraint]
        if style == .hero {
            overlayConstraints = [
                overlayView.centerXAnchor.constraint(equalTo: centerXAnchor),
                overlayView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            ]
        } else {
            overlayConstraints = [
                overlayView.centerXAnchor.constraint(equalTo: centerXAnchor),
                overlayView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }

        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewView.topAnchor.constraint(equalTo: topAnchor),
            previewView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlayStack.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: style == .hero ? 12 : 9),
            overlayStack.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: style == .hero ? -12 : -9),
            overlayStack.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: style == .hero ? 9 : 8),
            overlayStack.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: style == .hero ? -9 : -8),
        ] + overlayConstraints)
    }

    @objc private func triggerPrimaryAction() {
        guard hasContent else {
            NSSound.beep()
            return
        }
        onPrimaryAction?()
    }

    private func updateOverlay(animated: Bool) {
        let targetAlpha: CGFloat = hasContent && isHovering ? (style == .hero ? 0.82 : 0.72) : 0.0
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
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.10).cgColor

        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: text)?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = .secondaryLabelColor

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        textLabel.textColor = .secondaryLabelColor
        textLabel.stringValue = text
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1

        let stack = NSStackView(views: [iconView, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
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

private enum AnimationLibrarySortMode: Int, CaseIterable {
    case spotlight = 0
    case popularity
    case newest
    case likes
    case views
    case feed
    case title
    case category
    case collection
    case favoritesFirst
    case duplicates

    var title: String {
        switch self {
        case .spotlight:
            return "Spotlight"
        case .popularity:
            return "Popularity"
        case .newest:
            return "Newest"
        case .likes:
            return "Likes"
        case .views:
            return "Views"
        case .feed:
            return "Feed"
        case .title:
            return "Title"
        case .category:
            return "Category"
        case .collection:
            return "Collection"
        case .favoritesFirst:
            return "Favorites First"
        case .duplicates:
            return "Most Duplicated"
        }
    }
}

private final class AnimationLibraryCollectionItem: NSCollectionViewItem {
    private let glassView = NSVisualEffectView()
    private let previewView = HoverActionPreviewView(style: .compact)
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaIconView = NSImageView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let favoriteButton = NSButton(title: "", target: nil, action: nil)
    private let sourceChip = HeaderStatChipView(symbolName: "shippingbox", text: "Source")
    private let duplicateChip = HeaderStatChipView(symbolName: "square.on.square", text: "2x")
    private let chipRow = NSStackView()
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
        let collectionTitle = AnimationLibraryCatalog.displayCollectionTitle(for: item.collection)
        let sourceTitle = AnimationLibraryCatalog.displaySourceTitle(for: item.source)
        metaIconView.image = makeMenuSymbol(animationCategorySymbolName(item.category), description: item.category)
        let metaParts = [
            AnimationLibraryCatalog.displayTitle(for: item.category),
            collectionTitle == "Main" ? nil : collectionTitle,
            item.source == "divoom-cloud" ? "Cloud" : nil,
            item.likes > 0 ? "\(item.likes) likes" : nil,
        ].compactMap { $0 }
        metaLabel.stringValue = metaParts.joined(separator: " · ")
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
        sourceChip.update(text: sourceTitle, symbolName: item.source == "divoom-cloud" ? "icloud" : "shippingbox")
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
        glassView.material = .menu
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.wantsLayer = true
        glassView.layer?.cornerRadius = 22
        glassView.layer?.cornerCurve = .continuous
        glassView.layer?.borderWidth = 1
        glassView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        glassView.layer?.shadowOpacity = 0.10
        glassView.layer?.shadowRadius = 16
        glassView.layer?.shadowOffset = NSSize(width: 0, height: -4)

        previewView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2

        metaIconView.translatesAutoresizingMaskIntoConstraints = false
        metaIconView.contentTintColor = .secondaryLabelColor

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 10, weight: .medium)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.isBordered = false
        favoriteButton.bezelStyle = .regularSquare
        favoriteButton.imagePosition = .imageOnly
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.contentTintColor = .systemOrange
        favoriteButton.wantsLayer = true
        favoriteButton.layer?.cornerRadius = 14
        favoriteButton.layer?.cornerCurve = .continuous
        favoriteButton.layer?.borderWidth = 1

        duplicateChip.translatesAutoresizingMaskIntoConstraints = false
        duplicateChip.isHidden = true

        sourceChip.translatesAutoresizingMaskIntoConstraints = false

        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 8
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipRow.detachesHiddenViews = true
        chipRow.setViews([sourceChip, duplicateChip], in: .leading)

        let metaRow = NSStackView(views: [metaIconView, metaLabel])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, metaRow, pathLabel, chipRow])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(glassView)
        glassView.addSubview(previewView)
        glassView.addSubview(textStack)
        glassView.addSubview(favoriteButton)

        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: view.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            favoriteButton.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 10),
            favoriteButton.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -10),
            favoriteButton.widthAnchor.constraint(equalToConstant: 28),
            favoriteButton.heightAnchor.constraint(equalToConstant: 28),

            metaIconView.widthAnchor.constraint(equalToConstant: 14),
            metaIconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        gridConstraints = [
            previewView.topAnchor.constraint(equalTo: glassView.topAnchor, constant: 12),
            previewView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 12),
            previewView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -12),
            previewView.heightAnchor.constraint(equalToConstant: 128),

            textStack.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: glassView.trailingAnchor, constant: -12),
            textStack.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 9),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: glassView.bottomAnchor, constant: -12),
        ]

        listConstraints = [
            previewView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor, constant: 12),
            previewView.centerYAnchor.constraint(equalTo: glassView.centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 92),
            previewView.heightAnchor.constraint(equalToConstant: 92),

            textStack.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: favoriteButton.leadingAnchor, constant: -12),
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
        favoriteButton.layer?.backgroundColor = (isFavorite
            ? NSColor.systemOrange.withAlphaComponent(0.16)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.72)).cgColor
        favoriteButton.layer?.borderColor = (isFavorite
            ? NSColor.systemOrange.withAlphaComponent(0.32)
            : NSColor.separatorColor.withAlphaComponent(0.18)).cgColor
    }

    private func updateSelectionAppearance() {
        let accentColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.40) : NSColor.separatorColor.withAlphaComponent(0.14)
        glassView.layer?.borderColor = accentColor.cgColor
        glassView.layer?.backgroundColor = (isSelected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.14)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.10)).cgColor
        glassView.layer?.shadowColor = (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.08)).cgColor
    }
}

@MainActor
private final class AnimationLibraryWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let onSend: (AnimationLibraryItem) -> Void
    private let onReveal: (AnimationLibraryItem) -> Void
    private let onOpenCloudSettings: () -> Void
    private let onSaveCloudCredentials: (String, String) -> Void
    private let onImportSyncedCloudCredentials: () -> Void
    private let onSyncCloudNow: () -> Void
    private let onSearchCloud: (String) -> Void
    private let onToggleCloudLike: (AnimationLibraryItem, Bool, @escaping @MainActor (Bool, String) -> Void) -> Void

    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Animation Library")
    private let summaryLabel = NSTextField(labelWithString: "Curated and cloud-backed native browser with favorites, playlists, likes, and instant beam.")
    private let cloudLoginButton = NSButton(title: "Cloud Account…", target: nil, action: nil)
    private let assetChip = HeaderStatChipView(symbolName: "sparkles", text: "0 assets")
    private let categoryChip = HeaderStatChipView(symbolName: "square.grid.3x3.fill", text: "0 categories")
    private let sourceChip = HeaderStatChipView(symbolName: "shippingbox", text: "0 sources")
    private let favoriteChip = HeaderStatChipView(symbolName: "star.fill", text: "0 favorites")
    private let resultsLabel = NSTextField(labelWithString: "0 shown")
    private let searchField = NSSearchField()
    private let sourcePopUp = NSPopUpButton()
    private let scopePopUp = NSPopUpButton()
    private let categoryPopUp = NSPopUpButton()
    private let collectionPopUp = NSPopUpButton()
    private let sortPopUp = NSPopUpButton()
    private let filterDisclosureButton = NSButton(title: "Filters", target: nil, action: nil)
    private let advancedFilterRow = NSStackView()
    private let displayModeControl = NSSegmentedControl(labels: ["Grid", "List"], trackingMode: .selectOne, target: nil, action: nil)
    private let favoritesOnlyButton = NSButton(title: "Favorites", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Reload", target: nil, action: nil)
    private let syncCloudButton = NSButton(title: "Sync", target: nil, action: nil)
    private let searchCloudButton = NSButton(title: "Cloud Search", target: nil, action: nil)
    private let cloudAccessCard = NSVisualEffectView()
    private let cloudAccessStatusLabel = NSTextField(labelWithString: "")
    private let cloudEmailField = NSTextField()
    private let cloudPasswordField = NSSecureTextField()
    private let cloudSaveButton = NSButton(title: "Save to Keychain", target: nil, action: nil)
    private let cloudImportButton = NSButton(title: "Import from Passwords", target: nil, action: nil)
    private let cloudTipLabel = NSTextField(labelWithString: "Switch Source to Cloud when you want the search field to query Divoom.")
    private let flowLayout = NSCollectionViewFlowLayout()
    private let collectionView = NSCollectionView()
    private let collectionScrollView = NSScrollView()
    private let emptyStateStack = NSStackView()
    private let emptyStateIconView = NSImageView()
    private let emptyLabel = NSTextField(labelWithString: "No animations match this view.")
    private let emptyDetailLabel = NSTextField(labelWithString: "Clear a filter, switch libraries, or search again.")
    private let inspectorView = NSVisualEffectView()
    private let inspectorSectionLabel = NSTextField(labelWithString: "Preview")
    private let inspectorSectionSummaryLabel = NSTextField(labelWithString: "Beam it now, favorite it, reveal it, or push likes back into Divoom Cloud.")
    private let detailPreviewView = HoverActionPreviewView(style: .hero)
    private let detailTitleLabel = NSTextField(labelWithString: "Select an animation")
    private let detailMetaLabel = NSTextField(labelWithString: "Pick something excellent, then send it straight to the Ditoo.")
    private let detailSourceChip = HeaderStatChipView(symbolName: "shippingbox", text: "Source")
    private let detailFeedChip = HeaderStatChipView(symbolName: "square.stack.3d.up", text: "Feed")
    private let detailCategoryChip = HeaderStatChipView(symbolName: "sparkles", text: "Category")
    private let detailCollectionChip = HeaderStatChipView(symbolName: "folder", text: "Collection")
    private let detailDuplicateChip = HeaderStatChipView(symbolName: "square.on.square", text: "Unique")
    private let detailPopularityChip = HeaderStatChipView(symbolName: "heart", text: "Fresh pick")
    private let detailPathLabel = NSTextField(wrappingLabelWithString: "")
    private let detailStatusCard = NSVisualEffectView()
    private let detailStatusLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "Beam", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "Favorite", target: nil, action: nil)
    private let cloudLikeButton = NSButton(title: "Like in Cloud", target: nil, action: nil)
    private let backdropView = PixelShaderBackdropView()

    private var allItems: [AnimationLibraryItem] = []
    private var filteredItems: [AnimationLibraryItem] = []
    private var favorites: Set<String> = []
    private var cloudManifest: DivoomCloudManifest?
    private var selectedSource = "all"
    private var selectedScope = "all"
    private var selectedCategory = "all"
    private var selectedCollection = "all"
    private var selectedItemID: String?
    private var displayMode: AnimationLibraryDisplayMode = .grid
    private var sortMode: AnimationLibrarySortMode = .spotlight
    private var advancedFiltersVisible = false

    init(
        onSend: @escaping (AnimationLibraryItem) -> Void,
        onReveal: @escaping (AnimationLibraryItem) -> Void,
        onOpenCloudSettings: @escaping () -> Void,
        onSaveCloudCredentials: @escaping (String, String) -> Void,
        onImportSyncedCloudCredentials: @escaping () -> Void,
        onSyncCloudNow: @escaping () -> Void,
        onSearchCloud: @escaping (String) -> Void,
        onToggleCloudLike: @escaping (AnimationLibraryItem, Bool, @escaping @MainActor (Bool, String) -> Void) -> Void
    ) {
        self.onSend = onSend
        self.onReveal = onReveal
        self.onOpenCloudSettings = onOpenCloudSettings
        self.onSaveCloudCredentials = onSaveCloudCredentials
        self.onImportSyncedCloudCredentials = onImportSyncedCloudCredentials
        self.onSyncCloudNow = onSyncCloudNow
        self.onSearchCloud = onSearchCloud
        self.onToggleCloudLike = onToggleCloudLike

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1188, height: 764),
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
        updateCloudLoginButton()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadFromExternalSync() {
        reloadLibrary()
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

        func configureCard(_ view: NSVisualEffectView, material: NSVisualEffectView.Material = .menu, radius: CGFloat = 28) {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.material = material
            view.blendingMode = .withinWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
            view.layer?.shadowColor = NSColor.black.withAlphaComponent(0.05).cgColor
            view.layer?.shadowOpacity = 1
            view.layer?.shadowRadius = 18
            view.layer?.shadowOffset = NSSize(width: 0, height: -3)
            view.layer?.masksToBounds = true
        }

        func configureToolbarButton(_ button: NSButton, emphasized: Bool = false) {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = emphasized ? .white : .labelColor
            if emphasized {
                button.bezelColor = NSColor.controlAccentColor.withAlphaComponent(0.90)
            }
        }

        func configureToolbarPopUp(_ button: NSPopUpButton) {
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12, weight: .semibold)
        }

        func configureSectionEyebrow(_ label: NSTextField) {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .bold)
            label.textColor = .tertiaryLabelColor
            label.alignment = .left
            label.maximumNumberOfLines = 1
        }

        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        if #available(macOS 11.0, *) {
            panel.toolbarStyle = .unifiedCompact
        }

        let rootView = NSVisualEffectView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.material = .underWindowBackground
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.wantsLayer = true
        contentView.addSubview(rootView)

        backdropView.palette = .library
        backdropView.activityBoost = 0.16
        rootView.addSubview(backdropView)

        let heroCard = NSVisualEffectView()
        configureCard(heroCard, material: .underWindowBackground, radius: 26)
        let headerBackdrop = PixelShaderBackdropView()
        headerBackdrop.palette = .library
        headerBackdrop.activityBoost = 0.08
        heroCard.addSubview(headerBackdrop)

        headerIconView.translatesAutoresizingMaskIntoConstraints = false
        let headerSymbolConfig = NSImage.SymbolConfiguration(pointSize: 21, weight: .bold)
        headerIconView.image = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: "Animation Library")?.withSymbolConfiguration(headerSymbolConfig)
        headerIconView.contentTintColor = .systemOrange

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.lineBreakMode = .byWordWrapping

        resultsLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        resultsLabel.textColor = .secondaryLabelColor
        resultsLabel.setContentHuggingPriority(.required, for: .horizontal)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .large
        searchField.placeholderString = "Search animations, topics, collections, or cloud picks…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true

        sourcePopUp.translatesAutoresizingMaskIntoConstraints = false
        configureToolbarPopUp(sourcePopUp)
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)

        scopePopUp.translatesAutoresizingMaskIntoConstraints = false
        configureToolbarPopUp(scopePopUp)
        scopePopUp.target = self
        scopePopUp.action = #selector(scopeChanged)

        categoryPopUp.translatesAutoresizingMaskIntoConstraints = false
        configureToolbarPopUp(categoryPopUp)
        categoryPopUp.target = self
        categoryPopUp.action = #selector(categoryChanged)

        collectionPopUp.translatesAutoresizingMaskIntoConstraints = false
        configureToolbarPopUp(collectionPopUp)
        collectionPopUp.target = self
        collectionPopUp.action = #selector(collectionChanged)

        sortPopUp.translatesAutoresizingMaskIntoConstraints = false
        configureToolbarPopUp(sortPopUp)
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged)
        sortPopUp.removeAllItems()
        AnimationLibrarySortMode.allCases.forEach { mode in
            sortPopUp.addItem(withTitle: mode.title)
            sortPopUp.lastItem?.representedObject = mode.rawValue
        }
        sortPopUp.selectItem(at: sortMode.rawValue)

        filterDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        filterDisclosureButton.bezelStyle = .rounded
        filterDisclosureButton.title = "Filters"
        filterDisclosureButton.image = makeMenuSymbol("line.3.horizontal.decrease.circle", description: "More Filters")
        filterDisclosureButton.imagePosition = .imageLeading
        filterDisclosureButton.target = self
        filterDisclosureButton.action = #selector(toggleAdvancedFilters)
        configureToolbarButton(filterDisclosureButton)

        displayModeControl.translatesAutoresizingMaskIntoConstraints = false
        displayModeControl.controlSize = .small
        displayModeControl.selectedSegment = AnimationLibraryDisplayMode.grid.rawValue
        displayModeControl.target = self
        displayModeControl.action = #selector(displayModeChanged)

        favoritesOnlyButton.translatesAutoresizingMaskIntoConstraints = false
        favoritesOnlyButton.setButtonType(.toggle)
        favoritesOnlyButton.bezelStyle = .rounded
        favoritesOnlyButton.title = "Starred Only"
        favoritesOnlyButton.image = makeMenuSymbol("star", description: "Favorites")
        favoritesOnlyButton.imagePosition = .imageLeading
        favoritesOnlyButton.target = self
        favoritesOnlyButton.action = #selector(toggleFavoritesOnly)
        configureToolbarButton(favoritesOnlyButton)

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .rounded
        refreshButton.title = "Reload"
        refreshButton.image = makeMenuSymbol("arrow.clockwise", description: "Reload")
        refreshButton.imagePosition = .imageLeading
        refreshButton.target = self
        refreshButton.action = #selector(refreshLibrary)
        configureToolbarButton(refreshButton)

        syncCloudButton.translatesAutoresizingMaskIntoConstraints = false
        syncCloudButton.bezelStyle = .rounded
        syncCloudButton.title = "Sync"
        syncCloudButton.image = makeMenuSymbol("icloud.and.arrow.down", description: "Sync")
        syncCloudButton.imagePosition = .imageLeading
        syncCloudButton.target = self
        syncCloudButton.action = #selector(syncCloudNow)
        configureToolbarButton(syncCloudButton)

        searchCloudButton.translatesAutoresizingMaskIntoConstraints = false
        searchCloudButton.bezelStyle = .rounded
        searchCloudButton.title = "Search Cloud"
        searchCloudButton.image = makeMenuSymbol("magnifyingglass.circle", description: "Cloud Search")
        searchCloudButton.imagePosition = .imageLeading
        searchCloudButton.target = self
        searchCloudButton.action = #selector(searchCloudNow)
        configureToolbarButton(searchCloudButton)

        cloudAccessStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudAccessStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        cloudAccessStatusLabel.textColor = .labelColor
        cloudAccessStatusLabel.maximumNumberOfLines = 3
        cloudAccessStatusLabel.lineBreakMode = .byWordWrapping

        cloudTipLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudTipLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cloudTipLabel.textColor = .secondaryLabelColor
        cloudTipLabel.maximumNumberOfLines = 2
        cloudTipLabel.lineBreakMode = .byWordWrapping

        cloudEmailField.translatesAutoresizingMaskIntoConstraints = false
        cloudEmailField.controlSize = .small
        cloudEmailField.placeholderString = "Divoom account email"

        cloudPasswordField.translatesAutoresizingMaskIntoConstraints = false
        cloudPasswordField.controlSize = .small
        cloudPasswordField.placeholderString = "Divoom password"

        cloudSaveButton.translatesAutoresizingMaskIntoConstraints = false
        cloudSaveButton.bezelStyle = .rounded
        cloudSaveButton.title = "Save Local Login"
        cloudSaveButton.image = makeMenuSymbol("lock.shield", description: "Save Cloud Credentials")
        cloudSaveButton.imagePosition = .imageLeading
        cloudSaveButton.target = self
        cloudSaveButton.action = #selector(saveCloudCredentialsInline)
        configureToolbarButton(cloudSaveButton)

        cloudImportButton.translatesAutoresizingMaskIntoConstraints = false
        cloudImportButton.bezelStyle = .rounded
        cloudImportButton.title = "Import from Passwords"
        cloudImportButton.image = makeMenuSymbol("square.and.arrow.down.on.square", description: "Import from Passwords")
        cloudImportButton.imagePosition = .imageLeading
        cloudImportButton.target = self
        cloudImportButton.action = #selector(importCloudCredentials)
        configureToolbarButton(cloudImportButton)

        cloudLoginButton.translatesAutoresizingMaskIntoConstraints = false
        cloudLoginButton.bezelStyle = .rounded
        cloudLoginButton.imagePosition = .imageLeading
        cloudLoginButton.target = self
        cloudLoginButton.action = #selector(openCloudSettings)
        cloudLoginButton.setContentHuggingPriority(.required, for: .horizontal)
        configureToolbarButton(cloudLoginButton)

        let titleRow = NSStackView(views: [headerIconView, titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let headerIntroStack = NSStackView(views: [titleRow, summaryLabel])
        headerIntroStack.orientation = .vertical
        headerIntroStack.alignment = .leading
        headerIntroStack.spacing = 4
        headerIntroStack.translatesAutoresizingMaskIntoConstraints = false

        let headerMetricsRow = NSStackView(views: [assetChip, categoryChip, sourceChip, favoriteChip])
        headerMetricsRow.orientation = .horizontal
        headerMetricsRow.alignment = .centerY
        headerMetricsRow.spacing = 8
        headerMetricsRow.translatesAutoresizingMaskIntoConstraints = false

        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false

        let headerTopRow = NSStackView(views: [headerIntroStack, headerSpacer, resultsLabel])
        headerTopRow.orientation = .horizontal
        headerTopRow.alignment = .top
        headerTopRow.spacing = 12
        headerTopRow.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = NSStackView(views: [searchField, displayModeControl, favoritesOnlyButton, refreshButton])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 10
        searchRow.translatesAutoresizingMaskIntoConstraints = false

        let utilityRow = NSStackView(views: [sourcePopUp, sortPopUp, cloudLoginButton, syncCloudButton, searchCloudButton, filterDisclosureButton])
        utilityRow.orientation = .horizontal
        utilityRow.alignment = .centerY
        utilityRow.spacing = 10
        utilityRow.translatesAutoresizingMaskIntoConstraints = false
        utilityRow.detachesHiddenViews = true

        configureCard(cloudAccessCard, material: .hudWindow, radius: 20)
        cloudAccessCard.isHidden = true

        let cloudSpacer = NSView()
        cloudSpacer.translatesAutoresizingMaskIntoConstraints = false

        let cloudTopRow = NSStackView(views: [cloudAccessStatusLabel, cloudSpacer])
        cloudTopRow.orientation = .horizontal
        cloudTopRow.alignment = .top
        cloudTopRow.spacing = 12
        cloudTopRow.translatesAutoresizingMaskIntoConstraints = false

        let credentialRow = NSStackView(views: [cloudEmailField, cloudPasswordField, cloudSaveButton, cloudImportButton])
        credentialRow.orientation = .horizontal
        credentialRow.alignment = .centerY
        credentialRow.spacing = 8
        credentialRow.translatesAutoresizingMaskIntoConstraints = false

        let cloudStack = NSStackView(views: [cloudTopRow, credentialRow, cloudTipLabel])
        cloudStack.orientation = .vertical
        cloudStack.alignment = .leading
        cloudStack.spacing = 10
        cloudStack.translatesAutoresizingMaskIntoConstraints = false
        cloudAccessCard.addSubview(cloudStack)
        NSLayoutConstraint.activate([
            cloudStack.leadingAnchor.constraint(equalTo: cloudAccessCard.leadingAnchor, constant: 14),
            cloudStack.trailingAnchor.constraint(equalTo: cloudAccessCard.trailingAnchor, constant: -14),
            cloudStack.topAnchor.constraint(equalTo: cloudAccessCard.topAnchor, constant: 14),
            cloudStack.bottomAnchor.constraint(equalTo: cloudAccessCard.bottomAnchor, constant: -14),
        ])

        advancedFilterRow.setViews([scopePopUp, categoryPopUp, collectionPopUp], in: .leading)
        advancedFilterRow.orientation = .horizontal
        advancedFilterRow.alignment = .centerY
        advancedFilterRow.spacing = 10
        advancedFilterRow.translatesAutoresizingMaskIntoConstraints = false
        advancedFilterRow.isHidden = !advancedFiltersVisible
        advancedFilterRow.detachesHiddenViews = true

        let heroStack = NSStackView(views: [headerTopRow, headerMetricsRow, searchRow, utilityRow, advancedFilterRow])
        heroStack.orientation = .vertical
        heroStack.alignment = .leading
        heroStack.spacing = 8
        heroStack.translatesAutoresizingMaskIntoConstraints = false
        heroCard.addSubview(heroStack)

        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let browserPane = NSVisualEffectView()
        configureCard(browserPane, material: .hudWindow, radius: 24)

        let browserSectionLabel = NSTextField(labelWithString: "Catalog")
        configureSectionEyebrow(browserSectionLabel)

        let browserSectionSummaryLabel = NSTextField(labelWithString: "Large previews, fast filtering, and one-click beam across curated and cloud picks.")
        browserSectionSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        browserSectionSummaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        browserSectionSummaryLabel.textColor = .secondaryLabelColor
        browserSectionSummaryLabel.maximumNumberOfLines = 2
        browserSectionSummaryLabel.lineBreakMode = .byWordWrapping

        collectionScrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionScrollView.hasVerticalScroller = true
        collectionScrollView.drawsBackground = false

        flowLayout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 20, right: 8)
        flowLayout.minimumInteritemSpacing = 12
        flowLayout.minimumLineSpacing = 12

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.collectionViewLayout = flowLayout
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(AnimationLibraryCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("AnimationLibraryCollectionItem"))
        collectionScrollView.documentView = collectionView

        emptyStateStack.orientation = .vertical
        emptyStateStack.alignment = .centerX
        emptyStateStack.spacing = 6
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let emptyStateSymbolConfig = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        emptyStateIconView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateIconView.image = NSImage(systemSymbolName: "square.grid.3x3", accessibilityDescription: "Empty Library")?.withSymbolConfiguration(emptyStateSymbolConfig)
        emptyStateIconView.contentTintColor = .tertiaryLabelColor

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        emptyLabel.textColor = .labelColor

        emptyDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyDetailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        emptyDetailLabel.textColor = .secondaryLabelColor
        emptyDetailLabel.maximumNumberOfLines = 2
        emptyDetailLabel.lineBreakMode = .byWordWrapping
        emptyDetailLabel.alignment = .center

        emptyStateStack.addArrangedSubview(emptyStateIconView)
        emptyStateStack.addArrangedSubview(emptyLabel)
        emptyStateStack.addArrangedSubview(emptyDetailLabel)
        emptyStateStack.isHidden = true

        browserPane.addSubview(browserSectionLabel)
        browserPane.addSubview(browserSectionSummaryLabel)
        browserPane.addSubview(collectionScrollView)
        browserPane.addSubview(emptyStateStack)

        configureCard(inspectorView, material: .hudWindow, radius: 24)

        configureSectionEyebrow(inspectorSectionLabel)

        inspectorSectionSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        inspectorSectionSummaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        inspectorSectionSummaryLabel.textColor = .secondaryLabelColor
        inspectorSectionSummaryLabel.maximumNumberOfLines = 2
        inspectorSectionSummaryLabel.lineBreakMode = .byWordWrapping

        detailPreviewView.translatesAutoresizingMaskIntoConstraints = false
        detailPreviewView.onPrimaryAction = { [weak self] in
            guard let self, let item = self.currentSelectedItem else { return }
            self.triggerSend(for: item)
        }

        detailTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailTitleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        detailTitleLabel.lineBreakMode = .byTruncatingTail
        detailTitleLabel.maximumNumberOfLines = 2

        detailMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        detailMetaLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailMetaLabel.textColor = .secondaryLabelColor
        detailMetaLabel.maximumNumberOfLines = 2
        detailMetaLabel.lineBreakMode = .byWordWrapping

        detailPathLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailPathLabel.textColor = .secondaryLabelColor
        detailPathLabel.maximumNumberOfLines = 2
        detailPathLabel.lineBreakMode = .byTruncatingMiddle

        configureCard(detailStatusCard, material: .menu, radius: 16)

        detailStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        detailStatusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        detailStatusLabel.textColor = .secondaryLabelColor
        detailStatusLabel.lineBreakMode = .byWordWrapping
        detailStatusLabel.maximumNumberOfLines = 3
        detailStatusLabel.stringValue = ""

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.bezelStyle = .rounded
        sendButton.title = "Beam to Ditoo"
        sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
        sendButton.imagePosition = .imageLeading
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendSelectedItem)
        configureToolbarButton(sendButton, emphasized: true)

        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.bezelStyle = .rounded
        revealButton.image = makeMenuSymbol("folder", description: "Reveal in Finder")
        revealButton.imagePosition = .imageLeading
        revealButton.target = self
        revealButton.action = #selector(revealSelectedItem)
        configureToolbarButton(revealButton)

        favoriteButton.translatesAutoresizingMaskIntoConstraints = false
        favoriteButton.bezelStyle = .rounded
        favoriteButton.image = makeMenuSymbol("star", description: "Favorite")
        favoriteButton.imagePosition = .imageLeading
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavoriteForSelectedItem)
        configureToolbarButton(favoriteButton)

        cloudLikeButton.translatesAutoresizingMaskIntoConstraints = false
        cloudLikeButton.bezelStyle = .rounded
        cloudLikeButton.image = makeMenuSymbol("hand.thumbsup", description: "Like in Cloud")
        cloudLikeButton.imagePosition = .imageLeading
        cloudLikeButton.target = self
        cloudLikeButton.action = #selector(toggleCloudLikeForSelectedItem)
        cloudLikeButton.isHidden = true
        configureToolbarButton(cloudLikeButton)

        let secondaryButtons = NSStackView(views: [revealButton, favoriteButton, cloudLikeButton])
        secondaryButtons.orientation = .horizontal
        secondaryButtons.alignment = .centerY
        secondaryButtons.spacing = 8
        secondaryButtons.distribution = .fillEqually
        secondaryButtons.translatesAutoresizingMaskIntoConstraints = false
        secondaryButtons.detachesHiddenViews = true

        let inspectorButtons = NSStackView(views: [sendButton, secondaryButtons])
        inspectorButtons.orientation = .vertical
        inspectorButtons.alignment = .leading
        inspectorButtons.spacing = 8
        inspectorButtons.translatesAutoresizingMaskIntoConstraints = false

        let inspectorPrimaryChipRow = NSStackView(views: [detailSourceChip, detailFeedChip, detailCategoryChip])
        inspectorPrimaryChipRow.orientation = .horizontal
        inspectorPrimaryChipRow.alignment = .centerY
        inspectorPrimaryChipRow.spacing = 8
        inspectorPrimaryChipRow.translatesAutoresizingMaskIntoConstraints = false

        let inspectorSecondaryChipRow = NSStackView(views: [detailCollectionChip, detailDuplicateChip, detailPopularityChip])
        inspectorSecondaryChipRow.orientation = .horizontal
        inspectorSecondaryChipRow.alignment = .centerY
        inspectorSecondaryChipRow.spacing = 8
        inspectorSecondaryChipRow.translatesAutoresizingMaskIntoConstraints = false

        detailStatusCard.addSubview(detailStatusLabel)
        NSLayoutConstraint.activate([
            detailStatusLabel.leadingAnchor.constraint(equalTo: detailStatusCard.leadingAnchor, constant: 12),
            detailStatusLabel.trailingAnchor.constraint(equalTo: detailStatusCard.trailingAnchor, constant: -12),
            detailStatusLabel.topAnchor.constraint(equalTo: detailStatusCard.topAnchor, constant: 10),
            detailStatusLabel.bottomAnchor.constraint(equalTo: detailStatusCard.bottomAnchor, constant: -10),
        ])

        let inspectorText = NSStackView(views: [detailTitleLabel, detailMetaLabel, inspectorPrimaryChipRow, inspectorSecondaryChipRow, detailPathLabel, inspectorButtons, detailStatusCard])
        inspectorText.orientation = .vertical
        inspectorText.alignment = .leading
        inspectorText.spacing = 10
        inspectorText.translatesAutoresizingMaskIntoConstraints = false

        inspectorView.addSubview(inspectorSectionLabel)
        inspectorView.addSubview(inspectorSectionSummaryLabel)
        inspectorView.addSubview(detailPreviewView)
        inspectorView.addSubview(inspectorText)

        splitView.addArrangedSubview(browserPane)
        splitView.addArrangedSubview(inspectorView)

        rootView.addSubview(heroCard)
        rootView.addSubview(splitView)

        let safeGuide = rootView.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            backdropView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: rootView.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            heroCard.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            heroCard.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            heroCard.topAnchor.constraint(equalTo: safeGuide.topAnchor, constant: 12),

            headerBackdrop.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor),
            headerBackdrop.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor),
            headerBackdrop.topAnchor.constraint(equalTo: heroCard.topAnchor),
            headerBackdrop.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor),

            heroStack.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 16),
            heroStack.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -16),
            heroStack.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 14),
            heroStack.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -14),

            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            sourcePopUp.widthAnchor.constraint(equalToConstant: 122),
            sortPopUp.widthAnchor.constraint(equalToConstant: 132),
            scopePopUp.widthAnchor.constraint(equalToConstant: 136),
            categoryPopUp.widthAnchor.constraint(equalToConstant: 138),
            collectionPopUp.widthAnchor.constraint(equalToConstant: 144),
            displayModeControl.widthAnchor.constraint(equalToConstant: 116),

            splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            splitView.topAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: 14),
            splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),

            browserSectionLabel.leadingAnchor.constraint(equalTo: browserPane.leadingAnchor, constant: 16),
            browserSectionLabel.trailingAnchor.constraint(equalTo: browserPane.trailingAnchor, constant: -16),
            browserSectionLabel.topAnchor.constraint(equalTo: browserPane.topAnchor, constant: 14),

            browserSectionSummaryLabel.leadingAnchor.constraint(equalTo: browserPane.leadingAnchor, constant: 16),
            browserSectionSummaryLabel.trailingAnchor.constraint(equalTo: browserPane.trailingAnchor, constant: -16),
            browserSectionSummaryLabel.topAnchor.constraint(equalTo: browserSectionLabel.bottomAnchor, constant: 2),

            collectionScrollView.leadingAnchor.constraint(equalTo: browserPane.leadingAnchor, constant: 8),
            collectionScrollView.trailingAnchor.constraint(equalTo: browserPane.trailingAnchor, constant: -8),
            collectionScrollView.topAnchor.constraint(equalTo: browserSectionSummaryLabel.bottomAnchor, constant: 10),
            collectionScrollView.bottomAnchor.constraint(equalTo: browserPane.bottomAnchor, constant: -8),

            emptyStateStack.centerXAnchor.constraint(equalTo: browserPane.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: browserPane.centerYAnchor),
            emptyStateStack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            inspectorView.widthAnchor.constraint(equalToConstant: 372),

            inspectorSectionLabel.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            inspectorSectionLabel.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            inspectorSectionLabel.topAnchor.constraint(equalTo: inspectorView.topAnchor, constant: 14),

            inspectorSectionSummaryLabel.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            inspectorSectionSummaryLabel.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            inspectorSectionSummaryLabel.topAnchor.constraint(equalTo: inspectorSectionLabel.bottomAnchor, constant: 2),

            detailPreviewView.topAnchor.constraint(equalTo: inspectorSectionSummaryLabel.bottomAnchor, constant: 12),
            detailPreviewView.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            detailPreviewView.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            detailPreviewView.heightAnchor.constraint(equalToConstant: 232),

            inspectorText.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            inspectorText.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            inspectorText.topAnchor.constraint(equalTo: detailPreviewView.bottomAnchor, constant: 14),
            inspectorText.bottomAnchor.constraint(lessThanOrEqualTo: inspectorView.bottomAnchor, constant: -18),

            sendButton.widthAnchor.constraint(equalTo: inspectorText.widthAnchor),
            secondaryButtons.widthAnchor.constraint(equalTo: inspectorText.widthAnchor),
        ])

        updateDetailPanel()
        updateCollectionLayout()
        updateAdvancedFilterVisibility()
    }

    @objc private func searchChanged() {
        applyFilters()
    }

    @objc private func sourceChanged() {
        selectedSource = (sourcePopUp.selectedItem?.representedObject as? String) ?? "all"
        rebuildScopeMenu()
        rebuildCategoryMenu()
        rebuildCollectionMenu()
        applyFilters()
    }

    @objc private func scopeChanged() {
        selectedScope = (scopePopUp.selectedItem?.representedObject as? String) ?? "all"
        rebuildCategoryMenu()
        rebuildCollectionMenu()
        applyFilters()
    }

    @objc private func categoryChanged() {
        selectedCategory = (categoryPopUp.selectedItem?.representedObject as? String) ?? "all"
        rebuildCollectionMenu()
        applyFilters()
    }

    @objc private func collectionChanged() {
        selectedCollection = (collectionPopUp.selectedItem?.representedObject as? String) ?? "all"
        applyFilters()
    }

    @objc private func sortChanged() {
        let rawValue = (sortPopUp.selectedItem?.representedObject as? Int) ?? AnimationLibrarySortMode.spotlight.rawValue
        sortMode = AnimationLibrarySortMode(rawValue: rawValue) ?? .spotlight
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

    @objc private func toggleAdvancedFilters() {
        advancedFiltersVisible.toggle()
        updateAdvancedFilterVisibility()
    }

    @objc private func syncCloudNow() {
        onSyncCloudNow()
    }

    @objc private func searchCloudNow() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            NSSound.beep()
            cloudAccessStatusLabel.stringValue = "Type a query first, then search the Divoom cloud library."
            return
        }
        selectedSource = "divoom-cloud"
        selectedScope = "search"
        cloudAccessStatusLabel.stringValue = "Searching Divoom Cloud for “\(query)” and pulling the best matches into the native browser."
        onSearchCloud(query)
    }

    @objc private func openCloudSettings() {
        onOpenCloudSettings()
    }

    @objc private func saveCloudCredentialsInline() {
        onSaveCloudCredentials(
            cloudEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            cloudPasswordField.stringValue
        )
        cloudPasswordField.stringValue = ""
        reloadLibrary()
    }

    @objc private func importCloudCredentials() {
        onImportSyncedCloudCredentials()
        cloudPasswordField.stringValue = ""
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

    @objc private func toggleCloudLikeForSelectedItem() {
        guard let currentSelectedItem, currentSelectedItem.source == "divoom-cloud", currentSelectedItem.galleryID > 0 else {
            NSSound.beep()
            return
        }

        cloudLikeButton.isEnabled = false
        let shouldLike = !currentSelectedItem.isLiked
        onToggleCloudLike(currentSelectedItem, shouldLike) { [weak self] success, details in
            guard let self else { return }
            self.cloudLikeButton.isEnabled = true
            if success {
                self.updateCloudLikeState(for: currentSelectedItem.id, isLiked: shouldLike)
                self.detailStatusLabel.stringValue = shouldLike ? "Saved to Divoom Cloud likes." : "Removed from Divoom Cloud likes."
            } else {
                self.detailStatusLabel.stringValue = details
            }
        }
    }

    private var currentSelectedItem: AnimationLibraryItem? {
        guard let selectedItemID else {
            return nil
        }
        return filteredItems.first(where: { $0.id == selectedItemID }) ?? allItems.first(where: { $0.id == selectedItemID })
    }

    private func reloadLibrary() {
        cloudAccessStatusLabel.stringValue = "Refreshing curated and cloud-backed picks."
        updateCloudLoginButton()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = AnimationLibraryCatalog.loadItems()
            let manifest = AnimationLibraryCatalog.loadCloudManifest()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.allItems = items
                self.cloudManifest = manifest
                self.favorites = AnimationLibraryCatalog.loadFavorites(resolvingAgainst: items)
                self.rebuildSourceMenu()
                self.rebuildScopeMenu()
                self.rebuildCategoryMenu()
                self.rebuildCollectionMenu()
                self.applyFilters()
            }
        }
    }

    private func rebuildSourceMenu() {
        let previousSource = selectedSource
        let sources = Array(Set(allItems.map(\.source))).sorted()
        sourcePopUp.removeAllItems()
        sourcePopUp.addItem(withTitle: "All Sources")
        sourcePopUp.lastItem?.representedObject = "all"
        sourcePopUp.lastItem?.image = makeMenuSymbol("photo.stack", description: "All Sources")
        for source in sources {
            let title = AnimationLibraryCatalog.displaySourceTitle(for: source)
            sourcePopUp.addItem(withTitle: title)
            sourcePopUp.lastItem?.representedObject = source
            sourcePopUp.lastItem?.image = makeMenuSymbol(source == "divoom-cloud" ? "icloud" : "shippingbox", description: title)
        }

        let targetSource = previousSource != "all" && sources.contains(previousSource) ? previousSource : "all"
        selectedSource = targetSource
        if let item = sourcePopUp.itemArray.first(where: { ($0.representedObject as? String) == targetSource }) {
            sourcePopUp.select(item)
        } else {
            sourcePopUp.selectItem(at: 0)
        }
    }

    private func rebuildCategoryMenu() {
        let previousCategory = selectedCategory
        let categories = Array(
            Set(
                allItems
                    .filter { selectedSource == "all" || $0.source == selectedSource }
                    .filter { selectedScope == "all" || $0.scope == selectedScope }
                    .map(\.category)
            )
        ).sorted()
        categoryPopUp.removeAllItems()
        categoryPopUp.addItem(withTitle: "All Topics")
        categoryPopUp.lastItem?.representedObject = "all"
        categoryPopUp.lastItem?.image = makeMenuSymbol("square.grid.3x3.fill", description: "All Topics")
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

    private func rebuildCollectionMenu() {
        let previousCollection = selectedCollection
        let collections = Array(
            Set(
                allItems
                    .filter { selectedSource == "all" || $0.source == selectedSource }
                    .filter { selectedScope == "all" || $0.scope == selectedScope }
                    .filter { selectedCategory == "all" || $0.category == selectedCategory }
                    .map(\.collection)
            )
        ).sorted()

        collectionPopUp.removeAllItems()
        collectionPopUp.addItem(withTitle: "All Collections")
        collectionPopUp.lastItem?.representedObject = "all"
        collectionPopUp.lastItem?.image = makeMenuSymbol("shippingbox", description: "All Collections")
        for collection in collections {
            let title = AnimationLibraryCatalog.displayCollectionTitle(for: collection)
            collectionPopUp.addItem(withTitle: title)
            collectionPopUp.lastItem?.representedObject = collection
            collectionPopUp.lastItem?.image = makeMenuSymbol(collection == "root" ? "shippingbox" : "folder", description: title)
        }

        let targetCollection = previousCollection != "all" && collections.contains(previousCollection) ? previousCollection : "all"
        selectedCollection = targetCollection
        if let item = collectionPopUp.itemArray.first(where: { ($0.representedObject as? String) == targetCollection }) {
            collectionPopUp.select(item)
        } else {
            collectionPopUp.selectItem(at: 0)
        }
    }

    private func applyFilters() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let favoritesOnly = favoritesOnlyButton.state == .on
        let preservedSelectionID = selectedItemID

        let matches = allItems.filter { item in
            if selectedSource != "all" && item.source != selectedSource {
                return false
            }
            if selectedScope != "all" && item.scope != selectedScope {
                return false
            }
            if selectedCategory != "all" && item.category != selectedCategory {
                return false
            }
            if selectedCollection != "all" && item.collection != selectedCollection {
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

        filteredItems = sortItems(matches)

        collectionView.reloadData()
        emptyStateStack.isHidden = !filteredItems.isEmpty
        if filteredItems.isEmpty {
            if favoritesOnly {
                emptyLabel.stringValue = "No starred animations in this view."
                emptyDetailLabel.stringValue = "Turn off Starred or widen the source filters to bring more animations back."
            } else if selectedSource == "divoom-cloud" && query.isEmpty {
                emptyLabel.stringValue = "Cloud source is selected."
                emptyDetailLabel.stringValue = "Type a search above or sync the cloud library to pull Divoom results into the browser."
            } else if !query.isEmpty {
                emptyLabel.stringValue = "No matches for “\(searchField.stringValue)”."
                emptyDetailLabel.stringValue = "Try a broader search, switch source, or open Refine to widen the current view."
            } else {
                emptyLabel.stringValue = "Nothing matches this browser view."
                emptyDetailLabel.stringValue = "Clear a filter, switch libraries, or run a cloud search to widen the catalog."
            }
        }
        let visibleSourceCount = Set(filteredItems.map(\.source)).count
        updateCloudLoginButton()
        updateLibrarySummary(visibleSourceCount: visibleSourceCount)
        updateHeaderChips()
        resultsLabel.stringValue = filteredItems.count == 1 ? "1 match" : "\(filteredItems.count) matches"

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

    private func updateCloudLoginButton() {
        let credentialState = resolvedCloudCredentialUIState()
        let hasAnyCredentials = credentialState.usesLocalKeychain
        let hasLocalCredentials = credentialState.usesLocalKeychain

        syncCloudButton.isEnabled = hasAnyCredentials
        searchCloudButton.isEnabled = hasAnyCredentials && selectedSource == "divoom-cloud"
        searchCloudButton.alphaValue = selectedSource == "divoom-cloud" ? 1.0 : 0.72
        cloudImportButton.isEnabled = credentialState.canImportSyncedCredentials
        cloudAccessStatusLabel.stringValue = credentialState.status
        cloudTipLabel.stringValue = selectedSource == "divoom-cloud"
            ? "Cloud Search uses the current query and drops the results directly into this browser."
            : "Switch Source to Divoom Cloud when you want the search field to query the live catalog."

        let isEditingEmailField = cloudEmailField.currentEditor() != nil
        if !credentialState.email.isEmpty, !isEditingEmailField {
            cloudEmailField.stringValue = credentialState.email
        } else if !isEditingEmailField {
            cloudEmailField.stringValue = ""
        }
        cloudPasswordField.placeholderString = credentialState.passwordPlaceholder

        cloudEmailField.isHidden = true
        cloudPasswordField.isHidden = true
        cloudSaveButton.isHidden = true
        cloudImportButton.isHidden = true
        updateCloudAccessCardVisibility(
            hasAnyCredentials: hasAnyCredentials,
            hasLocalCredentials: hasLocalCredentials,
            selectedCloudSource: selectedSource == "divoom-cloud"
        )

        if hasLocalCredentials {
            cloudLoginButton.title = "Cloud Account…"
            cloudLoginButton.toolTip = "Review saved credentials, sync cadence, and cloud cache settings."
            cloudLoginButton.image = makeMenuSymbol("lock.icloud", description: "Manage Cloud")
            syncCloudButton.title = "Sync Cloud"
        } else {
            cloudLoginButton.title = "Connect Cloud…"
            cloudLoginButton.toolTip = "Save Divoom credentials here or import them from Passwords."
            cloudLoginButton.image = makeMenuSymbol("person.crop.circle.badge.plus", description: "Connect Cloud")
            syncCloudButton.title = "Sync Locked"
        }
    }

    private func updateCloudAccessCardVisibility(
        hasAnyCredentials: Bool,
        hasLocalCredentials: Bool,
        selectedCloudSource: Bool
    ) {
        _ = hasAnyCredentials
        _ = hasLocalCredentials
        _ = selectedCloudSource
        cloudAccessCard.isHidden = true
        cloudAccessCard.alphaValue = 0.0
    }

    private func updateLibrarySummary(visibleSourceCount: Int) {
        let storeChannels = cloudManifest?.storeClassify?.count ?? 0
        let playlists = (cloudManifest?.myPlaylists?.count ?? 0) + (cloudManifest?.someonePlaylists?.count ?? 0)
        let credentialState = resolvedCloudCredentialUIState()
        let sourceCopy: String
        switch selectedSource {
        case "divoom-cloud":
            sourceCopy = "Cloud catalog"
        case "curated":
            sourceCopy = "Curated catalog"
        default:
            sourceCopy = "Unified catalog"
        }
        if credentialState.usesLocalKeychain {
            summaryLabel.stringValue = "\(sourceCopy) with native search, likes, playlists, store channels, and direct Ditoo beam."
            cloudAccessStatusLabel.stringValue = "\(filteredItems.count) visible across \(visibleSourceCount) source\(visibleSourceCount == 1 ? "" : "s"). Cloud is linked with \(storeChannels) store channels and \(playlists) playlists ready."
        } else {
            summaryLabel.stringValue = "\(sourceCopy) with favorites, direct beam, and optional Divoom Cloud search."
            cloudAccessStatusLabel.stringValue = "\(filteredItems.count) visible across \(visibleSourceCount) source\(visibleSourceCount == 1 ? "" : "s"). Connect Cloud in Settings to unlock search, likes, store channels, and playlists."
        }
    }

    private func updateAdvancedFilterVisibility() {
        advancedFilterRow.isHidden = !advancedFiltersVisible
        filterDisclosureButton.title = advancedFiltersVisible ? "Hide Filters" : "Filters"
        filterDisclosureButton.toolTip = advancedFiltersVisible
            ? "Collapse scope, category, and collection filters"
            : "Expand scope, category, and collection filters"
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func sortItems(_ items: [AnimationLibraryItem]) -> [AnimationLibraryItem] {
        items.sorted { lhs, rhs in
            switch sortMode {
            case .spotlight:
                let leftScore = spotlightScore(for: lhs)
                let rightScore = spotlightScore(for: rhs)
                if leftScore == rightScore {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return leftScore > rightScore
            case .popularity:
                let leftScore = lhs.likes * 4 + lhs.views
                let rightScore = rhs.likes * 4 + rhs.views
                if leftScore == rightScore {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return leftScore > rightScore
            case .newest:
                if lhs.date == rhs.date {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.date > rhs.date
            case .likes:
                if lhs.likes == rhs.likes {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.likes > rhs.likes
            case .views:
                if lhs.views == rhs.views {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.views > rhs.views
            case .feed:
                if lhs.scope == rhs.scope {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.scope.localizedCaseInsensitiveCompare(rhs.scope) == .orderedAscending
            case .title:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .category:
                if lhs.category == rhs.category {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            case .collection:
                if lhs.collection == rhs.collection {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.collection.localizedCaseInsensitiveCompare(rhs.collection) == .orderedAscending
            case .favoritesFirst:
                let leftFavorite = favorites.contains(lhs.id)
                let rightFavorite = favorites.contains(rhs.id)
                if leftFavorite == rightFavorite {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return leftFavorite && !rightFavorite
            case .duplicates:
                if lhs.duplicateCount == rhs.duplicateCount {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.duplicateCount > rhs.duplicateCount
            }
        }
    }

    private func spotlightScore(for item: AnimationLibraryItem) -> Int {
        var score = 0
        if favorites.contains(item.id) {
            score += 1000
        }
        score += item.duplicateCount * 12
        if item.collection == "root" {
            score += 18
        }
        if item.category == "pixel-displays" || item.category == "divoom" {
            score += 10
        }
        score += min(item.likes, 1200) / 16
        score += min(item.views, 4000) / 180
        if !item.relativePath.contains("/textfiles/") {
            score += 6
        }
        score -= item.relativePath.count / 6
        return score
    }

    private func rebuildScopeMenu() {
        let previousScope = selectedScope
        let scopes = Array(
            Set(
                allItems
                    .filter { selectedSource == "all" || $0.source == selectedSource }
                    .map(\.scope)
            )
        ).sorted()

        scopePopUp.removeAllItems()
        scopePopUp.addItem(withTitle: "All Feeds")
        scopePopUp.lastItem?.representedObject = "all"
        scopePopUp.lastItem?.image = makeMenuSymbol("square.grid.2x2", description: "All Feeds")
        for scope in scopes {
            scopePopUp.addItem(withTitle: AnimationLibraryCatalog.displayScopeTitle(for: scope))
            scopePopUp.lastItem?.representedObject = scope
            scopePopUp.lastItem?.image = makeMenuSymbol("square.stack.3d.up", description: scope)
        }

        let targetScope = previousScope != "all" && scopes.contains(previousScope) ? previousScope : "all"
        selectedScope = targetScope
        if let item = scopePopUp.itemArray.first(where: { ($0.representedObject as? String) == targetScope }) {
            scopePopUp.select(item)
        } else {
            scopePopUp.selectItem(at: 0)
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
            let targetCardWidth: CGFloat = 194
            let spacing: CGFloat = 10
            let columns = max(Int((contentWidth + spacing) / (targetCardWidth + spacing)), 2)
            let totalSpacing = CGFloat(max(columns - 1, 0)) * spacing
            let width = floor((contentWidth - totalSpacing - 8) / CGFloat(columns))
            flowLayout.itemSize = NSSize(width: max(width, 176), height: max(width, 176) + 60)
            flowLayout.minimumInteritemSpacing = spacing
            flowLayout.minimumLineSpacing = spacing
        case .list:
            flowLayout.itemSize = NSSize(width: max(contentWidth - 8, 420), height: 108)
            flowLayout.minimumInteritemSpacing = 0
            flowLayout.minimumLineSpacing = 8
        }
        flowLayout.invalidateLayout()
    }

    private func triggerSend(for item: AnimationLibraryItem) {
        sendButton.title = "Beaming…"
        sendButton.image = makeMenuSymbol("bolt.circle.fill", description: "Beaming")
        sendButton.isEnabled = false
        detailStatusLabel.stringValue = "Beaming \(item.title)…"
        onSend(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.sendButton.title = "Beam to Ditoo"
            self.sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
            self.sendButton.isEnabled = self.currentSelectedItem != nil
        }
    }

    private func updateDetailPanel() {
        guard let item = currentSelectedItem else {
            detailPreviewView.setFileURL(nil)
            detailTitleLabel.stringValue = "Select an animation"
            detailMetaLabel.stringValue = "Choose a favorite, a cloud find, or a curated local pick to inspect it here."
            detailSourceChip.update(text: "Source", symbolName: "shippingbox")
            detailFeedChip.update(text: "Feed", symbolName: "square.stack.3d.up")
            detailCategoryChip.update(text: "Category", symbolName: "sparkles")
            detailCollectionChip.update(text: "Collection", symbolName: "folder")
            detailDuplicateChip.update(text: "Unique", symbolName: "square.on.square")
            detailPopularityChip.update(text: "Fresh pick", symbolName: "sparkles")
            detailPathLabel.stringValue = ""
            detailPathLabel.isHidden = true
            detailStatusLabel.stringValue = "Preview comes alive here once you select something from the browser."
            sendButton.isEnabled = false
            revealButton.isEnabled = false
            favoriteButton.isEnabled = false
            favoriteButton.title = "Favorite"
            cloudLikeButton.isHidden = true
            cloudLikeButton.isEnabled = false
            return
        }

        let collectionTitle = AnimationLibraryCatalog.displayCollectionTitle(for: item.collection)
        let sourceTitle = AnimationLibraryCatalog.displaySourceTitle(for: item.source)
        let feedTitle = AnimationLibraryCatalog.displayScopeTitle(for: item.scope)
        detailPreviewView.setFileURL(item.fileURL)
        detailTitleLabel.stringValue = item.title
        detailMetaLabel.stringValue = item.source == "divoom-cloud"
            ? "Cloud animation from \(collectionTitle), ready to beam now or save back into your Divoom likes."
            : "Local animation from \(collectionTitle), ready for instant beam or Finder reveal."
        detailSourceChip.update(text: sourceTitle, symbolName: item.source == "divoom-cloud" ? "icloud" : "shippingbox")
        detailFeedChip.update(text: feedTitle, symbolName: "square.stack.3d.up")
        detailCategoryChip.update(text: AnimationLibraryCatalog.displayTitle(for: item.category), symbolName: animationCategorySymbolName(item.category))
        detailCollectionChip.update(text: collectionTitle, symbolName: item.collection == "root" ? "shippingbox" : "folder")
        detailDuplicateChip.update(text: item.duplicateCount > 1 ? "\(item.duplicateCount) dupes" : "Unique", symbolName: "square.on.square")
        if item.likes > 0 || item.views > 0 {
            detailPopularityChip.update(
                text: item.likes > 0 ? "\(item.likes) likes · \(item.views) views" : "\(item.views) views",
                symbolName: item.likes > 0 ? "heart.fill" : "eye"
            )
        } else {
            detailPopularityChip.update(text: "Fresh pick", symbolName: "sparkles")
        }
        detailPathLabel.stringValue = item.relativePath
        detailPathLabel.isHidden = item.relativePath.isEmpty
        detailStatusLabel.stringValue = item.source == "divoom-cloud"
            ? "Beam it now, or push the like back into Divoom Cloud."
            : "Beam it now, reveal the source file, or save it into starred picks."
        sendButton.isEnabled = true
        sendButton.title = "Beam to Ditoo"
        sendButton.image = makeMenuSymbol("paperplane.circle.fill", description: "Beam to Ditoo")
        revealButton.isEnabled = true
        favoriteButton.isEnabled = true
        favoriteButton.title = favorites.contains(item.id) ? "Unfavorite" : "Favorite"
        favoriteButton.image = makeMenuSymbol(favorites.contains(item.id) ? "star.fill" : "star", description: "Favorite")
        let cloudLikeAvailable = item.source == "divoom-cloud" && item.galleryID > 0
        cloudLikeButton.isHidden = !cloudLikeAvailable
        cloudLikeButton.isEnabled = cloudLikeAvailable
        cloudLikeButton.title = item.isLiked ? "Unlike in Cloud" : "Like in Cloud"
        cloudLikeButton.image = makeMenuSymbol(item.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup", description: "Like in Cloud")
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
        let sourceCount = Set(allItems.map(\.source)).count
        let visibleCollections = Set(filteredItems.map(\.collection)).count
        assetChip.update(text: filteredItems.count == 1 ? "1 match" : "\(filteredItems.count) matches", symbolName: filteredItems.isEmpty ? "square.grid.3x3" : "sparkles")
        categoryChip.update(text: "\(Set(filteredItems.map(\.category)).count) topics · \(visibleCollections) sets")
        sourceChip.update(text: "\(sourceCount) source\(sourceCount == 1 ? "" : "s")", symbolName: sourceCount > 1 ? "shippingbox.circle" : "shippingbox")
        favoriteChip.update(text: "\(favorites.count) starred", symbolName: favorites.isEmpty ? "star" : "star.fill")
    }

    private func updateCloudLikeState(for itemID: String, isLiked: Bool) {
        let delta = isLiked ? 1 : -1
        allItems = allItems.map { item in
            guard item.id == itemID else { return item }
            return AnimationLibraryItem(
                id: item.id,
                source: item.source,
                scope: item.scope,
                sort: item.sort,
                title: item.title,
                category: item.category,
                cloudClassify: item.cloudClassify,
                collection: item.collection,
                relativePath: item.relativePath,
                fileURL: item.fileURL,
                searchText: item.searchText,
                duplicateCount: item.duplicateCount,
                likes: max(item.likes + delta, 0),
                views: item.views,
                galleryID: item.galleryID,
                fileType: item.fileType,
                clockID: item.clockID,
                itemID: item.itemID,
                userID: item.userID,
                date: item.date,
                isLiked: isLiked
            )
        }
        applyFilters()
    }
}

private enum AppSettingsTab: Int, CaseIterable {
    case general = 0
    case live = 1
    case library = 2
    case about = 3

    var title: String {
        switch self {
        case .general:
            return "General"
        case .live:
            return "Live"
        case .library:
            return "Cloud"
        case .about:
            return "About"
        }
    }
}

private func resolvedCloudCredentialUIState() -> DivoomCloudCredentialUIState {
    if let localEmailHint = DivoomCloudCredentialResolver.passiveLocalCredentialHint() {
        return DivoomCloudCredentialUIState(
            email: localEmailHint,
            passwordPlaceholder: "Saved in this app Keychain",
            status: "A local Divoom cloud login is saved in this app Keychain and is ready for sync, search, likes, and playlists.",
            canImportSyncedCredentials: true,
            usesLocalKeychain: true,
            usesSyncedPasswords: false
        )
    }

    return DivoomCloudCredentialUIState(
        email: "",
        passwordPlaceholder: "Enter Divoom password",
        status: "Save the Divoom login here. If the same account already exists in Passwords, use Import from Passwords once to copy it into this app Keychain.",
        canImportSyncedCredentials: true,
        usesLocalKeychain: false,
        usesSyncedPasswords: false
    )
}

private struct AppSettingsSnapshot {
    let launchAtLoginEnabled: Bool
    let favoritesPlayback: FavoritesPlaybackOption
    let showUsed: Bool
    let codexMetric: CodexBarMetricPreference
    let claudeMetric: CodexBarMetricPreference
    let cloudCredentialEmail: String
    let cloudCredentialPasswordPlaceholder: String
    let cloudCredentialStatus: String
    let canImportSyncedCloudCredentials: Bool
    let cloudLibraryEnabled: Bool
    let cloudSyncOnLaunchEnabled: Bool
    let cloudAutoSyncEnabled: Bool
    let cloudManifestSummary: String
    let version: String
    let build: String
    let gitCommit: String
}

private struct DivoomCloudCredentialUIState {
    let email: String
    let passwordPlaceholder: String
    let status: String
    let canImportSyncedCredentials: Bool
    let usesLocalKeychain: Bool
    let usesSyncedPasswords: Bool
}

@MainActor
private final class AppSettingsWindowController: NSWindowController {
    private let snapshotProvider: () -> AppSettingsSnapshot
    private let onToggleLaunchAtLogin: (Bool) -> Void
    private let onSetFavoritesPlayback: (FavoritesPlaybackOption) -> Void
    private let onSetShowUsed: (Bool) -> Void
    private let onSetCodexMetric: (CodexBarMetricPreference) -> Void
    private let onSetClaudeMetric: (CodexBarMetricPreference) -> Void
    private let onSaveCloudCredentials: (String, String) -> Void
    private let onImportSyncedCloudCredentials: () -> Void
    private let onClearCloudCredentials: () -> Void
    private let onSetCloudLibraryEnabled: (Bool) -> Void
    private let onSetCloudSyncOnLaunchEnabled: (Bool) -> Void
    private let onSetCloudAutoSyncEnabled: (Bool) -> Void
    private let onSyncCloudNow: () -> Void
    private let onRevealCloudFolder: () -> Void
    private let onOpenCloudGuide: () -> Void
    private let onOpenGitHub: () -> Void
    private let onOpenReleases: () -> Void
    private let onOpenLogs: () -> Void

    private let tabView = NSTabView()
    private let settingsHeaderCard = NSVisualEffectView()
    private let settingsTitleLabel = NSTextField(labelWithString: "Divoom Ditoo Pro Mac")
    private let settingsSubtitleLabel = NSTextField(labelWithString: "Tune the desktop shell, live feeds, and cloud-backed library from one native control deck.")
    private let tabPicker = NSSegmentedControl(
        labels: AppSettingsTab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let favoritesPlaybackPopUp = NSPopUpButton()
    private let usageModePopUp = NSPopUpButton()
    private let codexMetricPopUp = NSPopUpButton()
    private let claudeMetricPopUp = NSPopUpButton()
    private let cloudEmailField = NSTextField()
    private let cloudPasswordField = NSSecureTextField()
    private let cloudLibraryButton = NSButton(checkboxWithTitle: "Include Divoom Cloud source in the native library", target: nil, action: nil)
    private let cloudSyncOnLaunchButton = NSButton(checkboxWithTitle: "Sync Divoom Cloud on app launch", target: nil, action: nil)
    private let cloudAutoSyncButton = NSButton(checkboxWithTitle: "Auto-sync Divoom Cloud every 6 hours", target: nil, action: nil)
    private let cloudCredentialStatusLabel = NSTextField(labelWithString: "")
    private let cloudSummaryLabel = NSTextField(labelWithString: "")
    private let importSyncedCloudButton = NSButton(title: "Import from Passwords", target: nil, action: nil)
    private let versionLabel = NSTextField(labelWithString: "")
    private let buildLabel = NSTextField(labelWithString: "")
    private let commitLabel = NSTextField(labelWithString: "")

    init(
        snapshotProvider: @escaping () -> AppSettingsSnapshot,
        onToggleLaunchAtLogin: @escaping (Bool) -> Void,
        onSetFavoritesPlayback: @escaping (FavoritesPlaybackOption) -> Void,
        onSetShowUsed: @escaping (Bool) -> Void,
        onSetCodexMetric: @escaping (CodexBarMetricPreference) -> Void,
        onSetClaudeMetric: @escaping (CodexBarMetricPreference) -> Void,
        onSaveCloudCredentials: @escaping (String, String) -> Void,
        onImportSyncedCloudCredentials: @escaping () -> Void,
        onClearCloudCredentials: @escaping () -> Void,
        onSetCloudLibraryEnabled: @escaping (Bool) -> Void,
        onSetCloudSyncOnLaunchEnabled: @escaping (Bool) -> Void,
        onSetCloudAutoSyncEnabled: @escaping (Bool) -> Void,
        onSyncCloudNow: @escaping () -> Void,
        onRevealCloudFolder: @escaping () -> Void,
        onOpenCloudGuide: @escaping () -> Void,
        onOpenGitHub: @escaping () -> Void,
        onOpenReleases: @escaping () -> Void,
        onOpenLogs: @escaping () -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onSetFavoritesPlayback = onSetFavoritesPlayback
        self.onSetShowUsed = onSetShowUsed
        self.onSetCodexMetric = onSetCodexMetric
        self.onSetClaudeMetric = onSetClaudeMetric
        self.onSaveCloudCredentials = onSaveCloudCredentials
        self.onImportSyncedCloudCredentials = onImportSyncedCloudCredentials
        self.onClearCloudCredentials = onClearCloudCredentials
        self.onSetCloudLibraryEnabled = onSetCloudLibraryEnabled
        self.onSetCloudSyncOnLaunchEnabled = onSetCloudSyncOnLaunchEnabled
        self.onSetCloudAutoSyncEnabled = onSetCloudAutoSyncEnabled
        self.onSyncCloudNow = onSyncCloudNow
        self.onRevealCloudFolder = onRevealCloudFolder
        self.onOpenCloudGuide = onOpenCloudGuide
        self.onOpenGitHub = onOpenGitHub
        self.onOpenReleases = onOpenReleases
        self.onOpenLogs = onOpenLogs

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 648, height: 536),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 648, height: 536)

        super.init(window: window)
        buildUI(in: window)
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings(tab: AppSettingsTab = .general) {
        select(tab: tab)
        refresh()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        let snapshot = snapshotProvider()
        if let selectedItem = tabView.selectedTabViewItem ?? tabView.tabViewItems.first {
            let selectedIndex = tabView.indexOfTabViewItem(selectedItem)
            tabPicker.selectedSegment = selectedIndex == NSNotFound ? AppSettingsTab.general.rawValue : selectedIndex
        } else {
            tabPicker.selectedSegment = AppSettingsTab.general.rawValue
        }
        launchAtLoginButton.state = snapshot.launchAtLoginEnabled ? .on : .off

        usageModePopUp.selectItem(at: snapshot.showUsed ? 0 : 1)

        favoritesPlaybackPopUp.removeAllItems()
        FavoritesPlaybackOption.allCases.forEach { favoritesPlaybackPopUp.addItem(withTitle: $0.title) }
        favoritesPlaybackPopUp.selectItem(at: FavoritesPlaybackOption.allCases.firstIndex(of: snapshot.favoritesPlayback) ?? 0)

        codexMetricPopUp.removeAllItems()
        CodexBarMetricPreference.allCases.forEach { codexMetricPopUp.addItem(withTitle: $0.title) }
        codexMetricPopUp.selectItem(at: CodexBarMetricPreference.allCases.firstIndex(of: snapshot.codexMetric) ?? 0)

        claudeMetricPopUp.removeAllItems()
        CodexBarMetricPreference.allCases.forEach { claudeMetricPopUp.addItem(withTitle: $0.title) }
        claudeMetricPopUp.selectItem(at: CodexBarMetricPreference.allCases.firstIndex(of: snapshot.claudeMetric) ?? 0)

        cloudEmailField.stringValue = snapshot.cloudCredentialEmail
        cloudPasswordField.stringValue = ""
        cloudPasswordField.placeholderString = snapshot.cloudCredentialPasswordPlaceholder
        cloudCredentialStatusLabel.stringValue = snapshot.cloudCredentialStatus
        importSyncedCloudButton.isEnabled = snapshot.canImportSyncedCloudCredentials

        cloudLibraryButton.state = snapshot.cloudLibraryEnabled ? .on : .off
        cloudSyncOnLaunchButton.state = snapshot.cloudSyncOnLaunchEnabled ? .on : .off
        cloudAutoSyncButton.state = snapshot.cloudAutoSyncEnabled ? .on : .off
        cloudSummaryLabel.stringValue = snapshot.cloudManifestSummary

        versionLabel.stringValue = "Version \(snapshot.version)"
        buildLabel.stringValue = "Build \(snapshot.build)"
        commitLabel.stringValue = snapshot.gitCommit.isEmpty ? "Git commit unknown" : "Git commit \(snapshot.gitCommit)"
    }

    private func buildUI(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let rootView = NSVisualEffectView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.material = .underWindowBackground
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        contentView.addSubview(rootView)

        settingsHeaderCard.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderCard.material = .menu
        settingsHeaderCard.blendingMode = .withinWindow
        settingsHeaderCard.state = .active
        settingsHeaderCard.wantsLayer = true
        settingsHeaderCard.layer?.cornerRadius = 24
        settingsHeaderCard.layer?.cornerCurve = .continuous
        settingsHeaderCard.layer?.borderWidth = 1
        settingsHeaderCard.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        settingsHeaderCard.layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        settingsHeaderCard.layer?.shadowOpacity = 1
        settingsHeaderCard.layer?.shadowRadius = 16
        settingsHeaderCard.layer?.shadowOffset = NSSize(width: 0, height: -4)
        rootView.addSubview(settingsHeaderCard)

        settingsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        settingsTitleLabel.textColor = .labelColor

        settingsSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        settingsSubtitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        settingsSubtitleLabel.textColor = .secondaryLabelColor
        settingsSubtitleLabel.maximumNumberOfLines = 2
        settingsSubtitleLabel.lineBreakMode = .byWordWrapping

        tabPicker.translatesAutoresizingMaskIntoConstraints = false
        tabPicker.segmentStyle = .rounded
        tabPicker.controlSize = .large
        tabPicker.target = self
        tabPicker.action = #selector(changeSelectedTab)
        tabPicker.selectedSegment = AppSettingsTab.general.rawValue
        tabPicker.setContentCompressionResistancePriority(.required, for: .vertical)

        let headerStack = NSStackView(views: [settingsTitleLabel, settingsSubtitleLabel, tabPicker])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        settingsHeaderCard.addSubview(headerStack)

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder
        rootView.addSubview(tabView)

        let generalItem = NSTabViewItem(identifier: AppSettingsTab.general.rawValue)
        generalItem.label = AppSettingsTab.general.title
        generalItem.view = buildGeneralPane()
        tabView.addTabViewItem(generalItem)

        let liveItem = NSTabViewItem(identifier: AppSettingsTab.live.rawValue)
        liveItem.label = AppSettingsTab.live.title
        liveItem.view = buildLivePane()
        tabView.addTabViewItem(liveItem)

        let libraryItem = NSTabViewItem(identifier: AppSettingsTab.library.rawValue)
        libraryItem.label = AppSettingsTab.library.title
        libraryItem.view = buildLibraryPane()
        tabView.addTabViewItem(libraryItem)

        let aboutItem = NSTabViewItem(identifier: AppSettingsTab.about.rawValue)
        aboutItem.label = AppSettingsTab.about.title
        aboutItem.view = buildAboutPane()
        tabView.addTabViewItem(aboutItem)

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            settingsHeaderCard.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            settingsHeaderCard.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            settingsHeaderCard.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: 14),

            headerStack.leadingAnchor.constraint(equalTo: settingsHeaderCard.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: settingsHeaderCard.trailingAnchor, constant: -20),
            headerStack.topAnchor.constraint(equalTo: settingsHeaderCard.topAnchor, constant: 18),
            headerStack.bottomAnchor.constraint(equalTo: settingsHeaderCard.bottomAnchor, constant: -18),

            tabView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            tabView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            tabView.topAnchor.constraint(equalTo: settingsHeaderCard.bottomAnchor, constant: 14),
            tabView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
        ])
    }

    private func buildGeneralPane() -> NSView {
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)

        let card = makeSectionCard(
            title: "App Behavior",
            subtitle: "Normal desktop-app settings, not buried in the menu."
        )

        let launchHint = makeBodyLabel("Start the Ditoo menu bar app automatically when you log in. This works best once the app is installed in Applications.")

        let buttonRow = NSStackView(views: [
            makeActionButton(title: "GitHub", symbolName: "chevron.left.forwardslash.chevron.right", action: #selector(openGitHub)),
            makeActionButton(title: "Releases", symbolName: "arrow.down.circle", action: #selector(openReleases)),
            makeActionButton(title: "Logs", symbolName: "doc.text.magnifyingglass", action: #selector(openLogs)),
        ])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.distribution = .fillEqually

        let stack = NSStackView(views: [launchAtLoginButton, launchHint, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        return wrapPane(cards: [card])
    }

    private func buildLivePane() -> NSView {
        usageModePopUp.target = self
        usageModePopUp.action = #selector(changeUsageMode)
        usageModePopUp.addItems(withTitles: ["Show Used", "Show Remaining"])

        favoritesPlaybackPopUp.target = self
        favoritesPlaybackPopUp.action = #selector(changeFavoritesPlayback)

        codexMetricPopUp.target = self
        codexMetricPopUp.action = #selector(changeCodexMetric)

        claudeMetricPopUp.target = self
        claudeMetricPopUp.action = #selector(changeClaudeMetric)

        let syncCard = makeSectionCard(
            title: "CodexBar Sync",
            subtitle: "The Ditoo feed follows the same metric and mode settings as CodexBar."
        )
        let syncGrid = makeSettingsGrid(rows: [
            ("Usage Mode", usageModePopUp),
            ("Codex Metric", codexMetricPopUp),
            ("Claude Metric", claudeMetricPopUp),
            ("Favorites Playback", favoritesPlaybackPopUp),
        ])
        syncCard.addSubview(syncGrid)
        NSLayoutConstraint.activate([
            syncGrid.leadingAnchor.constraint(equalTo: syncCard.leadingAnchor, constant: 18),
            syncGrid.trailingAnchor.constraint(equalTo: syncCard.trailingAnchor, constant: -18),
            syncGrid.topAnchor.constraint(equalTo: syncCard.topAnchor, constant: 52),
            syncGrid.bottomAnchor.constraint(equalTo: syncCard.bottomAnchor, constant: -18),
        ])

        return wrapPane(cards: [syncCard])
    }

    private func buildLibraryPane() -> NSView {
        cloudEmailField.translatesAutoresizingMaskIntoConstraints = false
        cloudEmailField.placeholderString = "Enter your Divoom email"

        cloudPasswordField.translatesAutoresizingMaskIntoConstraints = false
        cloudPasswordField.placeholderString = "Enter Divoom password"

        cloudCredentialStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudCredentialStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cloudCredentialStatusLabel.textColor = .secondaryLabelColor
        cloudCredentialStatusLabel.maximumNumberOfLines = 0
        cloudCredentialStatusLabel.lineBreakMode = .byWordWrapping

        let credentialsCard = makeSectionCard(
            title: "Cloud Credentials",
            subtitle: "Store Divoom cloud login safely in Keychain, or reuse the synced Passwords entry for divoom-gz.com."
        )

        let credentialsGrid = makeSettingsGrid(rows: [
            ("Email", cloudEmailField),
            ("Password", cloudPasswordField),
        ])
        credentialsCard.addSubview(credentialsGrid)

        let credentialsButtons = NSStackView(views: [
            makeActionButton(title: "Save Credentials", symbolName: "lock.shield", action: #selector(saveCloudCredentials)),
            importSyncedCloudButton,
            makeActionButton(title: "Clear Saved", symbolName: "trash", action: #selector(clearCloudCredentials)),
        ])
        importSyncedCloudButton.translatesAutoresizingMaskIntoConstraints = false
        importSyncedCloudButton.target = self
        importSyncedCloudButton.action = #selector(importSyncedCloudCredentials)
        importSyncedCloudButton.bezelStyle = .rounded
        importSyncedCloudButton.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: "Import from Passwords")
        importSyncedCloudButton.imagePosition = .imageLeading
        credentialsButtons.orientation = .horizontal
        credentialsButtons.alignment = .centerY
        credentialsButtons.spacing = 10
        credentialsButtons.distribution = .fillEqually
        credentialsButtons.translatesAutoresizingMaskIntoConstraints = false
        credentialsCard.addSubview(credentialsButtons)
        credentialsCard.addSubview(cloudCredentialStatusLabel)

        NSLayoutConstraint.activate([
            credentialsGrid.leadingAnchor.constraint(equalTo: credentialsCard.leadingAnchor, constant: 18),
            credentialsGrid.trailingAnchor.constraint(equalTo: credentialsCard.trailingAnchor, constant: -18),
            credentialsGrid.topAnchor.constraint(equalTo: credentialsCard.topAnchor, constant: 52),

            credentialsButtons.leadingAnchor.constraint(equalTo: credentialsCard.leadingAnchor, constant: 18),
            credentialsButtons.trailingAnchor.constraint(equalTo: credentialsCard.trailingAnchor, constant: -18),
            credentialsButtons.topAnchor.constraint(equalTo: credentialsGrid.bottomAnchor, constant: 14),

            cloudCredentialStatusLabel.leadingAnchor.constraint(equalTo: credentialsCard.leadingAnchor, constant: 18),
            cloudCredentialStatusLabel.trailingAnchor.constraint(equalTo: credentialsCard.trailingAnchor, constant: -18),
            cloudCredentialStatusLabel.topAnchor.constraint(equalTo: credentialsButtons.bottomAnchor, constant: 12),
            cloudCredentialStatusLabel.bottomAnchor.constraint(equalTo: credentialsCard.bottomAnchor, constant: -18),
        ])

        cloudLibraryButton.target = self
        cloudLibraryButton.action = #selector(toggleCloudLibrary)

        cloudSyncOnLaunchButton.target = self
        cloudSyncOnLaunchButton.action = #selector(toggleCloudSyncOnLaunch)

        cloudAutoSyncButton.target = self
        cloudAutoSyncButton.action = #selector(toggleCloudAutoSync)

        cloudSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        cloudSummaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        cloudSummaryLabel.textColor = .secondaryLabelColor
        cloudSummaryLabel.maximumNumberOfLines = 0
        cloudSummaryLabel.lineBreakMode = .byWordWrapping

        let syncButtons = NSStackView(views: [
            makeActionButton(title: "Sync Now", symbolName: "arrow.triangle.2.circlepath", action: #selector(syncCloudNow)),
            makeActionButton(title: "Reveal Folder", symbolName: "folder", action: #selector(revealCloudFolder)),
            makeActionButton(title: "Guide", symbolName: "book", action: #selector(openCloudGuide)),
        ])
        syncButtons.orientation = .horizontal
        syncButtons.alignment = .centerY
        syncButtons.spacing = 10
        syncButtons.distribution = .fillEqually

        let card = makeSectionCard(
            title: "Divoom Cloud Library",
            subtitle: "Control the native cloud-backed source, sync cadence, and library visibility from the app."
        )

        let stack = NSStackView(views: [cloudLibraryButton, cloudSyncOnLaunchButton, cloudAutoSyncButton, cloudSummaryLabel, syncButtons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        return wrapPane(cards: [credentialsCard, card])
    }

    private func buildAboutPane() -> NSView {
        let card = makeSectionCard(
            title: "Divoom Ditoo Pro Mac",
            subtitle: "Native menu bar control for the Ditoo Pro 16x16 RGB display."
        )

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApplication.shared.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        buildLabel.translatesAutoresizingMaskIntoConstraints = false
        buildLabel.font = .systemFont(ofSize: 12, weight: .medium)
        buildLabel.textColor = .secondaryLabelColor

        commitLabel.translatesAutoresizingMaskIntoConstraints = false
        commitLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commitLabel.textColor = .secondaryLabelColor

        let creditLabel = makeBodyLabel("Built by @kirniy. Reverse engineering notes, native BLE control, CLI, menu bar app, and animation tooling all live in the public repo.")

        let linkRow = NSStackView(views: [
            makeActionButton(title: "GitHub Repo", symbolName: "chevron.left.forwardslash.chevron.right", action: #selector(openGitHub)),
            makeActionButton(title: "Releases", symbolName: "shippingbox", action: #selector(openReleases)),
            makeActionButton(title: "Open Logs", symbolName: "doc.plaintext", action: #selector(openLogs)),
        ])
        linkRow.orientation = .horizontal
        linkRow.alignment = .centerY
        linkRow.spacing = 10
        linkRow.distribution = .fillEqually

        let stack = NSStackView(views: [iconView, versionLabel, buildLabel, commitLabel, creditLabel, linkRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 88),
            iconView.heightAnchor.constraint(equalToConstant: 88),

            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        return wrapPane(cards: [card])
    }

    private func wrapPane(cards: [NSView]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeSectionCard(title: String, subtitle: String) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .menu
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.24).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        card.addSubview(titleLabel)
        card.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])

        return card
    }

    private func makeSettingsGrid(rows: [(String, NSView)]) -> NSGridView {
        let gridRows = rows.map { row -> [NSView] in
            let label = NSTextField(labelWithString: row.0)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            return [label, row.1]
        }
        let grid = NSGridView(views: gridRows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 18
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        return grid
    }

    private func makeActionButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    private func makeBodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func select(tab: AppSettingsTab) {
        tabView.selectTabViewItem(at: tab.rawValue)
        tabPicker.selectedSegment = tab.rawValue
    }

    @objc private func changeSelectedTab() {
        guard let tab = AppSettingsTab(rawValue: tabPicker.selectedSegment) else {
            return
        }
        select(tab: tab)
    }

    @objc private func toggleLaunchAtLogin() {
        onToggleLaunchAtLogin(launchAtLoginButton.state == .on)
        refresh()
    }

    @objc private func changeUsageMode() {
        onSetShowUsed(usageModePopUp.indexOfSelectedItem == 0)
        refresh()
    }

    @objc private func changeFavoritesPlayback() {
        let options = FavoritesPlaybackOption.allCases
        guard favoritesPlaybackPopUp.indexOfSelectedItem >= 0, favoritesPlaybackPopUp.indexOfSelectedItem < options.count else {
            return
        }
        onSetFavoritesPlayback(options[favoritesPlaybackPopUp.indexOfSelectedItem])
        refresh()
    }

    @objc private func changeCodexMetric() {
        let options = CodexBarMetricPreference.allCases
        guard codexMetricPopUp.indexOfSelectedItem >= 0, codexMetricPopUp.indexOfSelectedItem < options.count else {
            return
        }
        onSetCodexMetric(options[codexMetricPopUp.indexOfSelectedItem])
        refresh()
    }

    @objc private func changeClaudeMetric() {
        let options = CodexBarMetricPreference.allCases
        guard claudeMetricPopUp.indexOfSelectedItem >= 0, claudeMetricPopUp.indexOfSelectedItem < options.count else {
            return
        }
        onSetClaudeMetric(options[claudeMetricPopUp.indexOfSelectedItem])
        refresh()
    }

    @objc private func toggleCloudLibrary() {
        onSetCloudLibraryEnabled(cloudLibraryButton.state == .on)
        refresh()
    }

    @objc private func saveCloudCredentials() {
        onSaveCloudCredentials(
            cloudEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            cloudPasswordField.stringValue
        )
        refresh()
    }

    @objc private func importSyncedCloudCredentials() {
        onImportSyncedCloudCredentials()
        refresh()
    }

    @objc private func clearCloudCredentials() {
        onClearCloudCredentials()
        refresh()
    }

    @objc private func toggleCloudSyncOnLaunch() {
        onSetCloudSyncOnLaunchEnabled(cloudSyncOnLaunchButton.state == .on)
        refresh()
    }

    @objc private func toggleCloudAutoSync() {
        onSetCloudAutoSyncEnabled(cloudAutoSyncButton.state == .on)
        refresh()
    }

    @objc private func openGitHub() {
        onOpenGitHub()
    }

    @objc private func openReleases() {
        onOpenReleases()
    }

    @objc private func openLogs() {
        onOpenLogs()
    }

    @objc private func syncCloudNow() {
        onSyncCloudNow()
    }

    @objc private func revealCloudFolder() {
        onRevealCloudFolder()
    }

    @objc private func openCloudGuide() {
        onOpenCloudGuide()
    }
}

@MainActor
private protocol CommandRunnerDelegate: AnyObject {
    func commandDidFinish(spec: CommandSpec, success: Bool, output: String)
}

private final class CommandRunner {
    private let executableURL = divoomRepoURL("bin/divoom-display")
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
    private let curatedAnimationsURL = divoomRepoURL("assets/16x16/curated", isDirectory: true)
    private let recentAnimationDefaultsKey = "dev.kirniy.divoom.recent-library-animations"
    private let favoriteRotationIndexDefaultsKey = "dev.kirniy.divoom.favorite-rotation-index"
    private let favoritePlaybackLoopsDefaultsKey = "dev.kirniy.divoom.favorite-playback-loops"
    private let summaryCard = MenuSummaryView(frame: NSRect(x: 0, y: 0, width: rootMenuSurfaceWidth, height: summaryCardHeight))
    private let summaryCardItem = NSMenuItem()
    private let quickActionHub = QuickActionHubView(frame: NSRect(x: 0, y: 0, width: rootMenuSurfaceWidth, height: quickHubHeight))
    private let quickActionHubItem = NSMenuItem()
    private let colorStudioView = ColorStudioView(frame: NSRect(x: 0, y: 0, width: studioMenuSurfaceWidth, height: colorStudioHeight))
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
    private var favoritesPlaybackItems: [FavoritesPlaybackOption: NSMenuItem] = [:]
    private var codexMetricItems: [CodexBarMetricPreference: NSMenuItem] = [:]
    private var claudeMetricItems: [CodexBarMetricPreference: NSMenuItem] = [:]
    private var timer: Timer?
    private var cloudSyncTimer: Timer?
    private var favoritesRotationTimer: Timer?
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
    private var cachedFavoriteCount = 0
    private var cachedCloudItemCount = 0
    private var animationLibraryController: AnimationLibraryWindowController?
    private var settingsController: AppSettingsWindowController?
    private var recentAnimationRelativePaths = UserDefaults.standard.stringArray(forKey: "dev.kirniy.divoom.recent-library-animations") ?? []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.write("applicationDidFinishLaunching begin")
        runner.delegate = self
        bluetoothDiagnostics.statusHandler = { [weak self] summary, details in
            self?.updateConnectionStatus(summary: summary, details: details)
        }
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        configureStatusItem()
        configureIPC()
        configureCloudSyncBehavior()
        refreshSummaryMetadataAsync()
        AppLog.write("applicationDidFinishLaunching ready")
        bluetoothDiagnostics.requestAccessAndScan()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        cloudSyncTimer?.invalidate()
        ipcTimer?.invalidate()
        ipcTimer = nil
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
        quickActionHub.onScreenPick = { [weak self] in self?.pickScreenColorForStudio() }
        menu.addItem(quickActionHubItem)
        menu.addItem(.separator())

        let studioMenu = NSMenu(title: "Studio")
        let colorStudioItem = NSMenuItem()
        colorStudioItem.isEnabled = false
        colorStudioItem.view = colorStudioView
        colorStudioView.onSendColor = { [weak self] color in
            self?.sendSelectedSceneColor(color, source: "Color studio")
        }
        colorStudioView.onSendAmbientColor = { [weak self] color in
            self?.sendSelectedAmbientColor(color, source: "Color studio")
        }
        colorStudioView.onSendMotion = { [weak self] colors, mode in
            self?.sendColorMotion(colors, mode: mode)
        }
        colorStudioView.onPickScreen = { [weak self] in
            self?.pickScreenColorForStudio()
        }
        studioMenu.addItem(colorStudioItem)
        studioMenu.addItem(.separator())
        studioMenu.addItem(makeSectionHeader("Instant"))
        studioMenu.addItem(makeItem("Solid Red", action: #selector(runNativeSolidRed), symbolName: "lightspectrum.horizontal"))
        studioMenu.addItem(makeItem("Ambient Red", action: #selector(runNativePurityRed), symbolName: "lightbulb.max.fill"))
        studioMenu.addItem(makeItem("Pixel Badge Test", action: #selector(runNativePixelTest), symbolName: "square.grid.3x3.fill"))
        studioMenu.addItem(.separator())
        studioMenu.addItem(makeSectionHeader("Motion Loops"))
        studioMenu.addItem(makeItem("Signal Sweep Loop", action: #selector(runNativeAnimationSample), symbolName: "sparkles"))
        studioMenu.addItem(makeItem("Doom Fire Loop", action: #selector(runNativeUploadDoomFire), symbolName: "flame.fill"))
        studioMenu.addItem(makeItem("Nyan Cat", action: #selector(runNativeUploadNyan), symbolName: "star"))
        studioMenu.addItem(makeItem("Bunny Hop", action: #selector(runNativeUploadBunny), symbolName: "hare"))
        studioMenu.addItem(makeRecentAnimationsMenuItem())

        let libraryMenu = NSMenu(title: "Library")
        libraryMenu.addItem(makeSectionHeader("Browse"))
        libraryMenu.addItem(makeItem("Open Animation Library", action: #selector(openAnimationLibrary), symbolName: "photo.stack"))
        libraryMenu.addItem(makeItem("Manage Cloud Login…", action: #selector(openLibrarySettings), symbolName: "key.horizontal"))
        libraryMenu.addItem(makeItem("Reveal Curated Folder", action: #selector(revealCuratedAnimations), symbolName: "folder"))
        libraryMenu.addItem(.separator())
        libraryMenu.addItem(makeSectionHeader("Divoom Cloud"))
        libraryMenu.addItem(makeItem("Sync Cloud Library", action: #selector(syncDivoomCloudLibrary), symbolName: "arrow.triangle.2.circlepath"))
        libraryMenu.addItem(makeItem("Reveal Divoom Cloud Folder", action: #selector(revealDivoomCloudFolder), symbolName: "shippingbox"))
        libraryMenu.addItem(makeItem("Open Cloud Guide", action: #selector(openDivoomCloudGuide), symbolName: "book"))

        let liveMenu = NSMenu(title: "Now")
        liveMenu.addItem(makeSectionHeader("Live Now"))
        autoCodexItem = makeItem("Codex Live", action: #selector(toggleAutoCodex), symbolName: "brain")
        autoClaudeItem = makeItem("Claude Live", action: #selector(toggleAutoClaude), symbolName: "message")
        autoPairItem = makeItem("Split Live", action: #selector(toggleAutoPair), symbolName: "rectangle.split.2x1")
        autoIPFlagItem = makeItem("IP Flag", action: #selector(toggleAutoIPFlag), symbolName: "flag.2.crossed")
        autoFavoritesItem = makeItem("Rotate Favorites", action: #selector(toggleAutoFavorites), symbolName: "arrow.triangle.2.circlepath")
        liveMenu.addItem(autoCodexItem)
        liveMenu.addItem(autoClaudeItem)
        liveMenu.addItem(autoPairItem)
        liveMenu.addItem(autoIPFlagItem)
        liveMenu.addItem(autoFavoritesItem)
        liveMenu.addItem(.separator())
        liveMenu.addItem(makeItem("Open Live Settings…", action: #selector(openLiveSettings), symbolName: "slider.horizontal.3"))

        let deviceMenu = NSMenu(title: "Device")
        deviceMenu.addItem(makeSectionHeader("Connection"))
        deviceMenu.addItem(makeItem("Request Bluetooth Access", action: #selector(requestBluetoothAccess), symbolName: "dot.radiowaves.left.and.right"))
        deviceMenu.addItem(makeItem("Reconnect Light Link", action: #selector(reconnectLightLink), symbolName: "arrow.clockwise"))
        deviceMenu.addItem(makeItem("Run Bluetooth Diagnostics", action: #selector(runBluetoothDiagnostics), symbolName: "antenna.radiowaves.left.and.right"))
        deviceMenu.addItem(makeItem("Probe Volume", action: #selector(runNativeVolumeProbe), symbolName: "speaker.wave.2"))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(makeSectionHeader("Dashboards"))
        deviceMenu.addItem(makeItem("Battery Dashboard", action: #selector(runNativeBatteryStatus), symbolName: "battery.75"))
        deviceMenu.addItem(makeItem("System Dashboard", action: #selector(runNativeSystemStatus), symbolName: "cpu"))
        deviceMenu.addItem(makeItem("Network Dashboard", action: #selector(runNativeNetworkStatus), symbolName: "arrow.up.arrow.down.circle"))
        deviceMenu.addItem(makeItem("Animated Monitor", action: #selector(runNativeAnimatedMonitor), symbolName: "waveform.path.ecg"))
        deviceMenu.addItem(makeItem("Analog Clock", action: #selector(runNativeClockFace), symbolName: "clock"))
        deviceMenu.addItem(makeItem("Animated Clock", action: #selector(runNativeAnimatedClock), symbolName: "clock.arrow.2.circlepath"))
        deviceMenu.addItem(makeItem("Pomodoro Timer", action: #selector(runNativePomodoroTimer), symbolName: "timer"))
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(makeSectionHeader("Sounds"))
        deviceMenu.addItem(makeItem("Attention Chime", action: #selector(playAttentionSound), symbolName: "bell.badge"))
        deviceMenu.addItem(makeItem("Completion Chime", action: #selector(playCompletionSound), symbolName: "checkmark.circle"))

        let settingsMenu = NSMenu(title: "Settings")
        settingsMenu.addItem(makeSectionHeader("App"))
        settingsMenu.addItem(makeItem("Open Settings…", action: #selector(openSettings), keyEquivalent: ",", symbolName: "gearshape"))
        settingsMenu.addItem(makeItem("About Divoom Ditoo Pro Mac", action: #selector(showAboutPanel), symbolName: "info.circle"))
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(makeSectionHeader("Support & Logs"))
        settingsMenu.addItem(makeItem("Open GitHub Repo", action: #selector(openGitHubRepo), symbolName: "chevron.left.forwardslash.chevron.right"))
        settingsMenu.addItem(makeItem("Open Releases", action: #selector(openReleasesPage), symbolName: "shippingbox"))
        settingsMenu.addItem(makeItem("Open Diagnostic Log", action: #selector(openLogFile), symbolName: "doc.text.magnifyingglass"))
        settingsMenu.addItem(makeItem("Reveal Log File", action: #selector(revealLogFile), symbolName: "folder"))
        settingsMenu.addItem(makeItem("Export Logs…", action: #selector(exportLogFile), symbolName: "square.and.arrow.up"))
        menu.addItem(makeSubmenuItem("Studio", symbolName: "wand.and.stars", submenu: studioMenu))
        menu.addItem(makeSubmenuItem("Library", symbolName: "photo.stack", submenu: libraryMenu))
        menu.addItem(makeSubmenuItem("Now", symbolName: "waveform", submenu: liveMenu))
        menu.addItem(makeSubmenuItem("Device", symbolName: "dot.radiowaves.left.and.right", submenu: deviceMenu))
        menu.addItem(.separator())
        menu.addItem(makeSubmenuItem("Settings", symbolName: "gearshape", submenu: settingsMenu))
        menu.addItem(makeItem("Quit", action: #selector(quitApp), keyEquivalent: "q", symbolName: "power"))
        updateAutoRefreshUI()
        refreshSummaryCard()
    }

    private func configureIPC() {
        ensureIPCDirectories()
        cleanupStaleIPCArtifacts()
        ipcTimer?.invalidate()
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainIPCQueue()
            }
        }
        timer.tolerance = 0.12
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        ipcTimer = timer
        AppLog.write("configureIPC root=\(ipcRootURL.path)")
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
        settingsController?.refresh()
    }

    private func currentFavoritesPlaybackOption() -> FavoritesPlaybackOption {
        let storedValue = UserDefaults.standard.object(forKey: favoritePlaybackLoopsDefaultsKey) as? Int ?? FavoritesPlaybackOption.twice.rawValue
        return FavoritesPlaybackOption(rawValue: storedValue) ?? .twice
    }

    private func setFavoritesPlaybackOption(_ option: FavoritesPlaybackOption) {
        UserDefaults.standard.set(option.rawValue, forKey: favoritePlaybackLoopsDefaultsKey)
        configureMenu()
        settingsController?.refresh()
        updateActionStatus(
            summary: "Favorites playback set to \(option.title.lowercased())",
            success: true,
            details: "Rotate Favorites will now play each animation \(option.title.lowercased()) before moving on."
        )
    }

    private func currentMetricPreference(for provider: String) -> CodexBarMetricPreference {
        let rawValue = codexBarPreferences().metrics[provider] ?? "primary"
        return CodexBarMetricPreference(rawValue: rawValue) ?? .primary
    }

    private func setMetricPreference(provider: String, metric: CodexBarMetricPreference) {
        mutateCodexBarPreferences { domain in
            var metrics = (domain["menuBarMetricPreferences"] as? [String: String]) ?? [:]
            metrics[provider] = metric.rawValue
            domain["menuBarMetricPreferences"] = metrics
        }
        updateActionStatus(
            summary: "\(provider.capitalized) metric set to \(metric.rawValue)",
            success: true,
            details: "Ditoo feeds now follow CodexBar's \(provider) metric = \(metric.rawValue)."
        )
    }

    private func setCodexBarUsageMode(showUsed: Bool) {
        mutateCodexBarPreferences { domain in
            domain["usageBarsShowUsed"] = showUsed
        }
        updateActionStatus(
            summary: "CodexBar sync set to \(showUsed ? "used" : "remaining")",
            success: true,
            details: "Ditoo feeds will now follow CodexBar's \(showUsed ? "used" : "remaining") percentages."
        )
    }

    private func appVersionString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func appBuildString() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private func appGitCommit() -> String {
        Bundle.main.object(forInfoDictionaryKey: "DivoomGitCommit") as? String ?? "unknown"
    }

    private func currentSettingsSnapshot() -> AppSettingsSnapshot {
        let cloudCredentialState = currentCloudCredentialUIState()
        return AppSettingsSnapshot(
            launchAtLoginEnabled: isLaunchAtLoginEnabled(),
            favoritesPlayback: currentFavoritesPlaybackOption(),
            showUsed: codexBarPreferences().showUsed,
            codexMetric: currentMetricPreference(for: "codex"),
            claudeMetric: currentMetricPreference(for: "claude"),
            cloudCredentialEmail: cloudCredentialState.email,
            cloudCredentialPasswordPlaceholder: cloudCredentialState.passwordPlaceholder,
            cloudCredentialStatus: cloudCredentialState.status,
            canImportSyncedCloudCredentials: cloudCredentialState.canImportSyncedCredentials,
            cloudLibraryEnabled: isCloudLibraryEnabled(),
            cloudSyncOnLaunchEnabled: isCloudSyncOnLaunchEnabled(),
            cloudAutoSyncEnabled: isCloudAutoSyncEnabled(),
            cloudManifestSummary: currentCloudManifestSummary(),
            version: appVersionString(),
            build: appBuildString(),
            gitCommit: appGitCommit()
        )
    }

    private func isCloudLibraryEnabled() -> Bool {
        UserDefaults.standard.object(forKey: cloudLibraryEnabledDefaultsKey) as? Bool ?? true
    }

    private func isCloudSyncOnLaunchEnabled() -> Bool {
        UserDefaults.standard.object(forKey: cloudSyncOnLaunchDefaultsKey) as? Bool ?? false
    }

    private func isCloudAutoSyncEnabled() -> Bool {
        UserDefaults.standard.object(forKey: cloudAutoSyncEnabledDefaultsKey) as? Bool ?? false
    }

    private func currentCloudCredentialUIState() -> DivoomCloudCredentialUIState {
        resolvedCloudCredentialUIState()
    }

    private func loadCurrentCloudManifest() -> DivoomCloudManifest? {
        guard let data = try? Data(contentsOf: cloudManifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(DivoomCloudManifest.self, from: data)
    }

    private func currentCloudManifestSummary() -> String {
        guard let manifest = loadCurrentCloudManifest() else {
            return "No synced Divoom cloud manifest yet. Use Sync Now after saving credentials in Settings or importing them from Passwords."
        }

        let generatedAt = ISO8601DateFormatter().date(from: manifest.generatedAt)
        let syncText: String
        if let generatedAt {
            syncText = "Last sync \(timestampFormatter.string(from: generatedAt))"
        } else {
            syncText = "Last sync unknown"
        }
        let storeCount = manifest.storeClassify?.count ?? 0
        let playlistCount = (manifest.myPlaylists?.count ?? 0) + (manifest.someonePlaylists?.count ?? 0)
        let searchCount = manifest.searchQueries?.count ?? 0
        return "\(manifest.itemCount) cloud animations cached · \(manifest.categories.count) categories · \(storeCount) store channels · \(playlistCount) playlists · \(searchCount) searches · \(syncText)."
    }

    private func saveCloudCredentials(email: String, password: String) {
        guard persistDivoomCloudCredentials(email: email, password: password) else {
            settingsController?.refresh()
            updateActionStatus(
                summary: "Cloud credentials not saved",
                success: false,
                details: "Enter both the Divoom account email and password."
            )
            return
        }

        settingsController?.refresh()
        updateActionStatus(
            summary: "Cloud credentials saved",
            success: true,
            details: "Stored securely in Keychain for native Divoom cloud sync."
        )
    }

    private func importSyncedCloudCredentials() {
        updateActionStatus(
            summary: "Unlocking synced Divoom password",
            success: true,
            details: "Looking for the synced divoom-gz.com Passwords entry."
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let syncedCredentials = DivoomCloudCredentialResolver.syncedInternetPasswordCredentials(
                allowInteraction: true,
                forceRefresh: true
            )

            guard let syncedCredentials else {
                Task { @MainActor [weak self] in
                    self?.settingsController?.refresh()
                    self?.updateActionStatus(
                        summary: "No synced Divoom password found",
                        success: false,
                        details: "No Passwords entry was found for divoom-gz.com."
                    )
                }
                return
            }

            let saved = persistDivoomCloudCredentials(email: syncedCredentials.email, password: syncedCredentials.password)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsController?.refresh()
                if saved {
                    self.updateActionStatus(
                        summary: "Imported synced Divoom password",
                        success: true,
                        details: "The synced Passwords entry for \(syncedCredentials.email) is now stored in the app Keychain."
                    )
                } else {
                    self.updateActionStatus(
                        summary: "Synced Divoom password not saved",
                        success: false,
                        details: "The synced Passwords entry could not be copied into the app Keychain."
                    )
                }
            }
        }
    }

    private func clearCloudCredentials() {
        DivoomCloudKeychain.delete(account: divoomCloudEmailAccount)
        DivoomCloudKeychain.delete(account: divoomCloudPasswordAccount)
        DivoomCloudCredentialResolver.setPassiveLocalCredentialHint(nil)
        DivoomCloudCredentialResolver.resetPassiveCaches()
        settingsController?.refresh()
        updateActionStatus(
            summary: "Cleared saved cloud credentials",
            success: true,
            details: "The app-local cloud login was removed. You can still import a synced Passwords entry again later."
        )
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            updateActionStatus(
                summary: "Launch at login unsupported",
                success: false,
                details: "This requires macOS 13 or newer."
            )
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settingsController?.refresh()
            updateActionStatus(
                summary: enabled ? "Launch at login enabled" : "Launch at login disabled",
                success: true,
                details: enabled
                    ? "The app will now start automatically after login."
                    : "The app will no longer start automatically after login."
            )
        } catch {
            settingsController?.refresh()
            updateActionStatus(
                summary: "Launch at login failed",
                success: false,
                details: error.localizedDescription
            )
        }
    }

    private func setCloudLibraryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudLibraryEnabledDefaultsKey)
        animationLibraryController?.reloadFromExternalSync()
        refreshSummaryMetadataAsync()
        settingsController?.refresh()
        updateActionStatus(
            summary: enabled ? "Cloud library source enabled" : "Cloud library source disabled",
            success: true,
            details: enabled
                ? "Divoom cloud items will appear in the native library when synced."
                : "The native library will show local curated assets only."
        )
    }

    private func setCloudSyncOnLaunchEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudSyncOnLaunchDefaultsKey)
        settingsController?.refresh()
        updateActionStatus(
            summary: enabled ? "Cloud sync on launch enabled" : "Cloud sync on launch disabled",
            success: true,
            details: enabled
                ? "The app will attempt one Divoom cloud sync at launch."
                : "Launch will no longer trigger a cloud sync."
        )
    }

    private func setCloudAutoSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: cloudAutoSyncEnabledDefaultsKey)
        configureCloudSyncBehavior()
        settingsController?.refresh()
        updateActionStatus(
            summary: enabled ? "Cloud auto-sync enabled" : "Cloud auto-sync disabled",
            success: true,
            details: enabled
                ? "The app will try to sync Divoom cloud assets every 6 hours."
                : "Automatic Divoom cloud syncing is off."
        )
    }

    private func configureCloudSyncBehavior() {
        cloudSyncTimer?.invalidate()
        cloudSyncTimer = nil

        if isCloudAutoSyncEnabled() {
            let timer = Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.runDivoomCloudSync(silent: true)
                }
            }
            timer.tolerance = 300
            RunLoop.main.add(timer, forMode: .common)
            cloudSyncTimer = timer
        }

        if isCloudSyncOnLaunchEnabled() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runDivoomCloudSync(silent: true)
            }
        }
    }

    private func ensureSettingsController() -> AppSettingsWindowController {
        if let settingsController {
            return settingsController
        }

        let controller = AppSettingsWindowController(
            snapshotProvider: { [weak self] in
                self?.currentSettingsSnapshot() ?? AppSettingsSnapshot(
                    launchAtLoginEnabled: false,
                    favoritesPlayback: .twice,
                    showUsed: true,
                    codexMetric: .primary,
                    claudeMetric: .primary,
                    cloudCredentialEmail: "",
                    cloudCredentialPasswordPlaceholder: "Enter Divoom password",
                    cloudCredentialStatus: "No Divoom cloud credentials found yet.",
                    canImportSyncedCloudCredentials: false,
                    cloudLibraryEnabled: true,
                    cloudSyncOnLaunchEnabled: false,
                    cloudAutoSyncEnabled: false,
                    cloudManifestSummary: "No synced Divoom cloud manifest yet.",
                    version: "0.0.0",
                    build: "0",
                    gitCommit: "unknown"
                )
            },
            onToggleLaunchAtLogin: { [weak self] enabled in
                self?.setLaunchAtLoginEnabled(enabled)
            },
            onSetFavoritesPlayback: { [weak self] option in
                self?.setFavoritesPlaybackOption(option)
            },
            onSetShowUsed: { [weak self] showUsed in
                self?.setCodexBarUsageMode(showUsed: showUsed)
            },
            onSetCodexMetric: { [weak self] metric in
                self?.setMetricPreference(provider: "codex", metric: metric)
            },
            onSetClaudeMetric: { [weak self] metric in
                self?.setMetricPreference(provider: "claude", metric: metric)
            },
            onSaveCloudCredentials: { [weak self] email, password in
                self?.saveCloudCredentials(email: email, password: password)
            },
            onImportSyncedCloudCredentials: { [weak self] in
                self?.importSyncedCloudCredentials()
            },
            onClearCloudCredentials: { [weak self] in
                self?.clearCloudCredentials()
            },
            onSetCloudLibraryEnabled: { [weak self] enabled in
                self?.setCloudLibraryEnabled(enabled)
            },
            onSetCloudSyncOnLaunchEnabled: { [weak self] enabled in
                self?.setCloudSyncOnLaunchEnabled(enabled)
            },
            onSetCloudAutoSyncEnabled: { [weak self] enabled in
                self?.setCloudAutoSyncEnabled(enabled)
            },
            onSyncCloudNow: { [weak self] in
                self?.syncDivoomCloudLibrary()
            },
            onRevealCloudFolder: { [weak self] in
                self?.revealDivoomCloudFolder()
            },
            onOpenCloudGuide: { [weak self] in
                self?.openDivoomCloudGuide()
            },
            onOpenGitHub: { [weak self] in
                self?.openGitHubRepo()
            },
            onOpenReleases: { [weak self] in
                self?.openReleasesPage()
            },
            onOpenLogs: { [weak self] in
                self?.openLogFile()
            }
        )
        settingsController = controller
        return controller
    }

    private func makeFavoritesPlaybackMenu() -> NSMenuItem {
        let submenu = NSMenu(title: "Favorites Playback")
        let current = currentFavoritesPlaybackOption()
        var items: [FavoritesPlaybackOption: NSMenuItem] = [:]

        for option in FavoritesPlaybackOption.allCases {
            let item = makeItem(option.title, action: #selector(setFavoritesPlayback(_:)), symbolName: nil)
            item.representedObject = option.rawValue
            item.state = option == current ? .on : .off
            submenu.addItem(item)
            items[option] = item
        }

        favoritesPlaybackItems = items
        return makeSubmenuItem("Favorites Playback", symbolName: "repeat", submenu: submenu)
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
            process.executableURL = divoomRepoURL("bin/divoom-display")
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
                let serializedOutputPath = payload["serializedOutput"] as? String

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let serializedOutputPath, !serializedOutputPath.isEmpty {
                        self.bluetoothDiagnostics.runNativeBLESendGIF(path: serializedOutputPath, loopCount: 0) { [weak self] result in
                            DispatchQueue.main.async {
                                guard let self else { return }
                                self.updateActionStatus(
                                    summary: resolvedLabel,
                                    success: result.success,
                                    details: result.details
                                )
                                if result.success {
                                    if let successSound {
                                        self.playFeedbackSound(successSound)
                                    }
                                } else if playErrorSound {
                                    self.playFeedbackSound(.error)
                                }
                                let completionDetails = result.details.isEmpty ? result.summary : result.details
                                completion?(result.success, completionDetails)
                            }
                        }
                        return
                    }

                    self.run(
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
        divoomRepoURL("assets/sounds/openpeon-cute-minimal/\(profile.fileName)")
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
        refreshStatusIconState()
        refreshSummaryCard()
        updateStatusItemButton(summary: "\(prefix) \(summary) at \(time)", details: details)
    }

    private func updateConnectionStatus(summary: String, details: String?) {
        connectionSummary = summary
        connectionDetails = details
        refreshStatusIconState()
        refreshSummaryCard()
        updateStatusItemButton(summary: summary, details: details)
    }

    private func refreshStatusIconState() {
        let facts = currentConnectionFacts()
        if facts.authorizationDenied || facts.audioOnly || ((facts.scanFinished || facts.lightIdle) && !facts.lightReady && !facts.lightConnecting) {
            statusIconState = .error
            return
        }
        if lastActionDate != nil && !lastActionSuccess {
            statusIconState = .error
            return
        }
        if facts.lightReady || facts.lightConnected {
            statusIconState = .ok
            return
        }
        if lastActionDate != nil && lastActionSuccess {
            statusIconState = .ok
            return
        }
        statusIconState = .idle
    }

    private func refreshSummaryCard() {
        let presentation = currentSummaryPresentation()
        summaryCard.update(
            state: statusIconState,
            subtitle: presentation.subtitle,
            headline: presentation.headline,
            rotatingLines: presentation.rotatingLines,
            chips: presentation.chips
        )
    }

    private func currentSummaryPresentation() -> (subtitle: String, headline: String, rotatingLines: [String], chips: [SummaryChipSpec]) {
        return (
            subtitle: currentSummarySubtitle(),
            headline: currentSummaryHeadline(favoritesCount: cachedFavoriteCount, cloudItemCount: cachedCloudItemCount),
            rotatingLines: currentSummaryRotatingLines(favoritesCount: cachedFavoriteCount, cloudItemCount: cachedCloudItemCount),
            chips: currentSummaryChips(favoritesCount: cachedFavoriteCount, cloudItemCount: cachedCloudItemCount)
        )
    }

    private func currentConnectionFacts() -> ConnectionFacts {
        let summary = connectionSummary.lowercased()
        let details = (connectionDetails ?? "").lowercased()
        let combined = "\(summary)\n\(details)"

        var facts = ConnectionFacts()
        facts.authorizationPending = summary.contains("requested bluetooth access") || details.contains("bluetooth auth=notdetermined")
        facts.authorizationDenied = summary.contains("not granted")
            || summary.contains("unauthorized")
            || summary.contains("denied")
            || details.contains("bluetooth auth=denied")
            || details.contains("state=unauthorized")
        facts.lightReady = combined.contains("ble light write characteristic ready")
        facts.lightConnected = facts.lightReady || combined.contains("ble light connected")
        facts.lightConnecting = combined.contains("ble light connecting") || combined.contains("ble light reconnecting")
        facts.lightVisible = facts.lightConnected || details.contains("le scan: ditoopro-light")
        facts.lightIdle = combined.contains("ble light idle")
        facts.scanInProgress = summary.contains("ble scan progress") || summary.contains("scanning")
        facts.scanFinished = summary.contains("ble scan finished")
        facts.classicAudioVisible = combined.contains("ditoopro-audio@")
        return facts
    }

    private func refreshSummaryMetadataAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = AnimationLibraryCatalog.loadItems()
            let favoritesCount = AnimationLibraryCatalog.loadFavorites(resolvingAgainst: items).count
            let cloudItemCount = Self.cloudManifestItemCount()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cachedFavoriteCount = favoritesCount
                self.cachedCloudItemCount = cloudItemCount
                self.refreshSummaryCard()
            }
        }
    }

    nonisolated private static func cloudManifestItemCount() -> Int {
        guard let data = try? Data(contentsOf: cloudManifestURL),
              let manifest = try? JSONDecoder().decode(DivoomCloudManifest.self, from: data)
        else {
            return 0
        }
        return manifest.itemCount
    }

    private func currentSummarySubtitle() -> String {
        let facts = currentConnectionFacts()
        if facts.authorizationPending {
            return "Bluetooth permission needed"
        }
        if facts.authorizationDenied {
            return "Bluetooth is blocked"
        }
        if facts.lightReady {
            switch autoRefreshMode {
            case .off:
                return "16x16 Light Link online"
            case .favorites:
                return "Favorites rotation active"
            case .codex, .claude, .pair, .ipFlag:
                return "\(autoRefreshMode.title) live"
            }
        }
        if facts.lightConnecting {
            return "Reconnecting Light Link"
        }
        if facts.audioOnly {
            return "Audio link only"
        }
        if facts.scanInProgress {
            return "Scanning for Light Link"
        }
        if facts.scanFinished || facts.lightIdle {
            return "Display link offline"
        }
        if connectionSummary.isEmpty {
            return "Wake the Ditoo"
        }
        return "Checking the desk display"
    }

    private func currentSummaryHeadline(favoritesCount: Int, cloudItemCount: Int) -> String {
        let facts = currentConnectionFacts()
        if facts.authorizationPending || facts.authorizationDenied {
            return "Grant Bluetooth so the hidden DitooPro-Light display endpoint can beam again."
        }
        if facts.audioOnly {
            return "The audio speaker is present, but the display endpoint is missing."
        }
        if facts.lightConnecting {
            return "Rebuilding the Light Link and restoring the beam path."
        }
        if facts.scanInProgress {
            return "Scanning for DitooPro-Light so color, image, and live beams can resume."
        }
        if (facts.scanFinished || facts.lightIdle) && !facts.lightReady {
            return "Reconnect the Light Link to restore the 16x16 display."
        }
        if autoRefreshMode != .off {
            switch autoRefreshMode {
            case .codex:
                return "Codex usage is live on the Ditoo."
            case .claude:
                return "Claude usage is live on the Ditoo."
            case .pair:
                return "Split live view is active on the Ditoo."
            case .ipFlag:
                return "The current public IP flag is live on the Ditoo."
            case .favorites:
                let loopTitle = currentFavoritesPlaybackOption().title
                return favoritesCount > 0
                    ? "\(favoritesCount) favorites are rotating on the Ditoo · \(loopTitle)"
                    : "Favorites rotation is active on the Ditoo."
            case .off:
                break
            }
        }
        if let lastActionDate {
            let cleaned = cleanedActionSummary()
            if lastActionSuccess {
                return cleaned.isEmpty ? "Ready for the next beam." : "Last beam: \(cleaned) • \(timestampFormatter.string(from: lastActionDate))"
            }
            return cleaned.isEmpty
                ? "Something needs attention."
                : "Needs attention: \(cleaned) • \(timestampFormatter.string(from: lastActionDate))"
        }
        if favoritesCount > 0 || cloudItemCount > 0 {
            return "\(favoritesCount) favorites ready • \(cloudItemCount) cloud picks cached."
        }
        return "Open the Library, beam a color, or start a live feed."
    }

    private func currentSummaryRotatingLines(favoritesCount: Int, cloudItemCount: Int) -> [String] {
        let facts = currentConnectionFacts()
        let cloudLinked = resolvedCloudCredentialUIState().usesLocalKeychain

        if facts.authorizationPending {
            return ["If the Bluetooth prompt stays hidden, open Device → Request Bluetooth Access."]
        }
        if facts.authorizationDenied {
            return ["Use Device → Request Bluetooth Access after reopening the app, or re-enable it in System Settings."]
        }
        if facts.audioOnly {
            return ["Use Device → Reconnect Light Link to recover the hidden 16x16 display endpoint."]
        }
        if (facts.scanFinished || facts.lightIdle) && !facts.lightReady {
            return ["Device holds diagnostics and reconnection tools when the Light Link disappears."]
        }
        if autoRefreshMode == .favorites {
            return ["\(favoritesCount) starred animations are queued. Open Library to tune the rotation."]
        }
        if autoRefreshMode != .off {
            if cloudLinked {
                return ["\(cloudItemCount) cloud picks are cached. Open Library for playlists, likes, search, and store channels."]
            }
            return ["Open Library for curated picks now, then connect Cloud in Settings for playlists, search, and likes."]
        }
        if favoritesCount > 0 && cloudLinked {
            return ["\(favoritesCount) starred · \(cloudItemCount) cloud picks cached. Open Library for playlists, likes, and search."]
        }
        if favoritesCount > 0 {
            return ["\(favoritesCount) starred animations are ready. Open Library to build a stronger rotation."]
        }
        if cloudLinked {
            return ["\(cloudItemCount) cloud picks are cached. Start in Library for search, playlists, likes, and store channels."]
        }
        return ["Open Library for curated picks now, then connect Cloud in Settings to unlock search, likes, playlists, and store browsing."]
    }

    private func currentSummaryChips(favoritesCount: Int, cloudItemCount: Int) -> [SummaryChipSpec] {
        _ = cloudItemCount
        return [
            currentLinkChip(),
            currentActivityChip(favoritesCount: favoritesCount),
        ]
    }

    private func currentLinkChip() -> SummaryChipSpec {
        let facts = currentConnectionFacts()
        if facts.authorizationPending {
            return SummaryChipSpec(text: "Bluetooth Needed", symbolName: "dot.radiowaves.left.and.right", accentColor: .systemOrange)
        }
        if facts.authorizationDenied {
            return SummaryChipSpec(text: "Bluetooth Needed", symbolName: "bolt.horizontal.circle", accentColor: .systemOrange)
        }
        if facts.lightReady {
            return SummaryChipSpec(text: "Beam Ready", symbolName: "dot.radiowaves.left.and.right", accentColor: .systemMint)
        }
        if facts.lightConnecting {
            return SummaryChipSpec(text: "Reconnecting", symbolName: "link")
        }
        if facts.audioOnly {
            return SummaryChipSpec(text: "Audio Only", symbolName: "speaker.wave.2", accentColor: .systemOrange)
        }
        if facts.scanInProgress {
            return SummaryChipSpec(text: "Scanning", symbolName: "magnifyingglass")
        }
        if facts.scanFinished || facts.lightIdle {
            return SummaryChipSpec(text: "Display Offline", symbolName: "bolt.horizontal.circle", accentColor: .systemOrange)
        }
        return SummaryChipSpec(text: "Link Unknown", symbolName: "questionmark.circle")
    }

    private func currentActivityChip(favoritesCount: Int) -> SummaryChipSpec {
        switch autoRefreshMode {
        case .off:
            if favoritesCount > 0 {
                return SummaryChipSpec(text: "\(favoritesCount) Favorites", symbolName: "star.fill", accentColor: .systemYellow)
            }
            if lastActionDate != nil {
                if lastActionSuccess {
                    return SummaryChipSpec(text: "Last Beam OK", symbolName: "checkmark.circle.fill", accentColor: .systemGreen)
                }
                return SummaryChipSpec(text: "Needs Attention", symbolName: "exclamationmark.triangle.fill", accentColor: .systemOrange)
            }
            return SummaryChipSpec(text: "Create & Library", symbolName: "sparkles")
        case .favorites:
            return SummaryChipSpec(text: "Favorites Queue", symbolName: "arrow.triangle.2.circlepath", accentColor: .systemPink)
        case .codex, .claude, .pair, .ipFlag:
            return SummaryChipSpec(text: autoRefreshMode.title, symbolName: "livephoto", accentColor: .systemBlue)
        }
    }

    private func currentCloudChip(cloudItemCount: Int) -> SummaryChipSpec {
        let credentialState = currentCloudCredentialUIState()
        if !isCloudLibraryEnabled() {
            return SummaryChipSpec(text: "Cloud Hidden", symbolName: "icloud.slash")
        }

        if credentialState.usesLocalKeychain {
            let text = cloudItemCount > 0 ? "\(cloudItemCount) Cloud" : "Cloud Linked"
            return SummaryChipSpec(text: text, symbolName: "icloud", accentColor: .systemTeal)
        }
        return SummaryChipSpec(text: "Connect Cloud", symbolName: "icloud", accentColor: nil)
    }

    private func cleanedActionSummary() -> String {
        let cleaned = lastActionSummary
            .replacingOccurrences(of: "Native BLE ", with: "")
            .replacingOccurrences(of: "ipc-", with: "")
            .replacingOccurrences(of: "OK ", with: "")
            .replacingOccurrences(of: "ERR ", with: "")
            .replacingOccurrences(of: "purity", with: "ambient")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return ""
        }
        return String(cleaned.prefix(1)).uppercased() + cleaned.dropFirst()
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
        favoritesRotationTimer?.invalidate()
        favoritesRotationTimer = nil

        guard mode != .off else {
            updateAutoRefreshUI()
            return
        }

        if mode == .favorites {
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
        settingsController?.refresh()
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
            return "Rotate Favorites • \(currentFavoritesPlaybackOption().title)"
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
        AppLog.write("IPC dequeue file=\(requestURL.lastPathComponent)")
        handleIPCRequest(at: requestURL)
    }

    private func handleIPCRequest(at requestURL: URL) {
        let processingURL = requestURL.deletingPathExtension().appendingPathExtension("processing")

        do {
            if FileManager.default.fileExists(atPath: processingURL.path) {
                try FileManager.default.removeItem(at: processingURL)
            }
            try FileManager.default.moveItem(at: requestURL, to: processingURL)
            AppLog.write("IPC moved file=\(processingURL.lastPathComponent)")

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
                AppLog.write("IPC completion id=\(request.id) success=\(result.success)")
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
            if
                let payloadData = parameter.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                let path = payload["path"] as? String,
                !path.isEmpty
            {
                let loopCount = payload["loopCount"] as? Int ?? 0
                bluetoothDiagnostics.runNativeBLESendGIF(path: path, loopCount: loopCount, completion: completion)
            } else {
                bluetoothDiagnostics.runNativeBLESendGIF(path: parameter, completion: completion)
            }
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
        case .nativeReadOptionalKeyConfig:
            bluetoothDiagnostics.runNativeBLEReadOptionalKeyConfig(completion: completion)
        case .nativeResetOptionalKeyConfig:
            bluetoothDiagnostics.runNativeBLEResetOptionalKeyConfig(completion: completion)
        }
    }

    private func writeIPCResult(_ result: IPCResultPayload) {
        ensureIPCDirectories()
        let resultURL = ipcResultsURL.appendingPathComponent("\(result.id).json")
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: resultURL, options: .atomic)
            AppLog.write("writeIPCResult path=\(resultURL.lastPathComponent) success=\(result.success)")
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
                divoomRepoURL("assets/16x16/curated/pixel-displays/soniccrabe.gif").path,
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
                divoomRepoURL("assets/16x16/generated/doom_fire.divoom16").path,
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
                divoomRepoURL("andreas-js/images/bunny.divoom16").path,
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

    @objc private func reconnectLightLink() {
        bluetoothDiagnostics.resetLightLinkAndRescan()
        updateActionStatus(
            summary: "Reconnect light link",
            success: true,
            details: "Cleared the cached DitooPro-Light session and started a fresh BLE scan."
        )
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
                self?.handleNativeActionResult(result, summary: "Ambient red", successSound: .colorSet)
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
            path: divoomRepoURL("assets/16x16/generated/menu_fire.divoom16").path,
            loopCount: 0
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Doom Fire Loop", successSound: .animation)
            }
        }
    }

    @objc private func runNativeUploadNyan() {
        bluetoothDiagnostics.runNativeBLESendGIF(
            path: divoomRepoURL("assets/16x16/generated/menu_nyan.divoom16").path,
            loopCount: 0
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleNativeActionResult(result, summary: "Nyan Cat", successSound: .animation)
            }
        }
    }

    @objc private func runNativeUploadBunny() {
        bluetoothDiagnostics.runNativeBLESendGIF(
            path: divoomRepoURL("assets/16x16/generated/menu_bunny.divoom16").path,
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

    private func sendSelectedAmbientColor(_ color: NSColor, source: String) {
        guard
            let rgbColor = color.usingColorSpace(.deviceRGB),
            let (red, green, blue) = rgbComponents(from: rgbColor)
        else {
            updateActionStatus(
                summary: "Ambient light failed",
                success: false,
                details: "Could not convert the selected color into RGB components."
            )
            return
        }

        let colorHex = hexString(for: rgbColor) ?? "#000000"
        bluetoothDiagnostics.runNativeBLEAmbientColor(
            red: red,
            green: green,
            blue: blue
        ) { [weak self] result in
            DispatchQueue.main.async {
                let details = [result.details, "source=\(source)", "hex=\(colorHex)"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                self?.updateActionStatus(
                    summary: "Ambient light \(colorHex)",
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

        let effectiveMode: ColorMotionMode = mode == .solid ? .gradientSweep : mode

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = divoomRepoURL("bin/divoom-display")
            process.arguments = ["render-palette", "--mode", effectiveMode.rawValue]
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
                            summary: "\(effectiveMode.summaryPrefix) failed",
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
                            summary: "\(effectiveMode.summaryPrefix) failed",
                            success: false,
                            details: "Renderer did not return a usable output path."
                        )
                    }
                    return
                }

                let renderedLabel = (payload["label"] as? String) ?? effectiveMode.summaryPrefix
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
                        summary: "\(effectiveMode.summaryPrefix) failed",
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
        loopCount: Int? = nil,
        successSound: FeedbackSoundProfile? = .animation,
        playErrorSound: Bool = true,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        var arguments = ["native-headless", "send-gif", "--path", fileURL.path]
        if let loopCount {
            arguments.append(contentsOf: ["--loops", String(loopCount)])
        }
        run(
            label: label,
            arguments: arguments,
            successSound: successSound,
            playErrorSound: playErrorSound,
            completion: completion
        )
    }

    private func currentFavoriteAnimationItems() -> [AnimationLibraryItem] {
        let items = AnimationLibraryCatalog.loadItems()
        let favorites = AnimationLibraryCatalog.loadFavorites(resolvingAgainst: items)
        guard !favorites.isEmpty else {
            return []
        }
        return items.filter { favorites.contains($0.id) }
    }

    private func favoriteRotationDelay(
        for item: AnimationLibraryItem,
        playbackOption: FavoritesPlaybackOption
    ) -> TimeInterval? {
        guard playbackOption != .infinite else {
            return nil
        }
        guard let sequence = AnimationPreviewCache.sequence(for: item.fileURL) else {
            return max(Double(playbackOption.rawValue) * 1.0, 0.5)
        }
        return max(sequence.duration * Double(playbackOption.rawValue), 0.5)
    }

    private func scheduleNextFavoriteRotation(after delay: TimeInterval?) {
        favoritesRotationTimer?.invalidate()
        favoritesRotationTimer = nil

        guard autoRefreshMode == .favorites, let delay else {
            return
        }

        favoritesRotationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.favoritesRotationTimer?.invalidate()
                self.favoritesRotationTimer = nil
                guard self.autoRefreshMode == .favorites else { return }
                self.refreshLiveFeed(.favorites)
            }
        }
    }

    private func beamNextFavorite(
        playActivationSound: Bool,
        completion: (@MainActor (Bool, String, TimeInterval?) -> Void)? = nil
    ) {
        let items = currentFavoriteAnimationItems()
        guard !items.isEmpty else {
            if autoRefreshMode == .favorites {
                setAutoRefreshMode(.off)
            }
            updateActionStatus(
                summary: "Rotate Favorites needs favorites",
                success: false,
                details: "Add at least one favorite in the library, then start rotation again."
            )
            completion?(false, "Add at least one favorite in the library, then start rotation again.", nil)
            return
        }

        let currentIndex = UserDefaults.standard.integer(forKey: favoriteRotationIndexDefaultsKey)
        let item = items[currentIndex % items.count]
        let playbackOption = currentFavoritesPlaybackOption()
        let nextDelay = favoriteRotationDelay(for: item, playbackOption: playbackOption)
        UserDefaults.standard.set((currentIndex + 1) % items.count, forKey: favoriteRotationIndexDefaultsKey)
        recordRecentAnimation(relativePath: item.relativePath)
        beamAnimationFile(
            item.fileURL,
            label: "Favorites \(item.title)",
            loopCount: playbackOption.rawValue,
            successSound: playActivationSound ? .animation : nil,
            playErrorSound: playActivationSound,
            completion: { [weak self] success, details in
                if success, self?.autoRefreshMode == .favorites {
                    self?.scheduleNextFavoriteRotation(after: nextDelay)
                }
                completion?(success, details, nextDelay)
            }
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

    @objc private func setFavoritesPlayback(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? Int,
            let option = FavoritesPlaybackOption(rawValue: rawValue)
        else {
            return
        }
        setFavoritesPlaybackOption(option)
    }

    @objc private func setCodexBarShowUsed() {
        setCodexBarUsageMode(showUsed: true)
    }

    @objc private func setCodexBarShowRemaining() {
        setCodexBarUsageMode(showUsed: false)
    }

    @objc private func setCodexMetricPreference(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let metric = CodexBarMetricPreference(rawValue: rawValue)
        else { return }
        setMetricPreference(provider: "codex", metric: metric)
    }

    @objc private func setClaudeMetricPreference(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let metric = CodexBarMetricPreference(rawValue: rawValue)
        else { return }
        setMetricPreference(provider: "claude", metric: metric)
    }

    @objc private func openSettings() {
        ensureSettingsController().showSettings(tab: .general)
    }

    @objc private func openLiveSettings() {
        ensureSettingsController().showSettings(tab: .live)
    }

    @objc private func openLibrarySettings() {
        ensureSettingsController().showSettings(tab: .library)
    }

    @objc private func showAboutPanel() {
        let version = appVersionString()
        let build = appBuildString()
        let separator = NSAttributedString(string: " · ", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        let credits = NSMutableAttributedString()
        credits.append(NSAttributedString(string: "@kirniy", attributes: [.link: URL(string: "https://t.me/kirniy") as Any]))
        credits.append(NSAttributedString(string: " · early beta native menu bar app for the Divoom Ditoo Pro\n"))
        credits.append(NSAttributedString(string: "GitHub", attributes: [.link: URL(string: "https://github.com/kirniy/divoom-ditoo-pro-mac") as Any]))
        credits.append(separator)
        credits.append(NSAttributedString(string: "Releases", attributes: [.link: URL(string: "https://github.com/kirniy/divoom-ditoo-pro-mac/releases") as Any]))
        credits.append(separator)
        credits.append(NSAttributedString(string: "Issues", attributes: [.link: URL(string: "https://github.com/kirniy/divoom-ditoo-pro-mac/issues") as Any]))
        credits.append(NSAttributedString(string: "\nBuild \(build) · commit \(appGitCommit())", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Divoom Ditoo Pro Mac",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
            .applicationIcon: (NSApplication.shared.applicationIconImage ?? NSImage()) as Any,
        ])
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

    @objc private func syncDivoomCloudLibrary() {
        runDivoomCloudSync(silent: false)
    }

    private func runDivoomCloudSync(silent: Bool) {
        runDivoomCloudCommand(
            label: "Divoom cloud library",
            initialDetails: "Fetching 16x16 cloud animations, store channels, and playlist metadata into the native library.",
            extraArguments: ["--include-store-classify", "--include-my-list"],
            silent: silent,
            reloadLibrary: true
        )
    }

    private func searchDivoomCloudLibrary(_ query: String) {
        runDivoomCloudCommand(
            label: "Divoom cloud search",
            initialDetails: "Querying Divoom Cloud for \"\(query)\" and caching the matching animations.",
            extraArguments: [
                "--skip-albums",
                "--max-per-category", "0",
                "--search-query", query,
                "--include-store-classify",
                "--include-my-list",
            ],
            silent: false,
            reloadLibrary: true
        )
    }

    private func toggleDivoomCloudLike(
        item: AnimationLibraryItem,
        isLike: Bool,
        completion: @escaping @MainActor (Bool, String) -> Void
    ) {
        guard item.galleryID > 0, item.cloudClassify > 0, item.fileType > 0 else {
            completion(false, "This cloud item is missing the numeric metadata needed for GalleryLikeV2.")
            return
        }

        var extraArguments = [
            "--like-gallery-id", String(item.galleryID),
            "--like-classify", String(item.cloudClassify),
            "--like-file-type", String(item.fileType),
        ]
        if !isLike {
            extraArguments.append("--unlike")
        }

        runDivoomCloudCommand(
            label: isLike ? "Cloud like" : "Cloud unlike",
            initialDetails: isLike ? "Liking \(item.title) in Divoom Cloud." : "Removing like for \(item.title) in Divoom Cloud.",
            extraArguments: extraArguments,
            silent: false,
            reloadLibrary: false
        ) { success, details in
            completion(success, details)
        }
    }

    private func runDivoomCloudCommand(
        label: String,
        initialDetails: String,
        extraArguments: [String],
        silent: Bool,
        reloadLibrary: Bool,
        completion: (@MainActor (Bool, String) -> Void)? = nil
    ) {
        let pythonURL = divoomRepoURL(".venv/bin/python")
        let executableURL = FileManager.default.isExecutableFile(atPath: pythonURL.path)
            ? pythonURL
            : URL(fileURLWithPath: "/usr/bin/env")

        if !silent {
            updateActionStatus(
                summary: "Syncing \(label)",
                success: true,
                details: initialDetails
            )
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let credentials = DivoomCloudCredentialResolver.bestAvailableCredentials(allowInteraction: false) else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.settingsController?.refresh()
                    if !silent {
                        self.ensureSettingsController().showSettings(tab: .library)
                        self.updateActionStatus(
                            summary: "\(label) needs credentials",
                            success: false,
                            details: "Open Settings > Cloud, save a local Divoom login, or import the synced divoom-gz.com Passwords entry into this app."
                        )
                    }
                    completion?(false, "Open Settings > Cloud, save a local Divoom login, or import the synced divoom-gz.com Passwords entry into this app.")
                }
                return
            }

            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            var environment = ProcessInfo.processInfo.environment
            environment["DIVOOM_EMAIL"] = credentials.email
            environment["DIVOOM_PASSWORD"] = credentials.password
            process.executableURL = executableURL
            var arguments = executableURL == pythonURL
                ? [divoomRepoURL("tools/divoom_cloud_sync.py").path]
                : ["python3", divoomRepoURL("tools/divoom_cloud_sync.py").path]
            arguments.append(contentsOf: extraArguments)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let details = stderr.isEmpty ? stdout : stderr

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let success = process.terminationStatus == 0
                    self.settingsController?.refresh()
                    if !silent || !success {
                        self.updateActionStatus(
                            summary: success ? "\(label) finished" : "\(label) failed",
                            success: success,
                            details: details
                        )
                    }
                    if success && reloadLibrary {
                        self.animationLibraryController?.reloadFromExternalSync()
                        self.refreshSummaryMetadataAsync()
                    }
                    completion?(success, details)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.settingsController?.refresh()
                    self?.updateActionStatus(
                        summary: "\(label) failed",
                        success: false,
                        details: error.localizedDescription
                    )
                    completion?(false, error.localizedDescription)
                }
            }
        }
    }

    @objc private func revealDivoomCloudFolder() {
        let cloudURL = divoomRepoURL("assets/16x16/divoom-cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: cloudURL, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cloudURL.path)
        updateActionStatus(
            summary: "Revealed Divoom cloud folder",
            success: true,
            details: cloudURL.path
        )
    }

    @objc private func openDivoomCloudGuide() {
        NSWorkspace.shared.open(divoomRepoURL("docs/DIVOOM_CLOUD_SYNC.md"))
    }

    @objc private func sendRecentAnimation(_ sender: NSMenuItem) {
        guard let relativePath = sender.representedObject as? String else {
            NSSound.beep()
            return
        }
        let animationURL = divoomRepoURL("assets/16x16", isDirectory: true).appendingPathComponent(relativePath)
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
        NSWorkspace.shared.open(divoomRepoURL("RESEARCH.md"))
    }

    @objc private func openGitHubRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/divoom-ditoo-pro-mac")!)
    }

    @objc private func openReleasesPage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/kirniy/divoom-ditoo-pro-mac/releases")!)
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Users/kirniy/Library/Logs/DivoomMenuBar.log"))
    }

    @objc private func revealLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/Users/kirniy/Library/Logs/DivoomMenuBar.log")])
    }

    @objc private func exportLogFile() {
        let sourceURL = URL(fileURLWithPath: "/Users/kirniy/Library/Logs/DivoomMenuBar.log")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            updateActionStatus(
                summary: "Export logs failed",
                success: false,
                details: "The log file does not exist yet."
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DivoomMenuBar.log"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        panel.begin { [weak self] response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                self?.updateActionStatus(
                    summary: "Logs exported",
                    success: true,
                    details: destinationURL.path
                )
            } catch {
                self?.updateActionStatus(
                    summary: "Export logs failed",
                    success: false,
                    details: error.localizedDescription
                )
            }
        }
    }

    @objc private func openOpenClawDashboard() {
        launchDetachedShellCommand("openclaw dashboard >/tmp/divoom-openclaw-dashboard.log 2>&1 &", summary: "Opened OpenClaw dashboard")
    }

    @objc private func openOpenClawNotes() {
        NSWorkspace.shared.open(divoomRepoURL("OPENCLAW_INTEGRATION.md"))
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
            beamNextFavorite(playActivationSound: true) { [weak self] success, _, nextDelay in
                guard let self else { return }
                self.quickActionHub.loadingAction = nil
                guard success else { return }
                self.setAutoRefreshMode(.favorites)
                self.scheduleNextFavoriteRotation(after: nextDelay)
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
            },
            onOpenCloudSettings: { [weak self] in
                self?.ensureSettingsController().showSettings(tab: .library)
            },
            onSaveCloudCredentials: { [weak self] email, password in
                self?.saveCloudCredentials(email: email, password: password)
            },
            onImportSyncedCloudCredentials: { [weak self] in
                self?.importSyncedCloudCredentials()
                self?.animationLibraryController?.reloadFromExternalSync()
            },
            onSyncCloudNow: { [weak self] in
                self?.syncDivoomCloudLibrary()
            },
            onSearchCloud: { [weak self] query in
                self?.searchDivoomCloudLibrary(query)
            },
            onToggleCloudLike: { [weak self] item, isLike, completion in
                self?.toggleDivoomCloudLike(item: item, isLike: isLike, completion: completion)
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
    case nativeReadOptionalKeyConfig = "--headless-native-read-optional-key-config"
    case nativeResetOptionalKeyConfig = "--headless-native-reset-optional-key-config"
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

private func cleanupStaleIPCArtifacts() {
    let fileManager = FileManager.default
    let now = Date()
    let staleAge: TimeInterval = 24 * 60 * 60

    for directoryURL in [ipcRequestsURL, ipcResultsURL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let modifiedAt = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) > staleAge else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }
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
        case .nativeReadOptionalKeyConfig:
            bluetoothDiagnostics.runNativeBLEReadOptionalKeyConfig { [weak self] result in
                self?.finish(code: result.success ? 0 : 1, message: self?.format(result) ?? result.summary)
            }
        case .nativeResetOptionalKeyConfig:
            bluetoothDiagnostics.runNativeBLEResetOptionalKeyConfig { [weak self] result in
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
