import AVFoundation
import CoreLocation
import Foundation
import UIKit

/// Keeps Reloc genuinely alive in the background while injecting coordinates over 10.7.0.1
/// AND keeps `locationd` continuously subscribed (0xFFFA) to the external accessory GPS.
@MainActor
public final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var backgroundActivitySession: AnyObject?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var audioPlayer: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var isActive = false
    private var wantSilentAudio = false
    private var observersInstalled = false
    private var hasRequestedAlwaysUpgrade = false
    private var lastAuthStatus: CLAuthorizationStatus?
    public var onDiagnostic: ((String, [String: Any]) -> Void)?

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    public func start(useSilentAudio: Bool) {
        isActive = true
        wantSilentAudio = useSilentAudio
        lastAuthStatus = locationManager.authorizationStatus
        installObserversIfNeeded()

        renewBackgroundTask()
        startBackgroundLocation(forceRestart: true)
        startWatchdog()

        if useSilentAudio {
            startResilientAudioKeepAlive()
        } else {
            stopAudioKeepAlive()
        }
        emitStatus("keepalive_started")
    }

    public func stop() {
        isActive = false
        wantSilentAudio = false
        stopWatchdog()

        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false

        (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivitySession = nil

        stopAudioKeepAlive()
        endBackgroundTask()
    }

    /// Call after global Location Services is toggled OFF -> ON (e.g. 0xFFFC -> 0xFFFA),
    /// because turning Location Services off invalidates the previous CLBackgroundActivitySession.
    public func refreshAfterLocationToggle() {
        guard isActive else { return }
        renewBackgroundTask()
        startBackgroundLocation(forceRestart: true)
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
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
            backgroundActivitySession = nil
        }

        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }

        if status == .authorizedWhenInUse || status == .authorizedAlways {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            locationManager.startUpdatingLocation()
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

            // Use a 20 Hz sub-audible PCM waveform (+/-6 LSB) with volume = 0.5 -> +/-3 LSB (~ -81 dBFS):
            // completely silent to humans and iPhone speakers, yet guaranteed non-zero after 16-bit mixing
            // so iOS mediaserverd never suspends the app even while global Location Services is toggled.
            let wavData = Self.makeInaudibleKeepAliveWAV(durationSeconds: 4, sampleRate: 8000)
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.5
            player.prepareToPlay()
            player.play()
            audioPlayer = player
        } catch {
            audioPlayer = nil
        }
    }

    private func stopAudioKeepAlive() {
        audioPlayer?.stop()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Background Task & Interruption Recovery

    private func renewBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Reloc.iAP2Session") { [weak self] in
            Task { @MainActor in
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
                self.startBackgroundLocation()
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

    @objc private func handleDidEnterBackground() {
        guard isActive else { return }
        renewBackgroundTask()
        startBackgroundLocation()
        if wantSilentAudio {
            startResilientAudioKeepAlive()
        }
        emitStatus("app_background")
    }

    @objc private func handleWillEnterForeground() {
        guard isActive else { return }
        startBackgroundLocation()
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
            } else {
                self.startBackgroundLocation()
            }
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
