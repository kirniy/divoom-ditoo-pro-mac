#!/usr/bin/env swift

import Foundation
import IOBluetooth
import IOKit

struct Response {
    let originalCommand: UInt8
    let ack: Bool
    let data: Data
}

enum ToolError: Error, CustomStringConvertible {
    case usage(String)
    case bluetooth(String)
    case timeout(String)
    case parse(String)

    var description: String {
        switch self {
        case .usage(let message), .bluetooth(let message), .timeout(let message), .parse(let message):
            return message
        }
    }
}

func checksum(command: UInt8, payload: Data) -> UInt16 {
    let length = UInt16(payload.count + 3)
    let bytes = [UInt8(length & 0x00ff), UInt8(length >> 8), command] + payload
    let sum = bytes.reduce(0) { partial, byte in partial + UInt32(byte) }
    return UInt16(sum & 0xffff)
}

func buildPacket(command: UInt8, payload: Data = Data()) -> Data {
    let length = UInt16(payload.count + 3)
    let crc = checksum(command: command, payload: payload)
    var packet = Data([0x01, UInt8(length & 0x00ff), UInt8(length >> 8), command])
    packet.append(payload)
    packet.append(UInt8(crc & 0x00ff))
    packet.append(UInt8(crc >> 8))
    packet.append(0x02)
    return packet
}

func parseResponse(_ raw: Data) throws -> Response {
    guard raw.count >= 7 else {
        throw ToolError.parse("response too short: \(raw as NSData)")
    }
    guard raw.first == 0x01, raw.last == 0x02 else {
        throw ToolError.parse("bad response framing: \(raw as NSData)")
    }
    guard raw[3] == 0x04 else {
        throw ToolError.parse(String(format: "unexpected response command 0x%02x", raw[3]))
    }
    return Response(
        originalCommand: raw[4],
        ack: raw[5] == 0x55,
        data: raw.subdata(in: 6..<(raw.count - 3))
    )
}

func runLoopUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
}

final class SDPQueryDelegate: NSObject, IOBluetoothDeviceAsyncCallbacks {
    private(set) var status: IOReturn?

    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        self.status = status
    }

    func wait(timeout: TimeInterval) -> IOReturn? {
        _ = runLoopUntil({ self.status != nil }, timeout: timeout)
        return status
    }
}

final class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private(set) var incoming = Data()
    private(set) var openStatus: IOReturn?
    private(set) var closed = false

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

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closed = true
    }

    func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {}

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn, bytesWritten length: Int) {}

    func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func waitForFrame(timeout: TimeInterval) -> Data? {
        let received = runLoopUntil({
            if self.incoming.count < 3 {
                return false
            }
            let payloadLength = Int(UInt16(self.incoming[1]) | (UInt16(self.incoming[2]) << 8))
            return self.incoming.count >= payloadLength + 4
        }, timeout: timeout)
        guard received, incoming.count >= 3 else {
            return nil
        }
        let payloadLength = Int(UInt16(incoming[1]) | (UInt16(incoming[2]) << 8))
        let frameLength = payloadLength + 4
        guard incoming.count >= frameLength else {
            return nil
        }
        let frame = incoming.prefix(frameLength)
        incoming.removeFirst(frameLength)
        return Data(frame)
    }
}

func withDevice(address: String) throws -> IOBluetoothDevice {
    guard let device = IOBluetoothDevice(addressString: address) else {
        throw ToolError.bluetooth("could not create IOBluetoothDevice for \(address)")
    }
    return device
}

func ensureConnection(_ device: IOBluetoothDevice) throws {
    if device.isConnected() {
        return
    }
    let status = device.openConnection()
    let connectionExists = Int(kIOReturnSuccess) + 0 // silence type inference weirdness
    if status != kIOReturnSuccess && status != connectionExists {
        throw ToolError.bluetooth(String(format: "openConnection failed: 0x%08x", status))
    }
}

func performSDPQuery(_ device: IOBluetoothDevice, timeout: TimeInterval) throws {
    let delegate = SDPQueryDelegate()
    let status = device.performSDPQuery(delegate)
    guard status == kIOReturnSuccess else {
        throw ToolError.bluetooth(String(format: "performSDPQuery failed to start: 0x%08x", status))
    }
    guard let completion = delegate.wait(timeout: timeout) else {
        throw ToolError.timeout("SDP query timed out after \(timeout)s")
    }
    guard completion == kIOReturnSuccess else {
        throw ToolError.bluetooth(String(format: "SDP query failed: 0x%08x", completion))
    }
}

