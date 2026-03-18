import CoreBluetooth
import Foundation
import IOBluetooth

private let ditooLightServiceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
private let ditooLightLEWriteCharacteristicUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
private let ditooLightLEReadCharacteristicUUID = CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE")
private let ditooLightAca3CharacteristicUUID = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318")
private let ditooLightLegacyWriteCharacteristicUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
private let lastDitooLightPeripheralUUIDDefaultsKey = "DivoomLastDitooLightPeripheralUUID"
private let sampleAnimationPath = "/Users/kirniy/dev/divoom/andreas-js/images/witch.divoom16"

private func normalizeBluetoothAddress(_ address: String) -> String {
    address
        .uppercased()
        .replacingOccurrences(of: "-", with: ":")
}

private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func buildDivoomPacket(command: UInt8, payload: Data = Data()) -> Data {
    let length = UInt16(payload.count + 3)
    let checksumBytes = [UInt8(length & 0x00ff), UInt8(length >> 8), command] + payload
    let checksum = checksumBytes.reduce(UInt32.zero) { partial, byte in
        partial + UInt32(byte)
    }

    var packet = Data([0x01, UInt8(length & 0x00ff), UInt8(length >> 8), command])
    packet.append(payload)
    packet.append(UInt8(checksum & 0xff))
    packet.append(UInt8((checksum >> 8) & 0xff))
    packet.append(0x02)
    return packet
}

private func buildOldModeDivoomPacket(command: UInt8, payload: Data = Data()) -> Data {
    let rawPacket = buildDivoomPacket(command: command, payload: payload)
    guard rawPacket.count >= 2, rawPacket.first == 0x01, rawPacket.last == 0x02 else {
        return rawPacket
    }

    // Ditoo-class BLE devices use the Android app's "old mode" escaped framing.
    var escaped = Data([0x01])
    for byte in rawPacket.dropFirst().dropLast() {
        switch byte {
        case 0x01:
            escaped.append(contentsOf: [0x03, 0x04])
        case 0x02:
            escaped.append(contentsOf: [0x03, 0x05])
        case 0x03:
            escaped.append(contentsOf: [0x03, 0x06])
        default:
            escaped.append(byte)
        }
    }
    escaped.append(0x02)
    return escaped
}

private func buildNewModeLECommandPacket(
    command: UInt8,
    payload: Data = Data(),
    transmitMode: UInt8 = 0,
    packetID: UInt32 = 0
) -> Data {
    // Matches Aurabox BLECommLayer:
    // FE EF AA 55 + len_le16 + transmit_mode_u8 + [packet_id_le32 if mode == 1] + (cmd + payload) + checksum_le16
    var body = Data()
    let commandPayloadLength = payload.count + 1
    let length = UInt16(commandPayloadLength + (transmitMode == 1 ? 7 : 3))

    body.append(UInt8(length & 0x00ff))
    body.append(UInt8(length >> 8))
    body.append(transmitMode)
    if transmitMode == 1 {
        var littleEndianPacketID = packetID.littleEndian
        withUnsafeBytes(of: &littleEndianPacketID) { rawBuffer in
            body.append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }
    body.append(command)
    body.append(payload)

    let checksum = body.reduce(UInt32.zero) { partial, byte in
        partial + UInt32(byte)
    }

    var packet = Data([0xFE, 0xEF, 0xAA, 0x55])
    packet.append(body)
    packet.append(UInt8(checksum & 0xff))
    packet.append(UInt8((checksum >> 8) & 0xff))
    return packet
}

private func buildLECommandPacket(command: UInt8, payload: Data = Data(), requireAck: Bool = false, packetNumber: UInt32 = 1) -> Data {
    buildNewModeLECommandPacket(
        command: command,
        payload: payload,
        transmitMode: requireAck ? 1 : 0,
        packetID: packetNumber
    )
}

private func buildExtendedCommandPacket(type: UInt8, params: [UInt8] = []) -> Data {
    var payload = Data([type])
    payload.append(contentsOf: params)
    return buildOldModeDivoomPacket(command: 0xBD, payload: payload)
}

private func buildDateTimePayload(date: Date = Date()) -> Data {
    let calendar = Calendar.current
    let components = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second, .weekday],
        from: date
    )

    let year = max(0, components.year ?? 0)
    let weekday = max(0, (components.weekday ?? 1) - 1)
    return Data([
        UInt8(year % 100),
        UInt8(year / 100),
        UInt8(components.month ?? 1),
        UInt8(components.day ?? 1),
        UInt8(components.hour ?? 0),
        UInt8(components.minute ?? 0),
        UInt8(components.second ?? 0),
        UInt8(weekday),
    ])
}

private func vendorLanguageIndex() -> UInt8 {
    let mapping: [String: UInt8] = [
        "en": 0,
        "zh-hans": 1,
        "zh-hant": 2,
        "ja": 3,
        "th": 4,
        "fr": 5,
        "it": 6,
        "he": 7,
        "es": 8,
        "de": 9,
        "ru": 10,
        "pt": 11,
        "ko": 12,
        "nl": 13,
        "uk": 14,
        "ms": 15,
    ]

    for preferred in Locale.preferredLanguages {
        let normalized = preferred.lowercased()
        if let direct = mapping[normalized] {
            return direct
        }
        if let head = normalized.split(separator: "-").first, let short = mapping[String(head)] {
            return short
        }
    }

    return 0
}

private struct RGBColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private func buildPublicStaticImageCommandBody(colors: [RGBColor], frameDelay: UInt16 = 0) -> Data {
    precondition(colors.count == 16 * 16, "Ditoo Pro display is 16x16 pixels")

    var palette: [RGBColor] = []
    var paletteIndexes: [UInt8] = []
    paletteIndexes.reserveCapacity(colors.count)

    for color in colors {
        if let existingIndex = palette.firstIndex(of: color) {
            paletteIndexes.append(UInt8(existingIndex))
        } else {
            palette.append(color)
            paletteIndexes.append(UInt8(palette.count - 1))
        }
    }

    let bitWidth = max(1, Int(ceil(log2(Double(max(1, palette.count))))))
    var pixelData = Data()
    var offset = 0
    var pixel: UInt16 = 0

    for indexByte in paletteIndexes {
        let index = UInt16(indexByte)
        pixel |= index << offset
        offset += bitWidth
        if offset >= 8 {
            pixelData.append(UInt8(pixel & 0xff))
            if offset > 8 {
                pixel = index >> (bitWidth - (offset - 8))
            } else {
                pixel = 0
            }
            offset -= 8
        }
    }

    if offset > 0 {
        pixelData.append(UInt8(pixel & 0xff))
    }

    var paletteData = Data()
    for color in palette {
        paletteData.append(contentsOf: [color.r, color.g, color.b])
    }

    let size = UInt16(7 + paletteData.count + pixelData.count)
    var imageData = Data([0xAA, UInt8(size & 0xff), UInt8(size >> 8), 0x00, UInt8(frameDelay & 0xff), UInt8(frameDelay >> 8), UInt8(palette.count)])
    imageData.append(paletteData)
    imageData.append(pixelData)

    var body = Data([0x00, 0x0A, 0x0A, 0x04])
    body.append(imageData)
    return body
}

private func buildPublicCheckerboardTestImage() -> [RGBColor] {
    var colors: [RGBColor] = []
    colors.reserveCapacity(16 * 16)
    let red = RGBColor(r: 0xff, g: 0x10, b: 0x10)
    let white = RGBColor(r: 0xff, g: 0xff, b: 0xff)

    for y in 0..<16 {
        for x in 0..<16 {
            let onDiagonal = x == y || x == (15 - y)
            let checker = ((x / 2) + (y / 2)).isMultiple(of: 2)
            colors.append(onDiagonal || checker ? red : white)
        }
    }

    return colors
}

