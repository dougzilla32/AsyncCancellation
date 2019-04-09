//
//  CancellableURLSession.swift
//  AsyncCancellation
//
//  Created by Doug on 10/29/18.
//

import Foundation

/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: Cancellable {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

extension CancelToken {
    var urlSessionTasks: [URLSessionTask] { return cancellables() }
    
    func suspendTasks() { urlSessionTasks.forEach { $0.suspend() } }
    
    func resumeTasks() { urlSessionTasks.forEach { $0.resume() } }
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
            if let cancelToken: CancelToken = getCoroutineContext() {
                cancelToken.add(cancellable: task)
            }
            task.resume()
        }
    }
}
