import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// Floating live guidance while switching system Location Services off and on.
@MainActor
final class LocationRefreshPresenter: NSObject, ObservableObject {
    static let shared = LocationRefreshPresenter()

    @Published private(set) var isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    private var hostView: SampleBufferHostView?
    private var pipController: AVPictureInPictureController?
    private var possibleObserver: NSKeyValueObservation?
    private var dismissTimer: Timer?

    private var stepIndex: Int = 1
    private var headline: String = L10n.tr("pip.preparing.headline")
    private var subtitle: String = L10n.tr("pip.preparing.subtitle")
    private var countdownSeconds: Int?
    private var outcome: Outcome = .inProgress
    private var frameCounter: Int64 = 0
    private var wantsAutoStart = false
    private var pixelBufferPool: CVPixelBufferPool?

    enum Outcome {
        case inProgress
        case succeeded
        case failed
    }

    private override init() {
        super.init()
    }

    func startLocationRefreshGuide() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        self.stepIndex = 1
        self.headline = L10n.tr("pip.step1.headline")
        self.subtitle = L10n.tr("pip.step1.subtitle")
        self.countdownSeconds = nil
        self.outcome = .inProgress
        self.wantsAutoStart = true

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isSupported = false
            return
        }
        isSupported = true

        configureAudioSession()
        ensureControllerAttached()
        enqueueCurrentFrame()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.tryStartPiPIfDesired()
        }
    }

    func updateLocationRefresh(step: Int, headline: String, subtitle: String, countdown: Int? = nil) {
        if self.outcome == .inProgress,
           self.stepIndex == step,
           self.headline == headline,
           self.subtitle == subtitle,
           self.countdownSeconds == countdown {
            return
        }
        self.stepIndex = step
        self.headline = headline
        self.subtitle = subtitle
        self.countdownSeconds = countdown
        self.outcome = .inProgress
        enqueueCurrentFrame()
    }

    func finishLocationRefresh(succeeded: Bool, message: String, headline: String? = nil) {
        self.outcome = succeeded ? .succeeded : .failed
        self.stepIndex = succeeded ? 3 : self.stepIndex
        self.headline = headline ?? (succeeded ? L10n.tr("pip.finish.succeeded.headline") : L10n.tr("pip.finish.cancelled.headline"))
        self.subtitle = message
        self.countdownSeconds = nil
        self.wantsAutoStart = false
        enqueueCurrentFrame()

        dismissTimer?.invalidate()
        let dTimer = Timer(timeInterval: succeeded ? 3.5 : 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.teardown()
            }
        }
        RunLoop.main.add(dTimer, forMode: .common)
        dismissTimer = dTimer
    }

    func togglePiP() {
        guard let pip = pipController else {
            ensureControllerAttached()
            enqueueCurrentFrame()
            wantsAutoStart = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.tryStartPiPIfDesired()
            }
            return
        }
        if pip.isPictureInPictureActive {
            wantsAutoStart = false
            pip.stopPictureInPicture()
        } else if pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        } else {
            wantsAutoStart = true
            enqueueCurrentFrame()
        }
    }

    func teardown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        wantsAutoStart = false

        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        possibleObserver?.invalidate()
        possibleObserver = nil
        pipController = nil
        hostView?.removeFromSuperview()
        hostView = nil
        pixelBufferPool = nil
        isActive = false
        isPossible = false
        if !BackgroundKeepAlive.hasActiveBackgroundSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Setup & Frame Rendering

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // If BackgroundKeepAlive already activated `.playback`, avoid changing mode or re-activating
        // on the main thread (which stalls mediaserverd and causes PiP launch stutter).
        if session.category == .playback {
            return
        }
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func ensureControllerAttached() {
        guard let window = Self.activeKeyWindow() else { return }

        if hostView == nil {
            let view = SampleBufferHostView(frame: CGRect(x: 16, y: 120, width: 320, height: 112))
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.alpha = 0.02 // Must stay non-zero & attached in window hierarchy for PiP eligibility
            window.addSubview(view)
            hostView = view
        } else if hostView?.superview == nil {
            window.addSubview(hostView!)
        }

        guard let displayLayer = hostView?.displayLayer else { return }
        displayLayer.videoGravity = .resizeAspect

        if pipController == nil {
            let source = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            possibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] ctrl, _ in
                let possible = ctrl.isPictureInPicturePossible
                Task { @MainActor in
                    self?.isPossible = possible
                    if possible {
                        self?.tryStartPiPIfDesired()
                    }
                }
            }
            pipController = controller
        }
    }

    private func tryStartPiPIfDesired() {
        guard wantsAutoStart, let pip = pipController else { return }
        if !pip.isPictureInPictureActive && pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
        }
    }

    private func enqueueCurrentFrame() {
        guard let displayLayer = hostView?.displayLayer else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        guard let buffer = renderSampleBuffer() else { return }
        renderer.enqueue(buffer)
    }

    private func ensurePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pixelBufferPool {
            return pixelBufferPool
        }
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { return nil }
        pixelBufferPool = pool
        return pool
    }

    private func renderSampleBuffer() -> CMSampleBuffer? {
        let width = 640
        let height = 224

        var pixelBuffer: CVPixelBuffer?
        let status: CVReturn
        if let pool = ensurePixelBufferPool(width: width, height: height) {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Flip coordinates so UIKit/NSString drawing is upright
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        UIGraphicsPushContext(ctx)
        drawCard(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDesc
        ) == noErr, let format = formatDesc else { return nil }

        frameCounter += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameCounter, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return sb
    }

    private func drawCard(in rect: CGRect) {
        // Dark sleek surface gradient
        let bgColors: [CGColor]
        switch outcome {
        case .inProgress:
            bgColors = [
                UIColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1).cgColor,
            ]
        case .succeeded:
            bgColors = [
                UIColor(red: 0.05, green: 0.22, blue: 0.16, alpha: 1).cgColor,
                UIColor(red: 0.04, green: 0.13, blue: 0.10, alpha: 1).cgColor,
            ]
        case .failed:
            bgColors = [
                UIColor(red: 0.24, green: 0.08, blue: 0.09, alpha: 1).cgColor,
                UIColor(red: 0.14, green: 0.05, blue: 0.06, alpha: 1).cgColor,
            ]
        }

        if let ctx = UIGraphicsGetCurrentContext(),
           let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }

        // Top accent bar
        let accentColor: UIColor
        switch outcome {
        case .inProgress:
            accentColor = UIColor(red: 0.30, green: 0.56, blue: 1.0, alpha: 1)
        case .succeeded:
            accentColor = UIColor(red: 0.16, green: 0.82, blue: 0.54, alpha: 1)
        case .failed:
            accentColor = UIColor(red: 0.96, green: 0.34, blue: 0.34, alpha: 1)
        }
        accentColor.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: rect.width, height: 6))

        // Header badge
        let dotRect = CGRect(x: 24, y: 26, width: 12, height: 12)
        UIBezierPath(ovalIn: dotRect).fill()

        let headerText = L10n.tr("pip.header") as NSString
        headerText.draw(
            at: CGPoint(x: 46, y: 20),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 21, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.88),
            ]
        )

        // Right countdown or step pill
        if outcome == .inProgress {
            let statusBadge = L10n.format("pip.step_badge", stepIndex) as NSString
            let size = statusBadge.size(withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
            ])
            statusBadge.draw(
                at: CGPoint(x: rect.width - size.width - 24, y: 22),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .semibold),
                    .foregroundColor: accentColor,
                ]
            )
        }

        // Subtle divider
        UIColor.white.withAlphaComponent(0.12).setFill()
        UIRectFill(CGRect(x: 24, y: 58, width: rect.width - 48, height: 1.5))

        if let secs = countdownSeconds {
            let text = (secs > 0 ? L10n.format("pip.countdown.seconds", secs) : L10n.tr("pip.countdown.now")) as NSString
            let bigAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: secs > 0 ? 68 : 44, weight: .bold),
                .foregroundColor: secs > 0
                    ? UIColor(red: 1.0, green: 0.80, blue: 0.28, alpha: 1)
                    : UIColor(red: 0.16, green: 0.86, blue: 0.56, alpha: 1),
            ]
            let bigSize = text.size(withAttributes: bigAttrs)
            text.draw(
                at: CGPoint(x: (rect.width - bigSize.width) / 2, y: secs > 0 ? 70 : 84),
                withAttributes: bigAttrs
            )

            let hint = subtitle as NSString
            let hintPara = NSMutableParagraphStyle()
            hintPara.alignment = .center
            hintPara.lineBreakMode = .byWordWrapping
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.82),
                .paragraphStyle: hintPara,
            ]
            hint.draw(
                in: CGRect(x: 24, y: 158, width: rect.width - 48, height: 54),
                withAttributes: hintAttrs
            )
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail

            (headline as NSString).draw(
                in: CGRect(x: 24, y: 76, width: rect.width - 48, height: 42),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                ]
            )

            let subPara = NSMutableParagraphStyle()
            subPara.lineSpacing = 4
            (subtitle as NSString).draw(
                in: CGRect(x: 24, y: 126, width: rect.width - 48, height: 76),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 22, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.76),
                    .paragraphStyle: subPara,
                ]
            )
        }
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }
}

extension LocationRefreshPresenter: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.isActive = false
        }
    }
}

extension LocationRefreshPresenter: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Task { @MainActor in
            self.enqueueCurrentFrame()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

private final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}