private func buildPublicPixelBadgeTestImage() -> [RGBColor] {
    var colors: [RGBColor] = []
    colors.reserveCapacity(16 * 16)

    let background = RGBColor(r: 0x05, g: 0x10, b: 0x24)
    let border = RGBColor(r: 0xff, g: 0xff, b: 0xff)
    let diagonal = RGBColor(r: 0xff, g: 0x35, b: 0x5e)
    let cross = RGBColor(r: 0x33, g: 0xf7, b: 0x73)
    let center = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)

    for y in 0..<16 {
        for x in 0..<16 {
            let isBorder = x == 0 || y == 0 || x == 15 || y == 15
            let isDiagonal = x == y || x == (15 - y)
            let isCross = x == 7 || x == 8 || y == 7 || y == 8
            let isCenter = (5...10).contains(x) && (5...10).contains(y)

            if isBorder {
                colors.append(border)
            } else if isCenter {
                colors.append(center)
            } else if isCross {
                colors.append(cross)
            } else if isDiagonal {
                colors.append(diagonal)
            } else {
                colors.append(background)
            }
        }
    }

    return colors
}

private func chunked(_ data: Data, size: Int) -> [Data] {
    guard size > 0, !data.isEmpty else {
        return data.isEmpty ? [] : [data]
    }

    var chunks: [Data] = []
    var start = 0
    while start < data.count {
        let end = min(start + size, data.count)
        chunks.append(data.subdata(in: start..<end))
        start = end
    }
    return chunks
}

private func preferredBLEWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
    if characteristic.properties.contains(.write) {
        return .withResponse
    }
    if characteristic.properties.contains(.writeWithoutResponse) {
        return .withoutResponse
    }
    return .withResponse
}

struct NativeActionResult {
    let success: Bool
    let summary: String
    let details: String
}

struct DitooCandidate: Hashable {
    let name: String
    let address: String
    let connected: Bool
    let source: String
}

final class BluetoothDiagnostics: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, IOBluetoothDeviceInquiryDelegate {
    private var centralManager: CBCentralManager?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var discoveredLENames = Set<String>()
    private var inquiryDevicesByAddress: [String: IOBluetoothDevice] = [:]
    private var inquiryCandidatesByAddress: [String: DitooCandidate] = [:]
    private var lastInquiryStatus = "Classic inquiry idle"
    private var lastAuthorizationStatus = "Bluetooth auth unknown"
    private var lastLERefreshAt = Date.distantPast
    private var ditooLightPeripheral: CBPeripheral?
    private var ditooLightWriteCharacteristic: CBCharacteristic?
    private var ditooLightNotifyCharacteristic: CBCharacteristic?
    private var ditooLightState = "BLE light idle"
    var statusHandler: ((String, String?) -> Void)?

