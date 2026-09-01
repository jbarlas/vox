import Foundation

/// Vox speaks snake_case JSON on every surface: the config file, the mode
/// definitions, and the `--output json` agent interface.
public enum VoxJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, container in
            var container = container.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Expected an ISO-8601 timestamp, got \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try encoder(pretty: pretty).encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoxError(code: .internalError, message: "Encoded JSON was not valid UTF-8")
        }
        return text
    }
}

public enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
