import Foundation
import JinxJSON

/// Adds credentials to an outgoing request.
public protocol Authenticator: Sendable {
  func authorize(_ request: inout URLRequest) async throws
}

public struct BearerToken: Authenticator {
  public var token: String

  public init(_ token: String) {
    self.token = token
  }

  public func authorize(_ request: inout URLRequest) {
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }
}

public struct BasicCredentials: Authenticator {
  public var username: String
  public var password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }

  public func authorize(_ request: inout URLRequest) {
    let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
    request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
  }
}

public struct NoAuthentication: Authenticator {
  public init() {}
  public func authorize(_ request: inout URLRequest) {}
}

/// The result of a blob upload (RFC 8620 section 6.1).
public struct UploadResponse: Sendable, Hashable {
  public var accountId: String
  public var blobId: String
  public var type: String
  public var size: Int

  public init(json: JSONValue) throws(JMAPError) {
    guard let accountId = json["accountId"]?.stringValue,
          let blobId = json["blobId"]?.stringValue,
          let type = json["type"]?.stringValue,
          let size = json["size"]?.intValue
    else { throw .malformed("upload response missing a member") }
    self.accountId = accountId
    self.blobId = blobId
    self.type = type
    self.size = size
  }
}

/// A downloaded blob, or a range of one.
public struct BlobDownload: Sendable, Hashable {
  public var data: Data
  public var contentType: String?
  /// The byte range `data` covers, when the server honored a range
  /// request; `nil` means `data` is the whole blob.
  public var range: Range<Int>?
  /// The blob's full length, when the server said.
  public var totalLength: Int?
}

/// What the sync engine needs from the network.  `JMAPClient` is the
/// real one; a test harness substitutes its own.
public protocol JMAPTransport: Sendable {
  func fetchSession() async throws(JMAPError) -> Session
  func send(_ request: Request, to apiUrl: URL) async throws(JMAPError) -> Response
  func upload(_ data: Data, contentType: String, to uploadUrl: URL) async throws(JMAPError) -> UploadResponse
  func download(from url: URL, range: Range<Int>?) async throws(JMAPError) -> BlobDownload
  /// Opens a server-sent-event stream and yields its events until the
  /// connection ends.  Reconnection is `EventSourceClient`'s job.
  func events(from url: URL) -> AsyncThrowingStream<ServerSentEvent, any Error>
}

/// The transport over URLSession.
public struct JMAPClient: JMAPTransport {
  public var sessionUrl: URL
  public var authenticator: any Authenticator
  public var urlSession: URLSession

  public init(sessionUrl: URL, authenticator: any Authenticator, urlSession: URLSession = .shared) {
    self.sessionUrl = sessionUrl
    self.authenticator = authenticator
    self.urlSession = urlSession
  }

  public func fetchSession() async throws(JMAPError) -> Session {
    var request = URLRequest(url: sessionUrl)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await perform(request)
    guard let base = response.url ?? request.url else { throw .badSession("no URL") }
    return try Session(json: try Self.decode(data), base: base)
  }

  public func send(_ request: Request, to apiUrl: URL) async throws(JMAPError) -> Response {
    var urlRequest = URLRequest(url: apiUrl)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      urlRequest.httpBody = try request.json.serialized()
    } catch {
      throw .malformed("request did not serialize: \(error)")
    }
    let (data, _) = try await perform(urlRequest)
    return try Response(json: try Self.decode(data))
  }

  public func upload(_ data: Data, contentType: String, to uploadUrl: URL) async throws(JMAPError) -> UploadResponse {
    var request = URLRequest(url: uploadUrl)
    request.httpMethod = "POST"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = data
    let (body, _) = try await perform(request)
    return try UploadResponse(json: try Self.decode(body))
  }

  public func download(from url: URL, range: Range<Int>?) async throws(JMAPError) -> BlobDownload {
    var request = URLRequest(url: url)
    if let range {
      request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    let (data, response) = try await perform(request)
    var download = BlobDownload(data: data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
    if response.statusCode == 206,
       let header = response.value(forHTTPHeaderField: "Content-Range"),
       let parsed = Self.parseContentRange(header)
    {
      download.range = parsed.range
      download.totalLength = parsed.total
    } else if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) {
      download.totalLength = length
    }
    return download
  }

  public func events(from url: URL) -> AsyncThrowingStream<ServerSentEvent, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: url)
          request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
          request.timeoutInterval = .infinity
          try await authenticator.authorize(&request)
          let (bytes, response) = try await urlSession.bytes(for: request)
          guard let http = response as? HTTPURLResponse else { throw JMAPError.malformed("not HTTP") }
          guard (200..<300).contains(http.statusCode) else {
            throw JMAPError.httpStatus(http.statusCode, body: Data())
          }
          var splitter = LineSplitter()
          var parser = ServerSentEventParser()
          for try await byte in bytes {
            if let line = splitter.feed(byte), let event = parser.feed(line: line) {
              continuation.yield(event)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Plumbing

  private func perform(_ request: URLRequest) async throws(JMAPError) -> (Data, HTTPURLResponse) {
    var request = request
    let data: Data
    let response: URLResponse
    do {
      try await authenticator.authorize(&request)
      (data, response) = try await urlSession.data(for: request)
    } catch {
      throw .transport(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw .malformed("not an HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      if let problem = try? RequestError(problemDetails: try Self.decode(data)) {
        throw .request(problem)
      }
      throw .httpStatus(http.statusCode, body: data)
    }
    return (data, http)
  }

  private static func decode(_ data: Data) throws(JMAPError) -> JSONValue {
    do {
      return try JSONValue(parsing: data)
    } catch {
      throw .malformed("body is not JSON: \(error)")
    }
  }

  /// Parses `bytes 0-99/1234` or `bytes 0-99/*`.
  static func parseContentRange(_ header: String) -> (range: Range<Int>, total: Int?)? {
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("bytes ") else { return nil }
    let spec = trimmed.dropFirst("bytes ".count)
    guard let slash = spec.firstIndex(of: "/") else { return nil }
    let bounds = spec[..<slash].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]), last >= first else {
      return nil
    }
    let totalText = spec[spec.index(after: slash)...]
    return (first..<(last + 1), totalText == "*" ? nil : Int(totalText))
  }
}
