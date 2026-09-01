import CWhisper
import Foundation

/// Native logging from whisper.cpp and ggml.
///
/// Both write straight to stderr by default — model tensor dumps, backend and
/// Metal device banners, per-run timings — which drowns out the CLI's own
/// stderr progress lines and any error the user is actually meant to read.
/// The `print_*` params on `whisper_full_params` don't cover this; only the
/// log callbacks do, and they are process-global, so they must be installed
/// before whisper.cpp is first called.
public enum WhisperLogging {
    /// `verbose` restores the default stderr destination rather than doing
    /// nothing, so a caller can flip this at any point in a process's life.
    public static func configure(verbose: Bool) {
        let sink: ggml_log_callback = verbose ? stderrSink : discardSink
        whisper_log_set(sink, nil)
        ggml_log_set(sink, nil)
    }
}

private let discardSink: ggml_log_callback = { _, _, _ in }

private let stderrSink: ggml_log_callback = { _, text, _ in
    guard let text else { return }
    fputs(text, stderr)
}
