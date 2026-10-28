import Foundation

public enum QueryDirectory {
  public struct Request: Message.Request {
    public typealias Response = QueryDirectory.Response

    public let header: Header
    public let structureSize: UInt16
    public let fileInformationClass: FileInformationClass
    public let flags: Flags
    public let fileIndex: UInt32
    public let fileId: Data
    public let fileNameOffset: UInt16
    public let fileNameLength: UInt16
    public let outputBufferLength: UInt32
    public let buffer: Data

    public init(
      creditCharge: UInt16 = 1,
      headerFlags: Header.Flags = [],
      messageId: UInt64,
      treeId: UInt32,
      sessionId: UInt64,
      fileInformationClass: FileInformationClass,
      flags: Flags = [.restartScans],
      fileId: Data,
      fileName: String,
      outputBufferLength: UInt32 = 65535
    ) {
      header = Header(
        creditCharge: creditCharge,
        command: .queryDirectory,
        creditRequest: 256,
        flags: headerFlags,
        messageId: messageId,
        treeId: treeId,
        sessionId: sessionId
      )

      structureSize = 33
      self.fileInformationClass = fileInformationClass
      self.flags = flags
      fileIndex = 0
      self.fileId = fileId

      let fileNameData = fileName.encoded()
      fileNameOffset = 96
      fileNameLength = UInt16(truncatingIfNeeded: fileNameData.count)

      self.outputBufferLength = outputBufferLength
      buffer = fileNameData + Data(count: 2)
    }

    public func encoded() -> Data {
      var data = Data()

      data += header.encoded()
      data += structureSize
      data += fileInformationClass.rawValue
      data += flags.rawValue
      data += fileIndex
      data += fileId
      data += fileNameOffset
      data += fileNameLength
      data += outputBufferLength
      data += buffer

      return data
    }
  }

  public struct Response: Message.Response {
    public let header: Header
    public let structureSize: UInt16
    public let outputBufferOffset: UInt16
    public let outputBufferLength: UInt32
    public let buffer: Data

    public init(data: Data) throws {
      let reader = ByteReader(data)

      header = try reader.read()

      structureSize = try reader.read()
      outputBufferOffset = try reader.read()
      outputBufferLength = try reader.read()
      buffer = try reader.read(from: Int(outputBufferOffset), count: Int(outputBufferLength))
    }

    /// The entries in `buffer`. Each entry's `nextEntryOffset` must point
    /// forward and stay inside the buffer; otherwise the reply is refused.
    public func files() throws -> [FileDirectoryInformation] {
      var files = [FileDirectoryInformation]()
      guard outputBufferLength > 0 else { return files }
      var offset = 0
      while true {
        guard offset < buffer.count else {
          throw MalformedMessageError("directory entry at \(offset) is outside the \(buffer.count)-byte buffer")
        }
        let entry = try FileDirectoryInformation(data: Data(buffer[(buffer.startIndex + offset)...]))
        files.append(entry)
        guard entry.nextEntryOffset != 0 else { return files }
        offset += Int(entry.nextEntryOffset)
      }
    }
  }

  public enum FileInformationClass: UInt8 {
    case fileDirectoryInformation = 0x01
    case fileFullDirectoryInformation = 0x02
    case fileIdFullDirectoryInformation = 0x26
    case fileBothDirectoryInformation = 0x03
    case fileIdBothDirectoryInformation = 0x25
    case fileNamesInformation = 0x0C
    case fileIdExtdDirectoryInformation = 0x3C
    case fileInfomationClass_Reserved = 0x64
  }

  public struct Flags: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    public static let restartScans = Flags(rawValue: 0x01)
    public static let returnSingleEntry = Flags(rawValue: 0x02)
    public static let indexSpecified = Flags(rawValue: 0x04)
    public static let reopen = Flags(rawValue: 0x10)
  }
}
