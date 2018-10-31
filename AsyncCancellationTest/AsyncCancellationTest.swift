//
//  AsyncCancellationTest.swift
//  AsyncCancellationTest
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import XCTest

class AsyncCancellationTest: XCTestCase {

    override func setUp() { }

    override func tearDown() { }
    
    func appleRequest(_ ex: XCTestExpectation, shouldSucceed: Bool) -> () -> Void {
        return {
            let session = URLSession(configuration: .default)
            let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
            do {
                let result = try /* await */ session.asyncDataTask(with: request)
                if let resultString = String(data: result.2, encoding: .utf8)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
                    print("Apple search result: \(resultString)")
                } else {
                    print("Apple search result: \(result)")
                }
                shouldSucceed ? ex.fulfill() : XCTFail()
            } catch {
                print("Apple search error: \(error)")
                shouldSucceed ? XCTFail(error.localizedDescription) : ex.fulfill()
            }
        }
    }

    func testURLSessionVanilla() {
        let ex = expectation(description: "")
        beginAsync(appleRequest(ex, shouldSucceed: true))
        waitForExpectations(timeout: 1)
    }
    
    func testURLSessionSuccess() {
        let ex = expectation(description: "")
        let chain = beginAsyncTask(appleRequest(ex, shouldSucceed: true))
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 5.0) {
            chain.cancel()
        }
        waitForExpectations(timeout: 1)
    }
    
    func testURLSessionCancellation() {
        let ex = expectation(description: "")
        let chain = beginAsyncTask(appleRequest(ex, shouldSucceed: false))
        chain.cancel()
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
            let chain = try beginAsyncTask {
                let stuff = try suspendAsync { continuation, error, task in
                    task(getStuff(completion: continuation, error: error))
                }
                print("Stuff result: \(stuff)")
                ex.fulfill()
            }
            
            chain.cancel()
        } catch {
            print("Stuff error: \(error)")
            XCTFail()
        }

        waitForExpectations(timeout: 1)
    }
}
