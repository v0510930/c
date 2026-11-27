import AVFoundation
import CoreLocation
import Foundation
import UIKit

/// Keeps Reloc genuinely alive in the background while streaming coordinates through the local accessory endpoint
/// AND keeps `locationd` continuously subscribed (0xFFFA) to the external accessory GPS.
@MainActor
public final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    public private(set) static var hasActiveBackgroundSession = false
    private let locationManager = CLLocationManager()
    private var backgroundActivitySession: AnyObject?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var isActive = false
    private var locationSubscriptionActive = false
    private var isLocationUpdating = false
    private var wantSilentAudio = false
    private var observersInstalled = false
    private var hasRequestedAlwaysUpgrade = false
    private var lastAuthStatus: CLAuthorizationStatus?
    private var lastRefreshToggleAt: CFAbsoluteTime = 0
    public var onDiagnostic: ((String, [String: Any]) -> Void)?

    private static let keepAliveWAVData: Data = makeInaudibleKeepAliveWAV(durationSeconds: 4, sampleRate: 8000)

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    /// Starts background keep-alive (audio + background task) WITHOUT waking internal GPS yet.
    /// Call `activateLocationSubscription()` right after iAP2 authentication (0xAA05) succeeds so
    /// `locationd` sees a fresh navigation consumer while the external MFi accessory is already ready.
    public func prepareForSession(useSilentAudio: Bool) {
        isActive = true
        Self.hasActiveBackgroundSession = true
        locationSubscriptionActive = false
        wantSilentAudio = useSilentAudio
        lastAuthStatus = locationManager.authorizationStatus
        installObserversIfNeeded()

        renewBackgroundTask()
        startWatchdog()

        if useSilentAudio {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive(deactivateSession: true)
        }
        emitStatus("keepalive_prepared")
    }

    /// Activates the navigation-grade CoreLocation subscription to trigger iAP2 0xFFFA immediately.
    public func activateLocationSubscription(forceRestart: Bool = true) {
        guard isActive else { return }
        locationSubscriptionActive = true
        renewBackgroundTask()
        startBackgroundLocation(forceRestart: forceRestart)
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("keepalive_location_activated")
    }

    /// Gently nudges `locationd` to re-evaluate the external MFi GPS provider without stopping
    /// updates or invalidating `CLBackgroundActivitySession` (prevents spurious 0xFFFC drops).
    public func nudgeLocationSubscription() {
        guard isActive else { return }
        locationSubscriptionActive = true
        renewBackgroundTask()
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            startBackgroundLocation(forceRestart: false)
            return
        }
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isActive, self.locationSubscriptionActive else { return }
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            self.locationManager.startUpdatingLocation()
            self.emitStatus("keepalive_location_nudged")
        }
    }

    /// Forces a hard restart of CoreLocation subscription (stop -> brief pause -> restart)
    /// as a stronger fallback when gentle nudging did not wake 0xFFFA.
    public func pulseLocationSubscription() {
        guard isActive else { return }
        locationSubscriptionActive = true
        locationManager.stopUpdatingLocation()
        isLocationUpdating = false
        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive, self.locationSubscriptionActive else { return }
            self.startBackgroundLocation(forceRestart: false)
            self.emitStatus("keepalive_location_pulsed")
        }
    }

    /// Guarantees silent audio keep-alive is actively playing before jumping to iOS Settings
    /// to toggle global Location Services (otherwise turning Location Services OFF can let
    /// iOS suspend Reloc mid-countdown and drop the iAP2 tunnel).
    public func ensureAudioKeepAliveForSettingsToggle() {
        guard isActive else { return }
        renewBackgroundTask()
        startResilientAudioKeepAlive()
        emitStatus("keepalive_audio_armed_for_toggle")
    }

    /// Restores the user's configured silent-audio preference after a Settings refresh guide ends.
    public func restoreAudioPreferenceAfterSettingsToggle() {
        guard isActive else { return }
        if !wantSilentAudio {
            stopAudioKeepAlive()
        }
    }

    /// Toggles silent audio keep-alive for an active session without restarting CoreLocation updates.
    public func setAudioKeepAliveEnabled(_ enabled: Bool) {
        guard isActive else { return }
        wantSilentAudio = enabled
        if enabled {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive(deactivateSession: true)
        }
        emitStatus("keepalive_audio_changed")
    }

    public func start(useSilentAudio: Bool) {
        isActive = true
        Self.hasActiveBackgroundSession = true
        locationSubscriptionActive = true
        wantSilentAudio = useSilentAudio
        lastAuthStatus = locationManager.authorizationStatus
        installObserversIfNeeded()

        renewBackgroundTask()
        startBackgroundLocation(forceRestart: true)
        startWatchdog()

        if useSilentAudio {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive(deactivateSession: true)
        }
        emitStatus("keepalive_started")
    }

    public func stop(deactivateAudioSession: Bool = true) {
        isActive = false
        Self.hasActiveBackgroundSession = false
        locationSubscriptionActive = false
        isLocationUpdating = false
        wantSilentAudio = false
        stopWatchdog()

        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false

        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil

        stopAudioKeepAlive(deactivateSession: deactivateAudioSession)
        endBackgroundTask()
    }

    /// Call after global Location Services is toggled OFF -> ON (e.g. 0xFFFC -> 0xFFFA),
    /// because turning Location Services off invalidates the previous CLBackgroundActivitySession.
    public func refreshAfterLocationToggle() {
        guard isActive else { return }
        let status = locationManager.authorizationStatus
        // Ignore early 0xFFFA callbacks while CoreLocation still reports denied/restricted;
        // restarting CLBackgroundActivitySession before authorization recovers causes a 0xFFFC/0xFFFA bounce loop.
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRefreshToggleAt >= 1.5 else { return }
        lastRefreshToggleAt = now
        renewBackgroundTask()
        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = CLBackgroundActivitySession()
        startBackgroundLocation(forceRestart: false)
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("keepalive_refreshed")
    }

    // MARK: - Background Location Keep-Alive

    private func startBackgroundLocation(forceRestart: Bool = false) {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if status == .authorizedWhenInUse, !hasRequestedAlwaysUpgrade {
            hasRequestedAlwaysUpgrade = true
            locationManager.requestAlwaysAuthorization()
        }

        if forceRestart {
            locationManager.stopUpdatingLocation()
            isLocationUpdating = false
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
            backgroundActivitySession = nil
        }

        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            if !isLocationUpdating {
                locationManager.startUpdatingLocation()
                isLocationUpdating = true
            }
        }
    }

    private func emitStatus(_ event: String) {
        let statusName: String
        switch locationManager.authorizationStatus {
        case .authorizedAlways: statusName = "always"
        case .authorizedWhenInUse: statusName = "when_in_use"
        case .denied: statusName = "denied"
        case .restricted: statusName = "restricted"
        case .notDetermined: statusName = "not_determined"
        @unknown default: statusName = "unknown"
        }
        onDiagnostic?(event, [
            "auth": statusName,
            "accuracy": locationManager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
            "audio_playing": audioPlayer?.isPlaying ?? false,
            "app_state": UIApplication.shared.applicationState == .background ? "background" : "foreground",
        ])
    }

    // MARK: - Resilient Low-Level Audio Keep-Alive

    private func startResilientAudioKeepAlive() {
        if let player = audioPlayer, player.isPlaying {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Use a cached 20 Hz sub-audible PCM waveform (+/-6 LSB) with volume = 0.5 -> +/-3 LSB (~ -81 dBFS):
            // completely silent to humans and iPhone speakers, yet guaranteed non-zero after 16-bit mixing
            // so iOS mediaserverd never suspends the app even while global Location Services is toggled.
            let player = try AVAudioPlayer(data: Self.keepAliveWAVData)
            player.numberOfLoops = -1
            player.volume = 0.5
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            audioPlayer = nil
        }
    }

    private func stopAudioKeepAlive(deactivateSession: Bool = true) {
        audioPlayer?.stop()
        audioPlayer = nil
        if deactivateSession && !LocationRefreshPresenter.shared.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Background Task & Interruption Recovery

    private func renewBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Reloc.iAP2Session") { [weak self] in
            // UIKit invokes the expiration handler synchronously on the main thread.
            MainActor.assumeIsolated {
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                if self.locationSubscriptionActive {
                    self.startBackgroundLocation()
                }
                if self.wantSilentAudio, !(self.audioPlayer?.isPlaying ?? false) {
                    self.startResilientAudioKeepAlive()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard isActive, wantSilentAudio,
              let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if type == .began {
            emitStatus("audio_interrupted")
        } else if type == .ended {
            startResilientAudioKeepAlive()
            emitStatus("audio_resumed")
        }
    }

    @objc private func handleMediaServicesReset() {
        guard isActive, wantSilentAudio else { return }
        audioPlayer = nil
        startResilientAudioKeepAlive()
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard isActive, wantSilentAudio else { return }
        if !(audioPlayer?.isPlaying ?? false) {
            startResilientAudioKeepAlive()
            emitStatus("audio_route_resumed")
        }
    }

    @objc private func handleDidEnterBackground() {
        guard isActive else { return }
        renewBackgroundTask()
        if locationSubscriptionActive {
            startBackgroundLocation()
        }
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("app_background")
    }

    @objc private func handleWillEnterForeground() {
        guard isActive else { return }
        if locationSubscriptionActive {
            startBackgroundLocation()
        }
        if wantSilentAudio, !(audioPlayer?.isPlaying ?? false) {
            startResilientAudioKeepAlive()
        }
        emitStatus("app_foreground")
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isActive else { return }
            let newStatus = manager.authorizationStatus
            let recovered = (self.lastAuthStatus == .denied || self.lastAuthStatus == .restricted)
                && (newStatus == .authorizedAlways || newStatus == .authorizedWhenInUse)
            self.lastAuthStatus = newStatus
            if recovered {
                self.refreshAfterLocationToggle()
            } else if self.locationSubscriptionActive {
                self.startBackgroundLocation()
            }
        }
    }

    public nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isActive, self.locationSubscriptionActive else { return }
            self.isLocationUpdating = false
            self.startBackgroundLocation()
            self.emitStatus("keepalive_location_resumed_after_pause")
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Active subscription keeps Reloc alive in background and keeps locationd subscribed to iAP2 0xFFFA.
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation errors while keep-alive runs.
    }

    private static func makeInaudibleKeepAliveWAV(durationSeconds: Int, sampleRate: UInt32) -> Data {
        let numSamples = Int(sampleRate) * max(1, durationSeconds)
        let dataSize = UInt32(numSamples * 2)
        let riffSize = UInt32(36) + dataSize
        let byteRate = sampleRate * 2

        var data = Data(capacity: 44 + Int(dataSize))
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(riffSize)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(sampleRate)
        appendLE(byteRate)
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendLE(dataSize)

        // 20 Hz (+/-6 out of 32767) scaled by volume 0.5 -> +/-3 LSB (~ -81 dBFS):
        // completely inaudible to humans yet non-zero after integer mixing.
        for i in 0..<numSamples {
            let sample: Int16 = (i % 400 < 200) ? 6 : -6
            appendLE(sample)
        }
        return data
    }
}
