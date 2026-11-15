import Foundation
import Testing
@testable import AdbKit

@Suite("AdbHostClient against a fake server")
struct AdbHostClientTests {
    @Test func versionRoundTrip() async throws {
        let server = try await FakeAdbServer.start { client in
            #expect(try await client.readRequest() == "host:version")
            try await client.write("OKAY00040029")
        }
        defer { server.stop() }
        #expect(try await server.client().version() == 41)
    }

    @Test func devicesParsesList() async throws {
        let server = try await FakeAdbServer.start { client in
            #expect(try await client.readRequest() == "host:devices-l")
            try await client.write("OKAY")
            try await client.writeFramed("PIXEL4SERIAL01         device usb:1-1 product:flame model:Pixel_4 device:flame transport_id:63\n")
        }
        defer { server.stop() }
        let devices = try await server.client().devices()
        #expect(devices.map(\.serial) == ["PIXEL4SERIAL01"])
    }

    @Test func responseSplitIntoTinyWrites() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            for piece in ["OK", "AY00", "0", "4002", "9"] {
                try await client.write(piece)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { server.stop() }
        #expect(try await server.client().version() == 41)
    }

    // Replies below were recorded from adb 37.0.0 (protocol 41) on 2026-11-15.

    @Test func pairSendsCodeAndAddressAndReturnsTheSuccessMessage() async throws {
        let server = try await FakeAdbServer.start { client in
            #expect(try await client.readRequest() == "host:pair:123456:192.168.1.20:37099")
            try await client.write("OKAY")
            try await client.write("OKAY")
            try await client.writeFramed("Successfully paired to 192.168.1.20:37099 [guid=adb-PIXEL4SERIAL01-abc]")
        }
        defer { server.stop() }
        let message = try await server.client().pair(address: "192.168.1.20:37099", code: "123456")
        #expect(message.hasPrefix("Successfully paired to 192.168.1.20:37099"))
    }

    @Test func pairFailureCarriesAdbsReason() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            try await client.write("OKAYFAIL0027Failed: Unable to start pairing client.")
        }
        defer { server.stop() }
        await #expect(throws: AdbError.serverFailure("Failed: Unable to start pairing client.")) {
            try await server.client().pair(address: "127.0.0.1:1", code: "123456")
        }
    }

    @Test func connectSucceedsOnConnectedOrAlreadyConnected() async throws {
        for reply in ["connected to 192.168.1.20:41234", "already connected to 192.168.1.20:41234"] {
            let server = try await FakeAdbServer.start { client in
                #expect(try await client.readRequest() == "host:connect:192.168.1.20:41234")
                try await client.write("OKAY")
                try await client.writeFramed(reply)
            }
            defer { server.stop() }
            #expect(try await server.client().connect(address: "192.168.1.20:41234") == reply)
        }
    }

    @Test func connectFailureIsAnOkayWithAnErrorMessage() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            try await client.write("OKAY")
            try await client.writeFramed("failed to connect to '127.0.0.1:1': Connection refused")
        }
        defer { server.stop() }
        await #expect(throws: AdbError.serverFailure("failed to connect to '127.0.0.1:1': Connection refused")) {
            try await server.client().connect(address: "127.0.0.1:1")
        }
    }

    @Test func disconnectUnknownDeviceFails() async throws {
        let server = try await FakeAdbServer.start { client in
            #expect(try await client.readRequest() == "host:disconnect:127.0.0.1:1")
            try await client.write("FAIL001cno such device '127.0.0.1:1'")
        }
        defer { server.stop() }
        await #expect(throws: AdbError.serverFailure("no such device '127.0.0.1:1'")) {
            try await server.client().disconnect(address: "127.0.0.1:1")
        }
    }

    @Test func failBecomesServerFailure() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            try await client.write("FAIL001cunknown host service 'bogus'")
        }
        defer { server.stop() }
        await #expect(throws: AdbError.serverFailure("unknown host service 'bogus'")) {
            try await server.client().version()
        }
    }

    @Test func trackStreamsUpdatesThenFailsWhenServerCloses() async throws {
        let server = try await FakeAdbServer.start { client in
            #expect(try await client.readRequest() == "host:track-devices-l")
            try await client.write("OKAY")
            try await client.writeFramed("")
            try await client.writeFramed("emulator-5554          offline transport_id:3\n")
            try await client.writeFramed("emulator-5554          device product:sdk model:sdk device:emu transport_id:3\n")
            try await Task.sleep(for: .milliseconds(50))
            client.close()
        }
        defer { server.stop() }

        var updates: [[DeviceState]] = []
        await #expect(throws: AdbError.connectionClosed) {
            for try await devices in server.client().trackDevices() {
                updates.append(devices.map(\.state))
            }
        }
        #expect(updates == [[], [.offline], [.device]])
    }

    @Test func cancellingConsumerEndsTrackStream() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            try await client.write("OKAY")
            try await client.writeFramed("")
            try await Task.sleep(for: .seconds(30)) // keep the connection open
        }
        defer { server.stop() }

        let consumer = Task {
            var count = 0
            for try await _ in server.client().trackDevices() { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        let clock = ContinuousClock()
        let started = clock.now
        let count = try await consumer.value
        #expect(count == 1)
        #expect(clock.now - started < .seconds(1))
    }

    @Test func closedPortIsServerNotRunning() async throws {
        let server = try await FakeAdbServer.start { _ in }
        let client = server.client()
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: AdbError.serverNotRunning) {
            try await client.version()
        }
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await FakeAdbServer.start { client in
            _ = try await client.readRequest()
            try await Task.sleep(for: .seconds(30)) // never answer
        }
        defer { server.stop() }
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: AdbError.timeout) {
            try await server.client(requestTimeout: .milliseconds(300)).version()
        }
        #expect(clock.now - started < .seconds(2))
    }
}

@Suite("Cancellation races")
struct CancellationRaceTests {
    /// A task that is cancelled before it reaches the operation, so `onCancel` runs before the body.
    private func preCancelled<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await body()
        }
        task.cancel()
        return task
    }

    @Test func preCancelledConnectReturnsPromptly() async throws {
        let server = try await FakeAdbServer.start { _ in }
        defer { server.stop() }
        let port = server.port
        let clock = ContinuousClock()
        let started = clock.now
        let task = preCancelled { try await AdbConnection.connect(host: "127.0.0.1", port: port, timeout: .seconds(5)) }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(clock.now - started < .seconds(1))
    }

    @Test func preCancelledStartServerDoesNotLaunchOrCrash() async throws {
        // /usr/bin/true would succeed if launched; a pre-cancelled call must not launch it at all.
        let sut = AdbServerLauncher(environment: ["ADBFILES_ADB_PATH": "/usr/bin/true"])
        let task = preCancelled { try await sut.startServer() }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellingRunningStartServerTerminatesProcess() async throws {
        // `/bin/sleep start-server` exits immediately with an error, so use a script that waits instead.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-adb-\(UUID().uuidString).sh")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let sut = AdbServerLauncher(environment: ["ADBFILES_ADB_PATH": script.path])
        let task = Task { try await sut.startServer() }
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - started < .seconds(2))
    }
}
