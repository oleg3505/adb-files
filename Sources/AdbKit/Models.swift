/// Connection state of a device as reported by the ADB server.
///
/// Mirrors `to_string(ConnectionState)` in AOSP `adb.cpp`. Unknown words are preserved in `.unknown`.
public enum DeviceState: Sendable, Hashable {
    case device
    case offline
    case unauthorized
    case authorizing
    case connecting
    case bootloader
    case recovery
    case rescue
    case sideload
    case host
    case detached
    /// The host lacks USB permissions; carries the server's help text.
    case noPermissions(String)
    /// A state word this client does not know yet.
    case unknown(String)

    /// Parses the state text from a device-list line.
    public init(rawValue: String) {
        switch rawValue {
        case "device": self = .device
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        case "authorizing": self = .authorizing
        case "connecting": self = .connecting
        case "bootloader": self = .bootloader
        case "recovery": self = .recovery
        case "rescue": self = .rescue
        case "sideload": self = .sideload
        case "host": self = .host
        case "detached": self = .detached
        default:
            self = rawValue.hasPrefix("no permissions") ? .noPermissions(rawValue) : .unknown(rawValue)
        }
    }

    /// The state text as the server prints it.
    public var rawValue: String {
        switch self {
        case .device: "device"
        case .offline: "offline"
        case .unauthorized: "unauthorized"
        case .authorizing: "authorizing"
        case .connecting: "connecting"
        case .bootloader: "bootloader"
        case .recovery: "recovery"
        case .rescue: "rescue"
        case .sideload: "sideload"
        case .host: "host"
        case .detached: "detached"
        case .noPermissions(let text), .unknown(let text): text
        }
    }

    /// Whether files on the device can be accessed (only a fully connected, authorized device).
    public var isUsable: Bool { self == .device }
}

/// A device known to the ADB server, parsed from one `host:devices-l` line.
public struct Device: Sendable, Hashable, Identifiable {
    /// Serial number, e.g. `9A251FFAZ0073G`, `emulator-5554` or `192.168.1.5:5555`.
    public let serial: String
    /// Current connection state.
    public let state: DeviceState
    /// USB device path, e.g. `usb:1-1`; nil for TCP devices.
    public let devpath: String?
    /// Product name (`product:` field), e.g. `flame`.
    public let product: String?
    /// Model name (`model:` field) as sent by the server, with non-alphanumerics replaced by `_`.
    public let model: String?
    /// Device name (`device:` field), e.g. `flame`.
    public let deviceName: String?
    /// Server-assigned transport id, stable while the device stays connected.
    public let transportID: Int?

    /// Creates a device value.
    public init(
        serial: String, state: DeviceState, devpath: String? = nil, product: String? = nil,
        model: String? = nil, deviceName: String? = nil, transportID: Int? = nil
    ) {
        self.serial = serial
        self.state = state
        self.devpath = devpath
        self.product = product
        self.model = model
        self.deviceName = deviceName
        self.transportID = transportID
    }

    /// Stable identity: the serial.
    public var id: String { serial }

    /// Human-readable name: the model with underscores turned into spaces, or the serial.
    public var displayName: String {
        guard let model, !model.isEmpty else { return serial }
        return model.replacingOccurrences(of: "_", with: " ")
    }

    /// Whether this is an Android emulator instance.
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
}
