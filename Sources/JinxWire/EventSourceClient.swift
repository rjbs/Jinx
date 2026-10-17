import Foundation
import JinxJSON

/// Exponential backoff between retries.
public struct Backoff: Sendable, Hashable {
  public var initial: Duration
  public var maximum: Duration
  public var multiplier: Double

  public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(300), multiplier: Double = 2) {
    self.initial = initial
    self.maximum = maximum
    self.multiplier = multiplier
  }

  /// The delays, in order: `initial`, then growing by `multiplier` and
  /// capped at `maximum`, forever.
  public func delays() -> some Sequence<Duration> & Sendable {
    let initial = initial
    let maximum = maximum
    let multiplier = multiplier
    return sequence(state: initial) { current in
      let next = current
      current = min(maximum, current * multiplier)
      return next
    }
  }
}

/// What a push subscription reports.
public enum PushEvent: Sendable, Hashable {
  case connected
  case stateChange(StateChange)
  case ping
  /// The connection ended; the client will reconnect after `retryIn`.
  case disconnected(reason: String?, retryIn: Duration)
}

/// Holds a JMAP EventSource connection open, reconnecting with backoff
/// when it drops and honoring a server-sent `retry` hint.  The stream
/// never ends on its own; cancel the consuming task to stop.
public struct EventSourceClient: Sendable {
  public var transport: any JMAPTransport
  public var url: URL
  public var backoff: Backoff

  public init(transport: any JMAPTransport, url: URL, backoff: Backoff = Backoff()) {
    self.transport = transport
    self.url = url
    self.backoff = backoff
  }

  /// Builds the EventSource URL from the session's template.  `types` is
  /// the list of type names to subscribe to, or `["*"]` for all.
  public static func url(
    from session: Session,
    types: [String] = ["*"],
    closeAfter: String = "no",
    ping: Int = 30
  ) -> URL? {
    session.eventSourceUrl.expand([
      "types": types.joined(separator: ","),
      "closeafter": closeAfter,
      "ping": String(ping),
    ])
  }

  public func events() -> AsyncStream<PushEvent> {
    AsyncStream { continuation in
      let task = Task {
        var delays = backoff.delays().makeIterator()
        var serverRetry: Duration?
        while !Task.isCancelled {
          var receivedAnything = false
          var reason: String?
          do {
            var first = true
            for try await event in transport.events(from: url) {
              if first {
                first = false
                continuation.yield(.connected)
              }
              receivedAnything = true
              if let retry = event.retry { serverRetry = retry }
              switch event.event {
              case "state":
                if let json = try? JSONValue(parsing: event.data), let change = try? StateChange(json: json) {
                  continuation.yield(.stateChange(change))
                }
              case "ping":
                continuation.yield(.ping)
              default:
                break
              }
            }
          } catch {
            reason = String(describing: error)
          }
          if Task.isCancelled { break }
          // A connection that delivered events earned a fresh backoff;
          // one that failed outright keeps climbing. -- claude, 2026-10-17
          if receivedAnything { delays = backoff.delays().makeIterator() }
          let delay = serverRetry ?? delays.next() ?? backoff.maximum
          continuation.yield(.disconnected(reason: reason, retryIn: delay))
          do {
            try await Task.sleep(for: delay)
          } catch {
            break
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
