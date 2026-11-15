import AdbKit
import Foundation
import Observation
import os

/// The adb server calls the Wi-Fi window needs. `AdbHostClient` in production, a fake in tests.
protocol WifiConnecting: Sendable {
    func pair(address: String, code: String, timeout: Duration) async throws -> String
    func connect(address: String, timeout: Duration) async throws -> String
    func disconnect(address: String) async throws -> String
}

extension AdbHostClient: WifiConnecting {}

/// State of the "Connect via Wi-Fi" window: pair with a code (once per phone), then connect.
@Observable
@MainActor
final class WifiConnectModel {
    enum Action: Equatable { case pair, connect }

    struct Status: Equatable {
        let text: String
        let isError: Bool
    }

    var pairAddress = ""
    var pairCode = ""
    var connectAddress = ""
    private(set) var busy: Action?
    private(set) var status: Status?

    @ObservationIgnored private let client: any WifiConnecting

    init(client: any WifiConnecting = AdbHostClient()) {
        self.client = client
    }

    var canPair: Bool { busy == nil && Self.isValidAddress(pairAddress) && Self.isValidCode(pairCode) }
    var canConnect: Bool { busy == nil && Self.isValidAddress(connectAddress) }

    func pair() async {
        guard canPair else { return }
        let address = pairAddress.trimmingCharacters(in: .whitespaces)
        busy = .pair
        status = nil
        defer { busy = nil }
        do {
            let message = try await client.pair(address: address, code: pairCode, timeout: .seconds(45))
            Logger.ui.info("wifi pair ok address=\(address, privacy: .public)")
            status = Status(text: message, isError: false)
            pairCode = ""
            // The connect port differs from the pairing port; keep the host to save typing.
            if connectAddress.isEmpty, let host = Self.host(of: address) { connectAddress = host + ":" }
        } catch {
            Logger.ui.error("wifi pair failed address=\(address, privacy: .public): \(Self.message(error), privacy: .public)")
            status = Status(text: Self.message(error), isError: true)
        }
    }

    func connect() async {
        guard canConnect else { return }
        let address = connectAddress.trimmingCharacters(in: .whitespaces)
        busy = .connect
        status = nil
        defer { busy = nil }
        do {
            let message = try await client.connect(address: address, timeout: .seconds(30))
            Logger.ui.info("wifi connect ok address=\(address, privacy: .public)")
            status = Status(text: message, isError: false)
        } catch {
            Logger.ui.error("wifi connect failed address=\(address, privacy: .public): \(Self.message(error), privacy: .public)")
            status = Status(text: Self.message(error), isError: true)
        }
    }

    /// `host:port` with a port in 1…65535 and a host without spaces (IPv4 address or name).
    nonisolated static func isValidAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":"), let host = host(of: trimmed), !host.isEmpty,
              !host.contains(" "), !host.contains(":"),
              let port = Int(trimmed[trimmed.index(after: colon)...]), (1...65_535).contains(port) else { return false }
        return true
    }

    /// Six digits, as shown on the phone.
    nonisolated static func isValidCode(_ text: String) -> Bool {
        text.count == 6 && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber)
    }

    private nonisolated static func host(of address: String) -> String? {
        address.lastIndex(of: ":").map { String(address[..<$0]) }
    }

    private static func message(_ error: Error) -> String {
        if case AdbError.serverFailure(let text) = error { return text }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Whether a device serial is a network connection that `disconnect` can end.
    nonisolated static func isNetworkSerial(_ serial: String) -> Bool {
        serial.contains("._adb-tls-connect._tcp") || isValidAddress(serial)
    }
}
