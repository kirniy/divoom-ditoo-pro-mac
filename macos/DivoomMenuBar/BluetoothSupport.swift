import CoreBluetooth
import Darwin
import Foundation
import IOBluetooth
import IOKit.ps

private let ditooLightServiceUUID = CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455")
private let ditooLightLEWriteCharacteristicUUID = CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
private let ditooLightLEReadCharacteristicUUID = CBUUID(string: "49535343-6DAA-4D02-ABF6-19569ACA69FE")
private let ditooLightAca3CharacteristicUUID = CBUUID(string: "49535343-ACA3-481C-91EC-D85E28A60318")
private let ditooLightLegacyWriteCharacteristicUUID = CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
private let lastDitooLightPeripheralUUIDDefaultsKey = "DivoomLastDitooLightPeripheralUUID"
private let sampleAnimationPath = "/Users/kirniy/dev/divoom/assets/16x16/generated/menu_fire.divoom16"

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

private struct Divoom16AnimationFrame {
    let colors: [RGBColor]
    let duration: TimeInterval
}

private struct BatterySnapshot {
    let percent: Int
    let isCharging: Bool
}

private struct SystemSnapshot {
    let cpuPercent: Int
    let memoryPercent: Int
    let battery: BatterySnapshot?
}

private struct NetworkSnapshot {
    let downloadKBps: Int
    let uploadKBps: Int
}

private func readBitsFromData(_ data: Data, startingBit: Int, bitCount: Int) -> Int {
    var bitsLeft = bitCount
    var currentBit = startingBit
    var result = 0
    var resultShift = 0

    while bitsLeft > 0 {
        let byteIndex = currentBit / 8
        guard byteIndex < data.count else {
            break
        }

        let bitOffset = currentBit % 8
        let bitsToRead = min(8 - bitOffset, bitsLeft)
        let mask = (1 << bitsToRead) - 1
        let chunk = (Int(data[byteIndex]) >> bitOffset) & mask
        result |= chunk << resultShift

        bitsLeft -= bitsToRead
        currentBit += bitsToRead
        resultShift += bitsToRead
    }

    return result
}

