import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

extension SyncEngine {
  /// Brings every type up to date: `/changes` for types with a state,
  /// a full fetch for types without one or whose state the server no
  /// longer recognizes.
  func syncIn() async throws {
    let session = try await currentSession()
    let accountId = accountId
    let states = try await store.read { tx -> [String: String?] in
      var states: [String: String?] = [:]
      for type in self.orderedTypes { states[type.name] = try tx.serverState(accountId: accountId, type: type.name) }
      return states
    }
    var needFull: [TypeDescriptor] = []
    var incremental: [TypeDescriptor] = []
    var windowed: [TypeDescriptor] = []
    for descriptor in orderedTypes {
      if descriptor.mode == .windowed {
        windowed.append(descriptor)
      } else if states[descriptor.name] ?? nil == nil {
        needFull.append(descriptor)
      } else {
        incremental.append(descriptor)
      }
    }
    let (resyncs, moved) = try await syncInChanges(incremental, session: session)
    for descriptor in needFull + resyncs {
      try await fullFetch(descriptor, session: session)
    }
    try await refreshFullTypeSubscriptions(moved: moved.union((needFull + resyncs).map(\.name)), session: session)
    let windowedResyncs = try await syncInWindowed(windowed, session: session)
    if !windowedResyncs.isEmpty {
      for descriptor in windowedResyncs { try await resyncWindowed(descriptor) }
      _ = try await syncInWindowed(windowedResyncs, session: session)
    }
    status.lastSyncIn = Date()
  }

  var fetchChunk: Int {
    let serverMax = session?.core?.maxObjectsInGet ?? 256
    return max(1, min(serverMax, configuration.fetchChunk ?? serverMax))
  }

  /// Runs `/changes` rounds for the given types until none has more.
  /// Returns the types that need a full fetch instead, and the types
  /// whose state moved.
  private func syncInChanges(_ types: [TypeDescriptor], session: Session) async throws -> ([TypeDescriptor], Set<String>) {
    var remaining = types
    var needFull: [TypeDescriptor] = []
    var moved: Set<String> = []
    var staleRounds = 0
    let accountId = accountId
    let chunk = fetchChunk

    for _ in 0..<200 where !remaining.isEmpty {
      let remainingNow = remaining
      let states = try await store.read { tx -> [String: String] in
        var states: [String: String] = [:]
        for type in remainingNow { states[type.name] = try tx.serverState(accountId: accountId, type: type.name) }
        return states
      }
      var builder = RequestBuilder(using: capabilities)
      var calls: [String: (changes: RequestBuilder.Call, created: RequestBuilder.Call, updated: RequestBuilder.Call)] = [:]
      for descriptor in remaining {
        guard let state = states[descriptor.name] else { continue }
        let changes = builder.call("\(descriptor.name)/changes", .changesArguments(accountId: accountId, sinceState: state, maxChanges: chunk))
        let created = builder.call(
          "\(descriptor.name)/get",
          descriptor.getArguments(accountId: accountId, ids: []),
          references: ["ids": changes.reference("/created")]
        )
        let updated = builder.call(
          "\(descriptor.name)/get",
          descriptor.getArguments(accountId: accountId, ids: []),
          references: ["ids": changes.reference("/updated")]
        )
        calls[descriptor.name] = (changes, created, updated)
      }
      guard !builder.isEmpty else { break }

      let response: Response
      do {
        response = try await transport.send(builder.request, to: session.apiUrl)
      } catch {
        status.lastFailure = String(describing: error)
        throw Classification.classify(error) == .permanent
          ? SyncError.permanent(String(describing: error))
          : SyncError.retryable(String(describing: error))
      }

      let descriptors = descriptors
      let processId = configuration.processId
      let callsNow = calls
      let result = try await commit({ tx, changeSet -> (done: [String], stale: [String], resync: [String], moved: [String], failed: String?) in
        var done: [String] = []
        var stale: [String] = []
        var resync: [String] = []
        var movedNow: [String] = []
        var failed: String?
        for (type, call) in callsNow {
          let descriptor = descriptors[type]!
          guard let invocation = response.response(to: call.changes.callId) else {
            failed = "no response to \(type)/changes"
            continue
          }
          if let error = invocation.methodError {
            if error.type == MethodError.cannotCalculateChanges {
              resync.append(type)
            } else if Classification.classify(error) == .permanent {
              throw SyncError.permanent("\(type)/changes: \(error.type)")
            } else {
              failed = "\(type)/changes: \(error.type)"
            }
            continue
          }
          let changes = try ChangesResponse(json: invocation.arguments)
          guard changes.oldState == states[type] else {
            stale.append(type)
            continue
          }
          var fetched: [JSONValue] = []
          for getCall in [call.created, call.updated] {
            guard let get = response.response(to: getCall.callId), !get.isError else {
              failed = "\(type)/get failed: \(response.response(to: getCall.callId)?.methodError?.type ?? "missing")"
              continue
            }
            fetched += try GetResponse(json: get.arguments).list
          }
          if failed != nil { continue }
          for object in fetched {
            try Self.applyFetched(object, descriptor: descriptor, accountId: accountId, processId: processId, in: tx, changeSet: &changeSet)
          }
          for id in changes.destroyed {
            try Self.applyDestroyed(id, type: type, accountId: accountId, in: tx, changeSet: &changeSet)
          }
          try tx.setServerState(changes.newState, accountId: accountId, type: type)
          if changes.oldState != changes.newState { movedNow.append(type) }
          if !changes.hasMoreChanges { done.append(type) }
        }
        return (done, stale, resync, movedNow, failed)
      }, source: .syncIn)

      if let failed = result.failed {
        status.lastFailure = failed
        throw SyncError.retryable(failed)
      }
      moved.formUnion(result.moved)
      needsSyncIn.subtract(result.done)
      remaining.removeAll { result.done.contains($0.name) || result.resync.contains($0.name) }
      needFull += result.resync.compactMap { descriptors[$0] }
      if !result.stale.isEmpty {
        staleRounds += 1
        if staleRounds > 5 { throw SyncError.retryable("state kept moving during sync-in") }
      }
    }
    return (needFull, moved)
  }