    func requestAccessAndScan() {
        AppLog.write("BluetoothDiagnostics.requestAccessAndScan")
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                AppLog.write(
                    "BluetoothDiagnostics.requestAccessAndScan fallback auth=\(CBManager.authorization.rawValue) state=\(self.centralManager?.state.rawValue ?? -1)"
                )
                self.handleCentralState()
            }
        } else {
            handleCentralState()
        }
        refreshStatus(reason: "Requested Bluetooth access")
    }

    func refreshStatus(reason: String? = nil) {
        let summary = reason ?? "Bluetooth status updated"
        let auth = authorizationSummary()
        let inquiryStatus = lastInquiryStatus
        let lightState = ditooLightState
        let leNames = discoveredLENames.sorted()
        let inquirySnapshot = Array(inquiryCandidatesByAddress.values)

        lastAuthorizationStatus = auth

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let profiler = self.systemProfilerCandidates()
            let paired = self.pairedCandidates()
            let classicSummary = (paired + inquirySnapshot + profiler)
                .reduce(into: [String: DitooCandidate]()) { partial, candidate in
                    partial[candidate.address.uppercased()] = candidate
                }
                .values
                .sorted { lhs, rhs in
                    if lhs.name != rhs.name {
                        return lhs.name < rhs.name
                    }
                    return lhs.address < rhs.address
                }
                .map { "\($0.name)@\($0.address) [\($0.source)\($0.connected ? ",connected" : "")]" }
                .joined(separator: "; ")

            let leSummary = leNames.joined(separator: ", ")
            let details = [
                auth,
                inquiryStatus,
                lightState,
                leSummary.isEmpty ? "LE scan: none" : "LE scan: \(leSummary)",
                classicSummary.isEmpty ? "Classic Ditoo candidates: none" : "Classic Ditoo candidates: \(classicSummary)",
            ].joined(separator: "\n")

            AppLog.write("BluetoothDiagnostics.refreshStatus\nsummary=\(summary)\n\(details)")
            self.notifyStatus(summary: summary, details: details)
        }
    }

    func runNativeVolumeProbe(completion: @escaping (NativeActionResult) -> Void) {
        guard let target = preferredCandidate() else {
            AppLog.write("runNativeVolumeProbe no candidate")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native volume probe failed",
                    details: "No Divoom Ditoo candidate found. Run Bluetooth diagnostics after granting app access.",
                )
            )
            return
        }

        AppLog.write("runNativeVolumeProbe target=\(target.name)@\(target.address) source=\(target.source) connected=\(target.connected)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DitooRFCOMMClient.run(
                candidate: target,
                cachedDevice: self.inquiryDevicesByAddress[normalizeBluetoothAddress(target.address)],
                command: 0x09,
                payload: Data(),
                expectResponse: true,
                timeout: 6,
            )
            completion(result)
        }
    }

    func runNativeSolidRed(completion: @escaping (NativeActionResult) -> Void) {
        runNativeSolidRed(attempt: 0, completion: completion)
    }

    private func runNativeSolidRed(attempt: Int, completion: @escaping (NativeActionResult) -> Void) {
        if ditooLightPeripheral != nil, ditooLightWriteCharacteristic != nil {
            AppLog.write("runNativeSolidRed using BLE transport")
            runNativeBLESolidRed(completion: completion)
            return
        }

        if CBManager.authorization == .allowedAlways,
           ditooLightPeripheral != nil,
           ditooLightWriteCharacteristic == nil,
           attempt < 8 {
            AppLog.write("runNativeSolidRed waiting for BLE transport attempt=\(attempt) state=\(ditooLightState)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.runNativeSolidRed(attempt: attempt + 1, completion: completion)
            }
            return
        }

        guard CBManager.authorization == .allowedAlways else {
            let details = [
                "The Ditoo display path on this Mac is BLE-only.",
                authorizationSummary(),
                "Grant Bluetooth access to dev.kirniy.divoom.menubar in System Settings > Privacy & Security > Bluetooth.",
            ].joined(separator: "\n")
            AppLog.write("runNativeSolidRed blocked \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native solid red failed",
                    details: details,
                )
            )
            return
        }

        let details = [
            "BLE light transport not ready yet.",
            "attempt=\(attempt)",
            authorizationSummary(),
            "state=\(ditooLightState)",
        ].joined(separator: "\n")
        AppLog.write("runNativeSolidRed unavailable \(details)")
        completion(
            NativeActionResult(
                success: false,
                summary: "Native solid red failed",
                details: details,
            )
        )
    }

    func authorizationSummary() -> String {
        let authorization = CBManager.authorization
        let authText: String
        switch authorization {
        case .allowedAlways:
            authText = "allowedAlways"
        case .denied:
            authText = "denied"
        case .restricted:
            authText = "restricted"
        case .notDetermined:
            authText = "notDetermined"
        @unknown default:
            authText = "unknown"
        }

        let stateText: String
        if let centralManager {
            switch centralManager.state {
            case .poweredOn:
                stateText = "poweredOn"
            case .poweredOff:
                stateText = "poweredOff"
            case .resetting:
                stateText = "resetting"
            case .unauthorized:
                stateText = "unauthorized"
            case .unsupported:
                stateText = "unsupported"
            case .unknown:
                stateText = "unknown"
            @unknown default:
                stateText = "unknown"
            }
        } else {
            stateText = "manager-not-created"
        }

        return "Bluetooth auth=\(authText), state=\(stateText)"
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLog.write("centralManagerDidUpdateState state=\(central.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        handleCentralState()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateName = [localName, peripheral.name].compactMap { $0 }.first(where: { !$0.isEmpty })
        if let candidateName {
            discoveredLENames.insert(candidateName)
        }
        let now = Date()
        if let candidateName, candidateName.localizedCaseInsensitiveContains("Ditoo") {
            AppLog.write("didDiscover BLE Ditoo name=\(candidateName)")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastDitooLightPeripheralUUIDDefaultsKey)
            connectDitooLightIfNeeded(peripheral: peripheral, name: candidateName)
            lastLERefreshAt = now
            refreshStatus(reason: "Ditoo BLE discovered")
            return
        }

        guard now.timeIntervalSince(lastLERefreshAt) >= 2 else {
            return
        }
        lastLERefreshAt = now
        AppLog.write("didDiscover BLE peripheral name=\(candidateName ?? "<nil>")")
        refreshStatus(reason: "BLE scan progress")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastDitooLightPeripheralUUIDDefaultsKey)
        ditooLightState = "BLE light connected \(peripheral.identifier.uuidString)"
        peripheral.delegate = self
        AppLog.write("didConnect BLE peripheral name=\(peripheral.name ?? "<nil>") id=\(peripheral.identifier.uuidString)")
        peripheral.discoverServices(nil)
        refreshStatus(reason: "BLE light connected")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        ditooLightState = "BLE light connect failed: \(error?.localizedDescription ?? "unknown error")"
        AppLog.write("didFailToConnect BLE peripheral error=\(error?.localizedDescription ?? "unknown")")
        refreshStatus(reason: "BLE light connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        ditooLightWriteCharacteristic = nil
        ditooLightNotifyCharacteristic = nil
        ditooLightState = "BLE light disconnected: \(error?.localizedDescription ?? "no error")"
        AppLog.write("didDisconnect BLE peripheral error=\(error?.localizedDescription ?? "none")")
        refreshStatus(reason: "BLE light disconnected")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        if let error {
            ditooLightState = "BLE service discovery failed: \(error.localizedDescription)"
            AppLog.write("didDiscoverServices error=\(error.localizedDescription)")
            refreshStatus(reason: "BLE service discovery failed")
            return
        }

        let services = peripheral.services ?? []
        AppLog.write("didDiscoverServices count=\(services.count)")
        ditooLightState = "BLE services discovered: \(services.count)"
        for service in services {
            AppLog.write("BLE service uuid=\(service.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
        refreshStatus(reason: "BLE services discovered")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        if let error {
            AppLog.write("didDiscoverCharacteristics error service=\(service.uuid.uuidString) error=\(error.localizedDescription)")
            ditooLightState = "BLE characteristic discovery failed: \(error.localizedDescription)"
            refreshStatus(reason: "BLE characteristic discovery failed")
            return
        }

        let characteristics = service.characteristics ?? []
        AppLog.write("didDiscoverCharacteristics service=\(service.uuid.uuidString) count=\(characteristics.count)")
        for characteristic in characteristics {
            AppLog.write("BLE characteristic uuid=\(characteristic.uuid.uuidString) properties=\(characteristic.properties.rawValue)")
            if isPreferredWriteCharacteristic(characteristic) {
                if shouldReplaceWriteCharacteristic(current: ditooLightWriteCharacteristic, candidate: characteristic) {
                    ditooLightWriteCharacteristic = characteristic
                    ditooLightState = "BLE light write characteristic ready \(characteristic.uuid.uuidString)"
                    refreshStatus(reason: "BLE light write characteristic ready")
                }
            }
            if isPreferredNotifyCharacteristic(characteristic) {
                if shouldReplaceNotifyCharacteristic(current: ditooLightNotifyCharacteristic, candidate: characteristic) {
                    ditooLightNotifyCharacteristic = characteristic
                    ditooLightState = "BLE light notify characteristic ready \(characteristic.uuid.uuidString)"
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                    refreshStatus(reason: "BLE light notify characteristic ready")
                }
            }
        }

    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        AppLog.write(
            "didUpdateNotificationState uuid=\(characteristic.uuid.uuidString) notifying=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")"
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == ditooLightPeripheral?.identifier else {
            return
        }
        if let error {
            AppLog.write("didUpdateValue error uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        let value = characteristic.value ?? Data()
        AppLog.write("didUpdateValue uuid=\(characteristic.uuid.uuidString) rx=\(hexString(value))")
    }

    func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry) {
        lastInquiryStatus = "Classic inquiry started"
        AppLog.write("deviceInquiryStarted")
        refreshStatus(reason: "Classic inquiry started")
    }

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        recordInquiryDevice(device)
    }

    func deviceInquiryDeviceNameUpdated(
        _ sender: IOBluetoothDeviceInquiry,
        device: IOBluetoothDevice,
        devicesRemaining: UInt32
    ) {
        recordInquiryDevice(device)
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) {
        lastInquiryStatus = String(format: "Classic inquiry complete status=0x%08x aborted=%d", error, aborted)
        inquiry = nil
        AppLog.write("deviceInquiryComplete status=\(String(format: "0x%08x", error)) aborted=\(aborted)")
        refreshStatus(reason: "Classic inquiry finished")
    }

    func runNativeBLESolidRed(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLESolidColor(
            red: 0xff,
            green: 0x00,
            blue: 0x00,
            brightness: 0x64,
            threeModeType: 0x00,
            completion: completion
        )
    }

    func runNativeBLEPurityRed(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEPurityColor(
            red: 0xff,
            green: 0x00,
            blue: 0x00,
            completion: completion
        )
    }

    func runNativeBLESolidColor(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        brightness: UInt8,
        threeModeType: UInt8,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = [
                "BLE light transport not ready.",
                authorizationSummary(),
                "State: \(ditooLightState)",
            ].joined(separator: "\n")
            AppLog.write("runNativeBLESolidColor unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE solid color failed",
                    details: details
                )
            )
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        let packetSequence = buildVendorColorLightPacketSequence(
            characteristic: characteristic,
            red: red,
            green: green,
            blue: blue,
            brightness: brightness,
            threeModeType: threeModeType
        )
        let packetHex = packetSequence.map(hexString)

        AppLog.write(
            "runNativeBLESolidColor peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) packets=\(packetSequence.count) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse") threeModeType=\(threeModeType) tx=\(packetHex.joined(separator: ","))"
        )

        writeBLEPackets(
            packetSequence,
            packetIndex: 0,
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType
        ) {
            let details = [
                "peripheral=\(peripheral.identifier.uuidString)",
                "characteristic=\(characteristic.uuid.uuidString)",
                "writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
                "packets=\(packetSequence.count)",
                "red=\(red)",
                "green=\(green)",
                "blue=\(blue)",
                "brightness=\(brightness)",
                "threeModeType=\(threeModeType)",
                "tx=\(packetHex.joined(separator: "\n"))",
            ].joined(separator: "\n")
            completion(
                NativeActionResult(
                    success: true,
                    summary: "Native BLE solid color sent",
                    details: details
                )
            )
        }
    }

    func runNativeBLEPurityColor(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = [
                "BLE light transport not ready.",
                authorizationSummary(),
                "State: \(ditooLightState)",
            ].joined(separator: "\n")
            AppLog.write("runNativeBLEPurityColor unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE purity color failed",
                    details: details
                )
            )
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        let payload = Data([red, green, blue])
        let (packet, packetMode) = buildBLETransportPacket(
            characteristic: characteristic,
            command: 0x6f,
            payload: payload
        )
        let packetHex = hexString(packet)

        AppLog.write(
            "runNativeBLEPurityColor peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) packetMode=\(packetMode) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse") tx=\(packetHex)"
        )

        writeBLEPackets(
            [packet],
            packetIndex: 0,
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType
        ) {
            let details = [
                "peripheral=\(peripheral.identifier.uuidString)",
                "characteristic=\(characteristic.uuid.uuidString)",
                "packetMode=\(packetMode)",
                "writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
                "red=\(red)",
                "green=\(green)",
                "blue=\(blue)",
                "tx=\(packetHex)",
            ].joined(separator: "\n")
            completion(
                NativeActionResult(
                    success: true,
                    summary: "Native BLE purity color sent",
                    details: details
                )
            )
        }
    }

    func runNativeBLEAnimationSample(completion: @escaping (NativeActionResult) -> Void) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = "BLE light transport not ready. State: \(ditooLightState)"
            AppLog.write("runNativeBLEAnimationSample unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE animation sample failed",
                    details: details
                )
            )
            return
        }

        let characteristics = {
            let discovered = availableWriteCharacteristics(for: peripheral)
            if discovered.isEmpty {
                return [characteristic]
            }
            return discovered
        }()

        let encodedBody = buildPublicStaticImageCommandBody(colors: buildPublicCheckerboardTestImage())
        let variants = buildDrawingCommandMatrixVariants(encodedBody: encodedBody, mode: 0x00)

        func sendVariant(characteristicIndex: Int, variantIndex: Int, details: [String]) {
            guard characteristicIndex < characteristics.count else {
                completion(
                    NativeActionResult(
                        success: true,
                        summary: "Native BLE drawing matrix sent",
                        details: details.joined(separator: "\n")
                    )
                )
                return
            }

            let currentCharacteristic = characteristics[characteristicIndex]

            guard variantIndex < variants.count else {
                sendVariant(characteristicIndex: characteristicIndex + 1, variantIndex: 0, details: details)
                return
            }

            let variant = variants[variantIndex]
            let packetSequence = variant.packets
            let writeType = preferredBLEWriteType(for: currentCharacteristic)
            let packetHex = packetSequence.map(hexString)
            AppLog.write(
                "runNativeBLEAnimationSample peripheral=\(peripheral.identifier.uuidString) characteristic=\(currentCharacteristic.uuid.uuidString) variant=\(variant.label) packets=\(packetSequence.count) encodedBodyBytes=\(encodedBody.count) tx=\(packetHex.joined(separator: ","))"
            )

            writeBLEPackets(
                packetSequence,
                packetIndex: 0,
                peripheral: peripheral,
                characteristic: currentCharacteristic,
                writeType: writeType
            ) {
                let currentDetails = details + [
                    "characteristic[\(characteristicIndex)]=\(currentCharacteristic.uuid.uuidString)",
                    "variant[\(characteristicIndex):\(variantIndex)]=\(variant.label)",
                    "writeType[\(characteristicIndex):\(variantIndex)]=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
                    "packets[\(characteristicIndex):\(variantIndex)]=\(packetSequence.count)",
                ]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    sendVariant(characteristicIndex: characteristicIndex, variantIndex: variantIndex + 1, details: currentDetails)
                }
            }
        }

        let initialDetails = [
            "peripheral=\(peripheral.identifier.uuidString)",
            "pattern=public-checkerboard-x",
            "encodedBodyBytes=\(encodedBody.count)",
            "variants=\(variants.map(\.label).joined(separator: ","))",
            "characteristics=\(characteristics.map { $0.uuid.uuidString }.joined(separator: ","))",
        ]
        sendVariant(characteristicIndex: 0, variantIndex: 0, details: initialDetails)
    }

    func runNativeBLEPixelBadgeTest(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEStaticImage(
            colors: buildPublicPixelBadgeTestImage(),
            label: "pixel-badge-test",
            completion: completion
        )
    }

    private func runNativeBLEStaticImage(
        colors: [RGBColor],
        label: String,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = "BLE light transport not ready. State: \(ditooLightState)"
            AppLog.write("runNativeBLEStaticImage unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE static image failed",
                    details: details
                )
            )
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        let imagePayload = buildPublicStaticImageCommandBody(colors: colors)
        let (brightnessPacket, brightnessMode) = buildBLETransportPacket(
            characteristic: characteristic,
            command: 0x74,
            payload: Data([0x64])
        )
        let (imagePacket, imageMode) = buildBLETransportPacket(
            characteristic: characteristic,
            command: 0x44,
            payload: imagePayload
        )
        let packets = [brightnessPacket, imagePacket]
        let packetHex = packets.map(hexString)

        AppLog.write(
            "runNativeBLEStaticImage label=\(label) peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) packets=\(packets.count) imageBytes=\(imagePayload.count) brightnessMode=\(brightnessMode) imageMode=\(imageMode) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse") tx=\(packetHex.joined(separator: ","))"
        )

        writeBLEPackets(
            packets,
            packetIndex: 0,
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType
        ) {
            let details = [
                "label=\(label)",
                "peripheral=\(peripheral.identifier.uuidString)",
                "characteristic=\(characteristic.uuid.uuidString)",
                "brightnessMode=\(brightnessMode)",
                "imageMode=\(imageMode)",
                "writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
                "imageBytes=\(imagePayload.count)",
                "tx=\(packetHex.joined(separator: ","))",
            ].joined(separator: "\n")
            completion(
                NativeActionResult(
                    success: true,
                    summary: "Native BLE static image sent",
                    details: details
                )
            )
        }
    }

    private func handleCentralState() {
        guard let centralManager else {
            AppLog.write("handleCentralState missing manager")
            refreshStatus(reason: "Bluetooth manager missing")
            return
        }

        guard CBManager.authorization == .allowedAlways else {
            AppLog.write("handleCentralState auth not allowed: \(CBManager.authorization.rawValue)")
            refreshStatus(reason: "Bluetooth access not granted yet")
            return
        }

        switch centralManager.state {
        case .poweredOn:
            startLEScan()
            startClassicInquiry()
            refreshStatus(reason: "Bluetooth powered on")
        case .poweredOff:
            refreshStatus(reason: "Bluetooth is powered off")
        case .unauthorized:
            refreshStatus(reason: "Bluetooth access denied")
        case .unsupported:
            refreshStatus(reason: "Bluetooth unsupported")
        case .resetting:
            refreshStatus(reason: "Bluetooth resetting")
        case .unknown:
            refreshStatus(reason: "Bluetooth state unknown")
        @unknown default:
            refreshStatus(reason: "Bluetooth state unknown")
        }
    }

    private func startLEScan() {
        guard let centralManager, centralManager.state == .poweredOn else {
            return
        }
        centralManager.stopScan()
        discoveredLENames.removeAll()
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [ditooLightServiceUUID])
        for peripheral in connectedPeripherals {
            AppLog.write("retrieveConnectedPeripherals id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "<nil>")")
            adoptRetrievedDitooLight(peripheral: peripheral)
        }
        if let cachedPeripheral = retrieveCachedDitooLight(using: centralManager) {
            AppLog.write("retrievePeripherals cached id=\(cachedPeripheral.identifier.uuidString) name=\(cachedPeripheral.name ?? "<nil>")")
            adoptRetrievedDitooLight(peripheral: cachedPeripheral)
        }
        centralManager.scanForPeripherals(withServices: nil, options: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let centralManager = self.centralManager else { return }
            centralManager.stopScan()
            self.refreshStatus(reason: "BLE scan finished")
        }
    }

    private func startClassicInquiry() {
        inquiry?.stop()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else {
            lastInquiryStatus = "Classic inquiry could not be created"
            refreshStatus(reason: "Classic inquiry unavailable")
            return
        }
        inquiry.searchType = kIOBluetoothDeviceSearchClassic.rawValue
        inquiry.inquiryLength = 8
        inquiry.updateNewDeviceNames = true
        inquiryCandidatesByAddress.removeAll()
        inquiryDevicesByAddress.removeAll()
        let status = inquiry.start()
        self.inquiry = inquiry
        lastInquiryStatus = String(format: "Classic inquiry start status=0x%08x", status)
        refreshStatus(reason: "Classic inquiry requested")
    }

    private func connectDitooLightIfNeeded(peripheral: CBPeripheral, name: String) {
        guard name.localizedCaseInsensitiveContains("DitooPro-Light") else {
            return
        }
        adoptDitooLightPeripheral(peripheral: peripheral, name: name)
    }

    private func adoptRetrievedDitooLight(peripheral: CBPeripheral) {
        let name = peripheral.name ?? "DitooPro-Light"
        adoptDitooLightPeripheral(peripheral: peripheral, name: name)
    }

    private func retrieveCachedDitooLight(using centralManager: CBCentralManager) -> CBPeripheral? {
        guard
            let uuidString = UserDefaults.standard.string(forKey: lastDitooLightPeripheralUUIDDefaultsKey),
            let uuid = UUID(uuidString: uuidString)
        else {
            return nil
        }
        return centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
    }

    private func adoptDitooLightPeripheral(peripheral: CBPeripheral, name: String) {
        guard let centralManager else {
            return
        }

        if ditooLightPeripheral?.identifier != peripheral.identifier {
            ditooLightPeripheral = peripheral
            ditooLightWriteCharacteristic = nil
            ditooLightNotifyCharacteristic = nil
            ditooLightState = "BLE light discovered \(peripheral.identifier.uuidString)"
            AppLog.write("connectDitooLightIfNeeded discovered id=\(peripheral.identifier.uuidString)")
        }

        switch peripheral.state {
        case .connected:
            if peripheral.delegate == nil {
                peripheral.delegate = self
            }
            if peripheral.services == nil {
                peripheral.discoverServices(nil)
            }
        case .connecting:
            ditooLightState = "BLE light connecting \(peripheral.identifier.uuidString)"
        case .disconnected, .disconnecting:
            ditooLightState = "BLE light connecting \(peripheral.identifier.uuidString)"
            centralManager.connect(peripheral)
            AppLog.write("central.connect BLE light id=\(peripheral.identifier.uuidString)")
        @unknown default:
            ditooLightState = "BLE light state unknown \(peripheral.identifier.uuidString)"
        }
    }

    private func recordInquiryDevice(_ device: IOBluetoothDevice) {
        let name = device.nameOrAddress ?? device.name ?? ""
        let address = normalizeBluetoothAddress(device.addressString ?? "")
        guard !name.isEmpty, !address.isEmpty else {
            return
        }
        inquiryDevicesByAddress[address] = device
        if name.localizedCaseInsensitiveContains("Ditoo") {
            inquiryCandidatesByAddress[address] = DitooCandidate(
                name: name,
                address: address,
                connected: device.isConnected(),
                source: "classic-inquiry",
            )
            AppLog.write("recordInquiryDevice ditoo name=\(name) address=\(address) connected=\(device.isConnected())")
        }
        refreshStatus(reason: "Classic device found")
    }

    private func pairedCandidates() -> [DitooCandidate] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap { device in
            let name = device.nameOrAddress ?? device.name ?? ""
            let address = device.addressString ?? ""
            guard name.localizedCaseInsensitiveContains("Ditoo"), !address.isEmpty else {
                return nil
            }
            return DitooCandidate(
                name: name,
                address: normalizeBluetoothAddress(address),
                connected: device.isConnected(),
                source: "paired-api",
            )
        }
    }

    private func inquiryCandidates() -> [DitooCandidate] {
        inquiryCandidatesByAddress.values.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.address < rhs.address
        }
    }

    private func systemProfilerCandidates() -> [DitooCandidate] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard !output.isEmpty else {
            return []
        }

        var results: [DitooCandidate] = []
        var currentName: String?
        var currentConnected = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed == "Connected:" {
                currentConnected = true
                currentName = nil
                continue
            }

            if trimmed == "Not Connected:" {
                currentConnected = false
                currentName = nil
                continue
            }

            if raw.hasPrefix("          "), trimmed.hasSuffix(":"), trimmed != "Connected:", trimmed != "Not Connected:" {
                currentName = String(trimmed.dropLast())
                continue
            }

            if let currentNameValue = currentName, trimmed.hasPrefix("Address: ") {
                let address = normalizeBluetoothAddress(String(trimmed.dropFirst("Address: ".count)))
                if currentNameValue.localizedCaseInsensitiveContains("Ditoo") {
                    results.append(
                        DitooCandidate(
                            name: currentNameValue,
                            address: address,
                            connected: currentConnected,
                            source: "system_profiler",
                        )
                    )
                }
                currentName = nil
            }
        }

        return results
    }

    private func preferredCandidate() -> DitooCandidate? {
        let merged = (inquiryCandidates() + pairedCandidates() + systemProfilerCandidates())
            .reduce(into: [String: DitooCandidate]()) { partial, candidate in
                let key = normalizeBluetoothAddress(candidate.address)
                if partial[key] == nil {
                    partial[key] = candidate
                }
            }
            .values
            .sorted { lhs, rhs in
                let lhsLight = lhs.name.localizedCaseInsensitiveContains("Light")
                let rhsLight = rhs.name.localizedCaseInsensitiveContains("Light")
                if lhsLight != rhsLight {
                    return lhsLight && !rhsLight
                }
                if lhs.connected != rhs.connected {
                    return lhs.connected && !rhs.connected
                }
                if lhs.source != rhs.source {
                    return lhs.source < rhs.source
                }
                return lhs.address < rhs.address
            }
        let candidate = merged.first
        if let candidate {
            AppLog.write("preferredCandidate name=\(candidate.name) address=\(candidate.address) source=\(candidate.source) connected=\(candidate.connected)")
        } else {
            AppLog.write("preferredCandidate none")
        }
        return candidate
    }

    private func notifyStatus(summary: String, details: String?) {
        DispatchQueue.main.async {
            AppLog.write("notifyStatus summary=\(summary)")
            self.statusHandler?(summary, details)
        }
    }

    private func maximumBLEWriteLength(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType
    ) -> Int {
        let _ = peripheral
        let _ = writeType
        if characteristic.uuid == ditooLightLEWriteCharacteristicUUID
            || characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
        {
            // The vendor app uses 20-byte ATT chunks on the Ditoo light transport.
            return 20
        }
        return max(20, peripheral.maximumWriteValueLength(for: writeType))
    }

    private func writeTypeForBLEChunk(
        characteristic: CBCharacteristic,
        packetIndex: Int,
        chunkIndex: Int,
        defaultWriteType: CBCharacteristicWriteType
    ) -> CBCharacteristicWriteType {
        let _ = packetIndex
        let _ = chunkIndex
        if characteristic.uuid == ditooLightLEWriteCharacteristicUUID {
            if characteristic.properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
            if characteristic.properties.contains(.write) {
                return .withResponse
            }
        }
        if characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID || characteristic.uuid == ditooLightAca3CharacteristicUUID {
            if characteristic.properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
            if characteristic.properties.contains(.write) {
                return .withResponse
            }
        }
        return defaultWriteType
    }

    private func bleChunkDelay(characteristic: CBCharacteristic, writeType: CBCharacteristicWriteType) -> TimeInterval {
        if characteristic.uuid == ditooLightLEWriteCharacteristicUUID
            || characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
        {
            return writeType == .withResponse ? 0.12 : 0.04
        }
        return writeType == .withResponse ? 0.20 : 0.08
    }

    private func blePacketDelay(characteristic: CBCharacteristic) -> TimeInterval {
        if characteristic.uuid == ditooLightLEWriteCharacteristicUUID
            || characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
        {
            return 0.05
        }
        return 0.20
    }

    private func isPreferredWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        let properties = characteristic.properties
        let canWrite = properties.contains(.write) || properties.contains(.writeWithoutResponse)
        guard canWrite else {
            return false
        }
        return characteristic.uuid == ditooLightLEWriteCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
    }

    private func availableWriteCharacteristics(for peripheral: CBPeripheral) -> [CBCharacteristic] {
        let discovered = (peripheral.services ?? [])
            .flatMap { $0.characteristics ?? [] }
            .filter { isPreferredWriteCharacteristic($0) }

        var seen = Set<String>()
        return discovered
            .sorted { writeCharacteristicRank($0) < writeCharacteristicRank($1) }
            .filter { characteristic in
                let key = characteristic.uuid.uuidString
                if seen.contains(key) {
                    return false
                }
                seen.insert(key)
                return true
            }
    }

    private func isPreferredNotifyCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        let canNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
        guard canNotify else {
            return false
        }
        return characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID
            || characteristic.uuid == ditooLightLEReadCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
    }

    private func writeCharacteristicRank(_ characteristic: CBCharacteristic) -> Int {
        switch characteristic.uuid {
        case ditooLightLEWriteCharacteristicUUID:
            return 0
        case ditooLightAca3CharacteristicUUID:
            return 1
        default:
            return 10
        }
    }

    private func notifyCharacteristicRank(_ characteristic: CBCharacteristic) -> Int {
        switch characteristic.uuid {
        case ditooLightLegacyWriteCharacteristicUUID:
            return 0
        case ditooLightLEReadCharacteristicUUID:
            return 1
        case ditooLightAca3CharacteristicUUID:
            return 2
        default:
            return 10
        }
    }

    private func shouldReplaceWriteCharacteristic(current: CBCharacteristic?, candidate: CBCharacteristic) -> Bool {
        guard let current else {
            return true
        }
        return writeCharacteristicRank(candidate) < writeCharacteristicRank(current)
    }

    private func shouldReplaceNotifyCharacteristic(current: CBCharacteristic?, candidate: CBCharacteristic) -> Bool {
        guard let current else {
            return true
        }
        return notifyCharacteristicRank(candidate) < notifyCharacteristicRank(current)
    }

    private func buildBLETransportPacket(characteristic: CBCharacteristic, command: UInt8, payload: Data) -> (Data, String) {
        // The reversed iOS app chooses old vs new mode from device capabilities
        // (`blueEnum` / `newAniSendMode2020`), not from the command itself.
        // For the Ditoo Pro path we prefer the main 8841 LE write characteristic,
        // and Android device tables place DitooPro in the vendor's new animation
        // send mode family. Keep legacy characteristics on old-mode escaped frames.
        if characteristic.uuid == ditooLightLEWriteCharacteristicUUID {
            return (buildNewModeLECommandPacket(command: command, payload: payload), "new-mode")
        }
        if characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID
            || characteristic.uuid == ditooLightAca3CharacteristicUUID
        {
            return (buildOldModeDivoomPacket(command: command, payload: payload), "old-mode-escaped")
        }
        return (buildOldModeDivoomPacket(command: command, payload: payload), "legacy-old-mode")
    }

    private func writeBLEChunks(
        _ chunks: [Data],
        index: Int,
        packetIndex: Int,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        defaultWriteType: CBCharacteristicWriteType,
        completion: @escaping () -> Void
    ) {
        guard index < chunks.count else {
            completion()
            return
        }

        let chunk = chunks[index]
        let chunkWriteType = writeTypeForBLEChunk(
            characteristic: characteristic,
            packetIndex: packetIndex,
            chunkIndex: index,
            defaultWriteType: defaultWriteType
        )
        peripheral.writeValue(chunk, for: characteristic, type: chunkWriteType)
        AppLog.write(
            "writeBLEChunk packetIndex=\(packetIndex) index=\(index) bytes=\(chunk.count) writeType=\(chunkWriteType == .withoutResponse ? "withoutResponse" : "withResponse") tx=\(hexString(chunk))"
        )

        let delay = bleChunkDelay(characteristic: characteristic, writeType: chunkWriteType)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self != nil else { return }
            self?.writeBLEChunks(
                chunks,
                index: index + 1,
                packetIndex: packetIndex,
                peripheral: peripheral,
                characteristic: characteristic,
                defaultWriteType: defaultWriteType,
                completion: completion
            )
        }
    }

    private func writeBLEPackets(
        _ packets: [Data],
        packetIndex: Int,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        completion: @escaping () -> Void
    ) {
        guard packetIndex < packets.count else {
            completion()
            return
        }

        let packet = packets[packetIndex]
        let chunks = chunked(
            packet,
            size: maximumBLEWriteLength(
                peripheral: peripheral,
                characteristic: characteristic,
                writeType: writeType
            )
        )
        AppLog.write("writeBLEPacket packetIndex=\(packetIndex) packetBytes=\(packet.count) chunks=\(chunks.count) tx=\(hexString(packet))")
        writeBLEChunks(
            chunks,
            index: 0,
            packetIndex: packetIndex,
            peripheral: peripheral,
            characteristic: characteristic,
            defaultWriteType: writeType
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.blePacketDelay(characteristic: characteristic)) {
                self.writeBLEPackets(
                    packets,
                    packetIndex: packetIndex + 1,
                    peripheral: peripheral,
                    characteristic: characteristic,
                    writeType: writeType,
                    completion: completion
                )
            }
        }
    }
}

