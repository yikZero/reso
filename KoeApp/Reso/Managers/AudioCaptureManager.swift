import AVFoundation
import CoreAudio

typealias AudioFrameCallback = (_ buffer: UnsafePointer<UInt8>, _ length: UInt32, _ timestamp: UInt64) -> Void

final class AudioCaptureManager: @unchecked Sendable {
    private let targetSampleRate: Double = 16000
    private let frameSamples: Int = 3200
    private let frameBytes: Int = 6400

    private var audioEngine: AVAudioEngine?
    private var audioCallback: AudioFrameCallback?
    private var accumBuffer = Data()
    private var pendingDeviceID: AudioDeviceID = kAudioObjectUnknown

    private(set) var isCapturing = false

    func setInputDeviceID(_ deviceID: AudioDeviceID) {
        pendingDeviceID = deviceID
    }

    func startCapture(callback: @escaping AudioFrameCallback) {
        audioCallback = callback
        accumBuffer.removeAll()

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode

        if pendingDeviceID != kAudioObjectUnknown {
            let audioUnit = inputNode.audioUnit!
            var deviceID = pendingDeviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            print("[AudioCapture] invalid hardware format")
            return
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("[AudioCapture] failed to create target format")
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[AudioCapture] failed to create converter")
            return
        }

        let sampleRateRatio = targetSampleRate / hwFormat.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let inputFrames = buffer.frameLength
            let outputFrameCount = AVAudioFrameCount(Double(inputFrames) * sampleRateRatio + 1)

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            var gotInput = false
            let status = converter.convert(to: convertedBuffer, error: nil) { _, outStatus in
                if gotInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                gotInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, convertedBuffer.frameLength > 0 else { return }

            let floatPtr = convertedBuffer.floatChannelData![0]
            let sampleCount = Int(convertedBuffer.frameLength)
            var int16Data = Data(count: sampleCount * 2)

            int16Data.withUnsafeMutableBytes { rawBuffer in
                let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, floatPtr[i]))
                    int16Ptr[i] = Int16(sample * 32767.0)
                }
            }

            self.accumBuffer.append(int16Data)

            while self.accumBuffer.count >= self.frameBytes {
                let frame = self.accumBuffer.prefix(self.frameBytes)
                frame.withUnsafeBytes { rawBuffer in
                    let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                    self.audioCallback?(ptr, UInt32(self.frameBytes), 0)
                }
                self.accumBuffer.removeFirst(self.frameBytes)
            }
        }

        do {
            try engine.start()
            isCapturing = true
        } catch {
            print("[AudioCapture] engine start failed: \(error)")
        }
    }

    func stopCapture() {
        guard isCapturing else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        if !accumBuffer.isEmpty {
            accumBuffer.withUnsafeBytes { rawBuffer in
                let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                audioCallback?(ptr, UInt32(accumBuffer.count), 0)
            }
            accumBuffer.removeAll()
        }

        audioCallback = nil
        isCapturing = false
    }
}
