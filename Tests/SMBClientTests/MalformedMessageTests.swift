import XCTest
@testable import SMBClient

/// Replies that are too short, claim more data than they contain, or point
/// outside themselves must throw `MalformedMessageError`, never crash.
/// These tests need no server.
final class MalformedMessageTests: XCTestCase {
  // MARK: ByteReader

  func testReadingPastTheEndThrows() throws {
    let reader = ByteReader(Data([1, 2, 3]))
    XCTAssertThrowsError(try reader.read() as UInt32)
    XCTAssertEqual(reader.availableBytes, 3, "a failed read must not move the offset")
    XCTAssertEqual(try reader.read() as UInt16, 0x0201)
    XCTAssertThrowsError(try reader.read(count: 2))
    XCTAssertEqual(try reader.read(count: 1), Data([3]))
    XCTAssertEqual(try reader.read(count: 0), Data())
  }

  func testNegativeCountAndOutOfRangeSeekThrow() throws {
    let reader = ByteReader(Data(count: 8))
    XCTAssertThrowsError(try reader.read(count: -1))
    XCTAssertThrowsError(try reader.seek(to: 9))
    XCTAssertThrowsError(try reader.seek(to: -1))
    XCTAssertNoThrow(try reader.seek(to: 8))
    XCTAssertThrowsError(try reader.read(from: 4, count: 5))
    XCTAssertEqual(try reader.read(from: 4, count: 4), Data(count: 4))
  }

  func testReadsFromASliceWithANonZeroStartIndex() throws {
    let whole = Data([0xFF, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00])
    let reader = ByteReader(whole[1...])
    XCTAssertEqual(try reader.read() as UInt32, 1, "unaligned read from a slice")
    XCTAssertEqual(try reader.read(from: 4, count: 2), Data([0x02, 0x00]))
    XCTAssertThrowsError(try reader.read(from: 5, count: 2))
  }

  // MARK: Transport framing

  func testTransportFrameOver16MBIsRefused() {
    // First byte must be zero; 0x01000000 would make the client buffer 16 MB+.
    XCTAssertThrowsError(try DirectTCPPacket(response: Data([0x01, 0x00, 0x00, 0x00])))
    XCTAssertThrowsError(try DirectTCPPacket(response: Data([0xFF, 0xFF, 0xFF, 0xFF])))
    XCTAssertThrowsError(try DirectTCPPacket(response: Data([0x00, 0x00])))
    let valid = try? DirectTCPPacket(response: Data([0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB]))
    XCTAssertEqual(valid?.protocolLength, 2)
  }

  // MARK: Messages

  func testShortHeaderThrows() {
    XCTAssertThrowsError(try Header(data: Data(count: 63)))
    XCTAssertNoThrow(try Header(data: header()))
  }

  func testErrorResponseShorterThanItsHeaderThrows() {
    XCTAssertThrowsError(try ErrorResponse(data: Data(count: 10)))
  }

  func testReadResponseWithDataOutsideTheMessageThrows() throws {
    // StructureSize(2) DataOffset(1) Reserved(1) DataLength(4) DataRemaining(4) Reserved2(4)
    func response(offset: UInt8, length: UInt32, payload: Int) -> Data {
      header() + le(UInt16(17)) + Data([offset, 0]) + le(length) + le(UInt32(0)) + le(UInt32(0)) + Data(count: payload)
    }
    XCTAssertEqual(try Read.Response(data: response(offset: 80, length: 4, payload: 4)).buffer.count, 4)
    XCTAssertThrowsError(try Read.Response(data: response(offset: 80, length: 0xFFFF_FFFF, payload: 4)))
    XCTAssertThrowsError(try Read.Response(data: response(offset: 255, length: 4, payload: 4)))
  }

  func testDirectoryListingWithForgedEntryOffsetThrows() throws {
    // StructureSize(2) OutputBufferOffset(2) OutputBufferLength(4), then the buffer at 72.
    func listing(_ entries: Data) -> Data {
      header() + le(UInt16(9)) + le(UInt16(72)) + le(UInt32(entries.count)) + entries
    }
    let good = entry(name: "a.jpg", next: 0)
    let goodResponse = try QueryDirectory.Response(data: listing(good))
    XCTAssertEqual(try goodResponse.files().map(\.fileName), ["a.jpg"])

    // nextEntryOffset points past the end of the buffer.
    let forged = entry(name: "a.jpg", next: 0x7FFF_0000)
    XCTAssertThrowsError(try QueryDirectory.Response(data: listing(forged)).files())

    // fileNameLength larger than what follows.
    var longName = entry(name: "a.jpg", next: 0)
    longName.replaceSubrange(60..<64, with: le(UInt32(10_000)))
    XCTAssertThrowsError(try QueryDirectory.Response(data: listing(longName)).files())

    // OutputBufferLength larger than the message.
    var oversized = listing(good)
    oversized.replaceSubrange(68..<72, with: le(UInt32(1 << 30)))
    XCTAssertThrowsError(try QueryDirectory.Response(data: oversized))
  }