func openRFCOMMChannel(device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID, timeout: TimeInterval) throws -> (IOBluetoothRFCOMMChannel, RFCOMMDelegate) {
    let delegate = RFCOMMDelegate()
    var channel: IOBluetoothRFCOMMChannel?
    let status = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: delegate)
    guard status == kIOReturnSuccess else {
        throw ToolError.bluetooth(String(format: "openRFCOMMChannelSync(channel=%d) failed: 0x%08x", channelID, status))
    }
    guard let channel else {
        throw ToolError.bluetooth("openRFCOMMChannelSync succeeded but channel was nil")
    }
    _ = runLoopUntil({ delegate.openStatus != nil || channel.isOpen() }, timeout: timeout)
    let openStatus = delegate.openStatus ?? kIOReturnSuccess
    guard openStatus == kIOReturnSuccess, channel.isOpen() else {
        throw ToolError.bluetooth(String(format: "RFCOMM channel did not open cleanly: status=0x%08x isOpen=%d", openStatus, channel.isOpen()))
    }
    return (channel, delegate)
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func parseHex(_ string: String) throws -> Data {
    let compact = string.replacingOccurrences(of: " ", with: "")
    guard compact.count.isMultiple(of: 2) else {
        throw ToolError.usage("hex payload must have an even number of digits")
    }
    var output = Data()
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else {
            throw ToolError.usage("invalid hex payload: \(string)")
        }
        output.append(byte)
        index = next
    }
    return output
}

func commandArg(named flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func hasFlag(_ flag: String, in args: [String]) -> Bool {
    args.contains(flag)
}

func runSDP(address: String, timeout: TimeInterval) throws {
    let device = try withDevice(address: address)
    try ensureConnection(device)
    try performSDPQuery(device, timeout: timeout)
    let services = (device.services ?? []) as? [IOBluetoothSDPServiceRecord] ?? []
    let result: [[String: Any]] = services.map { service in
        var channelID: BluetoothRFCOMMChannelID = 0
        let channelStatus = service.getRFCOMMChannelID(&channelID)
        return [
            "name": service.getServiceName() ?? "",
            "rfcommChannel": channelStatus == kIOReturnSuccess ? Int(channelID) : NSNull(),
            "channelStatus": Int(channelStatus)
        ]
    }
    let payload: [String: Any] = [
        "address": address,
        "connected": device.isConnected(),
        "serviceCount": services.count,
        "services": result
    ]
    let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func runProbe(address: String, channelID: BluetoothRFCOMMChannelID, command: UInt8, payload: Data, expectResponse: Bool, timeout: TimeInterval) throws {
    let device = try withDevice(address: address)
    try ensureConnection(device)
    let (channel, delegate) = try openRFCOMMChannel(device: device, channelID: channelID, timeout: timeout)
    defer {
        _ = channel.close()
    }

    var packet = [UInt8](buildPacket(command: command, payload: payload))
    let writeStatus = channel.writeSync(&packet, length: UInt16(packet.count))
    guard writeStatus == kIOReturnSuccess else {
        throw ToolError.bluetooth(String(format: "writeSync failed: 0x%08x", writeStatus))
    }

    var result: [String: Any] = [
        "address": address,
        "channel": Int(channelID),
        "command": String(format: "0x%02x", command),
        "payload": hex(payload),
        "tx": hex(Data(packet))
    ]

    if expectResponse {
        guard let frame = delegate.waitForFrame(timeout: timeout) else {
            throw ToolError.timeout("no response received after \(timeout)s")
        }
        let parsed = try parseResponse(frame)
        result["rx"] = hex(frame)
        result["ack"] = parsed.ack
        result["responseCommand"] = String(format: "0x%02x", parsed.originalCommand)
        result["responseData"] = hex(parsed.data)
    }

    let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let subcommand = args.first else {
        throw ToolError.usage("""
        usage:
          divoom_rfcomm.swift sdp --address B1:21:81:32:C6:F8 [--timeout 8]
          divoom_rfcomm.swift probe --address B1:21:81:32:C6:F8 [--channel 2] [--command 09] [--payload 0102] [--expect-response] [--timeout 4]
        """)
    }

    let address = commandArg(named: "--address", in: args) ?? "B1:21:81:32:C6:F8"
    let timeout = TimeInterval(commandArg(named: "--timeout", in: args) ?? "4") ?? 4

    switch subcommand {
    case "sdp":
        try runSDP(address: address, timeout: timeout)
    case "probe":
        let channel = BluetoothRFCOMMChannelID(commandArg(named: "--channel", in: args).flatMap(UInt8.init) ?? 2)
        let commandText = commandArg(named: "--command", in: args) ?? "09"
        guard let command = UInt8(commandText, radix: 16) else {
            throw ToolError.usage("invalid hex command: \(commandText)")
        }
        let payload = try parseHex(commandArg(named: "--payload", in: args) ?? "")
        try runProbe(
            address: address,
            channelID: channel,
            command: command,
            payload: payload,
            expectResponse: hasFlag("--expect-response", in: args),
            timeout: timeout
        )
    default:
        throw ToolError.usage("unknown subcommand: \(subcommand)")
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