  /// Fetches every object of a type: the initial sync, and the resync
  /// after `cannotCalculateChanges`.  Commits per chunk, reports
  /// progress, and never wipes local data: objects the server no
  /// longer has are removed at the end, except ones with a pending
  /// create, which the server has never seen.
  func fullFetch(_ descriptor: TypeDescriptor, session: Session) async throws {
    let accountId = accountId
    let type = descriptor.name
    let chunk = fetchChunk
    status.initialSync[type] = InitialSyncProgress(fetched: 0, total: nil)
    defer { status.initialSync[type] = nil }

    var seen: Set<String> = []
    var typeState: String?

    // First try: everything in one /get.
    var builder = RequestBuilder(using: capabilities)
    let all = builder.call("\(type)/get", descriptor.getArguments(accountId: accountId, ids: nil))
    let first = try await send(builder.request, session: session)
    if let invocation = first.response(to: all.callId), !invocation.isError {
      let get = try GetResponse(json: invocation.arguments)
      typeState = get.state
      status.initialSync[type]?.total = get.list.count
      try await applyChunk(get.list, descriptor: descriptor)
      seen.formUnion(get.list.compactMap { $0["id"]?.stringValue })
      status.initialSync[type]?.fetched = seen.count
    } else if first.response(to: all.callId)?.methodError?.type == MethodError.requestTooLarge {
      // Page through /query, fetching each page in the same request.
      var position = 0
      while true {
        var builder = RequestBuilder(using: capabilities)
        let query = builder.call("\(type)/query", .queryArguments(accountId: accountId, position: position, limit: chunk, calculateTotal: true))
        let get = builder.call(
          "\(type)/get",
          descriptor.getArguments(accountId: accountId, ids: []),
          references: ["ids": query.reference("/ids")]
        )
        let response = try await send(builder.request, session: session)
        guard let queryInvocation = response.response(to: query.callId), !queryInvocation.isError,
              let getInvocation = response.response(to: get.callId), !getInvocation.isError
        else {
          let type = response.response(to: query.callId)?.methodError?.type ?? response.response(to: get.callId)?.methodError?.type
          status.lastFailure = "\(descriptor.name) full fetch: \(type ?? "no response")"
          throw SyncError.retryable(status.lastFailure!)
        }
        let page = try QueryResponse(json: queryInvocation.arguments)
        let got = try GetResponse(json: getInvocation.arguments)
        if typeState == nil { typeState = got.state }
        if let total = page.total { status.initialSync[type]?.total = total }
        try await applyChunk(got.list, descriptor: descriptor)
        seen.formUnion(got.list.compactMap { $0["id"]?.stringValue })
        status.initialSync[type]?.fetched = seen.count
        if page.ids.count < chunk { break }
        position += page.ids.count
      }
    } else {
      let error = first.response(to: all.callId)?.methodError?.type ?? "no response"
      status.lastFailure = "\(type)/get: \(error)"
      throw SyncError.retryable(status.lastFailure!)
    }

    let finalState = typeState
    let seenIds = seen
    try await commit({ tx, changeSet in
      for object in try tx.objects(accountId: accountId, type: type) {
        guard let id = object.id, !seenIds.contains(id) else { continue }
        if object.pending == .create { continue }
        try tx.delete(key: object.key)
        changeSet.noteDestroyed(object.key, type: type)
      }
      try tx.setServerState(finalState, accountId: accountId, type: type)
    }, source: .syncIn)
    needsSyncIn.remove(type)
  }

