//
//  Examples.swift
//  AsyncCancellationTests
//
//  Created by Doug on 4/8/19.
//  Copyright © 2019 Doug. All rights reserved.
//

import XCTest
import Foundation

class Examples: XCTestCase {
    enum WebResourceError: Error {
        case invalidResult
    }

    /// URLSession example
    func testAppleRequest() {
        func performAppleSearch() /* async */ throws -> String {
            let urlSession = URLSession(configuration: .default)
            let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
            let result = /* await */ try urlSession.asyncDataTask(with: request)
            if let resultString = String(data: result.data, encoding: .utf8) {
                return resultString
            }
            throw WebResourceError.invalidResult
        }

        // Execute the URLSession example

        // Set a timeout (seconds) to prevent hangs
        let cancelScope = CancelScope(timeout: 30.0)
        let appleError: (Error) -> () = { error in
            print("Apple search error: \(error)")
            XCTFail()
        }

        let ex = expectation(description: "Apple search successful")
        do {
            try beginAsync(context: cancelScope, error: appleError) {
                let result = try performAppleSearch()
                print("Apple search result: \(result)")
                ex.fulfill()
            }
        } catch {
            // Error is handled by the beginAsync 'error' callback
            XCTFail()
        }

        // Uncomment to see cancellation behavior
        // cancelScope.cancel()
        
        // Uncomment to see suspend behavior
        // cancelScope.suspendTasks()

        waitForExpectations(timeout: 5)
    }

    /***********************************************************************************
     Image loading example from 'Async/Await for Swift' by Chris Lattner and Joe Groff
     https://gist.github.com/dougzilla32/ce47a72067f9344742e10020ad4c8c41
     ***********************************************************************************/
    func testImageLoading() {
        /// For the purpose of this example, send a simple web request rather than loading actual image data
        func loadWebResource(_ name: String) throws -> String {
            let urlSession = URLSession(configuration: .default)
            let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
            let result = /* await */ try urlSession.asyncDataTask(with: request)
            if let resultString = String(data: result.data, encoding: .utf8) {
                return resultString
            }
            throw WebResourceError.invalidResult
        }

        /// For the purpose of this example, concat two strings in another thread rather than decoding image data
        func decodeImage(_ profile: String, _ data: String) throws -> String {
            return /* await */ try suspendAsync { continuation, error in
                let task = DispatchWorkItem {
                    continuation("\(profile)+\(data)")
                }
                if let cancelScope: CancelScope = getCoroutineContext() {
                    cancelScope.add(cancellable: task)
                }
                if let dispatchQueue: DispatchQueue = getCoroutineContext() {
                    dispatchQueue.asyncAfter(deadline: DispatchTime.now() + 0.5, execute: task)
                }
            }
        }

        /// For the purpose of this example, condense all the whitespace in the 'image' string
        func dewarpAndCleanupImage(_ image: String) throws -> String {
            return /* await */ try suspendAsync { continuation, error in
                let task = DispatchWorkItem {
                    let components = image.components(separatedBy: .whitespacesAndNewlines)
                    let condensedImage = components.filter { !$0.isEmpty }.joined(separator: " ")
                    continuation(condensedImage)
                }
                if let cancelScope: CancelScope = getCoroutineContext() {
                    cancelScope.add(cancellable: task)
                }
                if let dispatchQueue: DispatchQueue = getCoroutineContext() {
                    dispatchQueue.asyncAfter(deadline: DispatchTime.now() + 0.5, execute: task)
                }
            }
        }

        /// Image loading example
        func processImageData1a() /* async */ throws -> String {
            let dataResource = Future { /* await */ try loadWebResource("dataprofile.txt") }
            let imageResource = Future { /* await */ try loadWebResource("imagedata.dat") }

            // ... other stuff can go here to cover load latency...

            let imageTmp = /* await */ try decodeImage(
                try dataResource.get(), try imageResource.get())
            let imageResult = /* await */ try dewarpAndCleanupImage(imageTmp)
            return imageResult
        }

        // Set a timeout (seconds) to prevent hangs
        let cancelScope = CancelScope(timeout: 30.0)
        let queue = DispatchQueue.global(qos: .default)
        let imageError: (Error) -> () = { error in
            print("Image loading error: \(error)")
        }

        let ex = expectation(description: "Image loaded successfully")
        do {
            try beginAsync(context: [cancelScope, queue], error: imageError) {
                let result = try processImageData1a()
                print("Image result: \(result)")
                ex.fulfill()
            }
        } catch {
            // Error is handled by the beginAsync 'error' callback
            XCTFail()
        }

        // Uncomment to see cancellation behavior
        // cancelScope.cancel()

        waitForExpectations(timeout: 5)
    }
}
