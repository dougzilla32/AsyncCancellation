//
//  main.swift
//  AsyncCancellation
//
//  Created by Doug on 10/31/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import Foundation

public enum WebResourceError: Error {
    case invalidResult
}


//
// URLSession example
//

func performAppleSearch() /* async */ throws -> String {
    let urlSession = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
    let result = try /* await */ urlSession.asyncDataTask(with: request)
    if let resultString = String(data: result.2, encoding: .utf8) {
        return resultString
    }
    throw WebResourceError.invalidResult
}

// Execute the URLSession example
do {
    let chain = try beginAsyncTask {
        let result = try performAppleSearch()
        print("Apple search result: \(result)")
    }
    
    // Uncomment to see cancellation behavior
    // chain.cancel()
} catch {
    print("Apple search error: \(error)")
}


//
// Image loading example from 'Async/Await for Swift' by Chris Lattner and Joe Groff
// https://gist.github.com/dougzilla32/ce47a72067f9344742e10020ad4c8c41
//

/// For the purpose of this example, send a simple web request rather than loading actual image data
func loadWebResource(_ name: String) throws -> String {
    let urlSession = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
    let result = try /* await */ urlSession.asyncDataTask(with: request)
    if let resultString = String(data: result.2, encoding: .utf8) {
        return resultString
    }
    throw WebResourceError.invalidResult
}

/// For the purpose of this example, concat two strings in another thread rather than decoding image data
func decodeImage(_ profile: String, _ data: String) throws -> String {
    return try /* await */ suspendAsync { continuation, error, task in
        let taskItem = DispatchWorkItem {
            continuation("\(profile)+\(data)")
        }
        task(taskItem)
        DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + 0.5, execute: taskItem)
    }
}

/// For the purpose of this example, trim a string in another thread rather than processing image data
func dewarpAndCleanupImage(_ image: String) throws -> String {
    return try /* await */ suspendAsync { continuation, error, task in
        let taskItem = DispatchWorkItem {
            continuation(image.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        }
        task(taskItem)
        DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + 0.5, execute: taskItem)
    }
}

/// Image loading example
func processImageData1a() /* async */ throws -> String {
    let dataResource  = Future { /* await */ try loadWebResource("dataprofile.txt") }
    let imageResource = Future { /* await */ try loadWebResource("imagedata.dat") }
    
    // ... other stuff can go here to cover load latency...
    
    let imageTmp    = /* await */ try decodeImage(try dataResource.get(), try imageResource.get())
    let imageResult = /* await */ try dewarpAndCleanupImage(imageTmp)
    return imageResult
}

/// Execute the image loading example
do {
    let chain = try beginAsyncTask {
        let result = try processImageData1a()
        print("image result: \(result)")
    }

    // Uncomment to see cancellation behavior
    // chain.cancel()
} catch {
    print("image error: \(error)")
}

// Wait long enough for everything to complete
RunLoop.current.run(until: Date() + 5.0)