private final class SDPQueryDelegate: NSObject, IOBluetoothDeviceAsyncCallbacks {
    private(set) var status: IOReturn?

    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        self.status = status
    }
}

private final class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private(set) var incoming = Data()
    private(set) var openStatus: IOReturn?

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else {
            return
        }
        let bytes = dataPointer.bindMemory(to: UInt8.self, capacity: dataLength)
        incoming.append(bytes, count: dataLength)
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        openStatus = error
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {}

    func rfcommChannelWriteComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn,
        bytesWritten length: Int
    ) {}

    func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}

private struct Response {
    let originalCommand: UInt8
    let ack: Bool
    let data: Data
}

private enum NativeBluetoothError: Error, CustomStringConvertible {
    case bluetooth(String)
    case parse(String)
    case timeout(String)

    var description: String {
        switch self {
        case .bluetooth(let message), .parse(let message), .timeout(let message):
            return message
        }
    }
}

private enum DitooRFCOMMClient {
    static func run(
        candidate: DitooCandidate,
        cachedDevice: IOBluetoothDevice?,
        command: UInt8,
        payload: Data,
        expectResponse: Bool,
        timeout: TimeInterval
    ) -> NativeActionResult {
        do {
            AppLog.write("DitooRFCOMMClient.run command=0x\(String(format: "%02x", command)) payload=\(hexString(payload)) expectResponse=\(expectResponse)")
            let device = try resolveDevice(candidate: candidate, cachedDevice: cachedDevice)
            let connectionStatus = device.openConnection()
            AppLog.write("DitooRFCOMMClient.openConnection address=\(candidate.address) connected=\(device.isConnected()) status=\(String(format: "0x%08x", connectionStatus))")
            try performSDPQueryIfPossible(device: device, timeout: timeout)
            let channelIDs = channelCandidates(from: device.services)
            let packet = buildPacket(command: command, payload: payload)
            var lastError: NativeBluetoothError?

            for channelID in (channelIDs.isEmpty ? [2] : channelIDs) {
                let delegate = RFCOMMDelegate()
                var channel: IOBluetoothRFCOMMChannel?
                let openStatus = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate)
                AppLog.write("DitooRFCOMMClient.openRFCOMMChannelSync address=\(candidate.address) channel=\(channelID) status=\(String(format: "0x%08x", openStatus))")
                guard openStatus == kIOReturnSuccess, let channel else {
                    lastError = NativeBluetoothError.bluetooth(
                        String(
                            format: "openRFCOMMChannelSync address=%@ channel=%d status=0x%08x",
                            candidate.address,
                            channelID,
                            openStatus
                        )
                    )
                    continue
                }
                defer {
                    _ = channel.close()
                }

                var bytes = [UInt8](packet)
                let writeStatus = channel.writeSync(&bytes, length: UInt16(bytes.count))
                guard writeStatus == kIOReturnSuccess else {
                    lastError = NativeBluetoothError.bluetooth(String(format: "writeSync failed channel=%d status=0x%08x", channelID, writeStatus))
                    continue
                }

                var details = [
                    "candidate=\(candidate.name)@\(candidate.address) [\(candidate.source)\(candidate.connected ? ",connected" : "")]",
                    String(format: "channel=%d command=0x%02x", channelID, command),
                    "tx=\(hexString(packet))",
                ]

                if expectResponse {
                    guard let frame = waitForFrame(delegate: delegate, timeout: timeout) else {
                        lastError = NativeBluetoothError.timeout("no response received after \(timeout)s on channel \(channelID)")
                        continue
                    }
                    let parsed = try parseResponse(frame)
                    details.append("rx=\(hexString(frame))")
                    details.append("ack=\(parsed.ack)")
                    details.append(String(format: "responseCommand=0x%02x", parsed.originalCommand))
                    details.append("responseData=\(hexString(parsed.data))")
                }

                AppLog.write("DitooRFCOMMClient success\n\(details.joined(separator: "\n"))")
                return NativeActionResult(
                    success: true,
                    summary: "Native RFCOMM action succeeded",
                    details: details.joined(separator: "\n"),
                )
            }

            throw lastError ?? NativeBluetoothError.bluetooth("no RFCOMM channel candidates")
        } catch {
            AppLog.write("DitooRFCOMMClient failure \(error)")
            return NativeActionResult(
                success: false,
                summary: "Native RFCOMM action failed",
                details: "\(error)",
            )
        }
    }

    private static func resolveDevice(candidate: DitooCandidate, cachedDevice: IOBluetoothDevice?) throws -> IOBluetoothDevice {
        if let cachedDevice {
            AppLog.write("resolveDevice using cached device address=\(candidate.address)")
            return cachedDevice
        }

        if let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            if let paired = pairedDevices.first(where: { normalizeBluetoothAddress($0.addressString ?? "") == normalizeBluetoothAddress(candidate.address) }) {
                AppLog.write("resolveDevice using paired device address=\(candidate.address) paired=\(paired.isPaired()) connected=\(paired.isConnected())")
                return paired
            }
        }

        guard let device = IOBluetoothDevice(addressString: candidate.address)
            ?? IOBluetoothDevice(addressString: candidate.address.replacingOccurrences(of: ":", with: "-")) else {
            throw NativeBluetoothError.bluetooth("could not create IOBluetoothDevice for \(candidate.address)")
        }
        AppLog.write("resolveDevice created addressString device address=\(candidate.address) paired=\(device.isPaired()) connected=\(device.isConnected())")
        return device
    }

    private static func performSDPQueryIfPossible(device: IOBluetoothDevice, timeout: TimeInterval) throws {
        let delegate = SDPQueryDelegate()
        let status = device.performSDPQuery(delegate)
        AppLog.write("performSDPQuery status=\(String(format: "0x%08x", status)) address=\(device.addressString ?? "<nil>")")
        guard status == kIOReturnSuccess else {
            return
        }

        let completed = runLoopUntil(timeout: timeout) { delegate.status != nil }
        guard completed, let sdpStatus = delegate.status else {
            throw NativeBluetoothError.timeout("SDP query timed out after \(timeout)s")
        }

        guard sdpStatus == kIOReturnSuccess else {
            throw NativeBluetoothError.bluetooth(String(format: "SDP query failed: 0x%08x", sdpStatus))
        }
        let serviceDescriptions = (device.services as? [IOBluetoothSDPServiceRecord] ?? []).map { service -> String in
            var channelID: BluetoothRFCOMMChannelID = 0
            let name = service.getServiceName() ?? "<unnamed>"
            if service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
                return "\(name)#\(channelID)"
            }
            return "\(name)#-"
        }
        AppLog.write("performSDPQuery completed services=\(device.services?.count ?? 0) list=\(serviceDescriptions.joined(separator: ", "))")
    }

    private static func channelCandidates(from servicesAny: [Any]?) -> [BluetoothRFCOMMChannelID] {
        guard let services = servicesAny as? [IOBluetoothSDPServiceRecord] else {
            return []
        }

        var preferred: [BluetoothRFCOMMChannelID] = []
        var others: [BluetoothRFCOMMChannelID] = []
        var seen = Set<Int>()
        for service in services {
            var channelID: BluetoothRFCOMMChannelID = 0
            guard service.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
                continue
            }
            guard seen.insert(Int(channelID)).inserted else {
                continue
            }
            let name = service.getServiceName() ?? ""
            if name.localizedCaseInsensitiveContains("Serial") || name.localizedCaseInsensitiveContains("RFCOMM") {
                preferred.append(channelID)
            } else {
                others.append(channelID)
            }
        }
        return preferred + others
    }

    private static func waitForFrame(delegate: RFCOMMDelegate, timeout: TimeInterval) -> Data? {
        let received = runLoopUntil(timeout: timeout) {
            if delegate.incoming.count < 3 {
                return false
            }
            let payloadLength = Int(UInt16(delegate.incoming[1]) | (UInt16(delegate.incoming[2]) << 8))
            return delegate.incoming.count >= payloadLength + 4
        }
        guard received, delegate.incoming.count >= 3 else {
            return nil
        }
        let payloadLength = Int(UInt16(delegate.incoming[1]) | (UInt16(delegate.incoming[2]) << 8))
        let frameLength = payloadLength + 4
        guard delegate.incoming.count >= frameLength else {
            return nil
        }
        return Data(delegate.incoming.prefix(frameLength))
    }

    private static func buildPacket(command: UInt8, payload: Data = Data()) -> Data {
        buildDivoomPacket(command: command, payload: payload)
    }

    private static func parseResponse(_ raw: Data) throws -> Response {
        guard raw.count >= 7 else {
            throw NativeBluetoothError.parse("response too short: \(hexString(raw))")
        }
        guard raw.first == 0x01, raw.last == 0x02 else {
            throw NativeBluetoothError.parse("bad response framing: \(hexString(raw))")
        }
        guard raw[3] == 0x04 else {
            throw NativeBluetoothError.parse(String(format: "unexpected response command 0x%02x", raw[3]))
        }
        return Response(
            originalCommand: raw[4],
            ack: raw[5] == 0x55,
            data: raw.subdata(in: 6..<(raw.count - 3))
        )
    }

    private static func runLoopUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

