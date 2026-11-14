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
            try await client.writeFramed("9A251FFAZ0073G         device usb:1-1 product:flame model:Pixel_4 device:flame transport_id:63\n")
        }
        defer { server.stop() }
        let devices = try await server.client().devices()
        #expect(devices.map(\.serial) == ["9A251FFAZ0073G"])
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
