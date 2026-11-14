// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AVKit
import SwiftUI

/// The pairing code, drawn into a video layer that Picture in Picture can float
/// over Settings. That does two jobs: the person can read the code, and where
/// to go, while they're in Settings, and crate keeps running in the
/// background, which it must, since iOS only connects once they've picked
/// crate there.
///
/// Picture in Picture starts by itself when crate goes to the background, as
/// long as the person hasn't turned that off (Settings > General > Picture in
/// Picture). It doesn't survive everything, though (iOS may stop it while it
/// asks for the passcode), so crate also plays silence meanwhile, which keeps
/// it running either way: the audio background mode is there for both.
@MainActor
final class PairingCodePictureInPicture: NSObject {
    let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var refresh: Timer?
    private var silence: AVAudioEngine?
    private var text = (title: L10n.string("pair.pip.title"), code: "",
                        note: L10n.string("pair.pip.location"))

    /// The 16:9 frame size drawn, in pixels.
    private static let size = CGSize(width: 960, height: 540)

    override init() {
        super.init()
        layer.videoGravity = .resizeAspect
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
    }

    var isSupported: Bool { controller != nil }

    /// Starts drawing, and readies the audio session Picture in Picture needs
    /// (it plays nothing, and mixes with whatever else is playing).
    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        // Only while pairing: afterwards it would float up again on every
        // trip out of crate.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        playSilence()
        draw()
        // A frame now and then, so the layer always has a current one.
        refresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.draw() }
        }
    }

    func stop() {
        refresh?.invalidate()
        refresh = nil
        silence?.stop()
        silence = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.stopPictureInPicture()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The code, with where to find "Pair with crate" until Settings has
    /// connected and is asking for it.
    func show(code: String, connected: Bool) {
        text = (L10n.string("pair.pip.title"), Self.spaced(code),
                connected ? L10n.string("pair.pip.connectedNote") : L10n.string("pair.pip.location"))
        draw()
    }

    /// How pairing ended, for whoever is still in Settings: it stays up until
    /// crate is back in front, which then calls stop(). crate needn't keep
    /// running for it any more, and it won't float up again by itself.
    func finish(paired: Bool) {
        silence?.stop()
        silence = nil
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        text = paired
            ? ("crate", L10n.string("pair.pip.paired"), L10n.string("pair.pip.returnFinish"))
            : ("crate", L10n.string("pair.pip.notPaired"), L10n.string("pair.pip.returnRetry"))
        draw()
    }

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// "123456" reads more easily as "123 456".
    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    /// Floats the code now, from a button tap (starting it needs one).
    func startNow() {
        controller?.startPictureInPicture()
    }

    /// A quiet buffer on a loop: while it plays, iOS doesn't suspend crate.
    private func playSilence() {
        guard silence == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity  // zeroed: silence
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            AppLog.write("jit: pairing: couldn't play silence to stay running (\(error.localizedDescription))")
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        silence = engine
    }

    // MARK: - Drawing

    private func draw() {
        guard let buffer = Self.render(text) else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(buffer)
    }

    private static func render(_ text: (title: String, code: String, note: String)) -> CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                  attributes, &pixels) == kCVReturnSuccess, let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width),
                                height: Int(size.height), bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        if let context {
            UIGraphicsPushContext(context)
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            UIColor(white: 0.11, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            centered.baseWritingDirection = L10n.isRightToLeft(languageCode: L10n.languageCode)
                ? .rightToLeft : .leftToRight
            func line(_ string: String, font: UIFont, color: UIColor, y: CGFloat) {
                (string as NSString).draw(
                    in: CGRect(x: 0, y: y, width: size.width, height: font.lineHeight * 1.2),
                    withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: centered])
            }
            line(text.title, font: .systemFont(ofSize: 56, weight: .semibold), color: UIColor(white: 0.8, alpha: 1), y: 52)
            // A code in big digits; a word ("Paired") smaller, so it fits.
            let isCode = text.code.allSatisfy { $0.isNumber || $0 == " " }
            line(text.code,
                 font: isCode ? .monospacedDigitSystemFont(ofSize: 190, weight: .bold) : .systemFont(ofSize: 150, weight: .bold),
                 color: .white, y: isCode ? 138 : 162)
            line(text.note, font: .systemFont(ofSize: 46, weight: .medium), color: UIColor(white: 0.7, alpha: 1), y: 404)
            UIGraphicsPopContext()
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// Logged, so a pairing that stopped can be traced to Picture in Picture.
extension PairingCodePictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        AppLog.write("jit: pairing: Picture in Picture started")
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        AppLog.write("jit: pairing: Picture in Picture didn't start (\(error.localizedDescription))")
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        AppLog.write("jit: pairing: Picture in Picture stopped")
    }
}

/// A live stream with nothing to seek: Picture in Picture shows no scrubber.
extension PairingCodePictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime) async {}
}

/// Shows the layer in the setup sheet: Picture in Picture can only float a
/// layer that's on screen.
struct PairingCodeView: UIViewRepresentable {
    let pictureInPicture: PairingCodePictureInPicture

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.layer.addSublayer(pictureInPicture.layer)
        view.clipsToBounds = true
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.first?.frame = bounds
        }
    }
}
