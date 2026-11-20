import AVFoundation
import Foundation
import WhisperKit

enum AudioLoaderError: LocalizedError {
    case noAudioTrack
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "Die Datei enthält keine Tonspur."
        case .unreadable(let m): return "Die Datei konnte nicht gelesen werden: \(m)"
        }
    }
}

enum AudioLoader {
    static let sampleRate = 16_000.0

    /// Liest Audio oder die Tonspur eines Videos als 16 kHz Mono (Format, das Whisper erwartet).
    static func load(url: URL) async throws -> [Float] {
        // Reine Audiodateien über den erprobten Weg von WhisperKit lesen
        let audioOnly: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf"]
        if audioOnly.contains(url.pathExtension.lowercased()),
           let samples = try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path), !samples.isEmpty {
            return samples
        }
        do {
            return try await loadWithAssetReader(url: url)
        } catch AudioLoaderError.noAudioTrack {
            throw AudioLoaderError.noAudioTrack
        } catch {
            // Zweiter Versuch über WhisperKit (AVAudioFile)
            do {
                return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            } catch {
                throw AudioLoaderError.unreadable(error.localizedDescription)
            }
        }
    }

    private static func loadWithAssetReader(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioLoaderError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioLoaderError.unreadable("Format wird nicht unterstützt") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unbekannter Fehler")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { ptr in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: ptr.count, destination: ptr.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        if reader.status == .failed {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unbekannter Fehler")
        }
        return samples
    }
}
