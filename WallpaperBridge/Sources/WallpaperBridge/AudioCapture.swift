import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Listens to the Mac's sound output with ScreenCaptureKit and turns it into the same shape
/// Wallpaper Engine gives web wallpapers: 128 levels, 64 frequency bands for the left channel
/// followed by 64 for the right, roughly 0...1. Nothing is recorded or saved.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Wallpaper Bridge needs permission to hear system audio."
            case .noDisplay:
                return "No display was found to capture audio from."
            }
        }
    }

    static func describe(_ error: Error) -> String {
        "Couldn't listen to system audio. In System Settings › Privacy & Security › Screen & System Audio Recording, turn on Wallpaper Bridge (or Xcode while running from Xcode), then turn “React to audio” off and on again. (\(error.localizedDescription))"
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WallpaperBridge.audio", qos: .userInteractive)
    private var activeStream: SCStream?
    private let leftAnalyzer = SpectrumAnalyzer()
    private let rightAnalyzer = SpectrumAnalyzer()
    private var leftSamples: [Float] = []
    private var rightSamples: [Float] = []
    private var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount * 2)
    private var lastUpdate = Date.distantPast

    var isRunning: Bool {
        locked { activeStream != nil }
    }

    func start() async throws {
        if isRunning { return }
        if !CGPreflightScreenCaptureAccess() {
            // Shows the system prompt the first time; returns false until the user allows it.
            guard CGRequestScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false  // so the wallpaper's own music counts too
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video can't be switched off, so ask for the smallest, slowest picture possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        locked { self.activeStream = stream }
    }

    func stop() {
        let running: SCStream? = locked {
            let current = activeStream
            activeStream = nil
            leftSamples.removeAll()
            rightSamples.removeAll()
            bands = [Float](repeating: 0, count: bands.count)
            return current
        }
        running?.stopCapture { _ in }
    }

    /// The latest levels. When nothing is playing, they fall back towards zero.
    func latestBands() -> [Float] {
        locked {
            if Date().timeIntervalSince(lastUpdate) > 0.15 {
                for index in bands.indices { bands[index] *= 0.8 }
            }
            return bands
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let channels = Self.samples(from: sampleBuffer) else { return }
        let size = SpectrumAnalyzer.size
        locked {
            guard self.activeStream != nil else { return }
            leftSamples.append(contentsOf: channels.left)
            rightSamples.append(contentsOf: channels.right)
            if leftSamples.count > size { leftSamples.removeFirst(leftSamples.count - size) }
            if rightSamples.count > size { rightSamples.removeFirst(rightSamples.count - size) }
            guard leftSamples.count == size, rightSamples.count == size else { return }
            bands = leftAnalyzer.bands(from: leftSamples) + rightAnalyzer.bands(from: rightSamples)
            lastUpdate = Date()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        locked { self.activeStream = nil }
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Float32 samples for the left and right channels (interleaved or not).
    private static func samples(from sampleBuffer: CMSampleBuffer) -> (left: [Float], right: [Float])? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return nil }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channelCount = max(Int(format.mChannelsPerFrame), 1)

        return try? sampleBuffer.withAudioBufferList { list, _ -> (left: [Float], right: [Float]) in
            func floats(_ buffer: AudioBuffer) -> [Float] {
                guard let data = buffer.mData else { return [] }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            }

            if interleaved, channelCount > 1, let first = list.first {
                let all = floats(first)
                var left: [Float] = []
                var right: [Float] = []
                left.reserveCapacity(all.count / channelCount)
                right.reserveCapacity(all.count / channelCount)
                var index = 0
                while index + 1 < all.count {
                    left.append(all[index])
                    right.append(all[index + 1])
                    index += channelCount
                }
                return (left, right)
            }

            let left = list.count > 0 ? floats(list[0]) : []
            let right = list.count > 1 ? floats(list[1]) : left
            return (left, right)
        }
    }
}

/// FFT → 64 log-spaced frequency bands (40 Hz – 16 kHz), scaled to roughly 0...1 with a
/// quick rise and slower fall so it looks good on screen.
final class SpectrumAnalyzer {
    static let size = 1024
    static let bandCount = 64

    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private var window: [Float]
    private var smoothed = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private let edges: [Int]

    init(sampleRate: Float = 48_000) {
        setup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: Self.size)
        vDSP_hann_window(&hann, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        window = hann

        let binHz = sampleRate / Float(Self.size)
        let half = Self.size / 2
        edges = (0...Self.bandCount).map { index in
            let frequency = 40 * powf(16_000 / 40, Float(index) / Float(Self.bandCount))
            return min(half - 1, max(1, Int(frequency / binHz)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func bands(from samples: [Float]) -> [Float] {
        let size = Self.size
        let half = size / 2
        var input = [Float](repeating: 0, count: size)
        for index in 0..<min(size, samples.count) {
            input[index] = samples[index] * window[index]
        }

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        let fftSetup = setup
        let log2n = self.log2n

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                input.withUnsafeBufferPointer { inputPointer in
                    inputPointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var result = [Float](repeating: 0, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let low = edges[band]
            let high = min(max(edges[band + 1], low + 1), half)
            var peak: Float = 0
            for bin in low..<high { peak = max(peak, magnitudes[bin]) }
            let amplitude = sqrtf(peak) / Float(size)
            let decibels = 20 * log10f(max(amplitude, 1e-7))
            let level = min(max((decibels + 65) / 55, 0), 1.2)
            smoothed[band] = level > smoothed[band] ? level : smoothed[band] * 0.8 + level * 0.2
            result[band] = smoothed[band]
        }
        return result
    }
}
