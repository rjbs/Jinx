import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

// Windowed sync: for a type too large to mirror, the store holds only
// what subscriptions, pins, pending changes and references retain.  A
// pass brings the retained set up to date and evicts the rest.

extension SyncEngine {
  // MARK: - Public API

  /// Declares or redefines a live query.  The engine refreshes it on
  /// the next pass and keeps its window's objects held.  Redefining
  /// under the same id with different parameters starts it over.
  public func subscribe(_ subscription: QuerySubscription) async throws {
    guard descriptors[subscription.type] != nil else { throw SyncError.unknownType(subscription.type) }
    let accountId = accountId
    var subscription = subscription
    subscription.accountId = accountId
    let definition = subscription
    let changed = try await store.write { tx -> Bool in
      if let existing = try tx.subscription(accountId: accountId, id: definition.id) {
        if existing == definition { return false }
        try tx.setSubscriptionResult(nil, accountId: accountId, id: definition.id)
      }
      try tx.setSubscription(definition)
      return true
    }
    // An identical redefinition is a no-op all the way down: no store
    // change and no pass, so an app may re-declare freely.
    if changed { requestSync() }
  }

  public func unsubscribe(_ id: String) async throws {
    let accountId = accountId
    try await store.write { tx in try tx.removeSubscription(accountId: accountId, id: id) }
    requestSync()
  }

  /// Runs the type's subscriptions again on the next pass, as if the
  /// type had moved.  A query's answer can depend on more than the
  /// type's own objects: a saved search kept in another type, say, or
  /// the time of day.  When the app knows such an answer has gone
  /// stale, it asks for the queries to run again, and the results that
  /// stand are kept until the new ones arrive.
  public func refreshSubscriptions(of type: String) throws(SyncError) {
    guard descriptors[type] != nil else { throw SyncError.unknownType(type) }
    subscriptionsDirty.insert(type)
    requestSync()
  }

  public func subscriptions() async throws -> [QuerySubscription] {
    let accountId = accountId
    return try await store.read { tx in try tx.subscriptions(accountId: accountId) }
  }

  /// What the server last said the subscription's window holds, or
  /// `nil` before its first refresh.
  public func result(of subscriptionId: String) async throws -> SubscriptionResult? {
    let accountId = accountId
    return try await store.read { tx in try tx.subscriptionResult(accountId: accountId, id: subscriptionId) }
  }

  /// A subscription's result and the objects in its window, read in one
  /// transaction so they describe the same state.  Anything that cuts
  /// the window by numbers in `result.extra`, such as section counts,
  /// must read this way; two separate reads can straddle a commit.
  public struct Window: Sendable, Hashable {
    public var subscription: QuerySubscription
    public var result: SubscriptionResult
    /// In the query's order, omitting any object not yet held.
    public var objects: [SyncedObject]
    /// Ids in `result.ids` whose objects are not held.  Normally empty,
    /// because a pass fetches a window's objects before it commits the
    /// result; non-empty when a `/get` reported one not found, as when
    /// an object was destroyed between the query and the fetch.  A
    /// consumer that cuts the window positionally must check this.
    public var missingIds: [String]

    public var isComplete: Bool { missingIds.isEmpty }
  }

