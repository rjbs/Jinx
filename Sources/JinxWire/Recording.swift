import Foundation
import JinxJSON
import Synchronization

/// What a caller is doing when it talks to the server, for diagnostics.
/// The sync engine binds `purpose` around each step of a pass, and a
/// recording transport stamps it on every exchange it sees, so a log of
/// requests can say why each one was made, not just what it was.
public enum TransportContext {
  @TaskLocal public static var purpose: String?
}

/// One exchange with the server, as a `TransportRecorder` saw it.
public struct TransportExchange: Sendable, Identifiable {
  public enum Kind: Sendable {
    case session
    case api(Request, url: URL)
    case upload(contentType: String, size: Int, url: URL)
    case download(URL, range: Range<Int>?)
    case events(URL)
  }

  public enum Outcome: Sendable {
    /// Still under way; an event stream stays here while it is open.
    case pending
    case session(Session)
    case api(Response)
    case upload(UploadResponse)
    case download(contentType: String?, size: Int, range: Range<Int>?, totalLength: Int?)
    case eventStreamEnded(eventCount: Int)
    case failed(String)
  }

  /// Increases by one per exchange, in the order they began.
  public var id: Int
  public var purpose: String?
  public var kind: Kind
  public var started: Date
  public var finished: Date?
  public var outcome: Outcome

  public init(
    id: Int,
    purpose: String? = nil,
    kind: Kind,
    started: Date = Date(),
    finished: Date? = nil,
    outcome: Outcome = .pending
  ) {
    self.id = id
    self.purpose = purpose
    self.kind = kind
    self.started = started
    self.finished = finished
    self.outcome = outcome
  }

  public var duration: TimeInterval? {
    finished.map { $0.timeIntervalSince(started) }
  }

  public var isFailure: Bool {
    if case .failed = outcome { return true }
    return false
  }

  /// The request's method calls paired with their responses, for an API
  /// exchange; empty otherwise.
  public var calls: [CallExchange] {
    guard case .api(let request, _) = kind else { return [] }
    let response: Response? = if case .api(let response) = outcome { response } else { nil }
    return request.methodCalls.map { call in
      CallExchange(call: call, responses: response?.responses(to: call.callId) ?? [])
    }
  }

  /// One line saying what the exchange was, as a list would show it.
  public var title: String {
    switch kind {
    case .session: "session"
    case .api(let request, _): request.methodCalls.map(\.name).joined(separator: ", ")
    case .upload(let contentType, let size, _): "upload \(contentType), \(size) bytes"
    case .download(let url, let range):
      if let range { "download \(url.lastPathComponent) [\(range.lowerBound)..<\(range.upperBound)]" }
      else { "download \(url.lastPathComponent)" }
    case .events: "event stream"
    }
  }

  /// One line saying how it went.
  public var outcomeSummary: String {
    switch outcome {
    case .pending: "pending"
    case .session(let session): "state \(session.state), \(session.accounts.count) account(s)"
    case .api(let response):
      response.methodResponses.contains(where: \.isError)
        ? "\(response.methodResponses.filter(\.isError).count) method error(s)"
        : "\(response.methodResponses.count) response(s)"
    case .upload(let upload): "blob \(upload.blobId), \(upload.size) bytes"
    case .download(let contentType, let size, _, let totalLength):
      [
        "\(size) bytes",
        totalLength.map { "of \($0)" },
        contentType,
      ].compactMap(\.self).joined(separator: " ")
    case .eventStreamEnded(let count): "closed after \(count) event(s)"
    case .failed(let reason): "failed: \(reason)"
    }
  }

