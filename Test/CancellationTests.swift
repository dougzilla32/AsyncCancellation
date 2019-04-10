//
//  CancellationTests.swift
//  AsyncCancellationTests
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import XCTest
import Foundation

class CancellationTests: XCTestCase {
    func appleRequest() throws -> String {
        let session = URLSession(configuration: .default)
        let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
        let result = try /* await */ session.asyncDataTask(with: request)
        if let resultString = String(data: result.data, encoding: .utf8)?.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines)
        {
            return resultString
        }
        else {
            return String(describing: result)
        }
    }

    func appleRequest(_ ex: XCTestExpectation, shouldSucceed: Bool, delay: TimeInterval = 0.0)
        -> () -> Void {
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
                DispatchQueue.global(qos: .default).asyncAfter(deadline: DispatchTime.now() + delay)
                {
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
        let cancelScope = CancelScope()
        beginAsync(context: [queue, cancelScope], appleRequest(ex, shouldSucceed: true))
        queue.asyncAfter(deadline: DispatchTime.now() + 5.0) {
            cancelScope.cancel()
        }
        waitForExpectations(timeout: 5)
    }

    func testURLSessionCancellation() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelScope = CancelScope()
        beginAsync(context: [queue, cancelScope], appleRequest(ex, shouldSucceed: false))
        cancelScope.cancel()
        waitForExpectations(timeout: 1)
    }

    func testStuff() {
        class Stuff {}

        class StuffTask: Cancellable {
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
            let scope = CancelScope()
            try beginAsync(context: scope) {
                let stuff = /* await */ try suspendAsync { continuation, error in
                    (getCoroutineContext() as CancelScope?)?.add(
                        cancellable: getStuff(completion: continuation, error: error))
                }
                print("Stuff result: \(stuff)")
                ex.fulfill()
            }

            scope.cancel()
        } catch {
            print("Stuff error: \(error)")
            XCTFail()
        }

        waitForExpectations(timeout: 2)
    }

    func testNestedBeginAsync() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelScope = CancelScope()
        beginAsync(context: [queue, cancelScope]) {
            beginAsync(self.appleRequest(ex, shouldSucceed: false))
        }
        cancelScope.cancel()
        waitForExpectations(timeout: 1)
    }

    class TestCancelScope: CancelScope {
        let scope: CancelScope
        let exAdd: XCTestExpectation?
        let exCancel: XCTestExpectation?
        let exIsCancelled: XCTestExpectation?
        
        init(timeout: TimeInterval = 0.0,
                      scope: CancelScope,
                      exAdd: XCTestExpectation?,
                      exCancel: XCTestExpectation?,
                      exIsCancelled: XCTestExpectation?) {
            self.scope = scope
            self.exAdd = exAdd
            self.exCancel = exCancel
            self.exIsCancelled = exIsCancelled
            super.init(timeout: timeout)
        }

        override func add(cancellable: Cancellable) {
            exAdd?.fulfill()
            scope.add(cancellable: cancellable)
        }

        override func cancellables<T: Cancellable>() -> [T] {
            return scope.cancellables()
        }

        override func cancel() {
            exCancel?.fulfill()
            scope.cancel()
        }

        override var isCancelled: Bool {
            exIsCancelled?.fulfill()
            return scope.isCancelled
        }
    }

    func testCancelScope() {
        let exCancel = expectation(description: "cancelled")
        let exScopeAdd = expectation(description: "scope add")
        let exScopeCancel = expectation(description: "scope cancel")
        let exScopeIsCancelled = expectation(description: "scope cancelled")
        let queue = DispatchQueue.global(qos: .default)
        let cancelScope = CancelScope()
        do {
            try beginAsync(
                context: [queue, cancelScope],
                error: { error in
                    error.isCancelled ? exCancel.fulfill() : XCTFail()
                }
            ) {
                let result: (request: URLRequest, response: URLResponse, data: Data) = try suspendAsync
                { continuation, error in
                    let scope = TestCancelScope(
                        scope: cancelScope.makeSubscope(),
                        exAdd: exScopeAdd,
                        exCancel: exScopeCancel,
                        exIsCancelled: exScopeIsCancelled
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
                    scope.add(cancellable: task)
                    task.resume()

                    scope.cancel()
                    XCTAssert(scope.isCancelled)
                }
                if let resultString = String(
                    data: result.data, encoding: .utf8)?.trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines)
                {
                    print(resultString)
                } else {
                    print(String(describing: result))
                }
                XCTFail()
            }
        } catch {
            error.isCancelled ? exCancel.fulfill() : XCTFail()
        }
        cancelScope.cancel()
        waitForExpectations(timeout: 1)
    }

    func testCancelScopeAsContext() {
        let exCancel = expectation(description: "cancelled")
        let exScopeAdd = expectation(description: "scope add")
        let queue = DispatchQueue.global(qos: .default)
        let cancelScope = CancelScope()
        do {
            try beginAsync(
                context: [queue, cancelScope],
                error: { error in
                    error.isCancelled ? exCancel.fulfill() : XCTFail()
                }
            ) {
                let result: String = try suspendAsync { continuation, errorHandler in
                    beginAsync(
                        context: [
                            queue,
                            TestCancelScope(
                                scope: cancelScope.makeSubscope(),
                                exAdd: exScopeAdd,
                                exCancel: nil,
                                exIsCancelled: nil
                            )
                        ]
                    ) {
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
        cancelScope.cancel()
        waitForExpectations(timeout: 1)
    }

    func testTimeout() {
        let ex = expectation(description: "")
        let queue = DispatchQueue.global(qos: .default)
        let cancelScope = CancelScope(timeout: 0.25)
        beginAsync(
            context: [queue, cancelScope], self.appleRequest(ex, shouldSucceed: false, delay: 0.5)
        )
        waitForExpectations(timeout: 1)
    }

    func testTimer() {
        let ex = expectation(description: "")
        let cancelScope = CancelScope()
        let error: (Error) -> () = { error in
            XCTFail()
        }
        do {
            try beginAsync(context: cancelScope, error: error) {
                let theMeaningOfLife: Int = /* await */ try suspendAsync { continuation, error in
                    let workItem = DispatchWorkItem {
                        Thread.sleep(forTimeInterval: 0.1)
                        continuation(42)
                    }
                    DispatchQueue.global().async(execute: workItem)
                    (getCoroutineContext() as CancelScope?)?.add(cancellable: workItem)
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
