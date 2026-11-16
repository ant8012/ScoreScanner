#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#else
import OnnxRuntimeAndroid
#endif

enum RuntimePolicy {
    static let name = "CPU, 2 threads, KleidiAI disabled"

    static func options() throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        // Upstream #29538 / #27136: avoid the SME/KleidiAI convolution
        // memory regression on A18/A19 and M4+ without altering model weights.
        // This setting requires the pinned 1.27 runtime; 1.24.2 ignores it.
        try options.addConfigEntry(withKey: "mlas.disable_kleidiai", value: "1")
        return options
    }
}