private func loadDivoom16AnimationFrames(from url: URL) throws -> [Divoom16AnimationFrame] {
    let data = try Data(contentsOf: url)
    guard data.count >= 7, data[0] == 0xAA else {
        throw NSError(domain: "Divoom16", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Divoom16 header"])
    }

    let pixelCount = 16 * 16
    var frames: [Divoom16AnimationFrame] = []
    var frameOffset = 0

    var previousPalette: [RGBColor] = []

    while frameOffset + 7 <= data.count, data[frameOffset] == 0xAA {
        let frameLength = Int(UInt16(data[frameOffset + 1]) | (UInt16(data[frameOffset + 2]) << 8))
        guard frameLength >= 7, frameOffset + frameLength <= data.count else {
            break
        }

        let timeInMilliseconds = Int(UInt16(data[frameOffset + 3]) | (UInt16(data[frameOffset + 4]) << 8))
        let reusePalette = data[frameOffset + 5] != 0
        let rawPaletteCount = Int(data[frameOffset + 6])

        var palette: [RGBColor]
        let paletteDataSize: Int

        if reusePalette && rawPaletteCount == 0 && !previousPalette.isEmpty {
            palette = previousPalette
            paletteDataSize = 0
        } else {
            let localPaletteCount = rawPaletteCount == 0 ? 256 : rawPaletteCount
            palette = []
            palette.reserveCapacity(localPaletteCount)
            let paletteStart = frameOffset + 7
            for index in 0..<localPaletteCount {
                let base = paletteStart + index * 3
                guard base + 2 < data.count else {
                    break
                }
                palette.append(RGBColor(r: data[base], g: data[base + 1], b: data[base + 2]))
            }
            paletteDataSize = localPaletteCount * 3
        }

        let localBitsPerPixel = max(1, Int(ceil(log2(Double(max(2, palette.count))))))
        let pixelsOffset = frameOffset + 7 + paletteDataSize
        let pixelByteCount = (pixelCount * localBitsPerPixel + 7) / 8
        let pixelsEnd = pixelsOffset + pixelByteCount
        guard pixelsEnd <= frameOffset + frameLength else {
            break
        }

        let pixelData = data.subdata(in: pixelsOffset..<pixelsEnd)
        var colors: [RGBColor] = []
        colors.reserveCapacity(pixelCount)

        for pixelIndex in 0..<pixelCount {
            let paletteIndex = readBitsFromData(pixelData, startingBit: pixelIndex * localBitsPerPixel, bitCount: localBitsPerPixel)
            let color = palette.indices.contains(paletteIndex) ? palette[paletteIndex] : RGBColor(r: 0, g: 0, b: 0)
            colors.append(color)
        }

        previousPalette = palette

        frames.append(
            Divoom16AnimationFrame(
                colors: colors,
                duration: max(0.08, Double(timeInMilliseconds) / 1000.0)
            )
        )

        frameOffset += frameLength
    }

    if frames.isEmpty {
        throw NSError(domain: "Divoom16", code: 3, userInfo: [NSLocalizedDescriptionKey: "No frames decoded from Divoom16 file"])
    }

    return frames
}

private func normalizedAnimationFrames(
    _ frames: [Divoom16AnimationFrame],
    minimumFrameDuration: TimeInterval = 0.16
) -> [Divoom16AnimationFrame] {
    frames.map { frame in
        Divoom16AnimationFrame(
            colors: frame.colors,
            duration: max(minimumFrameDuration, frame.duration)
        )
    }
}

private func totalAnimationDuration(_ frames: [Divoom16AnimationFrame]) -> TimeInterval {
    frames.reduce(0) { partial, frame in
        partial + frame.duration
    }
}

private func effectiveAnimationLoopCount(
    requestedLoopCount: Int,
    frames _: [Divoom16AnimationFrame]
) -> Int {
    if requestedLoopCount <= 0 {
        return 0
    }
    return max(1, requestedLoopCount)
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

private func buildObviousAnimationFrames() -> [Divoom16AnimationFrame] {
    let background = RGBColor(r: 0x03, g: 0x08, b: 0x16)
    let borderColors = [
        RGBColor(r: 0xff, g: 0x35, b: 0x5e),
        RGBColor(r: 0x33, g: 0xf7, b: 0x73),
        RGBColor(r: 0x3a, g: 0xa0, b: 0xff),
        RGBColor(r: 0xff, g: 0xf0, b: 0x4d),
    ]
    let moverColors = [
        RGBColor(r: 0xff, g: 0xff, b: 0xff),
        RGBColor(r: 0xff, g: 0x8a, b: 0x00),
        RGBColor(r: 0x6b, g: 0xff, b: 0xff),
        RGBColor(r: 0xff, g: 0x4d, b: 0xd2),
    ]
    let positions = [
        (x: 1, y: 1),
        (x: 11, y: 1),
        (x: 11, y: 11),
        (x: 1, y: 11),
    ]

    return positions.enumerated().map { index, position in
        var colors: [RGBColor] = []
        colors.reserveCapacity(16 * 16)
        let border = borderColors[index % borderColors.count]
        let mover = moverColors[index % moverColors.count]

        for y in 0..<16 {
            for x in 0..<16 {
                let isBorder = x == 0 || y == 0 || x == 15 || y == 15
                let inMover = (position.x..<(position.x + 4)).contains(x) && (position.y..<(position.y + 4)).contains(y)
                let inCenterPulse = (6...9).contains(x) && (6...9).contains(y)
                let inGuide = x == 7 || x == 8 || y == 7 || y == 8

                if isBorder {
                    colors.append(border)
                } else if inMover {
                    colors.append(mover)
                } else if inCenterPulse {
                    colors.append(border)
                } else if inGuide {
                    colors.append(RGBColor(r: 0x12, g: 0x22, b: 0x40))
                } else {
                    colors.append(background)
                }
            }
        }

        return Divoom16AnimationFrame(colors: colors, duration: 0.35)
    }
}

private func currentBatterySnapshot() -> BatterySnapshot? {
    guard
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else {
        return nil
    }

    for source in list {
        guard
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            let current = description[kIOPSCurrentCapacityKey as String] as? Int,
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
            maxCapacity > 0
        else {
            continue
        }

        let state = (description[kIOPSPowerSourceStateKey as String] as? String) ?? ""
        let isCharging = state == kIOPSACPowerValue
        let percent = Swift.max(0, Swift.min(100, Int((Double(current) / Double(maxCapacity)) * 100.0)))
        return BatterySnapshot(percent: percent, isCharging: isCharging)
    }

    return nil
}

private func currentSystemSnapshot() -> SystemSnapshot {
    var loadAverages = [Double](repeating: 0, count: 3)
    let loadResult = getloadavg(&loadAverages, 3)
    let coreCount = max(1, ProcessInfo.processInfo.processorCount)
    let cpuPercent: Int
    if loadResult > 0 {
        cpuPercent = max(0, min(100, Int((loadAverages[0] / Double(coreCount)) * 100.0)))
    } else {
        cpuPercent = 0
    }

    let memoryPercent: Int = {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * Double(pageSize)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else {
            return 0
        }
        return max(0, min(100, Int((used / total) * 100.0)))
    }()

    return SystemSnapshot(
        cpuPercent: cpuPercent,
        memoryPercent: memoryPercent,
        battery: currentBatterySnapshot()
    )
}

private func buildBatteryStatusImage(snapshot: BatterySnapshot) -> [RGBColor] {
    var colors: [RGBColor] = []
    colors.reserveCapacity(16 * 16)

    let background = RGBColor(r: 0x05, g: 0x0d, b: 0x18)
    let frame = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let charge = snapshot.isCharging
        ? RGBColor(r: 0x33, g: 0xf7, b: 0x73)
        : (snapshot.percent >= 25 ? RGBColor(r: 0x3a, g: 0xa0, b: 0xff) : RGBColor(r: 0xff, g: 0x55, b: 0x6a))
    let dim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)

    let fillColumns = max(0, min(10, Int(round(Double(snapshot.percent) / 10.0))))

    for y in 0..<16 {
        for x in 0..<16 {
            let inFrame = (2...13).contains(x) && (4...11).contains(y)
            let isOutline = x == 2 || x == 13 || y == 4 || y == 11
            let isCap = (14...15).contains(x) && (6...9).contains(y)
            let inCellArea = (3...12).contains(x) && (5...10).contains(y)
            let cellIndex = x - 3
            let filled = inCellArea && cellIndex < fillColumns
            let showPulse = snapshot.isCharging && abs(x - 8) <= 1 && (6...9).contains(y)
            let topMeter = y <= 1 && x <= snapshot.percent / 7

            if isOutline || isCap {
                colors.append(frame)
            } else if showPulse {
                colors.append(frame)
            } else if filled {
                colors.append(charge)
            } else if inFrame {
                colors.append(dim)
            } else if topMeter {
                colors.append(charge)
            } else {
                colors.append(background)
            }
        }
    }

    return colors
}

private func buildExternalPowerStatusImage() -> [RGBColor] {
    var colors: [RGBColor] = []
    colors.reserveCapacity(16 * 16)

    let background = RGBColor(r: 0x06, g: 0x0d, b: 0x16)
    let frame = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let accent = RGBColor(r: 0xff, g: 0xd1, b: 0x4d)
    let dim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)

    for y in 0..<16 {
        for x in 0..<16 {
            let isBorder = x == 0 || y == 0 || x == 15 || y == 15
            let inSocket = (4...11).contains(x) && (4...11).contains(y)
            let isSocketOutline = x == 4 || x == 11 || y == 4 || y == 11
            let isProng = ((x == 6 || x == 9) && (5...7).contains(y))
            let isStem = (7...8).contains(x) && (8...11).contains(y)
            let isGlow = (2...13).contains(x) && y <= 1

            if isBorder || isSocketOutline {
                colors.append(frame)
            } else if isProng || isStem {
                colors.append(accent)
            } else if inSocket {
                colors.append(dim)
            } else if isGlow {
                colors.append(accent)
            } else {
                colors.append(background)
            }
        }
    }

    return colors
}

