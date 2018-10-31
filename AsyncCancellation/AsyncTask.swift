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
    func suspend() { }
    func resume() { }
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
    
    func append(_ item: TaskWithErrorHandler) {
        barrier.sync {
            taskList.append(item)
        }
    }
    
    func cancel() {
        var taskListCopy: [TaskWithErrorHandler]!
        barrier.sync {
            taskListCopy = taskList
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
