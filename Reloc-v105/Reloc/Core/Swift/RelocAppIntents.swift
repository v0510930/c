import AppIntents
import CoreLocation
import Foundation
import UIKit

private let systemLocationServicesPrefsURL = URL(string: "prefs:root=Privacy&path=LOCATION")!

// MARK: - Shortcut Errors

public enum RelocIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case mfiUnavailable
    case locationPermissionDenied
    case sessionFailed(String)
    case notActivated

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .mfiUnavailable:
            return "error.mfi_unavailable"
        case .locationPermissionDenied:
            return "intent.error.permission_denied"
        case .sessionFailed(let detail):
            return "\(detail)"
        case .notActivated:
            return "请先打开应用完成设备激活"
        }
    }
}

// MARK: - Dynamic Entity: Saved Favorites

public struct FavoritePlaceEntity: AppEntity, Identifiable, Sendable {
    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "intent.entity.favorite")
    }

    public static var defaultQuery = FavoritePlaceQuery()

    public let id: String
    public let name: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "mappin.circle.fill")
        )
    }

    public init(favorite: FavoriteLocation) {
        self.id = favorite.id.uuidString
        self.name = favorite.name
        self.subtitle = favorite.subtitle ?? String(format: "%.5f, %.5f", favorite.latitude, favorite.longitude)
        self.latitude = favorite.latitude
        self.longitude = favorite.longitude
        self.altitude = favorite.altitude
    }
}

public struct FavoritePlaceQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [FavoritePlaceEntity] {
        let all = CredentialStore().loadFavorites()
        var byLowerID: [String: FavoriteLocation] = [:]
        for fav in all {
            byLowerID[fav.id.uuidString.lowercased()] = fav
        }
        return identifiers.compactMap { rawID in
            if let hit = byLowerID[rawID.lowercased()] {
                return FavoritePlaceEntity(favorite: hit)
            }
            if let byName = all.first(where: { $0.name == rawID }) {
                return FavoritePlaceEntity(favorite: byName)
            }
            return nil
        }
    }

    public func entities(matching string: String) async throws -> [FavoritePlaceEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = CredentialStore().loadFavorites()
        guard !trimmed.isEmpty else { return all.map(FavoritePlaceEntity.init) }
        return all
            .filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
            .map(FavoritePlaceEntity.init)
    }

    public func suggestedEntities() async throws -> [FavoritePlaceEntity] {
        CredentialStore().loadFavorites().map(FavoritePlaceEntity.init)
    }
}

// MARK: - 1. Start Virtual Location (Pick Favorite -> Start -> Jump to System Location Services)

public struct StartFavoriteLocationIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.start_favorite.title"
    public static var description = IntentDescription("intent.start_favorite.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.favorite", requestValueDialog: IntentDialog("intent.prompt.choose_favorite"))
    public var place: FavoritePlaceEntity

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Locate \(\.$place) and refresh cache") {
            \.$autoJumpToLocationServices
        }
    }

    public init() {}

    public init(place: FavoritePlaceEntity) {
        self.place = place
        self.autoJumpToLocationServices = true
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        guard ActivationManager.isCurrentlyActivated() else {
            throw RelocIntentError.notActivated
        }
        let vm = RelocViewModel.shared
        guard vm.isMFiSignerReady else {
            throw RelocIntentError.mfiUnavailable
        }
        let auth = vm.locationAuthorizationStatus
        if auth == .denied || auth == .restricted {
            throw RelocIntentError.locationPermissionDenied
        }

        let loc = TargetLocation(latitude: place.latitude, longitude: place.longitude, altitude: place.altitude)
        await vm.startFixedLocationFromShortcut(
            wgsLocation: loc,
            name: place.name,
            subtitle: place.subtitle
        )
        await vm.waitForShortcutAuthReady(timeoutSeconds: 2.5)

        if let err = vm.snapshot.lastError, !vm.snapshot.isRunning {
            throw RelocIntentError.sessionFailed(err)
        }

        // Wait until Reloc's foreground window is active so the 7s PiP refresh overlay attaches cleanly.
        let activeDeadline = Date().addingTimeInterval(1.5)
        while UIApplication.shared.applicationState != .active && Date() < activeDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                // Attach 7s PiP overlay first, then hand off `prefs:root=Privacy&path=LOCATION`
                // to Shortcuts' system OpenURLIntent so iOS lands directly on Location Services
                // instead of falling back to Reloc's own App Settings page.
                vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            vm.launchOneTapLocationRefresh(skipAutoSettingsJump: false)
        } else {
            // Prepare the PiP countdown & background bridge when the user chains Shortcuts' own
            // "Open URL" action with the returned `prefs:root=Privacy&path=LOCATION`.
            vm.launchOneTapLocationRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - 2. Stop Virtual Location & Refresh System Location Services

public struct StopLocationIntent: AppIntent {
    public static var title: LocalizedStringResource = "intent.stop.title"
    public static var description = IntentDescription("intent.stop.desc")
    public static var openAppWhenRun: Bool = true

    @Parameter(title: "intent.param.auto_jump_settings", default: true)
    public var autoJumpToLocationServices: Bool

    public static var parameterSummary: some ParameterSummary {
        Summary("Stop virtual location and refresh cache") {
            \.$autoJumpToLocationServices
        }
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<URL> & OpensIntent {
        guard ActivationManager.isCurrentlyActivated() else {
            throw RelocIntentError.notActivated
        }
        let vm = RelocViewModel.shared
        if vm.snapshot.isRunning {
            vm.stopAndRestore()
        }

        // Wait until Reloc's foreground window is active so the 7s restore PiP overlay attaches cleanly.
        let activeDeadline = Date().addingTimeInterval(1.5)
        while UIApplication.shared.applicationState != .active && Date() < activeDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if autoJumpToLocationServices {
            if #available(iOS 18.2, *) {
                vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                return .result(
                    value: systemLocationServicesPrefsURL,
                    opensIntent: OpenURLIntent(systemLocationServicesPrefsURL)
                )
            }
            vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: false)
        } else {
            vm.launchOneTapRestoreRefresh(skipAutoSettingsJump: true)
            try? await Task.sleep(nanoseconds: 450_000_000)
        }

        return .result(value: systemLocationServicesPrefsURL)
    }
}

// MARK: - App Shortcuts Provider (Only 2 Essential Daily Shortcuts)

public struct RelocAppShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .blue }

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFavoriteLocationIntent(),
            phrases: [
                "Start \(.applicationName)",
                "用 \(.applicationName) 开始定位",
                "开启 \(.applicationName) 虚拟定位",
            ],
            shortTitle: "intent.start_favorite.short",
            systemImageName: "location.north.circle.fill"
        )
        AppShortcut(
            intent: StopLocationIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "关闭 \(.applicationName) 虚拟定位",
                "停止 \(.applicationName) 定位",
            ],
            shortTitle: "intent.stop.short",
            systemImageName: "stop.circle.fill"
        )
    }
}
