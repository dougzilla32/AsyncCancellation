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

/// A list of async tasks along with the associated error handler
public protocol AsyncTaskList: AsyncTask {
    var tasks: [(task: AsyncTask, error: (Error) -> ())] { get }
}

public enum AsyncError: Error {
    case cancelled
}

class AsyncTaskChain: AsyncTaskList {
    private let barrier = DispatchQueue(label: "AsyncTaskChain")
    private var taskList = [(task: AsyncTask, error: (Error) -> ())]()
    private var cancelInvoked = false
    
    var tasks: [(task: AsyncTask, error: (Error) -> ())] {
        var taskListCopy: [(task: AsyncTask, error: (Error) -> ())]!
        barrier.sync {
            taskListCopy = taskList
        }
        return taskListCopy
        
    }
    
    func append(_ item: (task: AsyncTask, error: (Error) -> ())) {
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
    
    func cancel() {
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
    
    var isCancelled: Bool {
        for t in tasks {
            if !t.task.isCancelled {
                return false
            }
        }
        return true
    }
}