private func buildSystemStatusImage(snapshot: SystemSnapshot) -> [RGBColor] {
    var colors = Array(repeating: RGBColor(r: 0x06, g: 0x0d, b: 0x16), count: 16 * 16)

    func setPixel(x: Int, y: Int, color: RGBColor) {
        guard (0..<16).contains(x), (0..<16).contains(y) else {
            return
        }
        colors[y * 16 + x] = color
    }

    let frame = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let cpu = RGBColor(r: 0xff, g: 0x8a, b: 0x00)
    let memory = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)
    let battery = RGBColor(r: 0x33, g: 0xf7, b: 0x73)
    let dim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)

    for x in 0..<16 {
        setPixel(x: x, y: 0, color: frame)
        setPixel(x: x, y: 15, color: frame)
    }
    for y in 0..<16 {
        setPixel(x: 0, y: y, color: frame)
        setPixel(x: 15, y: y, color: frame)
    }

    let cpuHeight = max(1, min(10, Int(round(Double(snapshot.cpuPercent) / 10.0))))
    let memoryHeight = max(1, min(10, Int(round(Double(snapshot.memoryPercent) / 10.0))))

    for x in 3...5 {
        for y in 4...13 {
            setPixel(x: x, y: y, color: dim)
        }
        for offset in 0..<cpuHeight {
            setPixel(x: x, y: 13 - offset, color: cpu)
        }
    }

    for x in 10...12 {
        for y in 4...13 {
            setPixel(x: x, y: y, color: dim)
        }
        for offset in 0..<memoryHeight {
            setPixel(x: x, y: 13 - offset, color: memory)
        }
    }

    for x in 6...9 {
        setPixel(x: x, y: 4, color: frame)
        setPixel(x: x, y: 5, color: frame)
    }

    if let batterySnapshot = snapshot.battery {
        let batteryColumns = max(1, min(4, Int(round(Double(batterySnapshot.percent) / 25.0))))
        for x in 6..<(6 + batteryColumns) {
            setPixel(x: x, y: 4, color: battery)
            setPixel(x: x, y: 5, color: battery)
        }
        if batterySnapshot.isCharging {
            setPixel(x: 8, y: 6, color: battery)
        }
    }

    return colors
}

private func buildAnimatedSystemMonitorFrames() -> [Divoom16AnimationFrame] {
    let snapshot = currentSystemSnapshot()
    let background = RGBColor(r: 0x06, g: 0x0d, b: 0x16)
    let frame = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let cpuColor = RGBColor(r: 0xff, g: 0x8a, b: 0x00)
    let memColor = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)
    let batteryColor = RGBColor(r: 0x33, g: 0xf7, b: 0x73)
    let dim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)
    let scanColor = RGBColor(r: 0xff, g: 0xff, b: 0xff)

    let cpuHeight = max(1, min(10, Int(round(Double(snapshot.cpuPercent) / 10.0))))
    let memHeight = max(1, min(10, Int(round(Double(snapshot.memoryPercent) / 10.0))))
    let batteryPercent = snapshot.battery?.percent ?? 0
    let batteryColumns = max(1, min(4, Int(round(Double(batteryPercent) / 25.0))))

    var frames: [Divoom16AnimationFrame] = []

    // 8 frames: scan line sweeps left-to-right across the display
    for scanX in stride(from: 1, to: 15, by: 2) {
        var colors = Array(repeating: background, count: 16 * 16)

        func setPixel(x: Int, y: Int, color: RGBColor) {
            guard (0..<16).contains(x), (0..<16).contains(y) else { return }
            colors[y * 16 + x] = color
        }

        // Border
        for x in 0..<16 {
            setPixel(x: x, y: 0, color: frame)
            setPixel(x: x, y: 15, color: frame)
        }
        for y in 0..<16 {
            setPixel(x: 0, y: y, color: frame)
            setPixel(x: 15, y: y, color: frame)
        }

        // CPU bar (columns 3-5)
        for x in 3...5 {
            for y in 4...13 { setPixel(x: x, y: y, color: dim) }
            for offset in 0..<cpuHeight { setPixel(x: x, y: 13 - offset, color: cpuColor) }
        }

        // Memory bar (columns 10-12)
        for x in 10...12 {
            for y in 4...13 { setPixel(x: x, y: y, color: dim) }
            for offset in 0..<memHeight { setPixel(x: x, y: 13 - offset, color: memColor) }
        }

        // Battery indicator (rows 4-5, columns 6-9)
        for x in 6...9 {
            setPixel(x: x, y: 4, color: dim)
            setPixel(x: x, y: 5, color: dim)
        }
        for x in 6..<(6 + batteryColumns) {
            setPixel(x: x, y: 4, color: batteryColor)
            setPixel(x: x, y: 5, color: batteryColor)
        }

        // Scan line
        for y in 1...14 {
            setPixel(x: scanX, y: y, color: scanColor)
        }

        frames.append(Divoom16AnimationFrame(colors: colors, duration: 0.18))
    }

    return frames
}

private func buildClockFaceImage(date: Date = Date()) -> [RGBColor] {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0

    var colors = Array(repeating: RGBColor(r: 0x06, g: 0x0d, b: 0x16), count: 16 * 16)

    func setPixel(x: Int, y: Int, color: RGBColor) {
        guard (0..<16).contains(x), (0..<16).contains(y) else { return }
        colors[y * 16 + x] = color
    }

    let frame = RGBColor(r: 0x2a, g: 0x3a, b: 0x50)
    let hourColor = RGBColor(r: 0xff, g: 0x8a, b: 0x00)
    let minuteColor = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)
    let centerColor = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let tickColor = RGBColor(r: 0x33, g: 0x44, b: 0x55)

    // Circular clock face ticks at 12, 3, 6, 9 o'clock positions
    let tickPositions: [(Int, Int)] = [
        (7, 1), (8, 1),    // 12
        (14, 7), (14, 8),  // 3
        (7, 14), (8, 14),  // 6
        (1, 7), (1, 8),    // 9
    ]
    for (tx, ty) in tickPositions {
        setPixel(x: tx, y: ty, color: tickColor)
    }

    // Circular outline approximation
    let circlePixels: [(Int, Int)] = [
        (5, 1), (6, 1), (9, 1), (10, 1),
        (3, 2), (4, 2), (11, 2), (12, 2),
        (2, 3), (13, 3),
        (2, 4), (13, 4),
        (1, 5), (14, 5),
        (1, 6), (14, 6),
        (1, 9), (14, 9),
        (1, 10), (14, 10),
        (2, 11), (13, 11),
        (2, 12), (13, 12),
        (3, 13), (4, 13), (11, 13), (12, 13),
        (5, 14), (6, 14), (9, 14), (10, 14),
    ]
    for (cx, cy) in circlePixels {
        setPixel(x: cx, y: cy, color: frame)
    }

    // Center dot
    setPixel(x: 7, y: 7, color: centerColor)
    setPixel(x: 8, y: 7, color: centerColor)
    setPixel(x: 7, y: 8, color: centerColor)
    setPixel(x: 8, y: 8, color: centerColor)

    // Hour hand (short, 3 pixels from center)
    let hourAngle = (Double(hour % 12) + Double(minute) / 60.0) * (Double.pi * 2.0 / 12.0) - Double.pi / 2.0
    for length in 1...3 {
        let hx = 7 + Int(round(Double(length) * cos(hourAngle)))
        let hy = 7 + Int(round(Double(length) * sin(hourAngle)))
        setPixel(x: hx, y: hy, color: hourColor)
        setPixel(x: hx + 1, y: hy, color: hourColor)
    }

    // Minute hand (longer, 5 pixels from center)
    let minuteAngle = Double(minute) * (Double.pi * 2.0 / 60.0) - Double.pi / 2.0
    for length in 1...5 {
        let mx = 7 + Int(round(Double(length) * cos(minuteAngle)))
        let my = 7 + Int(round(Double(length) * sin(minuteAngle)))
        setPixel(x: mx, y: my, color: minuteColor)
    }

    return colors
}

