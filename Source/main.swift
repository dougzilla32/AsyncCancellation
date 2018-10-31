//
//  main.swift
//  AsyncCancellation
//
//  Created by Doug on 10/31/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import Foundation

let chain = beginAsyncTask {
    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
    do {
        let result = try /* await */ session.asyncDataTask(with: request)
        if let resultString = String(data: result.2, encoding: .utf8) {
            print("Apple search result: \(resultString)")
        } else {
            print("Apple search result: \(result)")
        }
    } catch {
        print("Apple search error: \(error)")
    }
}

// Uncomment to see cancellation behavior
// chain.cancel()

RunLoop.current.run(until: Date() + 5.0)

