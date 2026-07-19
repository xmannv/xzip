import Foundation

/// A request passed from an extension (Finder Sync, Share) to the main app via
/// a custom `xzip://` URL scheme.
///
/// Design: a Codable value object with a stable URL representation. Centralizing
/// (de)serialization here — and unit-testing it in Core — keeps the app and its
/// extensions in agreement about the wire format, avoiding subtle drift between
/// separately-compiled targets.
public enum AppCommand: Sendable, Equatable {
    /// Where a Finder-initiated extraction should write.
    public enum ExtractDestination: String, Sendable, Equatable {
        /// Next to the archive (Finder's "Extract Here").
        case here
        /// The user's Downloads folder.
        case downloads
    }

    /// Compress the given file paths, optionally using a named preset and/or a
    /// specific target format (`ArchiveFormat` raw value, e.g. "7z"; nil = the
    /// user's saved default). `quick == true` means "one-shot": compress
    /// immediately with the saved defaults, no options dialog.
    case compress(paths: [String], presetID: String?, quick: Bool, format: String?)
    /// Extract the given archive paths. `destination` nil means "just open in the
    /// browser"; `withPassword` requests the password prompt first.
    case extract(paths: [String], destination: ExtractDestination?, withPassword: Bool)

    public static let scheme = "xzip"

    /// Encode into an `xzip://` URL.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case let .compress(paths, presetID, quick, format):
            components.host = "compress"
            components.queryItems =
                paths.map { URLQueryItem(name: "path", value: $0) }
                + (presetID.map { [URLQueryItem(name: "preset", value: $0)] } ?? [])
                + (quick ? [URLQueryItem(name: "quick", value: "1")] : [])
                + (format.map { [URLQueryItem(name: "format", value: $0)] } ?? [])
        case let .extract(paths, destination, withPassword):
            components.host = "extract"
            components.queryItems =
                paths.map { URLQueryItem(name: "path", value: $0) }
                + (destination.map { [URLQueryItem(name: "dest", value: $0.rawValue)] } ?? [])
                + (withPassword ? [URLQueryItem(name: "password", value: "1")] : [])
        }
        return components.url
    }

    /// Decode from an incoming `xzip://` URL.
    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let items = components.queryItems ?? []
        let paths = items.filter { $0.name == "path" }.compactMap(\.value)

        switch components.host {
        case "compress":
            let preset = items.first { $0.name == "preset" }?.value
            let quick = items.first { $0.name == "quick" }?.value == "1"
            let format = items.first { $0.name == "format" }?.value
            self = .compress(paths: paths, presetID: preset, quick: quick, format: format)
        case "extract":
            let destination = items.first { $0.name == "dest" }?.value
                .flatMap(ExtractDestination.init(rawValue:))
            let withPassword = items.first { $0.name == "password" }?.value == "1"
            self = .extract(paths: paths, destination: destination, withPassword: withPassword)
        default:
            return nil
        }
    }
}
