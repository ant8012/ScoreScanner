// Android stand-ins for the ONNX Runtime Objective-C classes ScannerCore uses on Apple platforms (ORTEnv,
// ORTSession, ORTValue...), with the same names and signatures, over ONNX Runtime's C API (COnnxRuntimeAndroid).
// Only what ScannerCore calls is here. The app must package libonnxruntime.so (Microsoft's onnxruntime-android).

import COnnxRuntimeAndroid
import Foundation

public struct ORTError: LocalizedError {
  public let message: String
  public var errorDescription: String? { "ONNX Runtime: \(message)" }
}

/// Calls `body` with a message buffer and throws its message when `failed` says the call failed.
private func checked<T>(_ body: (UnsafeMutablePointer<CChar>, Int) -> T, failed: (T) -> Bool) throws -> T {
  var buffer = [CChar](repeating: 0, count: 512)
  let result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
  if failed(result) {
    let message = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    throw ORTError(message: message.isEmpty ? "unknown error" : message)
  }
  return result
}

/// Passes `strings` to C as `const char *const *`.
private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> T) rethrows -> T {
  let copies = strings.map { strdup($0) }
  defer { copies.forEach { free($0) } }
  let pointers = copies.map { UnsafePointer<CChar>($0) }
  return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
}

public enum ORTLoggingLevel: Int { case verbose, info, warning, error, fatal }

public enum ORTTensorElementDataType: Int32 {
  case undefined = 0
  case float = 1
  case int64 = 7
}

/// The process's environment. ONNX Runtime keeps one; this only makes sure it is loaded.
public final class ORTEnv {
  public init(loggingLevel: ORTLoggingLevel) throws {
    _ = try checked({ sc_ort_load($0, $1) }, failed: { $0 != 0 })
  }
}

public final class ORTSessionOptions {
  var intraOpThreads: Int32 = 0
  var config: [(String, String)] = []

  public init() throws {}

  public func setIntraOpNumThreads(_ count: Int32) throws { intraOpThreads = count }

  public func addConfigEntry(withKey key: String, value: String) throws { config.append((key, value)) }
}

public final class ORTRunOptions {}

public final class ORTTensorTypeAndShapeInfo {
  public let elementType: ORTTensorElementDataType
  public let shape: [NSNumber]

  init(elementType: ORTTensorElementDataType, shape: [NSNumber]) {
    self.elementType = elementType
    self.shape = shape
  }
}

public final class ORTValue {
  let handle: OpaquePointer

  init(handle: OpaquePointer) { self.handle = handle }

  /// A tensor holding a copy of `tensorData`.
  public init(tensorData: NSMutableData, elementType: ORTTensorElementDataType, shape: [NSNumber]) throws {
    let dims = shape.map(\.int64Value)
    handle = try dims.withUnsafeBufferPointer { dims in
      try checked({ err, len in
        sc_ort_value_create(tensorData.bytes, tensorData.length, elementType.rawValue, dims.baseAddress, dims.count,
                            err, len)
      }, failed: { $0 == nil })!
    }
  }

  deinit { sc_ort_value_free(handle) }

  /// A copy of the tensor's data.
  public func tensorData() throws -> NSMutableData {
    var bytes = 0
    let data = try checked({ sc_ort_value_data(handle, &bytes, $0, $1) }, failed: { $0 == nil })!
    return NSMutableData(bytes: data, length: bytes)
  }

  public func tensorTypeAndShapeInfo() throws -> ORTTensorTypeAndShapeInfo {
    var dims = [Int64](repeating: 0, count: 16)
    let rank = try dims.withUnsafeMutableBufferPointer { dims in
      try checked({ sc_ort_value_shape(handle, dims.baseAddress, dims.count, $0, $1) }, failed: { $0 < 0 })
    }
    let type = ORTTensorElementDataType(rawValue: sc_ort_value_element_type(handle)) ?? .undefined
    return ORTTensorTypeAndShapeInfo(elementType: type, shape: dims.prefix(rank).map { NSNumber(value: $0) })
  }
}

public final class ORTSession {
  let handle: OpaquePointer

  public init(env: ORTEnv, modelPath: String, sessionOptions: ORTSessionOptions?) throws {
    let options = try sessionOptions ?? ORTSessionOptions()
    let keys = options.config.map(\.0), values = options.config.map(\.1)
    handle = try withCStrings(keys) { keys in
      try withCStrings(values) { values in
        try checked({ err, len in
          sc_ort_session_create(modelPath, options.intraOpThreads, keys, values, options.config.count, err, len)
        }, failed: { $0 == nil })!
      }
    }
  }

  deinit { sc_ort_session_free(handle) }

  public func inputNames() throws -> [String] { try names(output: false) }

  public func outputNames() throws -> [String] { try names(output: true) }

  private func names(output: Bool) throws -> [String] {
    var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    let count = try checked({ sc_ort_session_names(handle, output ? 1 : 0, &list, $0, $1) }, failed: { $0 < 0 })
    defer { free(list) }
    return (0..<Int(count)).map { i in
      defer { free(list![i]) }
      return String(cString: list![i]!)
    }
  }

  public func run(withInputs inputs: [String: ORTValue], outputNames: Set<String>, runOptions: ORTRunOptions?) throws
    -> [String: ORTValue]
  {
    let inputNames = Array(inputs.keys), outputList = Array(outputNames)
    let inputHandles: [OpaquePointer?] = inputNames.map { inputs[$0]!.handle }
    var outputHandles = [OpaquePointer?](repeating: nil, count: outputList.count)
    try withCStrings(inputNames) { inNames in
      try withCStrings(outputList) { outNames in
        try inputHandles.withUnsafeBufferPointer { ins in
          try outputHandles.withUnsafeMutableBufferPointer { outs in
            _ = try checked({ err, len in
              sc_ort_session_run(handle, inNames, ins.baseAddress, ins.count, outNames, outs.count, outs.baseAddress,
                                 err, len)
            }, failed: { $0 != 0 })
          }
        }
      }
    }
    var result: [String: ORTValue] = [:]
    for (name, output) in zip(outputList, outputHandles) {
      if let output { result[name] = ORTValue(handle: output) }
    }
    return result
  }
}
