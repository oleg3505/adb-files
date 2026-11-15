import AdbKit
import Foundation
import os
import Testing
@testable import AdbFiles

final class FakeWifi: WifiConnecting {
    private let state = OSAllocatedUnfairLock(initialState: (calls: [String](), pairResult: Result<String, AdbError>.success("Successfully paired to 192.168.1.20:37099 [guid=x]"),
                                                             connectResult: Result<String, AdbError>.success("connected to 192.168.1.20:41234")))
    let gate: Gate?

    init(gate: Gate? = nil, pair: Result<String, AdbError>? = nil, connect: Result<String, AdbError>? = nil) {
        self.gate = gate
        state.withLock { state in
            if let pair { state.pairResult = pair }
            if let connect { state.connectResult = connect }
        }
    }

    var calls: [String] { state.withLock { $0.calls } }

    func pair(address: String, code: String, timeout: Duration) async throws -> String {
        state.withLock { $0.calls.append("pair \(address) \(code)") }
        await gate?.wait()
        return try state.withLock { $0.pairResult }.get()
    }

    func connect(address: String, timeout: Duration) async throws -> String {
        state.withLock { $0.calls.append("connect \(address)") }
        await gate?.wait()
        return try state.withLock { $0.connectResult }.get()
    }

    func disconnect(address: String) async throws -> String { "disconnected \(address)" }
}

@MainActor
@Suite struct WifiConnectModelTests {
    @Test func validatesAddressAndCode() {
        #expect(WifiConnectModel.isValidAddress("192.168.1.20:37099"))
        #expect(WifiConnectModel.isValidAddress(" pixel.local:5555 "))
        #expect(!WifiConnectModel.isValidAddress("192.168.1.20"))
        #expect(!WifiConnectModel.isValidAddress("192.168.1.20:0"))
        #expect(!WifiConnectModel.isValidAddress("192.168.1.20:70000"))
        #expect(!WifiConnectModel.isValidAddress(":5555"))
        #expect(!WifiConnectModel.isValidAddress("a b:5555"))
        #expect(WifiConnectModel.isValidCode("123456"))
        #expect(!WifiConnectModel.isValidCode("12345"))
        #expect(!WifiConnectModel.isValidCode("12345a"))
        #expect(!WifiConnectModel.isValidCode("١٢٣٤٥٦"), "ASCII digits only")
    }

    @Test func networkSerialsCanBeDisconnected() {
        #expect(WifiConnectModel.isNetworkSerial("192.168.1.20:41234"))
        #expect(WifiConnectModel.isNetworkSerial("adb-9A251FFAZ0073G-abc._adb-tls-connect._tcp"))
        #expect(!WifiConnectModel.isNetworkSerial("9A251FFAZ0073G"))
        #expect(!WifiConnectModel.isNetworkSerial("emulator-5554"))
    }

    @Test func pairingSucceedsClearsTheCodeAndPrefillsTheHost() async {
        let wifi = FakeWifi()
        let model = WifiConnectModel(client: wifi)
        model.pairAddress = "192.168.1.20:37099"
        model.pairCode = "123456"
        #expect(model.canPair)
        await model.pair()
        #expect(wifi.calls == ["pair 192.168.1.20:37099 123456"])
        #expect(model.status?.isError == false)
        #expect(model.pairCode.isEmpty)
        #expect(model.connectAddress == "192.168.1.20:")
        #expect(!model.canConnect, "the connect port still has to be typed")
    }

    @Test func busyWhileRunningAndNoSecondRequest() async throws {
        let gate = Gate()
        let wifi = FakeWifi(gate: gate)
        let model = WifiConnectModel(client: wifi)
        model.connectAddress = "192.168.1.20:41234"
        let running = Task { await model.connect() }
        try await waitUntil { model.busy == .connect }
        #expect(!model.canConnect && !model.canPair)
        await model.connect() // ignored while busy
        await gate.open()
        await running.value
        #expect(wifi.calls == ["connect 192.168.1.20:41234"])
        #expect(model.busy == nil)
    }

    @Test func adbsFailureTextIsShown() async {
        let wifi = FakeWifi(connect: .failure(.serverFailure("failed to connect to '192.168.1.20:41234': Connection refused")))
        let model = WifiConnectModel(client: wifi)
        model.connectAddress = "192.168.1.20:41234"
        await model.connect()
        #expect(model.status == .init(text: "failed to connect to '192.168.1.20:41234': Connection refused", isError: true))
    }

    @Test func wrongPairingCodeIsShown() async {
        let wifi = FakeWifi(pair: .failure(.serverFailure("Failed: Wrong password or connection was dropped.")))
        let model = WifiConnectModel(client: wifi)
        model.pairAddress = "192.168.1.20:37099"
        model.pairCode = "000000"
        await model.pair()
        #expect(model.status?.isError == true)
        #expect(model.status?.text.contains("Wrong password") == true)
        #expect(model.pairCode == "000000", "kept so the user can correct it")
    }
}