private func buildAnimatedClockFaceFrames(date: Date = Date()) -> [Divoom16AnimationFrame] {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.hour, .minute, .second], from: date)
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    let second = components.second ?? 0

    let background = RGBColor(r: 0x06, g: 0x0d, b: 0x16)
    let outline = RGBColor(r: 0x2a, g: 0x3a, b: 0x50)
    let hourColor = RGBColor(r: 0xff, g: 0x8a, b: 0x00)
    let minuteColor = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)
    let secondColor = RGBColor(r: 0xff, g: 0x35, b: 0x5e)
    let centerColor = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let tickColor = RGBColor(r: 0x33, g: 0x44, b: 0x55)

    let tickPositions: [(Int, Int)] = [
        (7, 1), (8, 1),
        (14, 7), (14, 8),
        (7, 14), (8, 14),
        (1, 7), (1, 8),
    ]

    let circlePixels: [(Int, Int)] = [
        (5, 1), (6, 1), (9, 1), (10, 1),
        (3, 2), (4, 2), (11, 2), (12, 2),
        (2, 3), (13, 3),
        (2, 4), (13, 4),
        (1, 5), (14, 5),
        (1, 6), (14, 6),
        (1, 9), (14, 9),
        (1, 10), (14, 10),
        (2, 11), (13, 11),
        (2, 12), (13, 12),
        (3, 13), (4, 13), (11, 13), (12, 13),
        (5, 14), (6, 14), (9, 14), (10, 14),
    ]

    // 12 frames, each representing 5 seconds of the sweep
    let frameCount = 12
    var frames: [Divoom16AnimationFrame] = []

    for frameIndex in 0..<frameCount {
        let currentSecond = (second + frameIndex * 5) % 60
        let currentMinute = minute + (second + frameIndex * 5) / 60

        var colors = Array(repeating: background, count: 16 * 16)

        func setPixel(x: Int, y: Int, color: RGBColor) {
            guard (0..<16).contains(x), (0..<16).contains(y) else { return }
            colors[y * 16 + x] = color
        }

        for (cx, cy) in circlePixels {
            setPixel(x: cx, y: cy, color: outline)
        }
        for (tx, ty) in tickPositions {
            setPixel(x: tx, y: ty, color: tickColor)
        }

        // Center dot
        setPixel(x: 7, y: 7, color: centerColor)
        setPixel(x: 8, y: 7, color: centerColor)
        setPixel(x: 7, y: 8, color: centerColor)
        setPixel(x: 8, y: 8, color: centerColor)

        // Hour hand
        let hourAngle = (Double(hour % 12) + Double(currentMinute) / 60.0) * (Double.pi * 2.0 / 12.0) - Double.pi / 2.0
        for length in 1...3 {
            let hx = 7 + Int(round(Double(length) * cos(hourAngle)))
            let hy = 7 + Int(round(Double(length) * sin(hourAngle)))
            setPixel(x: hx, y: hy, color: hourColor)
            setPixel(x: hx + 1, y: hy, color: hourColor)
        }

        // Minute hand
        let minuteAngle = Double(currentMinute) * (Double.pi * 2.0 / 60.0) - Double.pi / 2.0
        for length in 1...5 {
            let mx = 7 + Int(round(Double(length) * cos(minuteAngle)))
            let my = 7 + Int(round(Double(length) * sin(minuteAngle)))
            setPixel(x: mx, y: my, color: minuteColor)
        }

        // Second hand (thin, 6 pixels from center)
        let secondAngle = Double(currentSecond) * (Double.pi * 2.0 / 60.0) - Double.pi / 2.0
        for length in 1...6 {
            let sx = 7 + Int(round(Double(length) * cos(secondAngle)))
            let sy = 7 + Int(round(Double(length) * sin(secondAngle)))
            setPixel(x: sx, y: sy, color: secondColor)
        }

        frames.append(Divoom16AnimationFrame(colors: colors, duration: 5.0))
    }

    return frames
}