private func buildAnimationUploadPacketSequence(
    animation: Data,
    packetBuilder: (UInt8, Data) -> Data
) -> [Data] {
    var packets: [Data] = []
    let totalSize = UInt32(animation.count)

    var startPayload = Data([0x00])
    startPayload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
    packets.append(packetBuilder(0x8B, startPayload))

    for (offset, chunkStart) in stride(from: 0, to: animation.count, by: 256).enumerated() {
        let chunk = animation[chunkStart..<min(chunkStart + 256, animation.count)]
        var payload = Data([0x01])
        payload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        let offsetID = UInt16(offset).littleEndian
        payload.append(contentsOf: withUnsafeBytes(of: offsetID, Array.init))
        payload.append(chunk)
        packets.append(packetBuilder(0x8B, payload))
    }

    packets.append(packetBuilder(0x8B, Data([0x02])))
    packets.append(packetBuilder(0x45, Data([0x05])))
    packets.append(packetBuilder(0xBD, Data([0x17, 0x00])))
    return packets
}

private func buildModernVendorAnimationPacketSequence(animation: Data) -> [Data] {
    var packets: [Data] = []
    let totalSize = UInt32(animation.count)

    packets.append(buildDivoomPacket(command: 0xBD, payload: Data([0x31])))

    var startPayload = Data([0x00])
    startPayload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
    packets.append(buildDivoomPacket(command: 0x8B, payload: startPayload))

    for (offset, chunkStart) in stride(from: 0, to: animation.count, by: 256).enumerated() {
        let chunk = animation[chunkStart..<min(chunkStart + 256, animation.count)]
        var payload = Data([0x01])
        payload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        let offsetID = UInt16(offset).littleEndian
        payload.append(contentsOf: withUnsafeBytes(of: offsetID, Array.init))
        payload.append(chunk)
        packets.append(buildDivoomPacket(command: 0x8B, payload: payload))
    }

    return packets
}

