//
//  AsyncURLSession.swift
//  AsyncCancellation
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import Foundation

/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: AsyncTask {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

extension URLSession {
    func asyncDataTask(with request: URLRequest) /* async */ throws -> (URLRequest, URLResponse, Data) {
        return /* await */ try suspendAsync { continuation, error, task in
            let dataTask = self.dataTask(with: request) { data, response, err in
                if let err = err {
                    error(err)
                } else if let response = response, let data = data {
                    continuation((request, response, data))
                }
            }
            task(dataTask)
            dataTask.resume()
        }
    }
}
