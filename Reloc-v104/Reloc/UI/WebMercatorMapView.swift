import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Pure UIKit Web Mercator (EPSG:3857) tile map view for WGS-84 global tile sources.
/// Completely independent of `MKMapView` so Apple China GeoServices / AutoNavi ("高德地图")
/// logos and GCJ-02 shifts never appear.
struct WebMercatorMapView: UIViewRepresentable {
    let activeCoordinate: CLLocationCoordinate2D
    let isSessionRunning: Bool
    let pendingCoordinate: CLLocationCoordinate2D?
    let mapSource: MapSource
    @Binding var cameraTarget: CLLocationCoordinate2D?
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeUIView(context: Context) -> WebMercatorCanvasView {
        let view = WebMercatorCanvasView(frame: .zero)
        view.onTapCoordinate = onTapCoordinate
        view.onRegionChange = onRegionChange
        view.mapSource = mapSource
        view.setCenter(activeCoordinate, zoom: 15.0, animated: false)
        view.updatePins(active: activeCoordinate, isRunning: isSessionRunning, pending: pendingCoordinate)
        return view
    }

    func updateUIView(_ uiView: WebMercatorCanvasView, context: Context) {
        uiView.onTapCoordinate = onTapCoordinate
        uiView.onRegionChange = onRegionChange
        if uiView.mapSource != mapSource {
            uiView.mapSource = mapSource
        }
        uiView.updatePins(active: activeCoordinate, isRunning: isSessionRunning, pending: pendingCoordinate)

        if let target = cameraTarget {
            let desiredZoom = max(uiView.currentZoom, 14.5)
            uiView.setCenter(target, zoom: desiredZoom, animated: true)
            DispatchQueue.main.async {
                cameraTarget = nil
            }
        }
    }
}

// MARK: - Projection Helpers

enum WebMercatorProjection {
    static let maxLatitude: Double = 85.05112878

