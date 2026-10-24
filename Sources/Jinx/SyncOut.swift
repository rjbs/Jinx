import Foundation
import JinxJSON
import JinxPatch
import JinxStore
import JinxWire

/// One claimed log entry with the object as it stood when claimed.
struct SyncOutItem: Sendable {
  var entry: PendingEntry
  var object: StoredObject
}

/// One `/set` call in flight: which items it carries and what was sent
/// for each, so the response can be reconciled.
struct SetBatch: Sendable {
  var type: String
  var callId: String
  var items: [SyncOutItem]
  var sent: [LocalKey: JSONValue]
}

extension SyncEngine {
  /// Sends every pending change, in log order, grouped by type in
  /// dependency order, until the log is empty or something needs a
  /// retry.
  func syncOut() async throws {
    let session = try await currentSession()
    for _ in 0..<20 {
      let items = try await claimItems()
      if items.isEmpty { break }
      let batches = try buildBatches(items, session: session)
      if batches.isEmpty { continue }
      let shouldContinue = try await sendAndApply(batches, session: session)
      if !shouldContinue { break }
    }
    status.lastSyncOut = Date()
  }

  private func claimItems() async throws -> [SyncOutItem] {
    let accountId = accountId
    let processId = configuration.processId
    let staleAfter = configuration.claimStaleAfter
    return try await store.write { tx in
      let entries = try tx.claimPending(accountId: accountId, processId: processId, now: Date(), staleAfter: staleAfter)
      var items: [SyncOutItem] = []
      for entry in entries {
        guard let object = try tx.object(key: entry.key) else {
          try tx.clearPending(key: entry.key)
          continue
        }
        items.append(SyncOutItem(entry: entry, object: object))
      }
      return items
    }
  }

  /// Turns claimed items into `/set` calls.  Updates whose diff is
  /// empty are dropped here, and destroys of never-sent objects are
  /// resolved locally.
  private func buildBatches(_ items: [SyncOutItem], session: Session) throws -> [SetBatch] {
    var byType: [String: [SyncOutItem]] = [:]
    for item in items { byType[item.object.type, default: []].append(item) }
    let maxInSet = session.core?.maxObjectsInSet ?? 128
    var batches: [SetBatch] = []
    for descriptor in orderedTypes {
      guard let typeItems = byType[descriptor.name] else { continue }
      let chunkSize = max(1, min(maxInSet, setChunk[descriptor.name] ?? maxInSet))
      var start = 0
      while start < typeItems.count {
        let chunk = Array(typeItems[start..<min(start + chunkSize, typeItems.count)])
        start += chunkSize
        batches.append(SetBatch(type: descriptor.name, callId: "", items: chunk, sent: [:]))
      }
    }
    return batches
  }