private func buildPomodoroTimerFrames(totalMinutes: Int = 25) -> [Divoom16AnimationFrame] {
    let background = RGBColor(r: 0x06, g: 0x0d, b: 0x16)
    let ringFull = RGBColor(r: 0xff, g: 0x35, b: 0x5e)
    let ringDim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)
    let digitColor = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let accentColor = RGBColor(r: 0x33, g: 0xf7, b: 0x73)

    // 20 ring positions (rough circle), clockwise from 12 o'clock
    let ringPositions: [(Int, Int)] = [
        (7, 0), (8, 0),   (10, 1), (12, 2),
        (13, 4), (14, 6), (14, 8), (13, 10),
        (12, 12), (10, 13), (8, 14), (7, 14),
        (5, 13), (3, 12), (2, 10), (1, 8),
        (1, 6), (2, 4),  (3, 2),  (5, 1),
    ]

    // Tiny 3x5 digit bitmaps for 0-9
    let digitBitmaps: [[UInt8]] = [
        [0b111, 0b101, 0b101, 0b101, 0b111], // 0
        [0b010, 0b110, 0b010, 0b010, 0b111], // 1
        [0b111, 0b001, 0b111, 0b100, 0b111], // 2
        [0b111, 0b001, 0b111, 0b001, 0b111], // 3
        [0b101, 0b101, 0b111, 0b001, 0b001], // 4
        [0b111, 0b100, 0b111, 0b001, 0b111], // 5
        [0b111, 0b100, 0b111, 0b101, 0b111], // 6
        [0b111, 0b001, 0b010, 0b010, 0b010], // 7
        [0b111, 0b101, 0b111, 0b101, 0b111], // 8
        [0b111, 0b101, 0b111, 0b001, 0b111], // 9
    ]

    func drawDigit(_ digit: Int, x: Int, y: Int, colors: inout [RGBColor], color: RGBColor) {
        guard (0...9).contains(digit) else { return }
        let bitmap = digitBitmaps[digit]
        for row in 0..<5 {
            for col in 0..<3 {
                if bitmap[row] & (1 << (2 - col)) != 0 {
                    let px = x + col
                    let py = y + row
                    if (0..<16).contains(px), (0..<16).contains(py) {
                        colors[py * 16 + px] = color
                    }
                }
            }
        }
    }

    let frameCount = max(1, totalMinutes + 1)
    var frames: [Divoom16AnimationFrame] = []

    for frameIndex in 0..<frameCount {
        let remainingMinutes = totalMinutes - frameIndex
        var colors = Array(repeating: background, count: 16 * 16)

        let filledPositions = Int(round(Double(remainingMinutes) / Double(totalMinutes) * Double(ringPositions.count)))
        for (index, position) in ringPositions.enumerated() {
            let color = index < filledPositions ? ringFull : ringDim
            let (px, py) = position
            if (0..<16).contains(px), (0..<16).contains(py) {
                colors[py * 16 + px] = color
            }
        }

        if remainingMinutes >= 10 {
            let tens = remainingMinutes / 10
            let ones = remainingMinutes % 10
            drawDigit(tens, x: 4, y: 6, colors: &colors, color: digitColor)
            drawDigit(ones, x: 9, y: 6, colors: &colors, color: digitColor)
        } else if remainingMinutes > 0 {
            drawDigit(remainingMinutes, x: 7, y: 6, colors: &colors, color: digitColor)
        } else {
            for y in 5...10 {
                for x in 5...10 {
                    colors[y * 16 + x] = accentColor
                }
            }
        }

        frames.append(Divoom16AnimationFrame(colors: colors, duration: 2.0))
    }

    return frames
}

private func currentNetworkCounters() -> (download: UInt64, upload: UInt64)? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else {
        return nil
    }
    defer { freeifaddrs(pointer) }

    var download: UInt64 = 0
    var upload: UInt64 = 0
    var cursor: UnsafeMutablePointer<ifaddrs>? = first

    while let current = cursor {
        let flags = Int32(current.pointee.ifa_flags)
        if (flags & IFF_UP) != 0,
           (flags & IFF_LOOPBACK) == 0,
           let dataPointer = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
            download += UInt64(dataPointer.pointee.ifi_ibytes)
            upload += UInt64(dataPointer.pointee.ifi_obytes)
        }
        cursor = current.pointee.ifa_next
    }

    return (download, upload)
}

