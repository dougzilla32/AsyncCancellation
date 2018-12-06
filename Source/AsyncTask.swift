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

/// The CancelToken is used to register an AsyncTask with its associated CancelContext
public struct CancelToken {
    weak var context: CancelContext?
    let tokenId: UInt
    let error: (Error) -> ()

    public func add(task: AsyncTask) {
        context?.append(item: CancelContext.Cancellable(task: task, tokenId: tokenId, error: error))
    }
}

/// Cancellation error
public enum AsyncError: Error {
    case cancelled
}

/**
 The CancelContext serves to:
 - Cancel tasks
 - Provide a CancelToken for registering cancellable tasks
 - Provide the current list of cancellable tasks, allowing extensions of CancelContext to define new operations on tasks
 - Optionally specify a timeout for its associated tasks
 Note: A task is considered resolved if either its `continuation` or its `error` closure has been invoked.
 */
public class CancelContext {
    public struct Cancellable {
        let task: AsyncTask
        let tokenId: UInt
        let error: (Error) -> ()
    }

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
    
    private let barrier = DispatchQueue(label: "CancelContext")
    private var taskList = [CancelContext.Cancellable]()
    private var cancelInvoked = false
    private var currentToken: CancelToken?
    private var cancelTimer: DispatchWorkItem?
    
    deinit {
        cancelTimer?.cancel()
    }
    
    /// Cancel all unresolved tasks
    public func cancel() {
        var taskListCopy: [CancelContext.Cancellable]!
        barrier.sync {
            taskListCopy = taskList
            cancelInvoked = true
        }
        taskListCopy.forEach {
            $0.error(AsyncError.cancelled)
            $0.task.cancel()
        }
    }
    
    /// Returns true if all tasks are resolved OR if all unresolved tasks have been successfully cancelled, false otherwise
    public var isCancelled: Bool {
        for t in tasks where !t.task.isCancelled {
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
    
    fileprivate func append(item: CancelContext.Cancellable) {
        var cancelled = false
        barrier.sync {
            taskList.append(item)
            cancelled = cancelInvoked
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
    public var cancelToken: CancelToken {
        var cancelToken: CancelToken!
        barrier.sync {
            cancelToken = currentToken
        }
        return cancelToken!
    }
    
    func makeToken(id: UInt, error: @escaping (Error) -> ()) {
        barrier.sync {
            currentToken = CancelToken(context: self, tokenId: id, error: error)
        }
    }
    
    func clearToken(id: UInt) {
        barrier.sync {
            assert(currentToken?.tokenId == id)
            currentToken = nil
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
