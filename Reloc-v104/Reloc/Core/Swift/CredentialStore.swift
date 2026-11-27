import Foundation
import SwiftUI

public enum AppAppearanceMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("appearance.system")
        case .light: return L10n.tr("appearance.light")
        case .dark: return L10n.tr("appearance.dark")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public enum MapSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleNative
    case globalStreet
    case globalOSM
    case globalSatellite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleNative: return L10n.tr("map.source.apple")
        case .globalStreet: return L10n.tr("map.source.esri_street")
        case .globalOSM: return L10n.tr("map.source.osm")
        case .globalSatellite: return L10n.tr("map.source.esri_satellite")
        }
    }

    public var shortTitle: String {
        switch self {
        case .appleNative: return L10n.tr("map.source.apple.short")
        case .globalStreet: return L10n.tr("map.source.esri_street.short")
        case .globalOSM: return L10n.tr("map.source.osm.short")
        case .globalSatellite: return L10n.tr("map.source.esri_satellite.short")
        }
    }

    /// True when the tile source uses pure WGS-84 coordinates (no GCJ-02 shift in Mainland China).
    public var isPureWGS84: Bool {
        self != .appleNative
    }
}

public enum MapDisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case satellite
    case hybrid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return L10n.tr("map.style.standard")
        case .satellite: return L10n.tr("map.style.satellite")
        case .hybrid: return L10n.tr("map.style.hybrid")
        }
    }
}

public struct FavoriteLocation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

public struct RecentLocation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String?
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var usedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String? = nil,
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0,
        usedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.usedAt = usedAt
    }
}

public struct InterruptedSessionRecord: Codable, Equatable, Sendable {
    public var placeName: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var savedAt: Date

    public init(
        placeName: String,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        savedAt: Date = Date()
    ) {
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.savedAt = savedAt
    }
}

