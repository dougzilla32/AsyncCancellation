//
//  Cancellable.swift
//  AsyncCancellation
//
//  Created by Doug on 10/29/18.
//

import Foundation

/// Cancellable tasks that conform to this protocol can be added to a CancelContext
public protocol Cancellable {
    func cancel()

    var isCancelled: Bool { get }
}

/// CancelToken determines a cancellation scope
public protocol CancelToken {
    func add(cancellable: Cancellable)
    
    func cancellables<T: Cancellable>() -> [T]

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
 The CancelContext serves to:
 - Track a set of cancellables, providing the ability to cancel the set from any thread at any time
 - Provides cancel tokens (`CancelToken`) for finer grained control over cancellation scope
 - Provide the current list of cancellables, allowing extensions of `CancelContext` to invoke other methods by casting
 - Optionally specify a timeout for its associated cancellables
 Note: A cancellable is considered resolved if either its `continuation` or its `error` closure has been invoked.
 */
public class CancelContext: CancelToken {
    private static let tokenBarrier = DispatchQueue(label: "CancelContext.tokenCounter")
    private static var tokenCounter: UInt = 0
    
    static func nextTokenId() -> UInt {
        var tokenId: UInt!
        CancelContext.tokenBarrier.sync {
            tokenId = CancelContext.tokenCounter
            CancelContext.tokenCounter += 1
        }
        return tokenId
    }
    
    private struct CancellableItem {
        let cancellable: Cancellable
        let tokenId: UInt
        let error: (Error) -> ()
    }
    
    private struct CancelScope: CancelToken {
        let context: CancelContext
        let tokenId: UInt
        let error: (Error) -> ()
        
        public func add(cancellable: Cancellable) {
            context.append(item: CancellableItem(cancellable: cancellable, tokenId: tokenId, error: error))
        }
        
        public func cancellables<T: Cancellable>() -> [T] {
            return context.cancellables(tokenId: tokenId) as [T]
        }
        
        public func cancel() {
            context.cancel(tokenId: tokenId)
        }
        
        public var isCancelled: Bool {
            return context.isCancelled(tokenId: tokenId)
        }

        public func makeCancelToken() -> CancelToken {
            return context.makeCancelToken()
        }
    }
    
    private let barrier = DispatchQueue(label: "CancelContext")
    private var cancellableItems = [CancellableItem]()
    private var cancelledEverything = false
    private var cancelledTokenIds = Set<UInt>()
    
    // The cancel scope stack is used to send cancellation errors to the correct invocation
    // of 'suspendAsync' (because 'suspendAsync' supports nested calls).
    private var cancelScopeStack = Stack<CancelScope>()
    
    // Timeout timer
    private var cancelTimer: DispatchWorkItem?
    
    deinit {
        cancelTimer?.cancel()
    }
    
    /// Cancel all unresolved cancellables
    public func cancel() {
        var cancellableItemsCopy: [CancellableItem]!
        barrier.sync {
            cancellableItemsCopy = cancellableItems
            cancelledEverything = true
        }
        cancellableItemsCopy.forEach {
            $0.error(AsyncError.cancelled)
            $0.cancellable.cancel()
        }
    }
    
    private func cancel(tokenId: UInt) {
        var cancellableItemsCopy: [CancellableItem]!
        barrier.sync {
            cancellableItemsCopy = cancellableItems
            cancelledTokenIds.insert(tokenId)
        }
        for item in cancellableItemsCopy where item.tokenId == tokenId {
            item.error(AsyncError.cancelled)
            item.cancellable.cancel()
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
    
    private func isCancelled(tokenId: UInt) -> Bool {
        var cancellableItemsCopy: [CancellableItem]!
        barrier.sync {
            cancellableItemsCopy = cancellableItems
        }
        for c in cancellableItemsCopy where c.tokenId == tokenId && !c.cancellable.isCancelled {
            return false
        }
        return true
    }
    
    /// The list of unresolved cancellables conforming to type 'T' for this cancel context
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
    
    private func cancellables<T: Cancellable>(tokenId: UInt) -> [T] {
        var cItems: [T] = []
        barrier.sync {
            for c in cancellableItems where c.tokenId == tokenId {
                if let t = c.cancellable as? T {
                    cItems.append(t)
                }
            }
        }
        return cItems
    }
    
    /// Add a cancellable to the cancel context
    public func add(cancellable: Cancellable) {
        guard let scope = cancelScopeStack.top else {
            fatalError("'CancelContext.add' may only be called from inside a 'suspendAsync' closure")
        }
        append(item: CancellableItem(cancellable: cancellable, tokenId: scope.tokenId, error: scope.error))
    }
    
    private func append(item: CancellableItem) {
        var cancelled = false
        barrier.sync {
            cancellableItems.append(item)
            cancelled = cancelledEverything || cancelledTokenIds.contains(item.tokenId)
        }
        if cancelled {
            item.error(AsyncError.cancelled)
            item.cancellable.cancel()
        }
    }
    
    func removeAll(id: UInt) {
        barrier.sync {
            cancellableItems = cancellableItems.filter { item in
                item.tokenId != id
            }
        }
    }
    
    /// Create a token that can be used to associate a cancellable with this context, and can be used
    /// to cancel or set a timeout on only the token's cancellables (as a subset of the 'CancelContext' cancellables).
    public func makeCancelToken() -> CancelToken {
        var error: ((Error) -> ())!
        barrier.sync {
            error = cancelScopeStack.top?.error
            if error == nil {
                if let _: CancelContext = getCoroutineContext() {
                    fatalError("'makeCancelToken' may only be called from inside a 'suspendAsync' closure")
                } else {
                    fatalError("'makeCancelToken' may only be called from inside a 'suspendAsync' closure, which in turn is inside a 'beginAsync' closure that provides a 'CancelContext' coroutine context")
                }
            }
        }
        return CancelScope(context: self, tokenId: CancelContext.nextTokenId(), error: error)
    }
    
    func pushCancelScope(id: UInt, error: @escaping (Error) -> ()) {
        barrier.sync {
            cancelScopeStack.push(CancelScope(context: self, tokenId: id, error: error))
        }
    }
    
    func popCancelScope(id: UInt) {
        barrier.sync {
            assert(cancelScopeStack.top?.tokenId == id)
            cancelScopeStack.pop()
        }
    }
    
    /// All associated unresolved cancellables will be cancelled after the given timeout.  Default is no timeout.
    public var timeout: TimeInterval = 0.0 {
        didSet {
            if timeout != oldValue {
                resetTimer()
            }
        }
    }
    
    private func resetTimer() {
        cancelTimer?.cancel()
        let timer = DispatchWorkItem {
            self.cancel()
        }
        DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + timeout, execute: timer)
        cancelTimer = timer
    }
}