  /// Commits one chunk of a full fetch.
  func applyChunk(_ list: [JSONValue], descriptor: TypeDescriptor) async throws {
    let accountId = accountId
    let processId = configuration.processId
    try await commit({ tx, changeSet in
      for object in list {
        try Self.applyFetched(object, descriptor: descriptor, accountId: accountId, processId: processId, in: tx, changeSet: &changeSet)
      }
    }, source: .syncIn)
  }

  func send(_ request: Request, session: Session) async throws -> Response {
    do {
      return try await transport.send(request, to: session.apiUrl)
    } catch {
      status.lastFailure = String(describing: error)
      throw Classification.classify(error) == .permanent
        ? SyncError.permanent(String(describing: error))
        : SyncError.retryable(String(describing: error))
    }
  }

  // MARK: Applying fetched objects

  /// Merges one fetched object into the store: insert, replace, rebase
  /// onto a pending change, or adopt by client identity.
  static func applyFetched(
    _ fetched: JSONValue,
    descriptor: TypeDescriptor,
    accountId: String,
    processId: String,
    in tx: Store.Transaction,
    changeSet: inout ChangeSet
  ) throws {
    guard let id = fetched["id"]?.stringValue else { return }
    let type = descriptor.name

    if var existing = try tx.object(accountId: accountId, type: type, id: id) {
      if let entry = try tx.pending(key: existing.key), let claimant = entry.claimedBy, claimant != processId {
        return  // another process is pushing this object; it reconciles
      }
      for property in descriptor.blobProperties {
        let old = existing.local[property]?.stringValue
        let new = fetched[property]?.stringValue
        if old != new {
          changeSet.blobs.append(BlobChange(type: type, key: existing.key, property: property, oldBlobId: old, newBlobId: new))
        }
      }
      switch existing.pending {
      case nil:
        if existing.serverVersion == fetched && existing.local == fetched { return }
        existing.serverVersion = fetched
        existing.local = fetched
        try tx.update(existing)
        changeSet.noteUpdated(existing.key, type: type)
      case .update, .create:
        let rebase = try Rebase(serverVersion: existing.serverVersion ?? .object([:]), local: existing.local, fetched: fetched, mayPatch: descriptor.mayPatch)
        existing.serverVersion = fetched
        existing.local = rebase.local
        try tx.update(existing)
        if rebase.isRedundant { try tx.clearPending(key: existing.key) }
        changeSet.noteUpdated(existing.key, type: type)
      case .destroy:
        existing.serverVersion = fetched
        try tx.update(existing)
      }
      return
    }

    if let identity = descriptor.clientIdentity,
       let value = fetched[identity.property],
       var candidate = try tx.object(accountId: accountId, type: type, property: identity.property, equals: value),
       candidate.id == nil
    {
      let rebase = try Rebase(serverVersion: candidate.serverVersion ?? .object([:]), local: candidate.local, fetched: fetched, mayPatch: descriptor.mayPatch)
      candidate.id = id
      candidate.serverVersion = fetched
      candidate.local = rebase.local
      try tx.update(candidate)
      if rebase.isRedundant {
        try tx.clearPending(key: candidate.key)
      } else {
        try tx.setPending(key: candidate.key, operation: .update)
      }
      changeSet.noteIdAssigned(id, to: candidate.key, type: type)
      changeSet.noteUpdated(candidate.key, type: type)
      return
    }

    let inserted = try tx.insert(NewObject(accountId: accountId, type: type, id: id, serverVersion: fetched, local: fetched))
    changeSet.noteCreated(inserted.key, type: type)
  }

  static func applyDestroyed(_ id: String, type: String, accountId: String, in tx: Store.Transaction, changeSet: inout ChangeSet) throws {
    guard let existing = try tx.object(accountId: accountId, type: type, id: id) else { return }
    try tx.delete(key: existing.key)
    changeSet.noteDestroyed(existing.key, type: type)
  }
}
