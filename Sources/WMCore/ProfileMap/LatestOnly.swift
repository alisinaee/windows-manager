import Foundation

/// Keeps only the newest of several overlapping async loads (a slow older load must not overwrite a newer one).
/// Each `load` cancels the previous task and carries a generation; a result is applied only while its generation is
/// still the latest.
@MainActor
public final class LatestOnly<Value: Sendable> {
    public private(set) var generation = 0
    private var task: Task<Void, Never>?

    public init() {}

    /// Starts `work` (off the caller) and hands its value to `apply` only if no newer `load` began meanwhile.
    @discardableResult
    public func load(_ work: @escaping @Sendable () async -> Value, apply: @escaping @MainActor (Value) -> Void) -> Task<Void, Never> {
        generation += 1
        let mine = generation
        task?.cancel()
        let t = Task { [weak self] in
            let value = await work()
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            apply(value)
        }
        task = t
        return t
    }
}
