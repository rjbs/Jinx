import Foundation
import Synchronization

/// A canned HTTP server behind URLSession.  Tests install a handler,
/// which sees each request and answers with a status, headers and body.
/// The handler is process-global, so suites that use it are serialized.
final class StubProtocol: URLProtocol {
  struct Reply {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "application/json"]
    var body: Data = Data()
  }

  typealias Handler = @Sendable (URLRequest, Data?) -> Reply

  private static let handler = Mutex<Handler?>(nil)
  private static let requests = Mutex<[URLRequest]>([])

  static func install(_ handler: @escaping Handler) {
    self.handler.withLock { $0 = handler }
    requests.withLock { $0 = [] }
  }

  static var seenRequests: [URLRequest] {
    requests.withLock { $0 }
  }

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
    Self.requests.withLock { $0.append(request) }
    guard let handler = Self.handler.withLock({ $0 }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let reply = handler(request, body)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: reply.status,
      httpVersion: "HTTP/1.1",
      headerFields: reply.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readAll(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
