//
//  AsyncAwait.swift
//  AsyncTest
//
//  Created by Doug on 10/29/18.
//

import Foundation

//
// async/await with cancellation experimental code
//

private var tlAsyncContext = ThreadLocal<Any?>(capturing: nil)
private var tlAsyncSemaphore = ThreadLocal<DispatchSemaphore?>(capturing: nil)

public func getCoroutineContext<T>() -> T? {
    let value = tlAsyncContext.inner.value
    if let rval = value as? T {
        return rval
    } else if let coroutineContexts = value as? [Any] {
        for context in coroutineContexts {
            if let rval = context as? T {
                return rval
            }
        }
    }
    return nil
}

public func beginAsync(asyncContext: Any? = nil, _ body: @escaping () throws -> Void) rethrows {
    let beginAsyncSemaphore = DispatchSemaphore(value: 0)
    var bodyError: Error?
    var beginAsyncReturned = false
    
    let outerContext = tlAsyncContext.inner.value
    
    DispatchQueue.global(qos: .default).async {
        // Inherit async contexts from parent 'beginAsync'
        let innerContext: Any?
        if let asyncContext = asyncContext, let outerContext = outerContext {
            if let asyncContexts = asyncContext as? [Any], var outerContexts = outerContext as? [Any] {
                outerContexts.insert(contentsOf: asyncContexts, at: 0)
                innerContext = outerContexts
            } else if var asyncContexts = asyncContext as? [Any] {
                asyncContexts.insert(outerContext, at: 0)
                innerContext = asyncContexts
            } else if var outerContexts = outerContext as? [Any] {
                outerContexts.insert(asyncContext, at: 0)
                innerContext = outerContexts
            } else {
                innerContext = [ asyncContext, outerContext ]
            }
        } else if let outerContext = outerContext {
            innerContext = outerContext
        } else {
            innerContext = asyncContext
        }

        // Check for nil and assign to nil before returning, to ensure this works with thread pools
        assert(tlAsyncContext.inner.value == nil)
        tlAsyncContext.inner.value = innerContext
        defer {
            tlAsyncContext.inner.value = nil
        }
        
        // Check for nil and assign to nil before returning, to ensure this works with thread pools
        assert(tlAsyncSemaphore.inner.value == nil)
        tlAsyncSemaphore.inner.value = beginAsyncSemaphore
        defer {
            beginAsyncSemaphore.signal()
            tlAsyncSemaphore.inner.value = nil
        }
        
        do {
            try body()
        } catch {
            if beginAsyncReturned {
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
    
    beginAsyncReturned = true
}

public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> ()) -> ()
    ) -> T
{
    guard let beginAsyncSemaphore = tlAsyncSemaphore.inner.value else {
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
    guard let beginAsyncSemaphore = tlAsyncSemaphore.inner.value else {
        fatalError("suspendAsync must be called within beginAsync")
    }

    let suspendAsyncSemaphore = DispatchSemaphore(value: 0)
    var theResult: T?
    var errorResult: Error?
    
    func isCancelError(_ error: Error?) -> Bool {
        guard let e = error as? AsyncError else {
            return false
        }
        if case .cancelled = e {
            return true
        } else {
            return false
        }
    }
    
    func continuation(_ result: T) {
        assert(theResult == nil)
        theResult = result
        suspendAsyncSemaphore.signal()
    }
    
    func error(_ error: Error) {
        // Allow multiple 'cancel' errors
        if !isCancelError(error) && !isCancelError(errorResult) {
            assert(errorResult == nil)
        }
        // Prefer other errors over 'cancel' errors
        if errorResult == nil || !isCancelError(error) {
            errorResult = error
        }
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