  /// Sends one request carrying every batch, then applies the response.
  /// Returns whether to go around again.
  private func sendAndApply(_ batches: [SetBatch], session: Session) async throws -> Bool {
    var builder = RequestBuilder(using: capabilities)
    var batches = batches
    let accountId = accountId
    var dropped: [LocalKey] = []
    var localDestroys: [LocalKey] = []

    for index in batches.indices {
      let descriptor = try self.descriptor(batches[index].type)
      var create: [String: JSONValue] = [:]
      var update: [String: JSONValue] = [:]
      var destroy: [String] = []
      for item in batches[index].items {
        switch item.entry.operation {
        case .create:
          var value = item.object.local
          value["id"] = nil
          create[item.object.key.creationId] = value
          batches[index].sent[item.object.key] = value
        case .update:
          guard let id = item.object.id else {
            dropped.append(item.object.key)
            continue
          }
          let serverVersion = item.object.serverVersion ?? .object([:])
          let patch = try PatchObject.diff(from: serverVersion, to: item.object.local, mayPatch: descriptor.mayPatch)
          if patch.isEmpty {
            dropped.append(item.object.key)
            continue
          }
          update[id] = .object(patch.entries)
          batches[index].sent[item.object.key] = item.object.local
        case .destroy:
          guard let id = item.object.id else {
            localDestroys.append(item.object.key)
            continue
          }
          destroy.append(id)
        }
      }
      batches[index].items.removeAll { dropped.contains($0.object.key) || localDestroys.contains($0.object.key) }
      guard !batches[index].items.isEmpty else { continue }
      let call = builder.call(
        "\(descriptor.name)/set",
        .setArguments(accountId: accountId, create: create, update: update, destroy: destroy)
      )
      batches[index].callId = call.callId
    }

    if !dropped.isEmpty || !localDestroys.isEmpty {
      let droppedNow = dropped
      let localDestroysNow = localDestroys
      try await store.write { tx in
        for key in droppedNow { try tx.clearPending(key: key) }
        for key in localDestroysNow { try tx.delete(key: key) }
      }
    }
    batches.removeAll { $0.callId.isEmpty }
    guard !batches.isEmpty else { return true }

    let response: Response
    do {
      response = try await transport.send(builder.request, to: session.apiUrl)
    } catch {
      try await releaseClaims()
      if batches.contains(where: { $0.items.contains { $0.entry.operation == .create } }) {
        // The server may have applied the creates before the response
        // was lost.  The next pass syncs in first so that objects with a
        // client identity get adopted rather than created twice.
        reconcileBeforeSyncOut = true
      }
      switch Classification.classify(error) {
      case .retryable, .tooLarge:
        status.lastFailure = String(describing: error)
        throw SyncError.retryable(String(describing: error))
      case .permanent:
        status.lastFailure = String(describing: error)
        throw SyncError.permanent(String(describing: error))
      }
    }

    let outcome = try await applySetResponses(batches, response: response)
    for (key, value) in outcome.adoptByIdentity {
      try await adoptByIdentity(key: key, type: value.type, identity: value.identity, value: value.value)
    }
    if outcome.retryable {
      throw SyncError.retryable(status.lastFailure ?? "retryable sync-out failure")
    }
    return true
  }

  private func releaseClaims() async throws {
    let processId = configuration.processId
    try await store.write { tx in try tx.releaseClaims(processId: processId) }
  }

  struct AdoptRequest: Sendable {
    var type: String
    var identity: TypeDescriptor.ClientIdentity
    var value: JSONValue
  }

  struct ApplyOutcome: Sendable {
    var retryable = false
    var adoptByIdentity: [LocalKey: AdoptRequest] = [:]
    var needsSyncIn: Set<String> = []
    var setChunk: [String: Int] = [:]
    var dirtyTypes: Set<String> = []
    var failure: String?
  }

