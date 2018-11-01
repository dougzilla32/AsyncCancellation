//
//  AsyncTask.swift
//  AsyncTest
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import Foundation

/// Represents a generic asynchronous task
public protocol AsyncTask {
    func cancel()
    var isCancelled: Bool { get }
    func suspend()
    func resume()
}

/// 'suspend' and 'resume' are optional
extension AsyncTask {
    public func suspend() { }
    public func resume() { }
}

public enum AsyncError: Error {
    case cancelled
}

class AsyncTaskChain: AsyncTask {
    struct TaskWithErrorHandler {
        let task: AsyncTask
        let error: (Error) -> ()
    }
    
    private let barrier = DispatchQueue(label: "AsyncTaskChain")
    private var taskList = [TaskWithErrorHandler]()
    private var cancelInvoked = false
    
    func append(_ item: TaskWithErrorHandler) {
        var cc = false
        barrier.sync {
            taskList.append(item)
            cc = cancelInvoked
        }
        if cc {
            item.error(AsyncError.cancelled)
            item.task.cancel()
        }
    }
    
    func cancel() {
        var taskListCopy: [TaskWithErrorHandler]!
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
        var taskListCopy: [TaskWithErrorHandler]!
        barrier.sync {
            taskListCopy = taskList
        }
        for t in taskListCopy {
            if !t.task.isCancelled {
                return false
            }
        }
        return true
    }
    
    func resume() { taskList.forEach { $0.task.resume() } }
    func suspend() { taskList.forEach { $0.task.suspend() } }
}