  /// The exchange as JSON, for a log file.  Request and response bodies
  /// are included whole, so this holds whatever the account holds.
  public var json: JSONValue {
    var members: [String: JSONValue] = [
      "id": .number(Double(id)),
      "started": .string(started.ISO8601Format(.iso8601.time(includingFractionalSeconds: true).year().month().day())),
      "title": .string(title),
      "outcome": .string(outcomeSummary),
    ]
    if let purpose { members["purpose"] = .string(purpose) }
    if let duration { members["duration"] = .number(duration) }
    switch kind {
    case .session: break
    case .api(let request, let url):
      members["url"] = .string(url.absoluteString)
      members["request"] = request.json
    case .upload(_, _, let url), .download(let url, _), .events(let url):
      members["url"] = .string(url.absoluteString)
    }
    if case .api(let response) = outcome {
      var responseMembers: [String: JSONValue] = [
        "methodResponses": .array(response.methodResponses.map(\.json)),
        "sessionState": .string(response.sessionState),
      ]
      if let created = response.createdIds {
        responseMembers["createdIds"] = .object(created.mapValues(JSONValue.string))
      }
      members["response"] = .object(responseMembers)
    }
    return .object(members)
  }
}

/// Something that watches a sync engine's exchanges with the server,
/// attached with `SyncEngine.addWireTap`.
///
/// `observe` is called when an exchange begins and again when it ends,
/// with the same `id`, on the task making the request.  It must be
/// quick, since the request waits for it; a tap with real work to do
/// should hand it off.
public protocol WireTap: AnyObject, Sendable {
  func observe(_ exchange: TransportExchange)
}

/// Keeps a tap attached until `cancel()` is called or the token is
/// released, whichever comes first.
public final class WireTapToken: Sendable {
  private let detach: Mutex<(@Sendable () -> Void)?>

  public init(detach: @escaping @Sendable () -> Void) {
    self.detach = Mutex(detach)
  }

  public func cancel() {
    let detach = self.detach.withLock { detach in
      defer { detach = nil }
      return detach
    }
    detach?()
  }

  deinit {
    cancel()
  }
}

/// A tap that keeps the most recent exchanges, and streams each one as
/// it begins and ends.
///
/// Recording is for diagnostics, and should happen only while someone
/// is looking: the recorder holds request and response bodies, which is
/// to say mail, contacts and whatever else the account holds.  Nothing
/// is written to disk unless `write(to:)` is called.
public final class TransportRecorder: WireTap {
  private struct State {
    var capacity: Int
    var exchanges: [TransportExchange] = []
    var subscribers: [UUID: AsyncStream<TransportExchange>.Continuation] = [:]
  }

  private let state: Mutex<State>

  public init(capacity: Int = 500) {
    state = Mutex(State(capacity: max(1, capacity)))
  }

  /// The exchanges kept, oldest first.
  public var exchanges: [TransportExchange] {
    state.withLock { $0.exchanges }
  }

  public func clear() {
    state.withLock { $0.exchanges.removeAll() }
  }

  /// Every exchange from now on, yielded when it begins and again each
  /// time it changes.  A consumer keeping a list replaces by `id`.
  public func updates() -> AsyncStream<TransportExchange> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<TransportExchange>.makeStream(bufferingPolicy: .bufferingNewest(1000))
    state.withLock { $0.subscribers[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
    return stream
  }

  /// Writes the kept exchanges to `url`, one JSON object per line.
  public func write(to url: URL) throws {
    var data = Data()
    for exchange in exchanges {
      data.append(try exchange.json.serialized())
      data.append(0x0A)
    }
    try data.write(to: url, options: .atomic)
  }

  public func observe(_ exchange: TransportExchange) {
    let subscribers = state.withLock { state in
      if let index = state.exchanges.lastIndex(where: { $0.id == exchange.id }) {
        state.exchanges[index] = exchange
      } else {
        state.exchanges.append(exchange)
        if state.exchanges.count > state.capacity {
          state.exchanges.removeFirst(state.exchanges.count - state.capacity)
        }
      }
      return Array(state.subscribers.values)
    }
    for subscriber in subscribers { subscriber.yield(exchange) }
  }
}
