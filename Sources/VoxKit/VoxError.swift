import Foundation

/// Every failure surfaced by Vox carries a stable machine-readable code and a
/// process exit code, so an agent harness can branch on the exit status without
/// parsing stdout.
public enum VoxErrorCode: String, Codable, Sendable, CaseIterable {
    case config
    case microphone
    case permission
    case audio
    case model
    case transcription
    case timeout
    case llm
    case output
    case cancelled
    case internalError = "internal"

    public var exitCode: Int32 {
        switch self {
        case .config: return 2
        case .microphone: return 3
        case .permission: return 4
        case .audio: return 5
        case .model: return 6
        case .transcription: return 7
        case .timeout: return 8
        case .llm: return 9
        case .output: return 10
        case .cancelled: return 11
        case .internalError: return 1
        }
    }
}

public struct VoxError: Error, Codable, Sendable, Equatable {
    public let code: VoxErrorCode
    public let message: String
    public let detail: String?

    public init(code: VoxErrorCode, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public var exitCode: Int32 { code.exitCode }
}

extension VoxError: LocalizedError {
    public var errorDescription: String? {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message): \(detail)"
    }
}

extension VoxError {
    public static func config(_ message: String, detail: String? = nil) -> VoxError {
        VoxError(code: .config, message: message, detail: detail)
    }

    public static func model(_ message: String, detail: String? = nil) -> VoxError {
        VoxError(code: .model, message: message, detail: detail)
    }

    public static func llm(_ message: String, detail: String? = nil) -> VoxError {
        VoxError(code: .llm, message: message, detail: detail)
    }

    /// Wraps an arbitrary error, preserving it if it is already a `VoxError`.
    public static func wrap(_ error: Error, code: VoxErrorCode, message: String) -> VoxError {
        if let voxError = error as? VoxError { return voxError }
        return VoxError(code: code, message: message, detail: String(describing: error))
    }
}