private struct DrawingCommandVariant {
    let label: String
    let packets: [Data]
}

private func buildDrawingEncodePicturePacket(
    encodedBody: Data,
    mode: UInt8,
    packetBuilder: (UInt8, Data) -> Data
) -> Data {
    let payloadLength = UInt16(encodedBody.count).littleEndian
    var payload = Data([mode])
    payload.append(contentsOf: withUnsafeBytes(of: payloadLength, Array.init))
    payload.append(encodedBody)
    return packetBuilder(0x5B, payload)
}

private func buildDrawingEncodePlayPacketSequence(
    encodedBody: Data,
    mode: UInt8,
    packetBuilder: (UInt8, Data) -> Data
) -> [Data] {
    let chunkSize = 200
    let payloadLength = UInt16(encodedBody.count).littleEndian
    var packets: [Data] = []

    for packetIndex in 0..<Int(ceil(Double(encodedBody.count) / Double(chunkSize))) {
        let chunkStart = packetIndex * chunkSize
        let chunkEnd = min(chunkStart + chunkSize, encodedBody.count)
        let chunk = encodedBody[chunkStart..<chunkEnd]
        var payload = Data([mode])
        payload.append(contentsOf: withUnsafeBytes(of: payloadLength, Array.init))
        payload.append(UInt8(packetIndex & 0xff))
        payload.append(chunk)
        packets.append(packetBuilder(0x5C, payload))
    }

    return packets
}

