//
//  AsyncTask.swift
//  AsyncTest
//
//  Created by Doug on 10/29/18.
//

import Foundation

/// Represents a generic asynchronous task
public protocol AsyncTask {
    func cancel()

    var isCancelled: Bool { get }
}

/// The CancelToken is used to register an AsyncTask within a cancellation scope
public protocol CancelToken {
    func add(task: AsyncTask)
    
    func cancel()
    
    var isCancelled: Bool { get }
}

/// Cancellation error
public enum AsyncError: Error {
    case cancelled
}

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
 - Cancel tasks
 - Provide a CancelToken for registering cancellable tasks
 - Provide the current list of cancellable tasks, allowing extensions of CancelContext to define new operations on tasks
 - Optionally specify a timeout for its associated tasks
 Note: A task is considered resolved if either its `continuation` or its `error` closure has been invoked.
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
    
    public struct Cancellable {
        let task: AsyncTask
        let tokenId: UInt
        let error: (Error) -> ()
    }

    private struct CancelScope: CancelToken {
        let context: CancelContext
        let tokenId: UInt
        let error: (Error) -> ()
        
        public func add(task: AsyncTask) {
            context.append(item: CancelContext.Cancellable(task: task, tokenId: tokenId, error: error))
        }
        
        public func cancel() {
            context.cancel(tokenId: tokenId)
        }
        
        public var isCancelled: Bool {
            return context.isCancelled(tokenId: tokenId)
        }
    }
    
    private let barrier = DispatchQueue(label: "CancelContext")
    private var taskList = [CancelContext.Cancellable]()
    private var cancelledEverything = false
    private var cancelledTokenIds = Set<UInt>()
    private var cancelScopeStack = Stack<CancelScope>()
    private var cancelTimer: DispatchWorkItem?
    
    deinit {
        cancelTimer?.cancel()
    }
    
    /// Cancel all unresolved tasks
    public func cancel() {
        var taskListCopy: [CancelContext.Cancellable]!
        barrier.sync {
            taskListCopy = taskList
            cancelledEverything = true
        }
        taskListCopy.forEach {
            $0.error(AsyncError.cancelled)
            $0.task.cancel()
        }
    }
    
    fileprivate func cancel(tokenId: UInt) {
        var taskListCopy: [CancelContext.Cancellable]!
        barrier.sync {
            taskListCopy = taskList
            cancelledTokenIds.insert(tokenId)
        }
        for item in taskListCopy where item.tokenId == tokenId {
            item.error(AsyncError.cancelled)
            item.task.cancel()
        }
    }
    
    /// Returns true if all tasks are resolved OR if all unresolved tasks have been successfully cancelled, false otherwise
    public var isCancelled: Bool {
        for t in tasks where !t.task.isCancelled {
            return false
        }
        return true
    }
    
    fileprivate func isCancelled(tokenId: UInt) -> Bool {
        for t in tasks where t.tokenId == tokenId && !t.task.isCancelled {
            return false
        }
        return true
    }
    
    /// The list of unresolved associated tasks
    public var tasks: [CancelContext.Cancellable] {
        var taskListCopy: [CancelContext.Cancellable]!
        barrier.sync {
            taskListCopy = taskList
        }
        return taskListCopy
        
    }
    
    public func add(task: AsyncTask) {
        guard let scope = cancelScopeStack.top else {
            fatalError("'CancelContext.add' may only be called from inside a 'suspendAsync' closure")
        }
        append(item: CancelContext.Cancellable(task: task, tokenId: scope.tokenId, error: scope.error))
    }
    
    fileprivate func append(item: CancelContext.Cancellable) {
        var cancelled = false
        barrier.sync {
            taskList.append(item)
            cancelled = cancelledEverything || cancelledTokenIds.contains(item.tokenId)
        }
        if cancelled {
            item.error(AsyncError.cancelled)
            item.task.cancel()
        }
    }
    
    func removeAll(id: UInt) {
        barrier.sync {
            taskList = taskList.filter { item in
                item.tokenId != id
            }
        }
    }
    
    /// A token that can be used to associate a task with this context
    public func makeCancelToken() -> CancelToken {
        var error: ((Error) -> ())!
        barrier.sync {
            error = cancelScopeStack.top?.error
            if error == nil {
                if let _: CancelContext = getCoroutineContext() {
                    fatalError("'makeCancelToken' may only be called from inside a 'suspendAsync' closure")
                } else {
                    fatalError("'makeCancelToken' may only be called from inside a 'suspendAsync' closure, which in turn is inside a 'beginAsync' closure that includes a 'CancelContext' in its coroutine context")
                }
            }
        }
        return CancelContext.CancelScope(context: self, tokenId: CancelContext.nextTokenId(), error: error)
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
    
    /// All associated unresolved tasks will be cancelled after the given timeout.  Default is no timeout.
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