/// Persists location preferences, favorites, history and recovery snapshots.
public final class CredentialStore {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let interval = "reloc.interval"
        static let duration = "reloc.duration"
        static let gcj02Correction = "reloc.gcj02Correction"
        static let backgroundKeepAlive = "reloc.backgroundKeepAlive"
        static let microJitter = "reloc.microJitter"
        static let appearance = "reloc.appearance"
        static let language = L10n.languageDefaultsKey
        static let mapStyle = "reloc.mapStyle"
        static let mapSource = "reloc.mapSource"
        static let favorites = "reloc.favorites"
        static let recents = "reloc.recents"
        static let interruptedSession = "reloc.interruptedSession"
        static let lastLatitude = "reloc.lastLat"
        static let lastLongitude = "reloc.lastLon"
        static let lastAltitude = "reloc.lastAlt"
    }

    public var intervalSeconds: Double {
        get {
            let v = defaults.double(forKey: Keys.interval)
            return v >= 1.0 ? v : 1.0
        }
        set { defaults.set(max(1.0, newValue), forKey: Keys.interval) }
    }

    public var durationSeconds: Double {
        get { max(0.0, defaults.double(forKey: Keys.duration)) }
        set { defaults.set(max(0.0, newValue), forKey: Keys.duration) }
    }

    public var gcj02CorrectionEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.gcj02Correction) == nil { return true }
            return defaults.bool(forKey: Keys.gcj02Correction)
        }
        set { defaults.set(newValue, forKey: Keys.gcj02Correction) }
    }

    public var backgroundKeepAliveEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.backgroundKeepAlive) == nil { return true }
            return defaults.bool(forKey: Keys.backgroundKeepAlive)
        }
        set { defaults.set(newValue, forKey: Keys.backgroundKeepAlive) }
    }

    public var microJitterEnabled: Bool {
        get { defaults.bool(forKey: Keys.microJitter) }
        set { defaults.set(newValue, forKey: Keys.microJitter) }
    }

    public var appearanceMode: AppAppearanceMode {
        get { defaults.string(forKey: Keys.appearance).flatMap(AppAppearanceMode.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    public var appLanguage: AppLanguage {
        get { defaults.string(forKey: Keys.language).flatMap(AppLanguage.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.language) }
    }

    public var mapStyle: MapDisplayStyle {
        get { defaults.string(forKey: Keys.mapStyle).flatMap(MapDisplayStyle.init) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Keys.mapStyle) }
    }

    public var mapSource: MapSource {
        get { defaults.string(forKey: Keys.mapSource).flatMap(MapSource.init) ?? .appleNative }
        set { defaults.set(newValue.rawValue, forKey: Keys.mapSource) }
    }

    public var lastTargetLocation: TargetLocation {
        get {
            if defaults.object(forKey: Keys.lastLatitude) == nil {
                return TargetLocation(latitude: 37.334606, longitude: -122.009102, altitude: 20.0)
            }
            return TargetLocation(
                latitude: defaults.double(forKey: Keys.lastLatitude),
                longitude: defaults.double(forKey: Keys.lastLongitude),
                altitude: defaults.object(forKey: Keys.lastAltitude) != nil ? defaults.double(forKey: Keys.lastAltitude) : 10.0
            )
        }
        set {
            defaults.set(newValue.latitude, forKey: Keys.lastLatitude)
            defaults.set(newValue.longitude, forKey: Keys.lastLongitude)
            defaults.set(newValue.altitude, forKey: Keys.lastAltitude)
        }
    }

    // MARK: - Favorites, Recents (max 30), and Interrupted Session Recovery

    public func loadFavorites() -> [FavoriteLocation] {
        guard let data = defaults.data(forKey: Keys.favorites),
              let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) else {
            return [
                FavoriteLocation(name: "Apple Park", subtitle: "Cupertino, CA", latitude: 37.334606, longitude: -122.009102, altitude: 20.0),
                FavoriteLocation(name: L10n.tr("favorite.tokyo_station.name"), subtitle: L10n.tr("favorite.tokyo_station.subtitle"), latitude: 35.681236, longitude: 139.767125, altitude: 10.0),
                FavoriteLocation(name: L10n.tr("favorite.taipei_101.name"), subtitle: L10n.tr("favorite.taipei_101.subtitle"), latitude: 25.033964, longitude: 121.564468, altitude: 12.0),
            ]
        }
        return decoded
    }

    public func saveFavorites(_ favorites: [FavoriteLocation]) {
        if let encoded = try? JSONEncoder().encode(favorites) {
            defaults.set(encoded, forKey: Keys.favorites)
        }
    }

    public func loadRecents() -> [RecentLocation] {
        guard let data = defaults.data(forKey: Keys.recents),
              let decoded = try? JSONDecoder().decode([RecentLocation].self, from: data) else {
            return []
        }
        return decoded
    }

    public func saveRecents(_ recents: [RecentLocation]) {
        let trimmed = Array(recents.prefix(30))
        if let encoded = try? JSONEncoder().encode(trimmed) {
            defaults.set(encoded, forKey: Keys.recents)
        }
    }

    public func loadInterruptedSession() -> InterruptedSessionRecord? {
        guard let data = defaults.data(forKey: Keys.interruptedSession) else { return nil }
        return try? JSONDecoder().decode(InterruptedSessionRecord.self, from: data)
    }

    public func saveInterruptedSession(_ record: InterruptedSessionRecord?) {
        guard let record else {
            defaults.removeObject(forKey: Keys.interruptedSession)
            return
        }
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: Keys.interruptedSession)
        }
    }

    // MARK: - Internal Bundled MFi Signer

    public func loadBundledMFiSigner() -> RLMFiSigner? {
        let bundle = Bundle.main
        guard let certURL = bundle.url(forResource: "certificate", withExtension: "p7b", subdirectory: "MFi")
                ?? bundle.url(forResource: "certificate", withExtension: "p7b"),
              let keyURL = bundle.url(forResource: "identity", withExtension: "pk8", subdirectory: "MFi")
                ?? bundle.url(forResource: "identity", withExtension: "pk8"),
              let certData = try? Data(contentsOf: certURL),
              let keyData = try? Data(contentsOf: keyURL) else {
            return nil
        }
        return try? RLMFiSigner(certificateData: certData, privateKeyData: keyData)
    }
}