  // MARK: Chained (compound) replies

  func testCompoundReplyMustHaveOneMessagePerRequest() throws {
    let first = header(nextCommand: 72) + Data(count: 8)
    let second = header(nextCommand: 0) + Data(count: 8)
    XCTAssertEqual(try Session.splitCompound(first + second, expectedCount: 2).count, 2)

    // Fewer replies than requests used to crash with an index out of range.
    XCTAssertThrowsError(try Session.splitCompound(header(nextCommand: 0), expectedCount: 2))
    // More replies than requests.
    XCTAssertThrowsError(try Session.splitCompound(first + second, expectedCount: 1))
    // nextCommand pointing past the end.
    XCTAssertThrowsError(try Session.splitCompound(header(nextCommand: 10_000), expectedCount: 2))
    // nextCommand pointing into the middle of a too-short message.
    XCTAssertThrowsError(try Session.splitCompound(header(nextCommand: 64) + Data(count: 10), expectedCount: 2))
  }

  // MARK: Share list

  func testShareListClaimingBillionsOfEntriesThrowsWithoutAllocating() {
    // level, shareCtr, referentID, count, then NetShareInfo1 referentID and count.
    let stub = words(1, 1, 1, 1, 1, UInt32.max)
    XCTAssertThrowsError(try NetShareEnumResponse(data: stub))
  }

  func testShareNameWithoutTerminatorThrows() {
    // One entry (name/type/comment referent IDs), then a WStr with actualCount 0.
    let stub = words(1, 1, 1, 1, 1, 1, /* entry */ 1, 0, 2, /* WStr */ 0, 0, 0)
    XCTAssertThrowsError(try NetShareEnumResponse(data: stub))
  }

  // MARK: Random input

  /// Random bytes (and random-length prefixes of a valid header) fed to every
  /// reply parser must either parse or throw; a crash fails the whole test run.
  func testRandomRepliesNeverCrash() {
    var rng = SeededGenerator(seed: 0x5EED)
    let parsers: [(Data) throws -> Any] = [
      { try Header(data: $0) },
      { try ErrorResponse(data: $0) },
      { try Negotiate.Response(data: $0) },
      { try SessionSetup.Response(data: $0) },
      { try TreeConnect.Response(data: $0) },
      { try Create.Response(data: $0) },
      { try Read.Response(data: $0) },
      { try Close.Response(data: $0) },
      { try IOCtl.Response(data: $0) },
      { try QueryInfo.Response(data: $0) },
      { try QueryDirectory.Response(data: $0).files() },
      { try DCERPC.Response(data: $0) },
      { try NetShareEnumResponse(data: $0) },
      { try NTLM.ChallengeMessage(data: $0) },
      { try FileAllInformation(data: $0) },
      { try DirectTCPPacket(response: $0) },
      { try Session.splitCompound($0, expectedCount: 3) },
    ]
    for _ in 0..<2_000 {
      let length = Int.random(in: 0...400, using: &rng)
      var data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
      if Bool.random(using: &rng) {
        // Mostly-valid header so parsing gets past the first fields.
        data = header().prefix(min(64, length)) + data.dropFirst(min(64, length))
      }
      for parse in parsers {
        _ = try? parse(data)
      }
    }
  }

  // MARK: Helpers

  private func le<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  /// A 64-byte SMB2 header with status success.
  private func header(nextCommand: UInt32 = 0) -> Data {
    let parts: [Data] = [
      Data([0xFE, 0x53, 0x4D, 0x42]), le(UInt16(64)), le(UInt16(0)), le(UInt32(0)),  // protocol, size, credit charge, status
      le(UInt16(0)), le(UInt16(1)), le(UInt32(1)), le(nextCommand), le(UInt64(1)),   // command, credits, flags, next, message ID
      le(UInt32(0)), le(UInt32(0)), le(UInt64(0)), Data(count: 16),                  // reserved, tree ID, session ID, signature
    ]
    return Data(parts.joined())
  }

  /// Little-endian 32-bit words.
  private func words(_ values: UInt32...) -> Data {
    Data(values.map(le).joined())
  }

  /// A FileDirectoryInformation entry (64 fixed bytes: offsets, times, sizes, attributes, name length, then the UTF-16 name).
  private func entry(name: String, next: UInt32) -> Data {
    let nameData = name.data(using: .utf16LittleEndian)!
    return le(next) + le(UInt32(0)) + Data(count: 52) + le(UInt32(nameData.count)) + nameData
  }
}

/// SplitMix64, so the random test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
