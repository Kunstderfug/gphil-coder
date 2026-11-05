import Foundation

enum AudioStreamCopy {
    /// Finds the first audio stream, matching the explicit `0:a:0` extraction map.
    static func outputExtension(ffmpegURL: URL, input: URL) throws -> String {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-nostdin", "-i", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain before waiting so stream metadata cannot fill the pipe and deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let metadata = String(decoding: data, as: UTF8.self)
        return try outputExtension(from: metadata)
    }

    static func outputExtension(from metadata: String) throws -> String {
        guard let stream = metadata.split(separator: "\n").first(where: {
            $0.contains("Stream #") && $0.contains("Audio:")
        }), let audioRange = stream.range(of: "Audio:") else {
            throw AudioStreamCopyError.noAudioStream
        }
        let codec = stream[audioRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            .lowercased()

        switch codec {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "flac": return "flac"
        case "opus": return "opus"
        case "vorbis": return "ogg"
        case "ac3": return "ac3"
        case "eac3": return "eac3"
        case "dts": return "dts"
        case "pcm_s16be", "pcm_s24be", "pcm_s32be", "pcm_f32be", "pcm_f64be", "pcm_s8":
            return "aiff"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le", "pcm_u8":
            return "wav"
        default:
            throw AudioStreamCopyError.unsupportedCodec(codec)
        }
    }
}

enum AudioStreamCopyError: LocalizedError {
    case noAudioStream
    case unsupportedCodec(String)

    var errorDescription: String? {
        switch self {
        case .noAudioStream:
            "No audio track was found in this video."
        case .unsupportedCodec(let codec):
            "Original audio extraction does not support the \(codec) codec. Choose an audio output format to convert it instead."
        }
    }
}