  private func applySetResponses(_ batches: [SetBatch], response: Response) async throws -> ApplyOutcome {
    let accountId = accountId
    let descriptors = descriptors

    let outcome: ApplyOutcome = try await commit({ tx, changeSet in
      var outcome = ApplyOutcome()
      for batch in batches {
        let descriptor = descriptors[batch.type]!
        guard let invocation = response.response(to: batch.callId) else {
          try Self.release(batch, in: tx)
          outcome.retryable = true
          outcome.failure = "no response to \(batch.type)/set"
          continue
        }
        if let error = invocation.methodError {
          switch Classification.classify(error) {
          case .retryable:
            try Self.release(batch, in: tx)
            outcome.retryable = true
            outcome.failure = "\(batch.type)/set: \(error.type)"
          case .tooLarge:
            try Self.release(batch, in: tx)
            outcome.setChunk[batch.type] = max(1, batch.items.count / 2)
            outcome.retryable = true
            outcome.failure = "\(batch.type)/set: requestTooLarge"
          case .permanent:
            let setError = SetError(type: error.type, description: error.description)
            for item in batch.items {
              try Self.revert(item, error: setError, in: tx, changeSet: &changeSet)
            }
          }
          continue
        }

        let set = try SetResponse(json: invocation.arguments)
        if !set.created.isEmpty || !set.updated.isEmpty || !set.destroyed.isEmpty {
          outcome.dirtyTypes.insert(batch.type)
        }
        for item in batch.items {
          let key = item.object.key
          switch item.entry.operation {
          case .create:
            if let props = set.created[key.creationId], let id = props["id"]?.stringValue {
              try Self.confirmCreate(item, id: id, serverSet: props, sent: batch.sent[key], in: tx, changeSet: &changeSet)
            } else if let error = set.notCreated[key.creationId] {
              if error.type == SetError.alreadyExists, let existingId = error.existingId {
                try Self.confirmCreate(item, id: existingId, serverSet: [:], sent: batch.sent[key], in: tx, changeSet: &changeSet)
                outcome.needsSyncIn.insert(batch.type)
              } else if let identity = descriptor.clientIdentity,
                        error.type == SetError.invalidProperties,
                        error.properties?.contains(identity.property) == true,
                        let value = item.object.local[identity.property]
              {
                outcome.adoptByIdentity[key] = AdoptRequest(type: batch.type, identity: identity, value: value)
              } else if Classification.classify(error) == .retryable {
                try Self.releaseItem(item, in: tx)
                outcome.retryable = true
                outcome.failure = "\(batch.type) create: \(error.type)"
              } else {
                try Self.revert(item, error: error, in: tx, changeSet: &changeSet)
              }
            } else {
              try Self.releaseItem(item, in: tx)
              outcome.retryable = true
              outcome.failure = "\(batch.type) create: no outcome"
            }

          case .update:
            guard let id = item.object.id else { continue }
            if let serverSet = set.updated[id] {
              try Self.confirmUpdate(item, serverSet: serverSet, sent: batch.sent[key], in: tx, changeSet: &changeSet)
            } else if let error = set.notUpdated[id] {
              if Classification.classify(error) == .retryable {
                try Self.releaseItem(item, in: tx)
                outcome.retryable = true
                outcome.failure = "\(batch.type) update: \(error.type)"
              } else {
                try Self.revert(item, error: error, in: tx, changeSet: &changeSet)
                if error.type == SetError.notFound { outcome.needsSyncIn.insert(batch.type) }
              }
            } else {
              try Self.releaseItem(item, in: tx)
              outcome.retryable = true
              outcome.failure = "\(batch.type) update: no outcome"
            }

          case .destroy:
            guard let id = item.object.id else { continue }
            if set.destroyed.contains(id) || set.notDestroyed[id]?.type == SetError.notFound {
              try tx.delete(key: key)
              changeSet.noteDestroyed(key, type: batch.type)
            } else if let error = set.notDestroyed[id] {
              if Classification.classify(error) == .retryable {
                try Self.releaseItem(item, in: tx)
                outcome.retryable = true
                outcome.failure = "\(batch.type) destroy: \(error.type)"
              } else {
                try Self.revert(item, error: error, in: tx, changeSet: &changeSet)
              }
            } else {
              try Self.releaseItem(item, in: tx)
              outcome.retryable = true
              outcome.failure = "\(batch.type) destroy: no outcome"
            }
          }
        }

        // Creates the server confirmed for objects destroyed locally
        // while the request was in flight: the server has them, we do
        // not want them, so queue destroys. -- claude, 2026-10-17
        for (creationId, props) in set.created {
          guard let key = LocalKey(creationId: creationId),
                let id = props["id"]?.stringValue,
                try tx.object(key: key) == nil,
                try tx.object(accountId: accountId, type: batch.type, id: id) == nil
          else { continue }
          let orphan = try tx.insert(NewObject(accountId: accountId, type: batch.type, id: id, serverVersion: props, local: props))
          try tx.setPending(key: orphan.key, operation: .destroy)
        }

        let stored = try tx.serverState(accountId: accountId, type: batch.type)
        if let stored {
          if stored == set.oldState {
            try tx.setServerState(set.newState, accountId: accountId, type: batch.type)
          } else {
            outcome.needsSyncIn.insert(batch.type)
          }
        }
      }
      return outcome
    }, source: .syncOut)

    needsSyncIn.formUnion(outcome.needsSyncIn)
    subscriptionsDirty.formUnion(outcome.dirtyTypes)
    for (type, chunk) in outcome.setChunk { setChunk[type] = chunk }
    if let failure = outcome.failure { status.lastFailure = failure }
    return outcome
  }

  // MARK: Reconciliation helpers, all inside the apply transaction

  private static func release(_ batch: SetBatch, in tx: Store.Transaction) throws {
    for item in batch.items { try releaseItem(item, in: tx) }
  }

  private static func releaseItem(_ item: SyncOutItem, in tx: Store.Transaction) throws {
    // Only this item's claim; a re-added entry (edited in flight) has a
    // new seq and no claim already.
    if let entry = try tx.pending(key: item.object.key), entry.seq == item.entry.seq {
      try tx.setPending(key: item.object.key, operation: entry.operation)
    }
  }

  /// Whether the object was edited while its entry was in flight.
  private static func editedInFlight(_ item: SyncOutItem, in tx: Store.Transaction) throws -> Bool {
    guard let entry = try tx.pending(key: item.object.key) else { return false }
    return entry.seq != item.entry.seq
  }

