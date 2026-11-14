import AdbKit
import Foundation
import Observation
import os

/// Owns the connection to the ADB server and the live device list.
///
/// Flow: track devices → if the server is not running, start it once → track again. When tracking
/// ends unexpectedly, reconnect with exponential backoff (0.5 s → 5 s).
@Observable
@MainActor
final class DeviceStore {
    enum Phase: Equatable {
        case connecting
        case adbMissing
        case failed(String)
        case ready
    }

    private(set) var phase: Phase = .connecting {
        didSet {
            if phase != oldValue { Logger.ui.info("phase=\(String(describing: self.phase), privacy: .public)") }
        }
    }
    private(set) var devices: [Device] = []
    /// Sidebar selection (any device, so its status can be shown).
    private(set) var selectedSerial: String?

    /// The selected device, if it is still connected.
    var selectedDevice: Device? {
        devices.first { $0.serial == selectedSerial }
    }

    @ObservationIgnored private let client: any DeviceTracking
    @ObservationIgnored private let launcher: any ServerStarting
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var trackingTask: Task<Void, Never>?
    @ObservationIgnored private let createdAt = ContinuousClock.now
    @ObservationIgnored private var hasLoggedFirstList = false

    /// - Parameters:
    ///   - client: Source of device-list updates (the ADB host client in production).
    ///   - launcher: Starts the ADB server when it is not running.
    ///   - sleep: Waits between reconnect attempts; injectable so tests run instantly.
    init(
        client: any DeviceTracking = AdbHostClient(),
        launcher: any ServerStarting = AdbServerLauncher(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.launcher = launcher
        self.sleep = sleep
    }

    /// Starts tracking if not already running.
    func start() {
        guard trackingTask == nil else { return }
        trackingTask = Task { [weak self] in await self?.run() }
    }

    /// Restarts tracking immediately (Retry button).
    func retry() {
        trackingTask?.cancel()
        trackingTask = nil
        phase = .connecting
        start()
    }

    /// Selects a device in the sidebar. Returns whether it can be browsed (only `device` state).
    @discardableResult
    func select(_ serial: String?) -> Bool {
        selectedSerial = serial
        guard let serial else { return false }
        let state = devices.first { $0.serial == serial }?.state
        let accepted = state?.isUsable ?? false
        Logger.ui.info(
            "select serial=\(serial, privacy: .public) \(accepted ? "accepted" : "refused", privacy: .public) state=\(state?.rawValue ?? "gone", privacy: .public)"
        )
        return accepted
    }

    // MARK: - Tracking loop

    private func run() async {
        var backoff = Duration.milliseconds(500)
        var serverStartAttempted = false
        var failures = 0

        while !Task.isCancelled {
            do {
                for try await list in client.trackDevices() {
                    logFirstListIfNeeded()
                    apply(list)
                    phase = .ready
                    backoff = .milliseconds(500)
                    serverStartAttempted = false
                    failures = 0
                }
                if Task.isCancelled { return }
                throw AdbError.connectionClosed
            } catch AdbError.serverNotRunning where !serverStartAttempted {
                serverStartAttempted = true
                Logger.ui.info("server not running, starting it")
                do {
                    try await launcher.startAdbServer()
                    continue // track again right away
                } catch {
                    // A retry() may have replaced this task; never let a stale loop overwrite state.
                    if Task.isCancelled || error is CancellationError { return }
                    if case AdbError.adbNotFound = error {
                        apply([])
                        phase = .adbMissing
                        return // nothing to retry automatically; the user installs adb and presses Retry
                    }
                    // adb's own output is the most useful diagnostic; keep it on screen for this streak.
                    failures = max(failures + 1, 3)
                    phase = .failed(error.localizedDescription)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                Logger.ui.error("tracking ended: \(error.localizedDescription, privacy: .public)")
                apply([])
                // Show an error only after repeated failures; a single server restart should look seamless.
                // Once the streak shows an error, keep the first message instead of flipping back to a spinner.
                if case .failed = phase {
                    // keep the existing message
                } else {
                    phase = failures >= 3 ? .failed(error.localizedDescription) : .connecting
                }
            }

            do {
                try await sleep(backoff)
            } catch {
                return
            }
            backoff = min(backoff * 2, .seconds(5))
        }
    }

    private func logFirstListIfNeeded() {
        guard !hasLoggedFirstList else { return }
        hasLoggedFirstList = true
        let elapsed = ContinuousClock.now - createdAt
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        Logger.ui.info("firstList ms=\(ms)")
    }

    private func apply(_ list: [Device]) {
        guard list != devices else { return }
        devices = list
        let summary = list.map { "\($0.serial):\($0.state.rawValue)" }.joined(separator: ", ")
        Logger.ui.info("devices count=\(list.count) [\(summary, privacy: .public)]")

        // Keep the selection while the device is present; otherwise pick the first usable device.
        if selectedSerial == nil || !list.contains(where: { $0.serial == selectedSerial }) {
            select(list.first(where: { $0.state.isUsable })?.serial)
        }
    }
}
