import Foundation

/// A GGML/GGUF whisper model that Vox knows how to download and run.
public struct WhisperModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let approximateSizeMB: Int
    public let isMultilingual: Bool
    public let summary: String

    public init(
        id: String,
        fileName: String,
        approximateSizeMB: Int,
        isMultilingual: Bool,
        summary: String
    ) {
        self.id = id
        self.fileName = fileName
        self.approximateSizeMB = approximateSizeMB
        self.isMultilingual = isMultilingual
        self.summary = summary
    }
}

/// The set of models offered by `vox models` and the menu bar model picker.
///
/// Files come from the official `ggerganov/whisper.cpp` Hugging Face repo, the
/// same source `whisper.cpp/models/download-ggml-model.sh` uses.
public enum ModelCatalog {
    public static let downloadBaseURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    )!

    public static let defaultModelID = "large-v3-turbo-q5_0"

    public static let all: [WhisperModel] = [
        WhisperModel(
            id: "tiny.en",
            fileName: "ggml-tiny.en.bin",
            approximateSizeMB: 75,
            isMultilingual: false,
            summary: "Fastest, English only. Useful for hotkey smoke tests."
        ),
        WhisperModel(
            id: "base.en",
            fileName: "ggml-base.en.bin",
            approximateSizeMB: 142,
            isMultilingual: false,
            summary: "Fast, English only."
        ),
        WhisperModel(
            id: "small.en",
            fileName: "ggml-small.en.bin",
            approximateSizeMB: 466,
            isMultilingual: false,
            summary: "Good accuracy/speed balance, English only."
        ),
        WhisperModel(
            id: "medium.en",
            fileName: "ggml-medium.en.bin",
            approximateSizeMB: 1500,
            isMultilingual: false,
            summary: "High accuracy, English only."
        ),
        WhisperModel(
            id: "large-v3",
            fileName: "ggml-large-v3.bin",
            approximateSizeMB: 3100,
            isMultilingual: true,
            summary: "Highest accuracy, slowest."
        ),
        WhisperModel(
            id: "large-v3-turbo",
            fileName: "ggml-large-v3-turbo.bin",
            approximateSizeMB: 1620,
            isMultilingual: true,
            summary: "Large-v3 accuracy at roughly 4x the speed."
        ),
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            approximateSizeMB: 574,
            isMultilingual: true,
            summary: "Quantized turbo. Vox default: near-turbo accuracy, ~570MB."
        ),
    ]

    public static var defaultModel: WhisperModel {
        // Force-unwrap is safe: `defaultModelID` is one of the literals above
        // and `ModelCatalogTests` asserts it.
        model(id: defaultModelID)!
    }

    public static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    public static func downloadURL(for model: WhisperModel) -> URL {
        downloadBaseURL.appendingPathComponent(model.fileName)
    }
}