  private static func confirmCreate(
    _ item: SyncOutItem,
    id: String,
    serverSet: JSONValue,
    sent: JSONValue?,
    in tx: Store.Transaction,
    changeSet: inout ChangeSet
  ) throws {
    guard var object = try tx.object(key: item.object.key) else { return }
    object.id = id
    var serverVersion = sent ?? item.object.local
    serverVersion["id"] = .string(id)
    if case .object(let props) = serverSet {
      for (property, value) in props { serverVersion[property] = value }
    }
    object.serverVersion = serverVersion
    let edited = try editedInFlight(item, in: tx)
    if edited {
      object.local["id"] = .string(id)
      if case .object(let props) = serverSet {
        for (property, value) in props where property != "id" { object.local[property] = value }
      }
    } else {
      object.local = serverVersion
      try tx.clearPending(key: object.key)
    }
    object.lastError = nil
    try tx.update(object)
    changeSet.noteIdAssigned(id, to: object.key, type: object.type)
    changeSet.noteUpdated(object.key, type: object.type)
  }

  private static func confirmUpdate(
    _ item: SyncOutItem,
    serverSet: JSONValue,
    sent: JSONValue?,
    in tx: Store.Transaction,
    changeSet: inout ChangeSet
  ) throws {
    guard var object = try tx.object(key: item.object.key) else { return }
    var serverVersion = sent ?? item.object.local
    if case .object(let props) = serverSet {
      for (property, value) in props { serverVersion[property] = value }
    }
    object.serverVersion = serverVersion
    if try editedInFlight(item, in: tx) {
      if case .object(let props) = serverSet {
        for (property, value) in props { object.local[property] = value }
      }
    } else {
      object.local = serverVersion
      try tx.clearPending(key: object.key)
    }
    object.lastError = nil
    try tx.update(object)
    changeSet.noteUpdated(object.key, type: object.type)
  }

  /// A permanent failure: revert this object alone to its server version,
  /// unless it was edited in flight, and record the error.
  private static func revert(_ item: SyncOutItem, error: SetError, in tx: Store.Transaction, changeSet: inout ChangeSet) throws {
    guard var object = try tx.object(key: item.object.key) else { return }
    object.lastError = error
    if try editedInFlight(item, in: tx) {
      try tx.update(object)
    } else {
      if let serverVersion = object.serverVersion { object.local = serverVersion }
      try tx.update(object)
      try tx.clearPending(key: object.key)
    }
    changeSet.failed[object.key] = error
    changeSet.noteUpdated(object.key, type: object.type)
  }

  /// After a create was refused as a duplicate of the identity
  /// property, finds the server's object and adopts its id.
  private func adoptByIdentity(key: LocalKey, type: String, identity: TypeDescriptor.ClientIdentity, value: JSONValue) async throws {
    let session = try await currentSession()
    var builder = RequestBuilder(using: capabilities)
    let query = builder.call("\(type)/query", .queryArguments(accountId: accountId, filter: [identity.filterProperty: value], limit: 1))
    let response: Response
    do {
      response = try await transport.send(builder.request, to: session.apiUrl)
    } catch {
      try await releaseClaims()
      throw SyncError.retryable("identity query: \(error)")
    }
    guard let invocation = response.response(to: query.callId), !invocation.isError,
          let id = try QueryResponse(json: invocation.arguments).ids.first
    else {
      try await commit({ tx, changeSet in
        guard var object = try tx.object(key: key) else { return }
        object.lastError = SetError(type: SetError.invalidProperties, description: "duplicate \(identity.property) with no matching object", properties: [identity.property])
        try tx.update(object)
        try tx.clearPending(key: key)
        changeSet.failed[key] = object.lastError!
      }, source: .syncOut)
      return
    }
    try await commit({ tx, changeSet in
      guard var object = try tx.object(key: key) else { return }
      object.id = id
      object.local["id"] = .string(id)
      object.serverVersion = object.local
      try tx.update(object)
      try tx.setPending(key: key, operation: .update)
      changeSet.noteIdAssigned(id, to: key, type: type)
      changeSet.noteUpdated(key, type: type)
    }, source: .syncOut)
    needsSyncIn.insert(type)
  }
}
