//
//  Cancellable.swift
//  AsyncCancellation
//
//  Created by Doug on 10/29/18.
//

import Foundation

/// `Cancellable` tasks that conform to this protocol can be used with `CancelScope`
public protocol Cancellable {
    func cancel()

    var isCancelled: Bool { get }
}

/// Cancellation error
public enum AsyncError: Error {
    case cancelled
}

/// Shortcut to check for cancellation errors
extension Error {
    public var isCancelled: Bool {
        do {
            throw self
        } catch AsyncError.cancelled {
            return true
        } catch {
            return false
        }
    }
}

/**
 The `CancelScope` serves to:
 - Track a set of cancellables, providing the ability to cancel the set from any thread at any time
 - Provides subscopes for finer grained control over cancellation scope
 - Provide the current list of cancellables, allowing extensions of `CancelScope` to invoke other methods by casting
 - Optionally specify a timeout for its associated cancellables
 Note: A cancellable is considered resolved if either its `continuation` or its `error` closure has been invoked.
 */
public class CancelScope: Cancellable {
    private struct CancellableItem {
        let cancellable: Cancellable
        let error: (Error) -> ()
    }

    private let barrier = DispatchQueue(label: "CancelScope")
    private var cancellableItems = [CancellableItem]()
    private var cancelCalled = false

    // The failure closure stack is used to send cancellation errors to the correct 'suspendAsync'
    // scope (because 'suspendAsync' supports nested calls).
    private var failureClosureStack = Stack<(Error) -> ()>()

    // Timeout timer
    private var cancelTimer: DispatchWorkItem?
    
    /// Create a new `CancelScope` with optional timeout in seconds.
    /// All associated unresolved tasks will be cancelled after the
    /// given timeout. Default is no timeout.
    public init(timeout: TimeInterval = 0.0) {
        if timeout != 0.0 {
            let timer = DispatchWorkItem {
                self.cancel()
            }
            DispatchQueue.global(qos: .default).asyncAfter(
                deadline: DispatchTime.now() + timeout, execute: timer)
            self.cancelTimer = timer
        }
    }

    deinit {
        cancelTimer?.cancel()
    }

    /// Cancel all unresolved cancellables
    public func cancel() {
        var cancellableItemsCopy: [CancellableItem]!
        barrier.sync {
            cancellableItemsCopy = cancellableItems
            cancelCalled = true
        }
        cancellableItemsCopy.forEach {
            $0.error(AsyncError.cancelled)
            $0.cancellable.cancel()
        }
    }

    /// Returns true if all cancellables are either cancelled or resolved
    public var isCancelled: Bool {
        var cancellableItemsCopy: [CancellableItem]!
        barrier.sync {
            cancellableItemsCopy = cancellableItems
        }
        for c in cancellableItemsCopy where !c.cancellable.isCancelled {
            return false
        }
        return true
    }

    /// Add a cancellable to the cancel scope
    public func add(cancellable: Cancellable) {
        guard let scope = failureClosureStack.top else {
            fatalError(
                "'CancelScope.add' may only be called from inside a 'suspendAsync' closure")
        }

        let item = CancellableItem(cancellable: cancellable, error: scope)
        var cancelled = false
        barrier.sync {
            cancellableItems.append(item)
            cancelled = cancelCalled
        }
        if cancelled {
            item.error(AsyncError.cancelled)
            item.cancellable.cancel()
        }
    }

    func removeAll() {
        barrier.sync {
            cancellableItems.removeAll()
        }
    }

    /// The list of unresolved cancellables conforming to type 'T' for this cancel scope
    public func cancellables<T: Cancellable>() -> [T] {
        var cItems: [T] = []
        barrier.sync {
            for c in cancellableItems {
                if let t = c.cancellable as? T {
                    cItems.append(t)
                }
            }
        }
        return cItems
    }

    /// Create a subscope.  The subscope can be cancelled separately
    /// from the parent scope. If the parent scope times out or is
    /// cancelled, all of it's  subscopes will be cancelled as well.
    /// The 'timeout' parameter specifies a timeout in seconds for
    /// the cancellation subscope, to cover the case where a shorter
    /// timeout than the parent scope is desired.
    public func makeSubscope(timeout: TimeInterval = 0.0) -> CancelScope {
        var error: ((Error) -> ())!
        barrier.sync {
            guard let top = failureClosureStack.top else {
                if let _: CancelScope = getCoroutineContext() {
                    fatalError(
                        "'makeSubscope' may only be called from inside a 'suspendAsync' closure")
                }
                else {
                    fatalError(
                        "'makeSubscope' may only be called from inside a 'suspendAsync' closure, which in turn is inside a 'beginAsync' closure that provides a 'CancelScope' coroutine context"
                    )
                }
            }
            error = top
        }
        let scope = CancelScope()
        scope.pushFailureClosure(error: error)
        add(cancellable: scope)
        return scope
    }

    func pushFailureClosure(error: @escaping (Error) -> ()) {
        _ = barrier.sync {
            failureClosureStack.push(error)
        }
    }

    func popFailureClosure() {
        _ = barrier.sync {
            failureClosureStack.pop()
        }
    }
}
