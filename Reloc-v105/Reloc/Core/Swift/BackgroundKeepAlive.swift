import CoreLocation
import Foundation
import UIKit

/// Keeps Reloc alive in the background purely via native CoreLocation background execution
/// (`UIBackgroundModes: location` + `CLBackgroundActivitySession` on iOS 17+) without using any
/// silent audio playback or holding `AVAudioSession`, while keeping `locationd` subscribed (`0xFFFA`)
/// to the virtual external accessory GPS.
@MainActor
public final class BackgroundKeepAlive: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var backgroundActivitySession: AnyObject?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var watchdogTimer: DispatchSourceTimer?
    private var isActive = false
    private var locationSubscriptionActive = false
    private var isLocationUpdating = false
    private var keepTransientTaskActive = false
    private var observersInstalled = false
    private var hasRequestedAlwaysUpgrade = false
    private var lastAuthStatus: CLAuthorizationStatus?
    private var lastRefreshToggleAt: TimeInterval = 0
    private var lastLocationCallbackAt: TimeInterval = 0

    public var onDiagnostic: ((String, [String: Any]) -> Void)?
    public var onLocationUpdate: ((CLLocation) -> Void)?
    public var onAuthorizationChange: ((CLAuthorizationStatus, CLAccuracyAuthorization) -> Void)?
    public var onForegroundResume: (() -> Void)?

    public var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    public var accuracyAuthorization: CLAccuracyAuthorization {
        locationManager.accuracyAuthorization
    }

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    private static var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Arms a short-lived OS background task before iAP2 auth completes so we don't wake internal GPS
    /// early and poison `locationd`'s fusion cache, while still surviving an immediate app switch.
    public func prepareForSession() {
        isActive = true
        locationSubscriptionActive = false
        keepTransientTaskActive = true
        lastAuthStatus = locationManager.authorizationStatus
        lastLocationCallbackAt = 0
        installObserversIfNeeded()

        renewBackgroundTask(name: "Reloc.SessionStartup")
        startWatchdog()
        emitStatus("keepalive_prepared")
    }

    /// Activates the navigation-grade CoreLocation subscription to trigger iAP2 `0xFFFA` immediately
    /// and sustain multi-hour background execution without any audio playback.
    public func activateLocationSubscription(forceRestart: Bool = true) {
        guard isActive else { return }
        locationSubscriptionActive = true
        keepTransientTaskActive = false
        let inBackground = UIApplication.shared.applicationState == .background
        // Never tear down an active CoreLocation assertion while in the background;
        // dropping it surrenders our only background execution grant and causes OS suspension.
        let safeForceRestart = forceRestart && !inBackground
        if inBackground && isLocationUpdating {
            nudgeLocationSubscription()
        } else {
            startBackgroundLocation(forceRestart: safeForceRestart)
        }
        emitStatus("keepalive_location_activated")
    }

    /// Gently nudges `locationd` to re-evaluate the external MFi GPS provider without stopping
    /// updates or invalidating `CLBackgroundActivitySession` (prevents spurious `0xFFFC` drops).
    public func nudgeLocationSubscription() {
        guard isActive else { return }
        locationSubscriptionActive = true
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            startBackgroundLocation(forceRestart: false)
            return
        }
        startBackgroundActivitySessionIfAvailable()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isActive, self.locationSubscriptionActive else { return }
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            self.locationManager.startUpdatingLocation()
            self.isLocationUpdating = true
            self.emitStatus("keepalive_location_nudged")
        }
    }

    /// Forces a hard restart of CoreLocation subscription in the foreground only.
    /// While in the background, degrades to a non-destructive accuracy nudge so iOS never
    /// suspends the process for dropping its sole background location assertion.
    public func pulseLocationSubscription() {
        guard isActive else { return }
        locationSubscriptionActive = true
        if UIApplication.shared.applicationState == .background {
            nudgeLocationSubscription()
            return
        }
        renewBackgroundTask(name: "Reloc.LocationPulse")
        locationManager.stopUpdatingLocation()
        isLocationUpdating = false
        invalidateBackgroundActivitySession()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive, self.locationSubscriptionActive else { return }
            self.startBackgroundLocation(forceRestart: false)
            self.emitStatus("keepalive_location_pulsed")
        }
    }

    /// Acquires a bounded OS background task (~25–30s) before jumping to iOS Settings to toggle
    /// global Location Services OFF for 7 seconds (coupled with active PiP, this bridges the brief
    /// window where Location Services is disabled without ever playing silent audio).
    public func beginTransientBackgroundBridge(reason: String = "Reloc.LocationRefresh") {
        guard isActive else { return }
        keepTransientTaskActive = true
        renewBackgroundTask(name: reason)
        emitStatus("keepalive_bridge_armed")
    }

    /// Releases any temporary background task bridge once Location Services & accessory lock recover.
    public func endTransientBackgroundBridge() {
        keepTransientTaskActive = false
        if isLocationUpdating {
            endBackgroundTask()
        }
    }

    public func stop() {
        isActive = false
        locationSubscriptionActive = false
        isLocationUpdating = false
        keepTransientTaskActive = false
        lastLocationCallbackAt = 0
        stopWatchdog()

        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = false

        invalidateBackgroundActivitySession()
        endBackgroundTask()
    }

    /// Call after global Location Services is toggled OFF -> ON (e.g. `0xFFFC` -> `0xFFFA`),
    /// because turning Location Services off invalidates the previous `CLBackgroundActivitySession`.
    public func refreshAfterLocationToggle() {
        guard isActive else { return }
        let status = locationManager.authorizationStatus
        // Ignore early 0xFFFA callbacks while CoreLocation still reports denied/restricted;
        // restarting CLBackgroundActivitySession before authorization recovers causes a 0xFFFC/0xFFFA bounce loop.
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        let now = Self.monotonicNow
        guard now - lastRefreshToggleAt >= 1.5 else { return }
        lastRefreshToggleAt = now
        invalidateBackgroundActivitySession()
        startBackgroundActivitySessionIfAvailable()
        startBackgroundLocation(forceRestart: false)
        emitStatus("keepalive_refreshed")
    }

    // MARK: - Background Location Keep-Alive

    private func startBackgroundActivitySessionIfAvailable() {
        if #available(iOS 17.0, *), backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }
    }

    private func invalidateBackgroundActivitySession() {
        if #available(iOS 17.0, *) {
            (backgroundActivitySession as? CLBackgroundActivitySession)?.invalidate()
        }
        backgroundActivitySession = nil
    }

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
            invalidateBackgroundActivitySession()
        }

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return
        }

        startBackgroundActivitySessionIfAvailable()
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .otherNavigation
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
        if !isLocationUpdating {
            locationManager.startUpdatingLocation()
            isLocationUpdating = true
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
            "mode": "location_only",
            "app_state": UIApplication.shared.applicationState == .background ? "background" : "foreground",
        ])
    }

    // MARK: - Transient Background Task & Low-Wakeup Health Watchdog

    private func renewBackgroundTask(name: String) {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
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

    /// Low-wakeup 30s health check with generous 5s timer leeway so iOS coalesces CPU wakeups.
    /// Only touches `CLLocationManager` if updates genuinely stalled for > 25s or stopped.
    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.locationSubscriptionActive else { return }
                let status = self.locationManager.authorizationStatus
                guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }

                let stalled = self.lastLocationCallbackAt > 0
                    && (Self.monotonicNow - self.lastLocationCallbackAt) >= 25.0
                if !self.isLocationUpdating {
                    self.startBackgroundLocation(forceRestart: false)
                    self.emitStatus("keepalive_location_restarted")
                } else if stalled {
                    self.nudgeLocationSubscription()
                    self.emitStatus("keepalive_location_stalled_nudged")
                }
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

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

    @objc private func handleDidEnterBackground() {
        guard isActive else { return }
        if locationSubscriptionActive {
            startBackgroundLocation(forceRestart: false)
        } else {
            renewBackgroundTask(name: "Reloc.BackgroundTransition")
        }
        emitStatus("app_background")
    }

    @objc private func handleWillEnterForeground() {
        guard isActive else { return }
        if locationSubscriptionActive {
            startBackgroundLocation(forceRestart: false)
            if !keepTransientTaskActive {
                endBackgroundTask()
            }
        }
        emitStatus("app_foreground")
        onForegroundResume?()
    }

    // MARK: - CLLocationManagerDelegate

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        let newAccuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.onAuthorizationChange?(newStatus, newAccuracy)
            guard self.isActive else { return }
            let recovered = (self.lastAuthStatus == .denied || self.lastAuthStatus == .restricted)
                && (newStatus == .authorizedAlways || newStatus == .authorizedWhenInUse)
            self.lastAuthStatus = newStatus
            if newStatus == .denied || newStatus == .restricted {
                self.isLocationUpdating = false
                self.invalidateBackgroundActivitySession()
            } else if recovered {
                self.refreshAfterLocationToggle()
            } else if self.locationSubscriptionActive {
                self.startBackgroundLocation(forceRestart: false)
            }
        }
    }

    public nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isActive, self.locationSubscriptionActive else { return }
            self.isLocationUpdating = false
            self.startBackgroundLocation(forceRestart: false)
            self.emitStatus("keepalive_location_resumed_after_pause")
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocationCallbackAt = Self.monotonicNow
            if !self.keepTransientTaskActive && self.backgroundTaskID != .invalid {
                self.endBackgroundTask()
            }
            self.onLocationUpdate?(loc)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore transient CoreLocation errors while background location keep-alive runs.
    }
}
