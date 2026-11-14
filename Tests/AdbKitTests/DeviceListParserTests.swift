import Foundation
import Testing
@testable import AdbKit

@Suite("devices-l parsing")
struct DeviceListParserTests {
    /// Exact bytes captured from adb 1.0.41 (`host:devices-l`) with a Pixel 4 attached over USB.
    static let livePixel4Response = Data(
        "OKAY005f9A251FFAZ0073G         device usb:1-1 product:flame model:Pixel_4 device:flame transport_id:63\n".utf8
    )

    @Test func parsesLiveCaptureEndToEnd() throws {
        var decoder = HostMessageDecoder()
        decoder.append(Self.livePixel4Response)
        #expect(try decoder.decodeStatus() == .okay)
        let payload = try #require(try decoder.decodeLengthPrefixed())
        let devices = DeviceListParser.parse(String(decoding: payload, as: UTF8.self))

        #expect(devices == [
            Device(
                serial: "9A251FFAZ0073G", state: .device, devpath: "usb:1-1", product: "flame",
                model: "Pixel_4", deviceName: "flame", transportID: 63
            ),
        ])
        #expect(devices.first?.displayName == "Pixel 4")
        #expect(decoder.bufferedCount == 0)
    }

    @Test func parsesEmulatorLine() {
        let line = "emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:2"
        let device = DeviceListParser.parseLine(Substring(line))
        #expect(device?.serial == "emulator-5554")
        #expect(device?.state == .device)
        #expect(device?.devpath == nil)
        #expect(device?.isEmulator == true)
        #expect(device?.transportID == 2)
    }

    @Test func parsesUnauthorizedWithoutModel() {
        let device = DeviceListParser.parseLine("9A251FFAZ0073G         unauthorized usb:1-1 transport_id:64")
        #expect(device?.state == .unauthorized)
        #expect(device?.model == nil)
        #expect(device?.displayName == "9A251FFAZ0073G")
        #expect(device?.state.isUsable == false)
    }

    @Test func parsesOfflineEmulator() {
        let device = DeviceListParser.parseLine("emulator-5554          offline transport_id:3")
        #expect(device?.state == .offline)
    }

    @Test func parsesSerialLongerThanPadding() {
        let line = "adb-9A251FFAZ0073G-abcdef._adb-tls-connect._tcp device product:flame model:Pixel_4 device:flame transport_id:7"
        let device = DeviceListParser.parseLine(Substring(line))
        #expect(device?.serial == "adb-9A251FFAZ0073G-abcdef._adb-tls-connect._tcp")
        #expect(device?.state == .device)
        #expect(device?.model == "Pixel_4")
    }

    @Test func parsesTCPSerial() {
        let device = DeviceListParser.parseLine("192.168.1.5:5555       device product:flame model:Pixel_4 device:flame transport_id:9")
        #expect(device?.serial == "192.168.1.5:5555")
    }

    @Test func parsesNoSerialNumber() {
        let device = DeviceListParser.parseLine("(no serial number)     offline usb:1-2 transport_id:5")
        #expect(device?.serial == "(no serial number)")
        #expect(device?.state == .offline)
        #expect(device?.devpath == "usb:1-2")
    }

    @Test func parsesNoPermissionsStateWithSpaces() {
        let line = "9A251FFAZ0073G         no permissions (missing udev rules? user is in the plugdev group); see [http://developer.android.com/tools/device.html] usb:1-1 transport_id:4"
        let device = DeviceListParser.parseLine(Substring(line))
        guard case .noPermissions(let text)? = device?.state else {
            Issue.record("expected .noPermissions, got \(String(describing: device?.state))")
            return
        }
        #expect(text.hasPrefix("no permissions (missing udev rules?"))
        #expect(text.hasSuffix("device.html]"))
        #expect(device?.devpath == "usb:1-1")
    }

    @Test func keepsUnknownState() {
        let device = DeviceListParser.parseLine("ABC123                 fastbootd transport_id:1")
        #expect(device?.state == .unknown("fastbootd"))
        #expect(device?.state.rawValue == "fastbootd")
    }

    @Test func parsesShortTabFormat() {
        let devices = DeviceListParser.parse("9A251FFAZ0073G\tdevice\nemulator-5554\toffline\n")
        #expect(devices.map(\.serial) == ["9A251FFAZ0073G", "emulator-5554"])
        #expect(devices.map(\.state) == [.device, .offline])
    }

    @Test func emptyPayloadIsEmptyList() {
        #expect(DeviceListParser.parse("").isEmpty)
        #expect(DeviceListParser.parse("\n").isEmpty)
    }

    @Test func skipsLineWithoutState() {
        #expect(DeviceListParser.parseLine("lonelyserial") == nil)
    }

    @Test func parsesSeveralDevices() {
        let text = """
        9A251FFAZ0073G         device usb:1-1 product:flame model:Pixel_4 device:flame transport_id:63
        emulator-5554          offline transport_id:64

        """
        #expect(DeviceListParser.parse(text).count == 2)
    }

    @Test func stateRawValueRoundTrips() {
        let words = ["device", "offline", "unauthorized", "authorizing", "connecting", "bootloader",
                     "recovery", "rescue", "sideload", "host", "detached"]
        for word in words {
            #expect(DeviceState(rawValue: word).rawValue == word)
            #expect(DeviceState(rawValue: word) != .unknown(word))
        }
    }
}