private func buildNetworkStatusImage(snapshot: NetworkSnapshot) -> [RGBColor] {
    var colors = Array(repeating: RGBColor(r: 0x06, g: 0x0d, b: 0x16), count: 16 * 16)

    func setPixel(x: Int, y: Int, color: RGBColor) {
        guard (0..<16).contains(x), (0..<16).contains(y) else {
            return
        }
        colors[y * 16 + x] = color
    }

    let frame = RGBColor(r: 0xf4, g: 0xf7, b: 0xfb)
    let downloadColor = RGBColor(r: 0x3a, g: 0xa0, b: 0xff)
    let uploadColor = RGBColor(r: 0x33, g: 0xf7, b: 0x73)
    let dim = RGBColor(r: 0x1b, g: 0x28, b: 0x40)

    for x in 0..<16 {
        setPixel(x: x, y: 0, color: frame)
        setPixel(x: x, y: 15, color: frame)
    }
    for y in 0..<16 {
        setPixel(x: 0, y: y, color: frame)
        setPixel(x: 15, y: y, color: frame)
    }

    let downHeight = max(1, min(10, snapshot.downloadKBps / 64))
    let upHeight = max(1, min(10, snapshot.uploadKBps / 64))

    for x in 3...5 {
        for y in 4...13 { setPixel(x: x, y: y, color: dim) }
        for offset in 0..<downHeight { setPixel(x: x, y: 13 - offset, color: downloadColor) }
    }
    for x in 10...12 {
        for y in 4...13 { setPixel(x: x, y: y, color: dim) }
        for offset in 0..<upHeight { setPixel(x: x, y: 13 - offset, color: uploadColor) }
    }

    setPixel(x: 4, y: 2, color: downloadColor)
    setPixel(x: 4, y: 3, color: downloadColor)
    setPixel(x: 3, y: 2, color: downloadColor)
    setPixel(x: 5, y: 2, color: downloadColor)

    setPixel(x: 11, y: 2, color: uploadColor)
    setPixel(x: 11, y: 3, color: uploadColor)
    setPixel(x: 10, y: 3, color: uploadColor)
    setPixel(x: 12, y: 3, color: uploadColor)

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
    private var activeFrameStreamGeneration: UInt64 = 0
    var statusHandler: ((String, String?) -> Void)?

    private func nextFrameStreamGeneration() -> UInt64 {
        activeFrameStreamGeneration &+= 1
        return activeFrameStreamGeneration
    }

    private func cancelActiveFrameStream() {
        activeFrameStreamGeneration &+= 1
    }

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
        recordDeviceResponse(value)
    }

    private var recentDeviceResponses: [(timestamp: Date, data: Data)] = []
    private let maxStoredResponses = 64

    private func recordDeviceResponse(_ data: Data) {
        recentDeviceResponses.append((timestamp: Date(), data: data))
        if recentDeviceResponses.count > maxStoredResponses {
            recentDeviceResponses.removeFirst(recentDeviceResponses.count - maxStoredResponses)
        }
    }

    func drainRecentResponses(since: Date) -> [Data] {
        recentDeviceResponses.filter { $0.timestamp >= since }.map(\.data)
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
        cancelActiveFrameStream()
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
        cancelActiveFrameStream()
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
        cancelActiveFrameStream()
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

    func runNativeBLEObviousAnimationSample(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEFrameStream(
            frames: buildObviousAnimationFrames(),
            label: "obvious-neon-signal",
            sourceDescription: "generated:obvious-neon-signal",
            loopCount: 0,
            completion: completion
        )
    }

    func runNativeBLEDivoom16Sample(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEDivoom16FrameStream(path: sampleAnimationPath, label: "sample-divoom16-stream", loopCount: 0, completion: completion)
    }

    func runNativeBLEDivoom16Animation(
        path: String,
        label: String,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        cancelActiveFrameStream()
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = "BLE light transport not ready. State: \(ditooLightState)"
            AppLog.write("runNativeBLEDivoom16Animation unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE animation failed",
                    details: details
                )
            )
            return
        }

        let animationURL = URL(fileURLWithPath: path)
        guard let animation = try? Data(contentsOf: animationURL), !animation.isEmpty else {
            let details = "Could not read animation payload at \(path)"
            AppLog.write("runNativeBLEDivoom16Animation missing file \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE animation failed",
                    details: details
                )
            )
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        let packets = buildNativeBLEAnimationUploadPacketSequence(animation: animation, characteristic: characteristic)
        let packetHex = packets.map(hexString)
        AppLog.write(
            "runNativeBLEDivoom16Animation label=\(label) path=\(path) bytes=\(animation.count) packets=\(packets.count) peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse") tx=\(packetHex.joined(separator: ","))"
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
                "path=\(path)",
                "bytes=\(animation.count)",
                "packets=\(packets.count)",
                "peripheral=\(peripheral.identifier.uuidString)",
                "characteristic=\(characteristic.uuid.uuidString)",
                "writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
                "tx=\(packetHex.joined(separator: ","))",
            ].joined(separator: "\n")
            completion(
                NativeActionResult(
                    success: true,
                    summary: "Native BLE animation sent",
                    details: details
                )
            )
        }
    }

    func runNativeBLEDivoom16FrameStream(
        path: String,
        label: String,
        loopCount: Int,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = "BLE light transport not ready. State: \(ditooLightState)"
            AppLog.write("runNativeBLEDivoom16FrameStream unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE frame stream failed",
                    details: details
                )
            )
            return
        }

        let animationURL = URL(fileURLWithPath: path)
        let frames: [Divoom16AnimationFrame]
        do {
            frames = try loadDivoom16AnimationFrames(from: animationURL)
        } catch {
            let details = "Could not decode Divoom16 frames at \(path): \(error.localizedDescription)"
            AppLog.write("runNativeBLEDivoom16FrameStream decode failed \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE frame stream failed",
                    details: details
                )
            )
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        AppLog.write(
            "runNativeBLEDivoom16FrameStream label=\(label) path=\(path) frames=\(frames.count) loopCount=\(loopCount) peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")"
        )

        runNativeBLEFrameStream(
            frames: frames,
            label: label,
            sourceDescription: path,
            loopCount: loopCount,
            completion: completion
        )
    }

    private func runNativeBLEFrameStream(
        frames: [Divoom16AnimationFrame],
        label: String,
        sourceDescription: String,
        loopCount: Int,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            let details = "BLE light transport not ready. State: \(ditooLightState)"
            AppLog.write("runNativeBLEFrameStream unavailable \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE frame stream failed",
                    details: details
                )
            )
            return
        }

        guard !frames.isEmpty else {
            let details = "No frames provided for \(label)"
            AppLog.write("runNativeBLEFrameStream empty \(details)")
            completion(
                NativeActionResult(
                    success: false,
                    summary: "Native BLE frame stream failed",
                    details: details
                )
            )
            return
        }

        let preparedFrames = normalizedAnimationFrames(frames)
        let effectiveLoopCount = effectiveAnimationLoopCount(
            requestedLoopCount: loopCount,
            frames: preparedFrames
        )
        let loopsIndefinitely = effectiveLoopCount == 0
        let generation = nextFrameStreamGeneration()
        let totalDuration = totalAnimationDuration(preparedFrames)
        let writeType = preferredBLEWriteType(for: characteristic)
        let effectiveLoopDescription = loopsIndefinitely ? "infinite" : String(effectiveLoopCount)
        let startedDetails = [
            "label=\(label)",
            "source=\(sourceDescription)",
            "frames=\(preparedFrames.count)",
            "requestedLoopCount=\(loopCount)",
            "effectiveLoopCount=\(effectiveLoopDescription)",
            "totalDuration=\(String(format: "%.2f", totalDuration))",
            "peripheral=\(peripheral.identifier.uuidString)",
            "characteristic=\(characteristic.uuid.uuidString)",
            "writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")",
        ].joined(separator: "\n")
        var didReportStart = false
        AppLog.write(
            "runNativeBLEFrameStream label=\(label) source=\(sourceDescription) frames=\(preparedFrames.count) requestedLoopCount=\(loopCount) effectiveLoopCount=\(effectiveLoopDescription) totalDuration=\(String(format: "%.2f", totalDuration)) generation=\(generation) peripheral=\(peripheral.identifier.uuidString) characteristic=\(characteristic.uuid.uuidString) writeType=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")"
        )

        func sendFrame(frameIndex: Int, cycleIndex: Int) {
            guard self.activeFrameStreamGeneration == generation else {
                AppLog.write("runNativeBLEFrameStream cancelled label=\(label) generation=\(generation) frame=\(frameIndex) cycle=\(cycleIndex)")
                return
            }

            if !loopsIndefinitely && cycleIndex >= effectiveLoopCount {
                if !didReportStart {
                    completion(
                        NativeActionResult(
                            success: true,
                            summary: "Native BLE frame stream sent",
                            details: startedDetails
                        )
                    )
                }
                AppLog.write("runNativeBLEFrameStream finished label=\(label) generation=\(generation)")
                return
            }

            let frame = preparedFrames[frameIndex]
            let imagePayload = buildPublicStaticImageCommandBody(colors: frame.colors)
            var packets: [Data] = []
            if frameIndex == 0 {
                packets.append(buildBLETransportPacketForCharacteristic(characteristic: characteristic, command: 0x74, payload: Data([0x64])))
            }
            packets.append(buildBLETransportPacketForCharacteristic(characteristic: characteristic, command: 0x44, payload: imagePayload))

            AppLog.write(
                "runNativeBLEDivoom16FrameStream frame=\(frameIndex) cycle=\(cycleIndex) duration=\(frame.duration) imageBytes=\(imagePayload.count)"
            )

            writeBLEPackets(
                packets,
                packetIndex: 0,
                peripheral: peripheral,
                characteristic: characteristic,
                writeType: writeType
            ) {
                if !didReportStart {
                    didReportStart = true
                    completion(
                        NativeActionResult(
                            success: true,
                            summary: "Native BLE frame stream started",
                            details: startedDetails
                        )
                    )
                }
                let nextFrameIndex = frameIndex + 1
                let wrappedFrameIndex = nextFrameIndex % preparedFrames.count
                let nextCycleIndex = nextFrameIndex >= preparedFrames.count ? cycleIndex + 1 : cycleIndex
                DispatchQueue.main.asyncAfter(deadline: .now() + frame.duration) {
                    sendFrame(frameIndex: wrappedFrameIndex, cycleIndex: nextCycleIndex)
                }
            }
        }

        sendFrame(frameIndex: 0, cycleIndex: 0)
    }

    func runNativeBLEPixelBadgeTest(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEStaticImage(
            colors: buildPublicPixelBadgeTestImage(),
            label: "pixel-badge-test",
            completion: completion
        )
    }

    func runNativeBLEBatteryStatus(completion: @escaping (NativeActionResult) -> Void) {
        guard let snapshot = currentBatterySnapshot() else {
            runNativeBLEStaticImage(
                colors: buildExternalPowerStatusImage(),
                label: "power-source-ac",
                completion: completion
            )
            return
        }

        runNativeBLEStaticImage(
            colors: buildBatteryStatusImage(snapshot: snapshot),
            label: "battery-\(snapshot.percent)-\(snapshot.isCharging ? "charging" : "battery")",
            completion: completion
        )
    }

    func runNativeBLESystemStatus(completion: @escaping (NativeActionResult) -> Void) {
        let snapshot = currentSystemSnapshot()
        runNativeBLEStaticImage(
            colors: buildSystemStatusImage(snapshot: snapshot),
            label: "system-cpu\(snapshot.cpuPercent)-mem\(snapshot.memoryPercent)",
            completion: completion
        )
    }

    func runNativeBLENetworkStatus(completion: @escaping (NativeActionResult) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let start = currentNetworkCounters() else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "Native BLE network status failed",
                        details: "Could not read network interface counters."
                    )
                )
                return
            }

            usleep(500_000)

            guard let end = currentNetworkCounters() else {
                completion(
                    NativeActionResult(
                        success: false,
                        summary: "Native BLE network status failed",
                        details: "Could not read network interface counters after sampling."
                    )
                )
                return
            }

            let downloadDelta = end.download >= start.download ? end.download - start.download : 0
            let uploadDelta = end.upload >= start.upload ? end.upload - start.upload : 0
            let snapshot = NetworkSnapshot(
                downloadKBps: Int((Double(downloadDelta) * 2.0) / 1024.0),
                uploadKBps: Int((Double(uploadDelta) * 2.0) / 1024.0)
            )

            DispatchQueue.main.async {
                self.runNativeBLEStaticImage(
                    colors: buildNetworkStatusImage(snapshot: snapshot),
                    label: "network-down\(snapshot.downloadKBps)-up\(snapshot.uploadKBps)",
                    completion: completion
                )
            }
        }
    }

    func runNativeBLEAnimatedSystemMonitor(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEFrameStream(
            frames: buildAnimatedSystemMonitorFrames(),
            label: "animated-system-monitor",
            sourceDescription: "generated:animated-system-monitor",
            loopCount: 4,
            completion: completion
        )
    }

    func runNativeBLEClockFace(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEStaticImage(
            colors: buildClockFaceImage(),
            label: "clock-face",
            completion: completion
        )
    }

    func runNativeBLEAnimatedClockFace(completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEFrameStream(
            frames: buildAnimatedClockFaceFrames(),
            label: "animated-clock-face",
            sourceDescription: "generated:animated-clock-face",
            loopCount: 1,
            completion: completion
        )
    }

    func runNativeBLEPomodoroTimer(minutes: Int = 25, completion: @escaping (NativeActionResult) -> Void) {
        runNativeBLEFrameStream(
            frames: buildPomodoroTimerFrames(totalMinutes: minutes),
            label: "pomodoro-\(minutes)m",
            sourceDescription: "generated:pomodoro-timer-\(minutes)m",
            loopCount: 1,
            completion: completion
        )
    }

    func runNativeBLESendGIF(path: String, loopCount: Int = 0, completion: @escaping (NativeActionResult) -> Void) {
        let url = URL(fileURLWithPath: path)
        let frames: [Divoom16AnimationFrame]
        do {
            frames = try loadDivoom16AnimationFrames(from: url)
        } catch {
            completion(NativeActionResult(
                success: false,
                summary: "send-gif failed",
                details: "Could not load .divoom16 frames at \(path): \(error.localizedDescription)"
            ))
            return
        }
        let preparedFrames = normalizedAnimationFrames(frames)
        let effectiveLoopCount = effectiveAnimationLoopCount(
            requestedLoopCount: loopCount,
            frames: preparedFrames
        )
        AppLog.write(
            "runNativeBLESendGIF path=\(path) frames=\(preparedFrames.count) requestedLoopCount=\(loopCount) effectiveLoopCount=\(effectiveLoopCount) totalDuration=\(String(format: "%.2f", totalAnimationDuration(preparedFrames)))"
        )
        runNativeBLEFrameStream(
            frames: preparedFrames,
            label: "send-gif",
            sourceDescription: path,
            loopCount: effectiveLoopCount,
            completion: completion
        )
    }

    func runNativeBLEAnimationVerify(path: String, completion: @escaping (NativeActionResult) -> Void) {
        cancelActiveFrameStream()
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            completion(NativeActionResult(
                success: false,
                summary: "animation-verify failed",
                details: "BLE light transport not ready. State: \(ditooLightState)"
            ))
            return
        }

        let animationURL = URL(fileURLWithPath: path)
        guard let animation = try? Data(contentsOf: animationURL), !animation.isEmpty else {
            completion(NativeActionResult(
                success: false,
                summary: "animation-verify failed",
                details: "Could not read animation payload at \(path)"
            ))
            return
        }

        let writeType = preferredBLEWriteType(for: characteristic)
        let packets = buildNativeBLEAnimationUploadPacketSequence(animation: animation, characteristic: characteristic)
        AppLog.write(
            "runNativeBLEAnimationVerify path=\(path) bytes=\(animation.count) packets=\(packets.count)"
        )

        let uploadStart = Date()
        writeBLEPackets(
            packets,
            packetIndex: 0,
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType
        ) { [weak self] in
            guard let self else { return }
            // Wait 2 seconds for any device responses after upload completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                let responses = self.drainRecentResponses(since: uploadStart)
                let responseHex = responses.map { hexString($0) }
                let details = [
                    "path=\(path)",
                    "bytes=\(animation.count)",
                    "packets=\(packets.count)",
                    "device_responses=\(responses.count)",
                    "response_hex=\(responseHex.joined(separator: ","))",
                ].joined(separator: "\n")
                completion(NativeActionResult(
                    success: true,
                    summary: "animation-verify sent (\(responses.count) device responses captured)",
                    details: details
                ))
            }
        }
    }

    func runNativeBLEAnimationUploadOldMode(path: String, completion: @escaping (NativeActionResult) -> Void) {
        cancelActiveFrameStream()
        guard let peripheral = ditooLightPeripheral, let characteristic = ditooLightWriteCharacteristic else {
            completion(NativeActionResult(
                success: false,
                summary: "animation-upload-oldmode failed",
                details: "BLE light transport not ready. State: \(ditooLightState)"
            ))
            return
        }

        let animationURL = URL(fileURLWithPath: path)
        guard let animation = try? Data(contentsOf: animationURL), !animation.isEmpty else {
            completion(NativeActionResult(
                success: false,
                summary: "animation-upload-oldmode failed",
                details: "Could not read animation payload at \(path)"
            ))
            return
        }

        // Experiment: skip the 0xBD [0x31] preamble and send just the 0x8B upload
        // followed by scene switch with a delay, matching the Python serial path more closely.
        var packets: [Data] = []
        let totalSize = UInt32(animation.count)
        // Start upload
        var startPayload = Data([0x00])
        startPayload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        packets.append(buildNewModeLECommandPacket(command: 0x8B, payload: startPayload))
        // Data chunks
        for (offset, chunkStart) in stride(from: 0, to: animation.count, by: 256).enumerated() {
            let chunk = animation[chunkStart..<min(chunkStart + 256, animation.count)]
            var payload = Data([0x01])
            payload.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
            let offsetID = UInt16(offset).littleEndian
            payload.append(contentsOf: withUnsafeBytes(of: offsetID, Array.init))
            payload.append(chunk)
            packets.append(buildNewModeLECommandPacket(command: 0x8B, payload: payload))
        }
        // End upload
        packets.append(buildNewModeLECommandPacket(command: 0x8B, payload: Data([0x02])))
        // Scene switch: mode 5 = user gallery
        packets.append(buildNewModeLECommandPacket(command: 0x45, payload: Data([0x05])))
        // Slot selection
        packets.append(buildNewModeLECommandPacket(command: 0xBD, payload: Data([0x17, 0x00])))
        // Recovered from iOS `sendAnimateSpeed` non-WiFi path.
        packets.append(buildNewModeLECommandPacket(command: 0x35, payload: buildVendorAnimationPlaybackControlPayload()))
        let writeType = preferredBLEWriteType(for: characteristic)
        AppLog.write(
            "runNativeBLEAnimationUploadOldMode path=\(path) bytes=\(animation.count) packets=\(packets.count)"
        )

        let uploadStart = Date()
        writeBLEPackets(
            packets,
            packetIndex: 0,
            peripheral: peripheral,
            characteristic: characteristic,
            writeType: writeType
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let responses = self.drainRecentResponses(since: uploadStart)
                let responseHex = responses.map { hexString($0) }
                let details = [
                    "path=\(path)",
                    "bytes=\(animation.count)",
                    "packets=\(packets.count)",
                    "framing=old-mode",
                    "device_responses=\(responses.count)",
                    "response_hex=\(responseHex.joined(separator: ","))",
                ].joined(separator: "\n")
                completion(NativeActionResult(
                    success: true,
                    summary: "animation-upload-oldmode sent (\(responses.count) device responses captured)",
                    details: details
                ))
            }
        }
    }

    private func runNativeBLEStaticImage(
        colors: [RGBColor],
        label: String,
        completion: @escaping (NativeActionResult) -> Void
    ) {
        cancelActiveFrameStream()
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
        // Use the negotiated ATT MTU reported by CoreBluetooth.  Earlier code
        // hard-coded 20 bytes based on the assumption the vendor app does the
        // same, but the negotiated MTU is typically 185+ bytes on macOS and
        // many BLE stacks use the full value.  Larger writes reduce the number
        // of ATT transactions needed for animation upload packets (~273 bytes
        // each) and make multi-packet protocols like 0x8B much more reliable.
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

    // The vendor Android app marks DitooPro as NewAniSendMode2020 and sends
    // 0xBD [0x31] before starting an animation upload.  Without this preamble
    // the device accepts the 0x8B traffic but never starts playback.
    packets.append(packetBuilder(0xBD, Data([0x31])))

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
    // Reversed iOS `sendAnimateSpeed` shows that non-WiFi devices receive a
    // follow-up `0x35` control payload after gallery upload/setup:
    // [0x00, lensMode, aniSpeed_le16]. Without it, uploads are frequently
    // accepted but remain stuck on a single frame.
    packets.append(packetBuilder(0x35, buildVendorAnimationPlaybackControlPayload()))
    return packets
}