    static func toNormalized(_ coord: CLLocationCoordinate2D) -> CGPoint {
        let lon = coord.longitude.isFinite ? coord.longitude : 0.0
        let lat = min(maxLatitude, max(-maxLatitude, coord.latitude.isFinite ? coord.latitude : 0.0))
        let x = (lon + 180.0) / 360.0
        let rad = lat * .pi / 180.0
        let y = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / .pi) / 2.0
        return CGPoint(x: x - floor(x), y: min(1.0, max(0.0, y)))
    }

    static func toCoordinate(_ normalized: CGPoint) -> CLLocationCoordinate2D {
        let wx = normalized.x - floor(normalized.x)
        let lon = wx * 360.0 - 180.0
        let clampedY = min(1.0, max(0.0, normalized.y))
        let n = .pi - 2.0 * .pi * clampedY
        let lat = atan(sinh(n)) * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Native UIKit Tile Map Canvas

final class WebMercatorCanvasView: UIView, UIGestureRecognizerDelegate {
    private struct TileKey: Hashable {
        let source: MapSource
        let z: Int
        let x: Int
        let y: Int

        var cacheKey: NSString {
            "\(source.rawValue)/\(z)/\(x)/\(y)" as NSString
        }
    }

    var onTapCoordinate: ((CLLocationCoordinate2D) -> Void)?
    var onRegionChange: ((MKCoordinateRegion) -> Void)?
    private var hasReportedInitialRegion = false
    var mapSource: MapSource = .globalStreet {
        didSet {
            if oldValue != mapSource {
                clearRenderedTiles()
                setNeedsLayout()
            }
        }
    }

    private(set) var currentZoom: Double = 15.0
    private var centerNorm = CGPoint(x: 0.5, y: 0.5)
    private let minZoom: Double = 2.0
    private let maxZoom: Double = 18.5

    private let tileContainer = UIView()
    private let pinContainer = UIView()
    private let activePin = MapPinView(kind: .active)
    private let pendingPin = MapPinView(kind: .pending)

    private var activeCoord = CLLocationCoordinate2D(latitude: 37.334606, longitude: -122.009102)
    private var pendingCoord: CLLocationCoordinate2D?

    private var tileViews: [TileKey: UIImageView] = [:]
    private var inFlightTasks: [TileKey: URLSessionDataTask] = [:]
    private var failedTiles: [TileKey: CFAbsoluteTime] = [:]

    // Pan / Pinch / Animation state
    private var panStartCenterNorm = CGPoint.zero
    private var pinchStartZoom: Double = 15.0
    private var pinchAnchorNorm = CGPoint.zero
    private var displayLink: CADisplayLink?
    private var velocityPixelsPerSec = CGPoint.zero
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var animFromNorm = CGPoint.zero
    private var animToNorm = CGPoint.zero
    private var animFromZoom: Double = 15.0
    private var animToZoom: Double = 15.0
    private var isCameraAnimating = false

    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 260
        return cache
    }()

    private static let tileSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "reloc_mercator_tiles"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = [
            "User-Agent": "Reloc/1.0 (iOS; https://github.com/reloc)",
        ]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        stopDisplayLink()
        for task in inFlightTasks.values {
            task.cancel()
        }
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground
        clipsToBounds = true

        tileContainer.isUserInteractionEnabled = false
        addSubview(tileContainer)

        pinContainer.isUserInteractionEnabled = false
        addSubview(pinContainer)

        pinContainer.addSubview(activePin)
        pendingPin.isHidden = true
        pinContainer.addSubview(pendingPin)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tileContainer.frame = bounds
        pinContainer.frame = bounds
        renderScene()
        if !hasReportedInitialRegion, bounds.width > 1, bounds.height > 1 {
            hasReportedInitialRegion = true
            notifyRegionChanged()
        }
    }

    var currentVisibleRegion: MKCoordinateRegion {
        let center = WebMercatorProjection.toCoordinate(centerNorm)
        guard bounds.width > 1, bounds.height > 1 else {
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
            )
        }
        let worldPixels = 256.0 * pow(2.0, currentZoom)
        let lonDelta = min(360.0, max(0.002, Double(bounds.width) / worldPixels * 360.0))
        let topCoord = WebMercatorProjection.toCoordinate(normalized(forScreenPoint: CGPoint(x: bounds.midX, y: 0)))
        let bottomCoord = WebMercatorProjection.toCoordinate(normalized(forScreenPoint: CGPoint(x: bounds.midX, y: bounds.height)))
        let latDelta = min(170.0, max(0.002, abs(topCoord.latitude - bottomCoord.latitude)))
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    private func notifyRegionChanged() {
        guard let onRegionChange else { return }
        let region = currentVisibleRegion
        DispatchQueue.main.async {
            onRegionChange(region)
        }
    }

    func setCenter(_ coordinate: CLLocationCoordinate2D, zoom: Double, animated: Bool) {
        let targetNorm = WebMercatorProjection.toNormalized(coordinate)
        let clampedZoom = min(maxZoom, max(minZoom, zoom))
        stopDisplayLink()

        if !animated || bounds.isEmpty {
            centerNorm = targetNorm
            currentZoom = clampedZoom
            renderScene()
            if !bounds.isEmpty {
                notifyRegionChanged()
            }
            return
        }

        animFromNorm = centerNorm
        animToNorm = targetNorm
        // Take shortest longitudinal path across the antimeridian
        var dx = animToNorm.x - animFromNorm.x
        if dx > 0.5 { dx -= 1.0 }
        if dx < -0.5 { dx += 1.0 }
        animToNorm.x = animFromNorm.x + dx

        animFromZoom = currentZoom
        animToZoom = clampedZoom
        animationStartTime = CACurrentMediaTime()
        animationDuration = 0.36
        isCameraAnimating = true
        startDisplayLink()
    }

    func updatePins(active: CLLocationCoordinate2D, isRunning: Bool, pending: CLLocationCoordinate2D?) {
        activeCoord = active
        pendingCoord = pending
        activePin.setRunning(isRunning)
        pendingPin.isHidden = (pending == nil)
        layoutPins()
    }

    // MARK: - Gestures

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let worldPixels = 256.0 * pow(2.0, currentZoom)
        switch gesture.state {
        case .began:
            stopDisplayLink()
            panStartCenterNorm = centerNorm
        case .changed:
            let translation = gesture.translation(in: self)
            let nx = panStartCenterNorm.x - Double(translation.x) / worldPixels
            let ny = panStartCenterNorm.y - Double(translation.y) / worldPixels
            centerNorm = CGPoint(x: nx - floor(nx), y: min(0.999, max(0.001, ny)))
            renderScene()
        case .ended:
            let vel = gesture.velocity(in: self)
            let speed = hypot(vel.x, vel.y)
            if speed > 80 {
                velocityPixelsPerSec = vel
                isCameraAnimating = false
                startDisplayLink()
            } else {
                notifyRegionChanged()
            }
        case .cancelled:
            notifyRegionChanged()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            stopDisplayLink()
            pinchStartZoom = currentZoom
            pinchAnchorNorm = normalized(forScreenPoint: location)
        case .changed:
            guard gesture.scale > 0 else { return }
            let nextZoom = min(maxZoom, max(minZoom, pinchStartZoom + log2(Double(gesture.scale))))
            currentZoom = nextZoom
            let newWorld = 256.0 * pow(2.0, currentZoom)
            let dx = Double(location.x - bounds.midX) / newWorld
            let dy = Double(location.y - bounds.midY) / newWorld
            let nx = pinchAnchorNorm.x - dx
            let ny = pinchAnchorNorm.y - dy
            centerNorm = CGPoint(x: nx - floor(nx), y: min(0.999, max(0.001, ny)))
            renderScene()
        case .ended, .cancelled:
            notifyRegionChanged()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        let coord = WebMercatorProjection.toCoordinate(normalized(forScreenPoint: pt))
        setCenter(coord, zoom: min(maxZoom, currentZoom + 1.25), animated: true)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        let pt = gesture.location(in: self)
        let norm = normalized(forScreenPoint: pt)
        let coord = WebMercatorProjection.toCoordinate(norm)
        onTapCoordinate?(coord)
    }

    // MARK: - DisplayLink Physics & Camera Animation

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(stepDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        isCameraAnimating = false
        velocityPixelsPerSec = .zero
    }

    @objc private func stepDisplayLink(_ link: CADisplayLink) {
        if isCameraAnimating {
            let elapsed = CACurrentMediaTime() - animationStartTime
            let t = min(1.0, max(0.0, elapsed / max(0.01, animationDuration)))
            // Cubic ease-out
            let eased = 1.0 - pow(1.0 - t, 3.0)
            let nx = animFromNorm.x + (animToNorm.x - animFromNorm.x) * eased
            let ny = animFromNorm.y + (animToNorm.y - animFromNorm.y) * eased
            centerNorm = CGPoint(x: nx - floor(nx), y: min(0.999, max(0.001, ny)))
            currentZoom = animFromZoom + (animToZoom - animFromZoom) * eased
            renderScene()
            if t >= 1.0 {
                stopDisplayLink()
                notifyRegionChanged()
            }
            return
        }

        // Inertial pan deceleration
        let dt = min(0.05, max(0.001, link.targetTimestamp - link.timestamp))
        let worldPixels = 256.0 * pow(2.0, currentZoom)
        let nx = centerNorm.x - Double(velocityPixelsPerSec.x) * dt / worldPixels
        let ny = centerNorm.y - Double(velocityPixelsPerSec.y) * dt / worldPixels
        centerNorm = CGPoint(x: nx - floor(nx), y: min(0.999, max(0.001, ny)))

        let damping = pow(0.04, dt)
        velocityPixelsPerSec.x *= damping
        velocityPixelsPerSec.y *= damping
        renderScene()

        if hypot(velocityPixelsPerSec.x, velocityPixelsPerSec.y) < 18.0 {
            stopDisplayLink()
            notifyRegionChanged()
        }
    }

    // MARK: - Coordinate <-> Screen Mapping

    private func screenPoint(for norm: CGPoint) -> CGPoint {
        let worldPixels = 256.0 * pow(2.0, currentZoom)
        var dx = norm.x - centerNorm.x
        if dx > 0.5 { dx -= 1.0 }
        if dx < -0.5 { dx += 1.0 }
        let dy = norm.y - centerNorm.y
        return CGPoint(
            x: bounds.midX + dx * worldPixels,
            y: bounds.midY + dy * worldPixels
        )
    }

    private func normalized(forScreenPoint pt: CGPoint) -> CGPoint {
        let worldPixels = 256.0 * pow(2.0, currentZoom)
        let nx = centerNorm.x + Double(pt.x - bounds.midX) / worldPixels
        let ny = centerNorm.y + Double(pt.y - bounds.midY) / worldPixels
        return CGPoint(x: nx - floor(nx), y: min(0.999, max(0.001, ny)))
    }

    // MARK: - Tile Rendering & Caching

    private func clearRenderedTiles() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        failedTiles.removeAll()
        for view in tileViews.values {
            view.removeFromSuperview()
        }
        tileViews.removeAll()
    }

    private func renderScene() {
        guard bounds.width > 1, bounds.height > 1 else { return }

        let worldPixels = 256.0 * pow(2.0, currentZoom)
        let tileZ = max(2, min(19, Int(ceil(currentZoom))))
        let n = 1 << tileZ
        let tileDrawSize = worldPixels / Double(n)

        let halfW = Double(bounds.width) / 2.0 / worldPixels
        let halfH = Double(bounds.height) / 2.0 / worldPixels

        let minTileX = Int(floor((centerNorm.x - halfW) * Double(n))) - 1
        let maxTileX = Int(floor((centerNorm.x + halfW) * Double(n))) + 1
        let minTileY = max(0, Int(floor((centerNorm.y - halfH) * Double(n))) - 1)
        let maxTileY = min(n - 1, Int(floor((centerNorm.y + halfH) * Double(n))) + 1)

        var neededKeys = Set<TileKey>()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for ty in minTileY...maxTileY {
            for rawTx in minTileX...maxTileX {
                let wrappedX = ((rawTx % n) + n) % n
                let key = TileKey(source: mapSource, z: tileZ, x: wrappedX, y: ty)
                neededKeys.insert(key)

                let tileNormX = Double(rawTx) / Double(n)
                let tileNormY = Double(ty) / Double(n)
                let screenX = Double(bounds.midX) + (tileNormX - centerNorm.x) * worldPixels
                let screenY = Double(bounds.midY) + (tileNormY - centerNorm.y) * worldPixels
                // Tiny 0.5pt overlap prevents hairline seams at fractional zoom scales
                let frame = CGRect(
                    x: floor(screenX),
                    y: floor(screenY),
                    width: ceil(tileDrawSize) + 1.0,
                    height: ceil(tileDrawSize) + 1.0
                )

                if let existing = tileViews[key] {
                    existing.frame = frame
                } else {
                    let imgView = UIImageView(frame: frame)
                    imgView.contentMode = .scaleToFill
                    imgView.clipsToBounds = true
                    tileContainer.addSubview(imgView)
                    tileViews[key] = imgView

                    if let cached = Self.memoryCache.object(forKey: key.cacheKey) {
                        imgView.image = cached
                    } else {
                        applyParentPreviewIfAvailable(to: imgView, for: key)
                        fetchTile(for: key)
                    }
                }
            }
        }

        // Prune off-screen tile views and cancel stale downloads
        for (key, view) in tileViews where !neededKeys.contains(key) {
            view.removeFromSuperview()
            tileViews.removeValue(forKey: key)
        }
        for (key, task) in inFlightTasks where !neededKeys.contains(key) {
            task.cancel()
            inFlightTasks.removeValue(forKey: key)
        }

        layoutPins()
        CATransaction.commit()
    }

    private func layoutPins() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let activePt = screenPoint(for: WebMercatorProjection.toNormalized(activeCoord))
        activePin.center = CGPoint(x: activePt.x, y: activePt.y - activePin.bounds.height / 2.0)

        if let pending = pendingCoord {
            let pendingPt = screenPoint(for: WebMercatorProjection.toNormalized(pending))
            pendingPin.center = CGPoint(x: pendingPt.x, y: pendingPt.y - pendingPin.bounds.height / 2.0)
        }
    }

    private func applyParentPreviewIfAvailable(to imgView: UIImageView, for key: TileKey) {
        for delta in 1...3 {
            let pz = key.z - delta
            guard pz >= 2 else { break }
            let scale = 1 << delta
            let px = key.x / scale
            let py = key.y / scale
            let parentKey = TileKey(source: key.source, z: pz, x: px, y: py)
            if let parentImage = Self.memoryCache.object(forKey: parentKey.cacheKey) {
                imgView.image = parentImage
                let subX = CGFloat(key.x % scale) / CGFloat(scale)
                let subY = CGFloat(key.y % scale) / CGFloat(scale)
                let size = 1.0 / CGFloat(scale)
                imgView.layer.contentsRect = CGRect(x: subX, y: subY, width: size, height: size)
                return
            }
        }
    }

    private func tileURL(for key: TileKey) -> URL {
        switch key.source {
        case .globalStreet, .appleNative:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/\(key.z)/\(key.y)/\(key.x)")!
        case .globalOSM:
            return URL(string: "https://tile.openstreetmap.org/\(key.z)/\(key.x)/\(key.y).png")!
        case .globalSatellite:
            return URL(string: "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/\(key.z)/\(key.y)/\(key.x)")!
        }
    }

    private func fetchTile(for key: TileKey) {
        guard inFlightTasks[key] == nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if let failedAt = failedTiles[key] {
            if now - failedAt < 15.0 {
                return
            }
            failedTiles.removeValue(forKey: key)
        }
        var req = URLRequest(url: tileURL(for: key))
        req.cachePolicy = .returnCacheDataElseLoad

        let task = Self.tileSession.dataTask(with: req) { [weak self] data, response, error in
            let image: UIImage?
            if error == nil,
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let data,
               let decoded = UIImage(data: data) {
                image = decoded
            } else {
                image = nil
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightTasks.removeValue(forKey: key)
                guard let image else {
                    if self.failedTiles.count > 500 {
                        self.failedTiles.removeAll()
                    }
                    self.failedTiles[key] = CFAbsoluteTimeGetCurrent()
                    return
                }
                Self.memoryCache.setObject(image, forKey: key.cacheKey)
                if let imgView = self.tileViews[key] {
                    imgView.layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    imgView.image = image
                }
            }
        }
        inFlightTasks[key] = task
        task.resume()
    }
}