  /// The subscription's window, or `nil` before its first refresh.
  public func window(of subscriptionId: String) async throws -> Window? {
    let accountId = accountId
    return try await store.read { tx in
      guard let subscription = try tx.subscription(accountId: accountId, id: subscriptionId),
            let result = try tx.subscriptionResult(accountId: accountId, id: subscriptionId)
      else { return nil }
      let held = Dictionary(
        try tx.objects(accountId: accountId, type: subscription.type, ids: result.ids).map { ($0.id!, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      return Window(
        subscription: subscription,
        result: result,
        objects: result.ids.compactMap { held[$0] }.map(SyncedObject.init),
        missingIds: result.ids.filter { held[$0] == nil }
      )
    }
  }

  /// The objects in a subscription's window, in the query's order,
  /// omitting any not yet held.  Pair with `result(of:)` only when the
  /// two need not agree; otherwise use `window(of:)`.
  public func objects(in subscriptionId: String) async throws -> [SyncedObject] {
    try await window(of: subscriptionId)?.objects ?? []
  }

  /// Keeps objects held regardless of any subscription, fetching them
  /// if missing on the next pass.  An app pins what it is showing
  /// outside a window, such as the messages of an open thread.
  public func pin(_ type: String, ids: [String]) async throws {
    guard descriptors[type] != nil else { throw SyncError.unknownType(type) }
    let accountId = accountId
    try await store.write { tx in try tx.setPinned(true, accountId: accountId, type: type, ids: ids) }
    requestSync()
  }

  public func unpin(_ type: String, ids: [String]) async throws {
    let accountId = accountId
    try await store.write { tx in try tx.setPinned(false, accountId: accountId, type: type, ids: ids) }
  }

  /// Fetches objects now, with extra `/get` arguments merged over the
  /// type's own, and stores what comes back.  This is how an app gets
  /// an Email's body: a fetch with `fetchHTMLBodyValues`.  The objects
  /// stay held only while something retains them, so pin them if they
  /// must survive the next pass.
  @discardableResult
  public func fetch(_ type: String, ids: [String], arguments: [String: JSONValue] = [:]) async throws -> [SyncedObject] {
    let descriptor = try self.descriptor(type)
    let session = try await currentSession()
    var all: [JSONValue] = []
    var start = 0
    while start < ids.count {
      let chunk = Array(ids[start..<min(start + fetchChunk, ids.count)])
      start += fetchChunk
      var builder = RequestBuilder(using: capabilities)
      var args = descriptor.getArguments(accountId: accountId, ids: chunk)
      for (key, value) in arguments where key != "accountId" && key != "ids" { args[key] = value }
      let call = builder.call("\(type)/get", args)
      let response = try await send(builder.request, session: session)
      guard let invocation = response.response(to: call.callId), !invocation.isError else {
        throw SyncError.retryable("\(type)/get: \(response.response(to: call.callId)?.methodError?.type ?? "no response")")
      }
      all += try GetResponse(json: invocation.arguments).list
    }
    let fetched = all
    try await applyChunk(fetched, descriptor: descriptor)
    let fetchedIds = fetched.compactMap { $0["id"]?.stringValue }
    let accountId = accountId
    return try await store.read { tx in
      try tx.objects(accountId: accountId, type: type, ids: fetchedIds).map(SyncedObject.init)
    }
  }

  // MARK: - The windowed pass

  /// One round for the windowed types: changes, subscription refresh,
  /// fetches, references, then retention.  Returns the types that need
  /// a resync.
  func syncInWindowed(_ types: [TypeDescriptor], session: Session) async throws -> [TypeDescriptor] {
    guard !types.isEmpty else { return [] }
    let accountId = accountId
    let chunk = fetchChunk
    let descriptors = descriptors
    var needResync: [TypeDescriptor] = []

    // Types with no state yet get one from an empty /get.
    let states = try await store.read { tx -> [String: String?] in
      var states: [String: String?] = [:]
      for type in types { states[type.name] = try tx.serverState(accountId: accountId, type: type.name) }
      return states
    }
    let stateless = types.filter { states[$0.name] ?? nil == nil }
    if !stateless.isEmpty {
      var builder = RequestBuilder(using: capabilities)
      var calls: [String: RequestBuilder.Call] = [:]
      for type in stateless {
        calls[type.name] = builder.call("\(type.name)/get", type.getArguments(accountId: accountId, ids: []))
      }
      let response = try await send(builder.request, session: session)
      let initial = calls.compactMapValues { call -> String? in
        guard let invocation = response.response(to: call.callId), !invocation.isError else { return nil }
        return try? GetResponse(json: invocation.arguments).state
      }
      try await store.write { tx in
        for (type, state) in initial { try tx.setServerState(state, accountId: accountId, type: type) }
      }
    }

    for _ in 0..<50 {
      // Step 1: /changes for every windowed type.
      let typeStates = try await store.read { tx -> [String: String] in
        var states: [String: String] = [:]
        for type in types { states[type.name] = try tx.serverState(accountId: accountId, type: type.name) }
        return states
      }
      var builder = RequestBuilder(using: capabilities)
      var changeCalls: [String: RequestBuilder.Call] = [:]
      for type in types {
        guard let state = typeStates[type.name] else { continue }
        changeCalls[type.name] = builder.call("\(type.name)/changes", .changesArguments(accountId: accountId, sinceState: state, maxChanges: chunk))
      }
      guard !builder.isEmpty else { break }
      let changesResponse = try await send(builder.request, session: session)

      var changes: [String: ChangesResponse] = [:]
      var hasMore = false
      for type in types {
        guard let call = changeCalls[type.name], let invocation = changesResponse.response(to: call.callId) else { continue }
        if let error = invocation.methodError {
          if error.type == MethodError.cannotCalculateChanges {
            needResync.append(type)
            continue
          }
          if Classification.classify(error) == .permanent { throw SyncError.permanent("\(type.name)/changes: \(error.type)") }
          throw SyncError.retryable("\(type.name)/changes: \(error.type)")
        }
        let parsed = try ChangesResponse(json: invocation.arguments)
        guard parsed.oldState == typeStates[type.name] else { continue }  // moved; next round
        changes[type.name] = parsed
        if parsed.hasMoreChanges { hasMore = true }
      }
      let active = types.filter { changes[$0.name] != nil }

      // Step 2: refresh subscriptions whose type moved or that have no
      // result, and fetch held objects that changed.
      let subscriptions = try await store.read { tx in try tx.subscriptions(accountId: accountId) }
        .filter { sub in active.contains { $0.name == sub.type } }
      let heldByType = try await store.read { tx -> [String: Set<String>] in
        var held: [String: Set<String>] = [:]
        for type in active { held[type.name] = try tx.ids(accountId: accountId, type: type.name) }
        return held
      }
      let results = try await store.read { tx -> [String: SubscriptionResult?] in
        var results: [String: SubscriptionResult?] = [:]
        for sub in subscriptions { results[sub.id] = try tx.subscriptionResult(accountId: accountId, id: sub.id) }
        return results
      }

      var refresh = RequestBuilder(using: capabilities)
      var queryCalls: [String: (call: RequestBuilder.Call, isChanges: Bool)] = [:]
      for sub in subscriptions {
        let change = changes[sub.type]!
        let result = results[sub.id] ?? nil
        let moved = change.oldState != change.newState || subscriptionsDirty.contains(sub.type)
        guard result == nil || moved else { continue }
        if let result, result.canCalculateChanges, let queryState = result.queryState, sub.limit == nil || sub.position == 0 {
          let upToId = sub.limit != nil ? result.ids.last : nil
          queryCalls[sub.id] = (refresh.call("\(sub.type)/queryChanges", sub.queryChangesArguments(
            accountId: accountId, sinceQueryState: queryState, upToId: upToId
          )), true)
        } else {
          queryCalls[sub.id] = (refresh.call("\(sub.type)/query", sub.queryArguments(accountId: accountId)), false)
        }
      }
      var wanted: [String: Set<String>] = [:]  // type -> ids to fetch now
      let wholeType = Set(subscriptions.filter(\.coversWholeType).map(\.type))
      for type in active {
        let change = changes[type.name]!
        let held = heldByType[type.name] ?? []
        var ids = Set(change.updated).intersection(held)
        if wholeType.contains(type.name) { ids.formUnion(change.created) }
        wanted[type.name] = ids
      }
      var getCalls: [(type: String, call: RequestBuilder.Call)] = []
      for (type, ids) in wanted where !ids.isEmpty {
        for part in Array(ids).sorted().chunked(chunk) {
          getCalls.append((type, refresh.call("\(type)/get", descriptors[type]!.getArguments(accountId: accountId, ids: part))))
        }
      }
      let refreshResponse = refresh.isEmpty ? nil : try await send(refresh.request, session: session)

      var newResults: [String: SubscriptionResult] = [:]
      var subscriptionsNeedingFullQuery: [QuerySubscription] = []
      for sub in subscriptions {
        guard let (call, isChanges) = queryCalls[sub.id], let response = refreshResponse?.response(to: call.callId) else { continue }
        if let error = response.methodError {
          if isChanges, error.type == MethodError.cannotCalculateChanges || error.type == MethodError.tooManyChanges {
            subscriptionsNeedingFullQuery.append(sub)
            continue
          }
          if Classification.classify(error) == .permanent {
            throw SyncError.permanent("\(sub.type)/query (\(sub.id)): \(error.type)")
          }
          throw SyncError.retryable("\(sub.type)/query (\(sub.id)): \(error.type)")
        }
        if isChanges {
          let delta = try QueryChangesResponse(json: response.arguments)
          var result = (results[sub.id] ?? nil) ?? SubscriptionResult(ids: [])
          result.ids.removeAll { delta.removed.contains($0) }
          for added in delta.added.sorted(by: { $0.index < $1.index }) {
            result.ids.insert(added.id, at: min(added.index, result.ids.count))
          }
          if let limit = sub.limit, result.ids.count > limit { result.ids.removeLast(result.ids.count - limit) }
          result.total = delta.total ?? result.total
          result.queryState = delta.newQueryState
          result.extra = delta.extra
          newResults[sub.id] = result
        } else {
          newResults[sub.id] = try await completeQuery(sub, from: QueryResponse(json: response.arguments), session: session)
        }
      }
      if !subscriptionsNeedingFullQuery.isEmpty {
        var again = RequestBuilder(using: capabilities)
        var calls: [String: RequestBuilder.Call] = [:]
        for sub in subscriptionsNeedingFullQuery {
          calls[sub.id] = again.call("\(sub.type)/query", sub.queryArguments(accountId: accountId))
        }
        let response = try await send(again.request, session: session)
        for sub in subscriptionsNeedingFullQuery {
          guard let invocation = response.response(to: calls[sub.id]!.callId), !invocation.isError else {
            throw SyncError.retryable("\(sub.type)/query (\(sub.id)) failed")
          }
          newResults[sub.id] = try await completeQuery(sub, from: QueryResponse(json: invocation.arguments), session: session)
        }
      }

      var fetched: [String: [JSONValue]] = [:]
      for (type, call) in getCalls {
        guard let invocation = refreshResponse?.response(to: call.callId), !invocation.isError else {
          throw SyncError.retryable("\(type)/get failed in windowed pass")
        }
        fetched[type, default: []] += try GetResponse(json: invocation.arguments).list
      }

      // Step 3: fetch window and pinned objects not yet held.
      var missing: [String: Set<String>] = [:]
      for sub in subscriptions {
        let ids = newResults[sub.id]?.ids ?? (results[sub.id] ?? nil)?.ids ?? []
        missing[sub.type, default: []].formUnion(ids)
      }
      let pins = try await store.read { tx -> [String: Set<String>] in
        var pins: [String: Set<String>] = [:]
        for type in active { pins[type.name] = try tx.pins(accountId: accountId, type: type.name) }
        return pins
      }
      for type in active { missing[type.name, default: []].formUnion(pins[type.name] ?? []) }
      for type in active {
        let already = (heldByType[type.name] ?? []).union(fetched[type.name]?.compactMap { $0["id"]?.stringValue } ?? [])
        missing[type.name]?.subtract(already)
        missing[type.name]?.subtract(changes[type.name]!.destroyed)
      }
      fetched = try await fetchMissing(missing, into: fetched, session: session)

      // Step 4: one level of references from everything fetched.
      var referenced: [String: Set<String>] = [:]
      for (type, objects) in fetched {
        guard let descriptor = descriptors[type] else { continue }
        for object in objects {
          for (refType, ids) in descriptor.referencedIds(in: object) where descriptors[refType] != nil {
            referenced[refType, default: []].formUnion(ids)
          }
        }
      }
      let referencedTypes = Array(referenced.keys)
      let heldReferenced = try await store.read { tx -> [String: Set<String>] in
        var held: [String: Set<String>] = [:]
        for type in referencedTypes { held[type] = try tx.ids(accountId: accountId, type: type) }
        return held
      }
      for (type, ids) in referenced {
        referenced[type] = ids.subtracting(heldReferenced[type] ?? []).subtracting(fetched[type]?.compactMap { $0["id"]?.stringValue } ?? [])
      }
      fetched = try await fetchMissing(referenced, into: fetched, session: session)

      // Step 5: commit, then retain and evict.
      let processId = configuration.processId
      let fetchedNow = fetched
      let changesNow = changes
      let resultsNow = newResults
      let queried = Dictionary(subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let activeNames = active.map(\.name)
      try await commit({ tx, changeSet in
        for type in activeNames {
          let descriptor = descriptors[type]!
          for object in fetchedNow[type] ?? [] {
            try Self.applyFetched(object, descriptor: descriptor, accountId: accountId, processId: processId, in: tx, changeSet: &changeSet)
          }
          for id in changesNow[type]!.destroyed {
            try Self.applyDestroyed(id, type: type, accountId: accountId, in: tx, changeSet: &changeSet)
          }
          try tx.setServerState(changesNow[type]!.newState, accountId: accountId, type: type)
        }
        for (type, objects) in fetchedNow where !activeNames.contains(type) {
          let descriptor = descriptors[type]!
          for object in objects {
            try Self.applyFetched(object, descriptor: descriptor, accountId: accountId, processId: processId, in: tx, changeSet: &changeSet)
          }
        }
        for (id, result) in resultsNow {
          // The app may have redefined the subscription while this pass
          // was querying its old definition; the stale answer must not
          // be committed over the new one, which the next pass will
          // run.  -- claude, 2026-11-02
          guard try tx.subscription(accountId: accountId, id: id) == queried[id] else { continue }
          let old = try tx.subscriptionResult(accountId: accountId, id: id)
          if old != result {
            try tx.setSubscriptionResult(result, accountId: accountId, id: id)
            changeSet.subscriptions.append(id)
          }
        }
        try Self.evict(windowed: types.filter { $0.mode == .windowed }, descriptors: descriptors, accountId: accountId, in: tx, changeSet: &changeSet)
      }, source: .syncIn)
      needsSyncIn.subtract(activeNames)
      subscriptionsDirty.subtract(activeNames)
      if !hasMore { break }
    }
    return needResync
  }

  private func fetchMissing(_ missing: [String: Set<String>], into fetched: [String: [JSONValue]], session: Session) async throws -> [String: [JSONValue]] {
    var fetched = fetched
    var builder = RequestBuilder(using: capabilities)
    var calls: [(type: String, call: RequestBuilder.Call)] = []
    for (type, ids) in missing where !ids.isEmpty {
      guard let descriptor = descriptors[type] else { continue }
      for part in Array(ids).sorted().chunked(fetchChunk) {
        calls.append((type, builder.call("\(type)/get", descriptor.getArguments(accountId: accountId, ids: part))))
      }
    }
    guard !builder.isEmpty else { return fetched }
    let response = try await send(builder.request, session: session)
    for (type, call) in calls {
      guard let invocation = response.response(to: call.callId), !invocation.isError else {
        throw SyncError.retryable("\(type)/get failed fetching missing objects")
      }
      fetched[type, default: []] += try GetResponse(json: invocation.arguments).list
    }
    return fetched
  }

  /// The whole of a `/query` answer the server cut short.  A server
  /// caps every query at a limit of its own, which it need not
  /// advertise, so an answer shorter than its total, and shorter than
  /// the subscription asked for, is a first page.  The pages after it
  /// are fetched from the next position with the same filter and sort,
  /// until the ids run out or reach the subscription's limit, and the
  /// whole list is one result with the first page's total and extras.
  /// A page answered under a different query state than the first
  /// cannot join it, so the answer starts over; a server that keeps
  /// moving gets a few tries, then the pass is retried later.
  func completeQuery(_ sub: QuerySubscription, from first: QueryResponse, session: Session) async throws -> SubscriptionResult {
    var first = first
    for _ in 0..<3 {
      var ids = first.ids
      var page = first
      while let total = first.total, !page.ids.isEmpty,
            first.position + ids.count < total, ids.count < sub.limit ?? .max
      {
        page = try await queryPage(sub, position: first.position + ids.count, limit: sub.limit.map { $0 - ids.count }, session: session)
        guard page.queryState == first.queryState else { break }
        ids += page.ids
      }
      if page.queryState == first.queryState {
        return SubscriptionResult(ids: ids, total: first.total, queryState: first.queryState, canCalculateChanges: first.canCalculateChanges, extra: first.extra)
      }
      first = try await queryPage(sub, position: sub.position, limit: sub.limit, session: session)
    }
    throw SyncError.retryable("\(sub.type)/query (\(sub.id)): the query state kept moving between pages")
  }

  private func queryPage(_ sub: QuerySubscription, position: Int, limit: Int?, session: Session) async throws -> QueryResponse {
    var builder = RequestBuilder(using: capabilities)
    let call = builder.call("\(sub.type)/query", sub.queryArguments(accountId: accountId, position: position, limit: limit))
    let response = try await send(builder.request, session: session)
    guard let invocation = response.response(to: call.callId), !invocation.isError else {
      let error = response.response(to: call.callId)?.methodError?.type ?? "no response"
      throw SyncError.retryable("\(sub.type)/query (\(sub.id)) at \(position): \(error)")
    }
    return try QueryResponse(json: invocation.arguments)
  }

  /// Removes objects of windowed types that nothing retains.  Retained:
  /// in a subscription window, pinned, carrying a pending change, or
  /// referenced by a retained object of another type (one level).
  static func evict(
    windowed: [TypeDescriptor],
    descriptors: [String: TypeDescriptor],
    accountId: String,
    in tx: Store.Transaction,
    changeSet: inout ChangeSet
  ) throws {
    guard !windowed.isEmpty else { return }
    let windowedNames = Set(windowed.map(\.name))
    var retained: [String: Set<String>] = [:]
    for sub in try tx.subscriptions(accountId: accountId) {
      if let result = try tx.subscriptionResult(accountId: accountId, id: sub.id) {
        retained[sub.type, default: []].formUnion(result.ids)
      }
    }
    for type in windowed {
      retained[type.name, default: []].formUnion(try tx.pins(accountId: accountId, type: type.name))
    }
    // References from retained objects of every type, one level.
    for (_, descriptor) in descriptors where !descriptor.references.isEmpty {
      let referrers: [StoredObject]
      if descriptor.mode == .full {
        referrers = try tx.objects(accountId: accountId, type: descriptor.name)
      } else {
        let base = retained[descriptor.name] ?? []
        referrers = try tx.objects(accountId: accountId, type: descriptor.name, ids: Array(base))
          + (try tx.objects(accountId: accountId, type: descriptor.name).filter { $0.pending != nil })
      }
      for referrer in referrers {
        for (refType, ids) in descriptor.referencedIds(in: referrer.local) where windowedNames.contains(refType) {
          retained[refType, default: []].formUnion(ids)
        }
      }
    }
    for type in windowed {
      let keep = retained[type.name] ?? []
      for object in try tx.objects(accountId: accountId, type: type.name) {
        guard object.pending == nil, let id = object.id, !keep.contains(id) else { continue }
        try tx.delete(key: object.key)
        changeSet.noteDestroyed(object.key, type: type.name)
      }
    }
  }

  /// Resync for a windowed type after `cannotCalculateChanges`: forget
  /// the state, drop held objects with no pending change, and clear
  /// subscription results so the next round re-queries.  Pins and
  /// pending objects survive.
  func resyncWindowed(_ descriptor: TypeDescriptor) async throws {
    let accountId = accountId
    let type = descriptor.name
    try await commit({ tx, changeSet in
      for object in try tx.objects(accountId: accountId, type: type) where object.pending == nil {
        try tx.delete(key: object.key)
        changeSet.noteDestroyed(object.key, type: type)
      }
      for sub in try tx.subscriptions(accountId: accountId) where sub.type == type {
        try tx.setSubscriptionResult(nil, accountId: accountId, id: sub.id)
      }
      try tx.setServerState(nil, accountId: accountId, type: type)
    }, source: .syncIn)
  }
}

extension Array {
  func chunked(_ size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: Swift.max(1, size)).map { Array(self[$0..<Swift.min($0 + size, count)]) }
  }
}

extension SyncEngine {
  /// Refreshes subscriptions on full-mirror types.  Every object is
  /// already held, so only the ordered id list and total come from the
  /// server, through `/query`.  Runs for subscriptions with no result
  /// and for types that moved or that this process changed.
  func refreshFullTypeSubscriptions(moved: Set<String>, session: Session) async throws {
    let accountId = accountId
    let fullTypes = Set(orderedTypes.filter { $0.mode == .full }.map(\.name))
    let dirty = moved.union(subscriptionsDirty).intersection(fullTypes)
    let (subscriptions, results) = try await store.read { tx -> ([QuerySubscription], [String: SubscriptionResult?]) in
      let subs = try tx.subscriptions(accountId: accountId).filter { fullTypes.contains($0.type) }
      var results: [String: SubscriptionResult?] = [:]
      for sub in subs { results[sub.id] = try tx.subscriptionResult(accountId: accountId, id: sub.id) }
      return (subs, results)
    }
    let due = subscriptions.filter { (results[$0.id] ?? nil) == nil || dirty.contains($0.type) }
    guard !due.isEmpty else { return }
    var builder = RequestBuilder(using: capabilities)
    var calls: [String: RequestBuilder.Call] = [:]
    for sub in due {
      calls[sub.id] = builder.call("\(sub.type)/query", sub.queryArguments(accountId: accountId))
    }
    let response = try await send(builder.request, session: session)
    var newResults: [String: SubscriptionResult] = [:]
    for sub in due {
      guard let invocation = response.response(to: calls[sub.id]!.callId), !invocation.isError else {
        throw SyncError.retryable("\(sub.type)/query (\(sub.id)) failed")
      }
      newResults[sub.id] = try await completeQuery(sub, from: QueryResponse(json: invocation.arguments), session: session)
    }
    let resultsNow = newResults
    let queried = Dictionary(due.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    try await commit({ tx, changeSet in
      // As in the windowed pass: a subscription redefined meanwhile
      // keeps the result it has until its new definition runs.
      for (id, result) in resultsNow where try tx.subscription(accountId: accountId, id: id) == queried[id]
        && (try tx.subscriptionResult(accountId: accountId, id: id)) != result {
        try tx.setSubscriptionResult(result, accountId: accountId, id: id)
        changeSet.subscriptions.append(id)
      }
    }, source: .syncIn)
    subscriptionsDirty.subtract(dirty)
  }
}

extension QuerySubscription {
  /// The `/query` arguments for this subscription: the app's extra
  /// arguments first, then the engine's, which win.  A later page of
  /// the same query gives its own position and limit.
  func queryArguments(accountId: String) -> JSONValue {
    queryArguments(accountId: accountId, position: position, limit: limit)
  }

  func queryArguments(accountId: String, position: Int, limit: Int?) -> JSONValue {
    var args = JSONValue.object(arguments)
    let engine = JSONValue.queryArguments(
      accountId: accountId, filter: filter, sort: sort, position: position, limit: limit, calculateTotal: true
    )
    for (key, value) in engine.objectValue ?? [:] { args[key] = value }
    return args
  }

  /// The `/queryChanges` arguments, carrying the same extras as `/query`.
  func queryChangesArguments(accountId: String, sinceQueryState: String, upToId: String?) -> JSONValue {
    var args = JSONValue.object(arguments)
    let engine = JSONValue.queryChangesArguments(
      accountId: accountId, filter: filter, sort: sort, sinceQueryState: sinceQueryState, upToId: upToId, calculateTotal: true
    )
    for (key, value) in engine.objectValue ?? [:] { args[key] = value }
    return args
  }
}
