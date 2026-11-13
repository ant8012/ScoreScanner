import Foundation

public enum ScannerError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