private func buildSandPaintEncodedPacket(
    encodedBody: Data,
    mode: UInt8,
    packetBuilder: (UInt8, Data) -> Data
) -> Data {
    let payloadLength = UInt16(encodedBody.count).littleEndian
    var payload = Data([0x00, mode])
    payload.append(contentsOf: withUnsafeBytes(of: payloadLength, Array.init))
    payload.append(encodedBody)
    return packetBuilder(0x34, payload)
}

private func buildDrawingCommandMatrixVariants(encodedBody: Data, mode: UInt8) -> [DrawingCommandVariant] {
    let rawPacketBuilder: (UInt8, Data) -> Data = { command, payload in
        buildDivoomPacket(command: command, payload: payload)
    }
    let oldModePacketBuilder: (UInt8, Data) -> Data = { command, payload in
        buildOldModeDivoomPacket(command: command, payload: payload)
    }

    return [
        DrawingCommandVariant(
            label: "raw-pic-5B",
            packets: [buildDrawingEncodePicturePacket(encodedBody: encodedBody, mode: mode, packetBuilder: rawPacketBuilder)]
        ),
        DrawingCommandVariant(
            label: "raw-sand-34",
            packets: [buildSandPaintEncodedPacket(encodedBody: encodedBody, mode: mode, packetBuilder: rawPacketBuilder)]
        ),
        DrawingCommandVariant(
            label: "raw-play-5C",
            packets: buildDrawingEncodePlayPacketSequence(encodedBody: encodedBody, mode: mode, packetBuilder: rawPacketBuilder)
        ),
        DrawingCommandVariant(
            label: "old-pic-5B",
            packets: [buildDrawingEncodePicturePacket(encodedBody: encodedBody, mode: mode, packetBuilder: oldModePacketBuilder)]
        ),
        DrawingCommandVariant(
            label: "old-sand-34",
            packets: [buildSandPaintEncodedPacket(encodedBody: encodedBody, mode: mode, packetBuilder: oldModePacketBuilder)]
        ),
        DrawingCommandVariant(
            label: "old-play-5C",
            packets: buildDrawingEncodePlayPacketSequence(encodedBody: encodedBody, mode: mode, packetBuilder: oldModePacketBuilder)
        ),
    ]
}

