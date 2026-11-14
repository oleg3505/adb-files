/// Parses the text payload of `host:devices-l` / `host:track-devices-l` (and the short `host:devices`).
///
/// Long line format, from AOSP `transport.cpp`:
/// `printf("%-22s %s", serial, state)` followed by ` <key><value>` for each non-empty field in order:
/// devpath (empty key, e.g. `usb:1-1`), `product:`, `model:`, `device:`, then ` transport_id:<n>`.
/// The short format is `serial\tstate`.
public enum DeviceListParser {
    private static let noSerial = "(no serial number)"
    private static let fieldPrefixes = ["usb:", "product:", "model:", "device:", "transport_id:"]

    /// Parses every non-empty line; lines that cannot be parsed are skipped.
    public static func parse(_ text: String) -> [Device] {
        text.split(whereSeparator: \.isNewline).compactMap { parseLine($0) }
    }

    /// Parses a single device line.
    public static func parseLine(_ line: Substring) -> Device? {
        let serial: String
        let rest: Substring
        if line.hasPrefix(noSerial) {
            serial = noSerial
            rest = line.dropFirst(noSerial.count)
        } else {
            guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
            serial = String(line[..<end])
            rest = line[end...]
        }
        guard !serial.isEmpty else { return nil }

        let tokens = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
        // State text runs until the first known `key:value` field; it may contain spaces (no-permissions help).
        let fieldStart = tokens.firstIndex { token in fieldPrefixes.contains { token.hasPrefix($0) } } ?? tokens.endIndex
        let stateText = tokens[..<fieldStart].joined(separator: " ")
        guard !stateText.isEmpty else { return nil }

        var devpath: String?
        var product: String?
        var model: String?
        var deviceName: String?
        var transportID: Int?
        for token in tokens[fieldStart...] {
            if token.hasPrefix("usb:") {
                devpath = String(token)
            } else if let value = token.value(after: "product:") {
                product = value
            } else if let value = token.value(after: "model:") {
                model = value
            } else if let value = token.value(after: "device:") {
                deviceName = value
            } else if let value = token.value(after: "transport_id:") {
                transportID = Int(value)
            }
        }

        return Device(
            serial: serial, state: DeviceState(rawValue: stateText), devpath: devpath, product: product,
            model: model, deviceName: deviceName, transportID: transportID
        )
    }
}

private extension Substring {
    func value(after prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
