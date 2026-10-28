import Foundation

public struct FileAccessInformation {
  public let accessFlags: AccessMask

  public init(data: Data) throws {
    let reader = ByteReader(data)
    accessFlags = AccessMask(rawValue: try reader.read())
  }
}

extension ByteReader {
  func read() throws -> FileAccessInformation {
    try FileAccessInformation(data: try read(count: 4))
  }
}
