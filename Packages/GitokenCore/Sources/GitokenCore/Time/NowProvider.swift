import Foundation
import Synchronization

/// The single source of "now" for snoozes, quiet hours, relative timestamps, and arrival bookkeeping.
public protocol NowProvider: Sendable {
    func now() -> Date
}

public struct SystemNow: NowProvider {
    public init() {}
    public func now() -> Date { Date() }
}

/// Wall clock plus an adjustable offset. Debug builds expose `advance(by:)` in a hidden menu to demo snooze expiry;
/// tests start it at a fixed instant.
public final class OffsetNow: NowProvider {
    private let base: @Sendable () -> Date
    private let offset: Mutex<TimeInterval>

    public init(offset: TimeInterval = 0, base: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.offset = Mutex(offset)
    }

    /// Frozen clock for tests: always returns `instant` plus any advanced offset.
    public static func fixed(_ instant: Date) -> OffsetNow {
        OffsetNow(base: { instant })
    }

    public func now() -> Date { base().addingTimeInterval(offset.withLock { $0 }) }

    public func advance(by interval: TimeInterval) { offset.withLock { $0 += interval } }

    public func reset() { offset.withLock { $0 = 0 } }

    public var currentOffset: TimeInterval { offset.withLock { $0 } }
}