private func buildVendorUserGIFPacketSequence(animation: Data) -> [Data] {
    let chunkSize = 200
    let totalSize = UInt16(animation.count)
    let packetCount = Int(ceil(Double(animation.count) / Double(chunkSize)))
    var packets: [Data] = []
    packets.reserveCapacity(packetCount)

    for packetIndex in 0..<packetCount {
        let chunkStart = packetIndex * chunkSize
        let chunkEnd = min(chunkStart + chunkSize, animation.count)
        let chunk = animation[chunkStart..<chunkEnd]

        var payload = Data([0x02])
        payload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        payload.append(UInt8(packetIndex & 0xff))
        payload.append(chunk)
        packets.append(buildOldModeDivoomPacket(command: 0xB1, payload: payload))
    }

    return packets
}

private func buildBLEAnimationUploadPacketSequence(animation: Data) -> [Data] {
    buildAnimationUploadPacketSequence(animation: animation, packetBuilder: buildOldModeDivoomPacket)
}

private func buildBLEAnimationUploadPacketSequence(animation: Data, characteristic: CBCharacteristic) -> [Data] {
    if characteristic.uuid == ditooLightLEWriteCharacteristicUUID || characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID {
        return buildAnimationUploadPacketSequence(animation: animation, packetBuilder: buildOldModeDivoomPacket)
    }
    return buildAnimationUploadPacketSequence(animation: animation) { command, payload in
        buildOldModeDivoomPacket(command: command, payload: payload)
    }
}

private func buildPublicBLEStaticImageTestPacketSequence(characteristic: CBCharacteristic, imagePayload: Data) -> [Data] {
    let brightnessPayload = Data([0x64])

    if characteristic.uuid == ditooLightLEWriteCharacteristicUUID || characteristic.uuid == ditooLightLegacyWriteCharacteristicUUID {
        return [
            buildOldModeDivoomPacket(command: 0x74, payload: brightnessPayload),
            buildOldModeDivoomPacket(command: 0x44, payload: imagePayload),
        ]
    }

    return [
        buildOldModeDivoomPacket(command: 0x74, payload: brightnessPayload),
        buildOldModeDivoomPacket(command: 0x44, payload: imagePayload),
    ]
}

private func buildVendorColorLightPacketSequence(
    characteristic: CBCharacteristic,
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    brightness: UInt8,
    threeModeType: UInt8
) -> [Data] {
    // Reversed from MiniLightBoxVC.colorSliderAction: plus BLEPeripheral.sppSetScene:.
    // For the solid-color light screen, the app updates the Family-B scene_mode=1 fields:
    // [scene_mode=0x01, red, green, blue, brightness, ext_mode, onOff].
    // The app then sends command 0x45 through the normal transport chooser.
    let sceneColorPayload = Data([0x01, red, green, blue, brightness, threeModeType, 0x01])

    if characteristic.uuid == ditooLightLEWriteCharacteristicUUID {
        return [buildNewModeLECommandPacket(command: 0x45, payload: sceneColorPayload)]
    }

    return [buildOldModeDivoomPacket(command: 0x45, payload: sceneColorPayload)]
}
