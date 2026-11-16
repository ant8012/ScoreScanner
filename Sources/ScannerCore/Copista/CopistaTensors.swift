import Foundation
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#else
import OnnxRuntimeAndroid
#endif

// Small helpers for moving data in and out of ONNX Runtime values.
// Confined to the caller's worker task: ORT objects never cross actor boundaries.

func tensor(_ data: Data, type: ORTTensorElementDataType, shape: [Int]) throws -> ORTValue {
  try ORTValue(tensorData: NSMutableData(data: data), elementType: type, shape: shape.map { NSNumber(value: $0) })
}

func require(_ name: String, in outputs: [String: ORTValue]) throws -> ORTValue {
  guard let value = outputs[name] else { throw ScannerError.invalid("Missing output \(name)") }
  return value
}

func floats(_ value: ORTValue) throws -> [Float] {
  decodeFloats(try value.tensorData() as Data)
}

func decodeFloats(_ data: Data) -> [Float] {
  data.withUnsafeBytes { buffer in
    stride(from: 0, to: buffer.count, by: 4).map {
      Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
    }
  }
}
