//
//  AsyncURLSession.swift
//  AsyncCancellation
//
//  Created by Doug on 10/29/18.
//

import Foundation

/// Add 'suspend' and 'resume' capabilities to CancelContext
extension CancelContext {
    func suspend() { tasks.forEach { ($0.task as? URLSessionTask)?.suspend() } }
    func resume() { tasks.forEach { ($0.task as? URLSessionTask)?.resume() } }
}

/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: AsyncTask {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

/// Add async version of dataTask(with:) which uses suspendAsync to handle the callback
extension URLSession {
    func asyncDataTask(with request: URLRequest) /* async */ throws -> (request: URLRequest, response: URLResponse, data: Data) {
        return /* await */ try suspendAsync { continuation, error in
            let task = self.dataTask(with: request) { data, response, err in
                if let err = err {
                    error(err)
                } else if let response = response, let data = data {
                    continuation((request, response, data))
                }
            }
            (getCoroutineContext() as CancelContext?)?.cancelToken.add(task: task)
            task.resume()
        }
    }
}