private func buildVendorAnimationPlaybackControlPayload(speed: UInt16 = 40, lensMode: UInt8 = 0) -> Data {
    var payload = Data([0x00, lensMode])
    payload.append(contentsOf: withUnsafeBytes(of: speed.littleEndian, Array.init))
    return payload
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

    packets.append(buildDivoomPacket(command: 0x8B, payload: Data([0x02])))
    packets.append(buildDivoomPacket(command: 0x45, payload: Data([0x05])))
    packets.append(buildDivoomPacket(command: 0xBD, payload: Data([0x17, 0x00])))
    packets.append(buildDivoomPacket(command: 0x35, payload: buildVendorAnimationPlaybackControlPayload()))

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

private func buildNativeBLEAnimationUploadPacketSequence(animation: Data, characteristic: CBCharacteristic) -> [Data] {
    buildAnimationUploadPacketSequence(animation: animation) { command, payload in
        buildBLETransportPacketForCharacteristic(characteristic: characteristic, command: command, payload: payload)
    }
}

private func buildBLETransportPacketForCharacteristic(characteristic: CBCharacteristic, command: UInt8, payload: Data) -> Data {
    if characteristic.uuid == ditooLightLEWriteCharacteristicUUID {
        return buildNewModeLECommandPacket(command: command, payload: payload)
    }
    return buildOldModeDivoomPacket(command: command, payload: payload)
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
