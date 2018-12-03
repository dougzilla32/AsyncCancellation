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

/// The async token is used to register cancellable tasks
public protocol CancelToken {
    func append(task: AsyncTask, error: @escaping (Error) -> ())
}

public enum AsyncError: Error {
    case cancelled
    case missingBeginAsync
}

public class CancelContext: CancelToken {
    private let barrier = DispatchQueue(label: "AsyncTaskChain")
    private var taskList = [(task: AsyncTask, error: (Error) -> ())]()
    private var cancelInvoked = false
    
    public var tasks: [(task: AsyncTask, error: (Error) -> ())] {
        var taskListCopy: [(task: AsyncTask, error: (Error) -> ())]!
        barrier.sync {
            taskListCopy = taskList
        }
        return taskListCopy
        
    }
    
    public func append(task: AsyncTask, error: @escaping (Error) -> ()) {
        var cancelled = false
        barrier.sync {
            taskList.append((task: task, error: error))
            cancelled = cancelInvoked
        }
        if cancelled {
            error(AsyncError.cancelled)
            task.cancel()
        }
    }
    
    public func cancel() {
        var taskListCopy: [(task: AsyncTask, error: (Error) -> ())]!
        barrier.sync {
            taskListCopy = taskList
            cancelInvoked = true
        }
        taskListCopy.forEach {
            $0.error(AsyncError.cancelled)
            $0.task.cancel()
        }
    }
    
    public var isCancelled: Bool {
        for t in tasks {
            if !t.task.isCancelled {
                return false
            }
        }
        return true
    }

    public var cancelToken: CancelToken {
        return self
    }
}
