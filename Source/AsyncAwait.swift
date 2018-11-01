//
//  AsyncAwait.swift
//  AsyncTest
//
//  Created by Doug on 10/29/18.
//  Copyright © 2018 Doug. All rights reserved.
//

import Foundation

//
// async/await with cancellation experimental code
//

private var asyncChain = ThreadLocal<AsyncTaskChain?>(capturing: nil)
private var asyncSemaphore = ThreadLocal<DispatchSemaphore?>(capturing: nil)

public func beginAsync(_ body: @escaping () throws -> Void) rethrows {
    let chain = asyncChain.inner.value
    let beginAsyncSemaphore = DispatchSemaphore(value: 0)
    var bodyError: Error?
    var done = false
    
    DispatchQueue.global(qos: .default).async {
        assert(asyncChain.inner.value == nil)
        asyncChain.inner.value = chain
        defer {
            asyncChain.inner.value = nil
        }
        
        assert(asyncSemaphore.inner.value == nil)
        asyncSemaphore.inner.value = beginAsyncSemaphore
        defer {
            beginAsyncSemaphore.signal()
            asyncSemaphore.inner.value = nil
        }
        
        do {
            try body()
        } catch {
            if done {
                // Not sure where this error is supposed to go as this is unclear from the spec
                print("beginAsync error: \(error)")
            } else {
                bodyError = error
            }
        }
    }
    
    beginAsyncSemaphore.wait()
    
    if let error = bodyError {
        // Would like to rethrow the body error here but the compiler does not seem to allow for this
        print("beginAsync initial error: \(error)")
        // throw error
    }
    
    done = true
}

@discardableResult
public func beginAsyncTask(_ body: @escaping () throws -> Void) rethrows -> AsyncTask {
    var chainCreated = false
    let chain: AsyncTaskChain
    if let c = asyncChain.inner.value {
        chain = c
    } else {
        chain = AsyncTaskChain()
        asyncChain.inner.value = chain
        chainCreated = true
    }
    defer {
        if chainCreated {
            asyncChain.inner.value = nil
        }
    }

    try beginAsync(body)
    
    return chain
}

public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> ()) -> ()
    ) -> T
{
    guard let beginAsyncSemaphore = asyncSemaphore.inner.value else {
        fatalError("suspendAsync must be called within beginAsync")
    }

    let suspendAsyncSemaphore = DispatchSemaphore(value: 0)
    var theResult: T?
    
    func continuation(_ result: T) {
        assert(theResult == nil)
        theResult = result
        suspendAsyncSemaphore.signal()
    }
    
    body(continuation)
    
    beginAsyncSemaphore.signal()
    suspendAsyncSemaphore.wait()
    
    return theResult!
}

public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> (),
                       _ error: @escaping (Error) -> ()) -> ()
    ) throws -> T
{
    guard let beginAsyncSemaphore = asyncSemaphore.inner.value else {
        fatalError("suspendAsync must be called within beginAsync")
    }

    let suspendAsyncSemaphore = DispatchSemaphore(value: 0)
    var theResult: T?
    var errorResult: Error?
    
    func continuation(_ result: T) {
        assert(theResult == nil)
        theResult = result
        suspendAsyncSemaphore.signal()
    }
    
    func error(_ error: Error) {
        assert(errorResult == nil)
        errorResult = error
        suspendAsyncSemaphore.signal()
    }
    
    body(continuation, error)
    
    beginAsyncSemaphore.signal()
    suspendAsyncSemaphore.wait()
    
    if let err = errorResult {
        throw err
    }
    
    return theResult!
}

public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> (),
                       _ error: @escaping (Error) -> (),
                       _ task: @escaping (AsyncTask) -> ()) -> ()
    ) throws -> T
{
    var errorHandler: ((Error) -> ())!
    var bodyError = false
    var cancelled = false

    func bodyErrorHandler(_ error: Error) {
        // If 'bodyError' is true, then call the errorHandler to cause a fatal exception as
        // the error handler is only allowed to be called once by the body.
        //
        // If 'cancelled' is false, then call the errorHandler to handle the error normally.
        // If 'cancelled' is true, then the errorHandler has already been called with a
        // cancellation error.
        if bodyError || !cancelled {
            errorHandler(error)
        }
        bodyError = true
    }
    
    func task(_ task: AsyncTask) {
        asyncChain.inner.value?.append(AsyncTaskChain.TaskWithErrorHandler(task: task) { error in
            if !bodyError && !cancelled {
                errorHandler(error)
                cancelled = true
            }
        })
    }
    
    return try suspendAsync { continuation, error in
        errorHandler = error
        body(continuation, bodyErrorHandler, task)
    }
}
