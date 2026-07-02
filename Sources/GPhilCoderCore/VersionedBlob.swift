import Foundation

// Shared versioned-blob decoding helpers for persisted UserDefaults/file
// payloads.
//
// Mirrors the discipline established by EncodingPresetDocument: a version
// envelope is read first so a future shape change can be detected (and,
// eventually, migrated) before a structural decode. Decode problems are
// surfaced as a typed `DecodeProblem` instead of a silent `nil`, so callers
// can show the user what happened and avoid overwriting on-disk data.

/// Why a versioned payload could not be decoded.
public enum DecodeProblem: Error, Equatable, Sendable {
    /// The blob was written by a version newer than this code understands.
    case versionMismatch(found: Int, supported: Int)
    /// The blob exists but could not be structurally decoded.
    case corrupt(underlying: String)
}

public enum VersionedBlob {
    /// A read of just the `version` field, tolerating its absence.
    private struct VersionEnvelope: Codable {
        let version: Int?
    }

    /// A versioned wrapper around a `[Payload]` array. New persisted array
    /// payloads should round-trip through this shape:
    /// `{"version":1,"items":[...]}`.
    public struct Envelope<Payload: Codable>: Codable {
        public var version: Int
        public var items: [Payload]

        public init(version: Int = 1, items: [Payload]) {
            self.version = version
            self.items = items
        }
    }

    /// Returns the persisted `version` field if present, or nil when the blob
    /// has no envelope (the legacy bare-shape case).
    public static func version(from data: Data) -> Int? {
        (try? JSONDecoder().decode(VersionEnvelope.self, from: data))?.version
    }

    /// Encodes `items` in the current versioned envelope shape.
    public static func encode<Payload: Codable>(
        _ items: [Payload],
        currentVersion: Int = 1
    ) throws -> Data {
        try JSONEncoder().encode(Envelope<Payload>(version: currentVersion, items: items))
    }

    /// Decodes a versioned payload, distinguishing a future version and
    /// corruption from a valid state.
    ///
    /// - Parameters:
    ///   - data: The raw persisted blob.
    ///   - currentVersion: The version this build understands.
    ///   - decodePayload: Structural decode of the current-version shape,
    ///     returning the decoded items. Throw to signal corruption.
    ///   - legacyBareArray: When `decodePayload` throws and the blob has no
    ///     version envelope, this closure is tried to decode a legacy bare
    ///     `[Payload]` shape (the backward-compat path for payloads that
    ///     predate versioning). May be nil when there is no legacy shape.
    /// - Returns: The decoded items, or a typed `DecodeProblem`.
    public static func decode<Payload: Decodable>(
        from data: Data,
        currentVersion: Int,
        decodePayload: (Data) throws -> [Payload],
        legacyBareArray: ((Data) -> [Payload]?)? = nil
    ) -> Result<[Payload], DecodeProblem> {
        let envelopeVersion = version(from: data)
        if let found = envelopeVersion, found != currentVersion {
            // Future: branch on `found` and migrate to currentVersion here.
            return .failure(.versionMismatch(found: found, supported: currentVersion))
        }
        do {
            return .success(try decodePayload(data))
        } catch {
            if let legacyBareArray, envelopeVersion == nil,
                let legacy = legacyBareArray(data)
            {
                return .success(legacy)
            }
            return .failure(.corrupt(underlying: String(describing: error)))
        }
    }

    /// Convenience: decode an `Envelope<Payload>` shape, with an optional
    /// legacy bare-array fallback for payloads that predate versioning.
    public static func decodeEnvelope<Payload: Codable>(
        from data: Data,
        currentVersion: Int = 1,
        allowLegacyBareArray: Bool = true
    ) -> Result<[Payload], DecodeProblem> {
        decode(
            from: data,
            currentVersion: currentVersion,
            decodePayload: { data in
                try JSONDecoder().decode(Envelope<Payload>.self, from: data).items
            },
            legacyBareArray: allowLegacyBareArray
                ? { data in try? JSONDecoder().decode([Payload].self, from: data) }
                : nil
        )
    }
}
