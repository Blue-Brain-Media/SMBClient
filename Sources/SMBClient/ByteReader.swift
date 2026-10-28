import Foundation

/// Thrown when a message from the server is shorter than its own fields say,
/// or points outside itself (an offset or length beyond the end, a chained
/// message that doesn't advance). Such messages are refused instead of
/// crashing the client.
public struct MalformedMessageError: Error, Equatable, CustomStringConvertible {
  public let reason: String

  public init(_ reason: String) {
    self.reason = reason
  }

  public var description: String {
    "Malformed SMB message: \(reason)"
  }
}

/// Reads little-endian fields from a message. Every read is bounds-checked:
/// reading past the end, a negative count or a seek outside the data throws
/// `MalformedMessageError` instead of trapping.
class ByteReader {
  private let data: Data
  private(set) var offset: Data.Index

  var availableBytes: Int {
    return data.endIndex - offset
  }

  init(_ data: Data) {
    self.data = data
    offset = data.startIndex
  }

  func read<T>() throws -> T {
    // Copy first: a fresh Data is suitably aligned for `load(as:)`; a slice of the message may not be.
    return Data(try take(MemoryLayout<T>.size)).to(type: T.self)
  }

  func read(count: Int) throws -> Data {
    return Data(try take(count))
  }

  /// Reads `count` bytes at `from`, measured from the start of the data.
  func read(from: Int, count: Int) throws -> Data {
    try seek(to: from)
    return try read(count: count)
  }

  /// Moves to `to`, measured from the start of the data. Seeking to the very
  /// end is allowed (nothing more can be read from there).
  func seek(to: Int) throws {
    guard to >= 0, to <= data.count else {
      throw MalformedMessageError("offset \(to) is outside a \(data.count)-byte message")
    }
    offset = data.startIndex + to
  }

  func remaining() -> Data {
    return Data(data[offset...])
  }

  private func take(_ count: Int) throws -> Data.SubSequence {
    guard count >= 0, count <= availableBytes else {
      throw MalformedMessageError(
        "needs \(count) bytes at offset \(offset - data.startIndex), only \(availableBytes) left"
      )
    }
    defer { offset += count }
    return data[offset..<(offset + count)]
  }
}

extension ByteReader {
  func read() throws -> Bool {
    let value: UInt8 = try read()
    return value == 1
  }

  func read() throws -> UUID {
    try read(count: 16).to(type: UUID.self)
  }
}
