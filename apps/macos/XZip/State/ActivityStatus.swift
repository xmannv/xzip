import Foundation

/// Pure logic behind the inline activity bar shown in the main window while
/// operations run (the Queue window itself stays optional, ⌘0).
enum ActivityStatus {
    /// Operations still in flight (queued / running / paused), in list order.
    static func active(in operations: [ArchiveOperation]) -> [ArchiveOperation] {
        operations.filter {
            $0.state == .queued || $0.state == .running || $0.state == .paused
        }
    }

    /// Mean progress across the given operations; 0 when empty.
    static func overallProgress(of operations: [ArchiveOperation]) -> Double {
        guard !operations.isEmpty else { return 0 }
        return operations.reduce(0) { $0 + $1.progress } / Double(operations.count)
    }

    /// Progress of the whole visible batch: finished operations count as 1,
    /// in-flight ones contribute their fraction. Unlike a mean over active
    /// operations only, enqueueing another job only dents this by the new
    /// job's share instead of collapsing the ring.
    static func batchProgress(of operations: [ArchiveOperation]) -> Double {
        guard !operations.isEmpty else { return 0 }
        let total = operations.reduce(0.0) { sum, op in
            switch op.state {
            case .completed, .cancelled, .failed: return sum + 1
            default: return sum + op.progress
            }
        }
        return total / Double(operations.count)
    }
}
