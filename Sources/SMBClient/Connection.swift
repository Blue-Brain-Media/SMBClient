import Foundation
import Network

public class Connection {
  let host: String
  var onDisconnected: (Error) -> Void

  private let connection: NWConnection
  private let queue: DispatchQueue
  private var buffer = Data()

  private let semaphore = Semaphore(value: 1)

  public var state: NWConnection.State {
    connection.state
  }

  public init(host: String) {
    self.host = host
    
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: 445)
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    queue = DispatchQueue(label: "com.kishikawakatsumi.smbclient.connection.\(host):445", qos: .userInitiated)
    onDisconnected = { _ in }
  }

  public init(host: String, port: Int) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      // A port outside 0...65535 used to trap here; now the connection just fails.
      port: UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    queue = DispatchQueue(label: "com.kishikawakatsumi.smbclient.connection.\(host):\(port)", qos: .userInitiated)
    onDisconnected = { _ in }
  }

  public func connect() async throws {
    return try await withCheckedThrowingContinuation { (continuation) in
      connection.stateUpdateHandler = { [weak self] (state) in
        switch state {
        case .setup, .preparing:
          break
        case .waiting(let error):
          continuation.resume(throwing: error)
          self?.connection.stateUpdateHandler = nil
        case .ready:
          continuation.resume()
          // NWConnection delivers all state updates on `queue`, so assigning
          // stateUpdateHandler here is safe: it runs on the same serial queue
          // as any future state updates.
          self?.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error), .failed(let error):
              self?.onDisconnected(error)
            case .setup, .preparing, .ready, .cancelled:
              break
            @unknown default:
              break
            }
          }
        case .failed(let error):
          continuation.resume(throwing: error)
          self?.connection.stateUpdateHandler = nil
        case .cancelled:
          continuation.resume(throwing: ConnectionError.cancelled)
          self?.connection.stateUpdateHandler = nil
        @unknown default:
          break
        }
      }

      connection.start(queue: queue)
    }
  }

  public func disconnect() {
    // Do not nil stateUpdateHandler before cancelling: NWConnection delivers
    // the .cancelled state update asynchronously, and clearing the handler
    // first would prevent any in-flight connect() continuation from being
    // resumed, causing a hang. The retain cycle is instead broken by
    // capturing self weakly in the handler closures.
    connection.cancel()
  }

  public func send(_ data: Data) async throws -> Data {
    await semaphore.wait()
    defer { Task { await semaphore.signal() } }

    switch connection.state {
    case .setup:
      try await connect()
    case .waiting(let error), .failed(let error):
      onDisconnected(error)
      throw error
    case .preparing, .ready:
      break
    case .cancelled:
      throw ConnectionError.cancelled
    @unknown default:
      throw ConnectionError.unknown
    }

    let transportPacket = DirectTCPPacket(smb2Message: data)
    let content = transportPacket.encoded()

    return try await withCheckedThrowingContinuation { (continuation) in
      connection.send(content: content, completion: .contentProcessed() { (error) in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        self.receive() { (result) in
          switch result {
          case .success(let data):
            continuation.resume(returning: data)
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      })
    }
  }

  private func receive(completion: @escaping (Result<Data, Error>) -> Void) {
    let minimumIncompleteLength = 1
    let maximumLength = 65536

    connection.receive(
      minimumIncompleteLength: minimumIncompleteLength,
      maximumLength: maximumLength)
    { (content, contentContext, isComplete, error) in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let content else {
        if isComplete {
          completion(.failure(ConnectionError.disconnected))
        } else {
          self.receive(completion: completion)
        }
        return
      }

      self.buffer.append(Data(content))

      self.receive(upTo: 4) { (headerResult) in
        switch headerResult {
        case .failure(let error):
          completion(.failure(error))
          return
        case .success:
          break
        }

        let transportPacket: DirectTCPPacket
        do {
          transportPacket = try DirectTCPPacket(response: self.buffer)
        } catch {
          completion(.failure(error))
          return
        }
        let length = Int(transportPacket.protocolLength)
        self.buffer = Data(transportPacket.smb2Message)

        self.receive(upTo: length) { (result) in
          switch result {
          case .success:
            // A malformed reply (short, oversized, or with offsets outside
            // itself) fails this request instead of crashing.
            do {
              let data = Data(self.buffer.prefix(length))
              self.buffer = Data(self.buffer.suffix(from: length))

              let reader = ByteReader(data)
              var offset = 0

              var header: Header
              var response = Data()
              repeat {
                header = try reader.read()

                switch NTStatus(header.status) {
                case
                  .success,
                  .moreProcessingRequired,
                  .noMoreFiles,
                  .endOfFile:
                  response += data
                case .pending:
                  if self.buffer.count >= 4 {
                    let transportPacket = try DirectTCPPacket(response: self.buffer)
                    let length = Int(transportPacket.protocolLength)

                    if self.buffer.count < 4 + length {
                      self.receive(completion: completion)
                      return
                    }

                    let data = transportPacket.smb2Message
                    self.buffer = Data(self.buffer.suffix(from: 4 + length))

                    let reader = ByteReader(data)
                    let header: Header = try reader.read()

                    switch NTStatus(header.status) {
                    case
                      .success,
                      .moreProcessingRequired,
                      .noMoreFiles,
                      .endOfFile:
                      response += data
                      break
                    default:
                      completion(.failure(try ErrorResponse(data: data)))
                      return
                    }
                  } else {
                    self.receive(completion: completion)
                    return
                  }
                default:
                  completion(.failure(try ErrorResponse(data: Data(data[offset...]))))
                  return
                }

                offset += Int(header.nextCommand)
                try reader.seek(to: offset)
              } while header.nextCommand > 0

              completion(.success(response))
            } catch {
              completion(.failure(error))
            }
          case .failure(let error):
            completion(.failure(error))
          }
        }
      }
    }
  }

  private func receive(upTo byteCount: Int, completion: @escaping (Result<(), Error>) -> Void) {
    let minimumIncompleteLength = 1
    let maximumLength = 65536

    if self.buffer.count < byteCount {
      self.connection.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { (data, _, isComplete, error) in
        if let error = error {
          completion(.failure(error))
          return
        }

        guard let data else {
          if isComplete {
            completion(.failure(ConnectionError.disconnected))
          } else {
            self.receive(upTo: byteCount, completion: completion)
          }
          return
        }

        self.buffer.append(data)
        self.receive(upTo: byteCount, completion: completion)
      }
      return
    }

    completion(.success(()))
  }
}

public enum ConnectionError: Error {
  case disconnected
  case cancelled
  case unknown
}
