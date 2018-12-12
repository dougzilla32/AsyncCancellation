//
//  AsyncCancellationTest.swift
//  AsyncCancellationTest
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import XCTest
import Foundation

class AsyncCancellationTest: XCTestCase {

    override func setUp() { }

    override func tearDown() { }
    
    func appleRequest() throws -> String {
        let session = URLSession(configuration: .default)
        let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
        let result = try /* await */ session.asyncDataTask(with: request)
        if let resultString = String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
            return resultString
        } else {
            return String(describing: result)
        }
    }
    
    func appleRequest(_ ex: XCTestExpectation, shouldSucceed: Bool, delay: TimeInterval = 0.0) -> () -> Void {
        let request = {
            do {
                let result = try self.appleRequest()
                print("Apple search result: \(result)")
                shouldSucceed ? ex.fulfill() : XCTFail()
            } catch {
                print("Apple search error: \(error)")
                shouldSucceed ? XCTFail(error.localizedDescription) : ex.fulfill()
            }
        }
        
        let rval: () -> Void
        if delay > 0.0 {
            rval = {
                let state = getCoroutineState()
                DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + delay) {
                    setCoroutineState(state)
                    request()
                    clearCoroutineState()
                }
            }
        } else {
            rval = request
        }
        return rval
    }
    
    func testURLSessionVanilla() {
        let ex = expectation(description: "")
        beginAsync(appleRequest(ex, shouldSucceed: true))
        waitForExpectations(timeout: 5)
    }
    
    func testURLSessionSuccess() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        beginAsync(context: [queue, cancelContext], appleRequest(ex, shouldSucceed: true))
        queue.asyncAfter(deadline: DispatchTime.now() + 5.0) {
            cancelContext.cancel()
        }
        waitForExpectations(timeout: 5)
    }
    
    func testURLSessionCancellation() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        beginAsync(context: [queue, cancelContext], appleRequest(ex, shouldSucceed: false))
        cancelContext.cancel()
        waitForExpectations(timeout: 1)
    }
    
    func testStuff() {
        class Stuff { }
        
        class StuffTask: AsyncTask {
            func cancel() {
                isCancelled = true
            }
            
            var isCancelled = false
        }
        
        func getStuff(completion: (Stuff) -> (), error: (Error) -> ()) -> StuffTask {
            completion(Stuff())
            return StuffTask()
        }
        
        let ex = expectation(description: "")
        
        do {
            let context = CancelContext()
            try beginAsync(context: context) {
                let stuff = /* await */ try suspendAsync { continuation, error in
                    (getCoroutineContext() as CancelToken?)?.add(task: getStuff(completion: continuation, error: error))
                }
                print("Stuff result: \(stuff)")
                ex.fulfill()
            }
            
            context.cancel()
        } catch {
            print("Stuff error: \(error)")
            XCTFail()
        }

        waitForExpectations(timeout: 2)
    }
    
    func testNestedBeginAsync() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        beginAsync(context:  [queue, cancelContext]) {
            beginAsync(self.appleRequest(ex, shouldSucceed: false))
        }
        cancelContext.cancel()
        waitForExpectations(timeout: 1)
    }
    
    struct TestCancelToken: CancelToken {
        let token: CancelToken
        let exAdd: XCTestExpectation?
        let exCancel: XCTestExpectation?
        let exIsCancelled: XCTestExpectation?
        
        func add(task: AsyncTask) {
            exAdd?.fulfill()
            token.add(task: task)
        }
        
        func cancel() {
            exCancel?.fulfill()
            token.cancel()
        }
        
        var isCancelled: Bool {
            exIsCancelled?.fulfill()
            return token.isCancelled
        }
    }
    
    func testCancelToken() {
        let exCancel = expectation(description: "cancelled")
        let exTokenAdd = expectation(description: "token add")
        let exTokenCancel = expectation(description: "token cancel")
        let exTokenIsCancelled = expectation(description: "token cancelled")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        do {
            try beginAsync(context: [queue, cancelContext], error: { error in
                error.isCancelled ? exCancel.fulfill() : XCTFail()
            }) {
                let result: (request: URLRequest, response: URLResponse, data: Data) = try suspendAsync { continuation, error in
                    let token = TestCancelToken(
                        token: cancelContext.makeCancelToken(),
                        exAdd: exTokenAdd,
                        exCancel: exTokenCancel,
                        exIsCancelled: exTokenIsCancelled
                    )

                    let session = URLSession(configuration: .default)
                    let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
                    let task = session.dataTask(with: request) { data, response, err in
                        if let err = err {
                            error(err)
                        } else if let response = response, let data = data {
                            continuation((request, response, data))
                        }
                    }
                    token.add(task: task)
                    task.resume()
                    
                    token.cancel()
                    XCTAssert(token.isCancelled)
                }
                if let resultString = String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
                    print(resultString)
                } else {
                    print(String(describing: result))
                }
                XCTFail()
            }
        } catch {
            error.isCancelled ? exCancel.fulfill() : XCTFail()
        }
        cancelContext.cancel()
        waitForExpectations(timeout: 1)
    }
    
    func testCancelTokenAsContext() {
        let exCancel = expectation(description: "cancelled")
        let exTokenAdd = expectation(description: "token add")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        do {
            try beginAsync(context: [queue, cancelContext], error: { error in
                error.isCancelled ? exCancel.fulfill() : XCTFail()
            }) {
                let result: String = try suspendAsync { continuation, errorHandler in
                    beginAsync(context: [queue, TestCancelToken(
                        token: cancelContext.makeCancelToken(),
                        exAdd: exTokenAdd,
                        exCancel: nil,
                        exIsCancelled: nil
                    )]) {
                        do {
                            continuation(try self.appleRequest())
                        } catch {
                            errorHandler(error)
                        }
                    }
                }
                print(result)
                XCTFail()
            }
        } catch {
            error.isCancelled ? exCancel.fulfill() : XCTFail()
        }
        cancelContext.cancel()
        waitForExpectations(timeout: 1)
    }
    
    func testTimeout() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelContext = CancelContext()
        beginAsync(context:  [queue, cancelContext], self.appleRequest(ex, shouldSucceed: false, delay: 0.5))
        cancelContext.timeout = 0.25
        waitForExpectations(timeout: 1)
    }
    
    func testTimer() {
        let ex = expectation(description: "")
        let cancelContext = CancelContext()
        let error: (Error) -> () = { error in
            XCTFail()
        }
        do {
            try beginAsync(context: cancelContext, error: error) {
                let theMeaningOfLife: Int = /* await */ try suspendAsync { continuation, error in
                    let workItem = DispatchWorkItem {
                        Thread.sleep(forTimeInterval: 0.1)
                        continuation(42)
                    }
                    DispatchQueue.global().async(execute: workItem)
                    (getCoroutineContext() as CancelToken?)?.add(task: workItem)
                }
                if theMeaningOfLife == 42 {
                    ex.fulfill()
                }
            }
        } catch {
            XCTFail()
        }
        waitForExpectations(timeout: 1)
    }
}
