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

/// Capture the coroutine state for the current thread
public struct CoroutineState {
    let asyncContext: Any?
    let asyncSemaphore: DispatchSemaphore?
}

/// 'getCoroutineState' and 'setCoroutineState' are used to copy the coroutine state to another thread.
/// This is a workaround for the prototype and would not be necessary in the Swift language implementation.
public func getCoroutineState()-> CoroutineState {
    return CoroutineState(asyncContext: tlAsyncContext.inner.value, asyncSemaphore: tlAsyncSemaphore.inner.value)
}

/// 'getCoroutineState' and 'setCoroutineState' are used to copy the coroutine state to another thread.
/// This is a workaround for the prototype and would not be necessary in the Swift language implementation.
public func setCoroutineState(_ state: CoroutineState) {
    tlAsyncContext.inner.value = state.asyncContext
    tlAsyncSemaphore.inner.value = state.asyncSemaphore
}

public func clearCoroutineState() {
    tlAsyncContext.inner.value = nil
    tlAsyncSemaphore.inner.value = nil
}

/**
 Return a coroutime context matching the given type `T` by applying the following checks in sequential order:
 1. If the coroutine context matches type 'T', then it is returned
 2. If the coroutine context is an array, then return the first item in the array matching `T`
 3. Return `nil` if there are no matches
 */
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

/**
 Begins an asynchronous coroutine, transferring control to `body` until it
 either suspends itself for the first time with `suspendAsync` or completes,
 at which point `beginAsync` returns. If the async process completes by
 throwing an error before suspending itself, `beginAsync` rethrows the error.
 
 Calls to `beginAsync` may be nested, which can be used to provide additional
 coroutine contexts.  Coroutine contexts from outer scopes are inherited by
 concantenating all contexts as an array.  The `getCoroutineContext` function
 runs through this array looking for a matching type.
 
 For nested calls to `beginAsync` the outer coroutine context is merged with the new coroutine context to form the inner coroutine context using the following rules:
    1. If either `outer` or `new` is `nil`, then use the non-nil value
    2. If `outer` ===  `new`, then it is the same reference so just use `outer`
    3. If  `outer` and `new` are both `[Any]`, then concatenated `new` and `outer` (`new` comes first)
    4. If  `outer` is `[Any]`, then prepend `new`  to `outer`
    5. If `new` is `[Any]`, then append `outer` to `new`
    6. Concatenate `new` and  `outer` as `[Any]`

 - Parameter asyncContext: the context to use for all encapsulated corotines
 - Parameter error: invoked if 'body' throws an error
 */
public func beginAsync(context newContext: Any? = nil, error errorHandler: ((Error) -> ())? = nil, _ body: @escaping () throws -> Void) rethrows {
    let beginAsyncSemaphore = DispatchSemaphore(value: 0)
    var bodyError: Error?
    var beginAsyncReturned = false
    
    let outerContext = tlAsyncContext.inner.value
    
    DispatchQueue.global(qos: .default).async {
        // Inherit async contexts from parent 'beginAsync'
        let innerContext: Any?
        if let newContext = newContext, let outerContext = outerContext {
            if newContext as AnyObject === outerContext as AnyObject {
                innerContext = outerContext
            } else if var newContexts = newContext as? [Any], let outerContexts = outerContext as? [Any] {
                newContexts.append(outerContexts)
                innerContext = newContexts
            } else if var outerContexts = outerContext as? [Any] {
                outerContexts.insert(newContext, at: 0)
                innerContext = outerContexts
            } else if var newContexts = newContext as? [Any] {
                newContexts.append(outerContext)
                innerContext = newContexts
            } else {
                innerContext = [ newContext, outerContext ]
            }
        } else if let outerContext = outerContext {
            innerContext = outerContext
        } else {
            innerContext = newContext
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
            errorHandler?(error)
            if !beginAsyncReturned {
                bodyError = error
            }
        }
    }
    
    beginAsyncSemaphore.wait()
    
    if let error = bodyError {
        // ToDo: Would like to rethrow the body error here but the compiler does not seem to allow for this
        print("beginAsync initial error: \(error)")
        // throw error
    }
    
    beginAsyncReturned = true
}

/**
 Suspends the current asynchronous task and invokes `body` with the task's
 continuation closure. Invoking `continuation` will resume the coroutine
 by having `suspendAsync` return the value passed into the continuation.
 It is a fatal error for `continuation` to be invoked more than once.
 
 - Note: Cancellation is not supported with this flavor of `suspendAsync`
 and attempts to access the `cancelToken` will trigger a fatal error.
 */
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

/**
 Suspends the current asynchronous task and invokes `body` with the task's
 continuation and failure closures. Invoking `continuation` will resume the
 coroutine by having `suspendAsync` return the value passed into the
 continuation. Invoking `error` will resume the coroutine by having
 `suspendAsync` throw the error passed into it. Only one of
 `continuation` and `error` may be called; it is a fatal error if both are
 called, or if either is called more than once.
 
 Code inside `body` can support cancellation as follows:
 ```swift
 // 'task' conforms to 'AsyncTask'
 (getCoroutineContext() as CancelToken?)?.add(task: task)
 ```
 */
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
    
    let cancelContext: CancelContext? = getCoroutineContext()
    let cancelTokenId: UInt! = cancelContext != nil ? CancelContext.nextTokenId() : nil
    
    func continuation(_ result: T) {
        assert(theResult == nil)
        assert(errorResult == nil || isCancelError(errorResult))
        
        theResult = result

        // Remove resolved tasks from the cancel context and clear the current cancel token
        cancelContext?.removeAll(id: cancelTokenId)

        suspendAsyncSemaphore.signal()
    }
    
    func error(_ error: Error) {
        assert(theResult == nil || isCancelError(error))
        
        // Allow multiple 'cancel' errors
        if !isCancelError(error) && !isCancelError(errorResult) {
            assert(errorResult == nil)
        }

        if errorResult == nil {
            // Remove resolved tasks from the cancel context and clear the current cancel token
            cancelContext?.removeAll(id: cancelTokenId)
        }

        // Prefer other errors over 'cancel' errors
        if errorResult == nil || !isCancelError(error) {
            errorResult = error
        }

        suspendAsyncSemaphore.signal()
    }
    
    cancelContext?.pushCancelScope(id: cancelTokenId, error: error)
    body(continuation, error)
    cancelContext?.popCancelScope(id: cancelTokenId)

    beginAsyncSemaphore.signal()
    suspendAsyncSemaphore.wait()
    
    if let errorResult = errorResult {
        throw errorResult
    }
    
    return theResult!
}
