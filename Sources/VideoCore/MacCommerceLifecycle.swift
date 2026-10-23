import Foundation

/// A refresh requested during an asynchronous read invalidates that read's snapshot.
/// Every caller waits for the final read; no caller is told stale state is current.
@MainActor public final class CommerceRefreshCycle<Value> {
    private let read: @MainActor () async -> Value
    private let apply: @MainActor (Value) -> Void
    private let stateChanged: @MainActor (Bool) -> Void
    private var running = false
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init(read: @escaping @MainActor () async -> Value, apply: @escaping @MainActor (Value) -> Void, stateChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.read = read; self.apply = apply; self.stateChanged = stateChanged
    }
    public func refresh() async {
        if running {
            requested = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        running = true
        stateChanged(true)
        repeat {
            requested = false
            let value = await read()
            // An update arrived while the source yielded. Re-read before exposing any state.
            if !requested { apply(value) }
        } while requested
        running = false
        stateChanged(false)
        let completed = waiters; waiters = []
        for waiter in completed { waiter.resume() }
    }
}

/// Controls acknowledgment only. Identity comes from the adapter's verified receipt;
/// neither this coordinator nor an injected source can create an application entitlement.
@MainActor public final class CommerceDeliveryCoordinator<Receipt: Sendable, Identity: Hashable & Sendable> {
    private let identity: @MainActor (Receipt) -> Identity?
    private let deliver: @MainActor (Receipt) async -> Bool
    private let finish: @MainActor (Receipt) async -> Void
    private var inFlight: [Identity: Task<Bool, Never>] = [:]
    private var completed: Set<Identity> = []
    private var completionOrder: [Identity] = []
    private var listener: Task<Void, Never>?
    public init(identity: @escaping @MainActor (Receipt) -> Identity?, deliver: @escaping @MainActor (Receipt) async -> Bool, finish: @escaping @MainActor (Receipt) async -> Void) {
        self.identity = identity; self.deliver = deliver; self.finish = finish
    }
    deinit { listener?.cancel() }
    /// The application owns this listener; a purchase view has no lifetime role here.
    @discardableResult public func start<Events: AsyncSequence>(_ events: Events) -> Task<Void, Never> where Events.Element == Receipt {
        if let listener { return listener }
        let task = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self else { break }
                    _ = await self.process(event)
                }
            } catch { /* No acknowledgment is fabricated if the source fails. */ }
            self?.listener = nil
        }
        listener = task
        return task
    }
    @discardableResult public func process(_ receipt: Receipt) async -> Bool {
        guard let id = identity(receipt) else { return false }
        if completed.contains(id) { return await deliver(receipt) }
        if let existing = inFlight[id] { return await existing.value }
        let task = Task { @MainActor [deliver, finish] in
            guard await deliver(receipt) else { return false }
            await finish(receipt)
            return true
        }
        inFlight[id] = task
        let delivered = await task.value
        inFlight.removeValue(forKey: id)
        if delivered {
            completed.insert(id); completionOrder.append(id)
            if completionOrder.count > 1024 { completed.remove(completionOrder.removeFirst()) }
        }
        return delivered
    }
}