// MARK: - Pin Marker View

private final class MapPinView: UIView {
    enum Kind { case active, pending }

    private let kind: Kind
    private let badge = UIView()
    private let icon = UIImageView()
    private let stem = UIView()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: CGRect(x: 0, y: 0, width: 38, height: 46))
        isUserInteractionEnabled = false

        badge.frame = CGRect(x: 2, y: 0, width: 34, height: 34)
        badge.layer.cornerRadius = 17
        badge.layer.borderWidth = 2.5
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.shadowColor = UIColor.black.cgColor
        badge.layer.shadowOpacity = 0.28
        badge.layer.shadowRadius = 5
        badge.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(badge)

        let symName = kind == .active ? "location.fill" : "mappin"
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        icon.image = UIImage(systemName: symName, withConfiguration: cfg)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = badge.bounds
        badge.addSubview(icon)

        stem.frame = CGRect(x: 17, y: 32, width: 4, height: 14)
        stem.layer.cornerRadius = 2
        stem.layer.borderWidth = 1
        stem.layer.borderColor = UIColor.white.cgColor
        addSubview(stem)

        setRunning(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRunning(_ isRunning: Bool) {
        let color: UIColor
        switch kind {
        case .active:
            color = isRunning ? UIColor(RelocTheme.emerald) : UIColor(RelocTheme.accent)
        case .pending:
            color = UIColor(RelocTheme.amber)
        }
        badge.backgroundColor = color
        stem.backgroundColor = color
    }
}
