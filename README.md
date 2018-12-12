## Async/Await with Cancellation

This project is an experimental implementation demonstrating 'cancellation' and 'timeout' abilities for the upcoming Async/Await Swift language feature.  This feature is described in ['Async/Await for Swift' by Chris Lattner and Joe Groff](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619) and further discussed in [Contextualizing async coroutines](https://forums.swift.org/t/contextualizing-async-coroutines/6588).  The addition of 'cancellation' and 'timeout' is proposed and discussed below.

To try it out, clone this project and run it!  And run the tests to see if it is working properly!

### Overview

In this proposal, the cancellation and timeout features are implemented using coroutine contexts:

* A cancel context (class  `CancelContext`) is used to track cancellable asynchronous tasks within coroutines.
* Tasks are manually added to the cancel context as they are created, and are automatically removed from the cancel context when their coroutine is resolved (i.e. the coroutine produces a result or an error).
* The cancel context has a `cancel()` method that can be used to explicitly cancel all unresolved tasks.
* The cancel context has a `timeout: TimeInterval` property for setting a timeout to cancel all unresolved tasks.
* When `cancel()` is called on a cancel context, all of its unresolved tasks are immediately resolved with the error `AsyncError.cancelled`.  Unwinding and cleanup for the task happen in the background after the cancellation error is thrown.
* The cancel context is thread safe, therefore the same instance can be used in multiple calls to `beginAsync` (course granularity)
* The cancel context can produce cancel tokens for finer granularity of cancellation and timeouts.  The cancel token can be used as a coroutine context, which will create a tree shaped cancellation structure (note: the cancel context is itself a cancel token)

### Examples

```swift
// Simple timer example

let cancelContext = CancelContext()
let error: (Error) -> () = { error in
    if error.isCancelled {
        print("Meaning Of Life calculation cancelled!")
    } else {
        print("An unknown error occurred while calculating the Meaning Of Life: \(error)")
    }
}

do {
    try beginAsync(context: cancelContext, error: error) {
        let theMeaningOfLife: Int = await suspendAsync { continuation, error in
            let workItem = DispatchWorkItem {
                Thread.sleep(forTimeInterval: 0.1)
                continuation(42)
            }
            DispatchQueue.global().async(execute: workItem)
            (getCoroutineContext() as CancelToken?)?.add(task: workItem)
        }
        if theMeaningOfLife == 42 {
            print("The Meaning Of Life is 42!!")
        } else {
            print("Wait, what?")
        }
    }
} catch {
    // Error is handled by the beginAsync 'error' callback
}

// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call 'cancel' to abort the request
cancelContext.cancel()
```

[`main.swift`](https://github.com/dougzilla32/AsyncCancellation/blob/master/Source/main.swift) contains the image loading example from ['Async/Await for Swift' by Chris Lattner and Joe Groff](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619).

### Prototype Limitations

This implementation has a limitation where `suspendAsync` blocks the current thread until either `continutation` or `error` has been called.  According to the Async/Await proposal `suspendAsync` is supposed to allow the current thread to resume execution while any of its coroutine are waiting to be resolved.

To implement `suspendAsync` properly would require either a custom preprocessor that rewrites the code or would require compiler support.  These is beyond the scope of this experimental implementation.

### Assumptions

I made some assumptions about how coroutine contexts might work, and how to handle errors (such as cancellation) that are propagated up to `beginAsync`. These are described below:

#### Contextualizing async coroutines

The proposal for [Contextualizing async coroutines](https://forums.swift.org/t/contextualizing-async-coroutines/6588) is incorporated in this implementation.  I found that it is desirable to allow multiple contexts with `beginAsync`.  Also for nested `beginAsync` calls, the contexts for the outer scopes should be preserved.  My take on this is the following:

* The coroutine context type is `Any`
* Multiple contexts are combined into an array  `[Any]`
* Inner contexts take precidence over outer contexts.
* There is a global function `getCoroutineContext<T>() -> T?`.  If the current coroutine context conforms to `T` then it is returned directly. Otherwise if the context is an `[Any]`, the first member of the array that conforms to `T` is returned.  If there is no match then `nil` is returned.
* For nested calls to `beginAsync` the outer coroutine context is merged with the new coroutine context to form the inner coroutine context using the following rules:
    1. If either `outer` or `new` is `nil`, then use the non-nil value
    2. If `outer` ===  `new`, then it is the same reference so just use `outer`
    3. If  `outer` and `new` are both `[Any]`, then concatenated `new` and `outer` (`new` comes first)
    4. If  `outer` is `[Any]`, then prepend `new`  to `outer`
    5. If `new` is `[Any]`, then append `outer` to `new`
    6. Concatenate `new` and  `outer` as `[Any]`

#### Error handling for `beginAsync`

Error handling for `beginAsync` is not fully specified in ['Async/Await for Swift' by Chris Lattner and Joe Groff](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619) .

To handle errors throw by the `body` parameter in the `beginAsync` function, I've added an optional error handler parameter to `beginAsync`.

### API

For 'cancellation' abilities the following changes and additions are proposed and are experimentally implemented in this project:

```swift
/// Represents a generic asynchronous task
public protocol AsyncTask {
    func cancel()
    var isCancelled: Bool { get }
}

/// The CancelToken is used to register an AsyncTask within a cancellation scope
public protocol CancelToken {
    func add(task: AsyncTask)    
    func cancel()    
    var isCancelled: Bool { get }
}

/// Cancellation error
public enum AsyncError: Error {
    case cancelled
}

/// Shortcut to check for cancellation errors
extension Error {
    public var isCancelled: Bool {
        do {
            throw self
        } catch AsyncError.cancelled {
            return true
        } catch {
            return false
        }
    }
}

/**
 The CancelContext serves to:
 - Cancel tasks
 - Provide a CancelToken for registering cancellable tasks
 - Provide the current list of cancellable tasks, allowing extensions of CancelContext to define new operations on tasks
 - Optionally specify a timeout for its associated tasks
 Note: A task is considered resolved if either its `continuation` or its `error` closure has been invoked.
 */
public class CancelContext: CancelToken {
    public func cancel()  
    public var isCancelled: Bool { get }

    /// Add a cancellable task to the cancel context
    public func add(task: AsyncTask)

    /// Create a token that can be used to associate a task with this context, and can be used
    /// to cancel or set a timeout on only the token's tasks (as a subset of the CancelContext tasks).
    public func makeCancelToken() -> CancelToken
    
    /// All associated unresolved tasks will be cancelled after the given timeout.
    /// Default is no timeout.
    public var timeout: TimeInterval

    /// The list of unresolved tasks for this cancel context
    public var tasks: [CancelContext.Cancellable] {

    public struct Cancellable {
        let task: AsyncTask
        let tokenId: UInt
        let error: (Error) -> ()
    }
}

/**
 Return a coroutime context matching the given type `T` by applying the following checks in sequential order:
 1. If the coroutine context matches type 'T', then it is returned
 2. If the coroutine context is an array, then return the first item in the array matching `T`
 3. Return `nil` if there are no matches
 */
public func getCoroutineContext<T>() -> T?

/**
 Begins an asynchronous coroutine, transferring control to `body` until it
 either suspends itself for the first time with `suspendAsync` or completes,
 at which point `beginAsync` returns. If the async process completes by
 throwing an error before suspending itself, `beginAsync` rethrows the error.

 Calls to `beginAsync` may be nested, which can be used to provide additional
 coroutine contexts.  Coroutine contexts from outer scopes are inherited by
 concantenating all contexts as an array.  The `getCoroutineContext` function
 runs through this array looking for a matching type.

 - Parameter asyncContext: the context to use for all encapsulated corotines
 - Parameter error: invoked if 'body' throws an error
*/
public func beginAsync(
    asyncContext: Any? = nil,
    error: ((Error) -> ())? = nil,
    _ body: @escaping () throws -> Void) rethrows

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

/**
 Suspends the current asynchronous task and invokes `body` with the task's
 continuation and failure closures. Invoking `continuation` will resume the
 coroutine by having `suspendAsync` return the value passed into the
 continuation. Invoking `error` will resume the coroutine by having
 `suspendAsync` throw the error passed into it. Only one of
 `continuation` and `error` may be called; it is a fatal error if both are
 called, or if either is called more than once.

 Code inside `body` can support cancellation as follows:
 
     // 'task' conforms to 'AsyncTask'
     (getCoroutineContext() as CancelToken?)?.add(task: task)
     
*/
public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> (),
    _ error: @escaping (Error) -> ()) -> ()
    ) throws -> T
```

#### This example shows how to define URLSession.dataTask as a coroutine that supports cancellation:

```swift
/// Add 'suspend' and 'resume' capabilities to CancelContext
extension CancelContext {
    func suspendURLSessionTasks() { tasks.forEach { ($0.task as? URLSessionTask)?.suspend() } }
    func resumeURLSessionTasks() { tasks.forEach { ($0.task as? URLSessionTask)?.resume() } }
}

/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: AsyncTask {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

/// Add async version of dataTask(with:) which uses suspendAsync for the callback
extension URLSession {
    func dataTask(with request: URLRequest) async -> (request: URLRequest, response: URLResponse, data: Data) {
        return await suspendAsync { continuation, error in
            let task = self.dataTask(with: request) { data, response, err in
                if let err = err {
                    error(err)
                } else if let response = response, let data = data {
                    continuation((request, response, data))
                }
            }
            (getCoroutineContext() as CancelToken?)?.add(task: task)
            task.resume()
        }
    }
}
```

#### This example demonstrates usage of the `URLSessionTask.dataTask` coroutine including cancellation and timeout:

```swift
import Foundation

// Example: how to make a cancellable web request with the
// URLSession.dataTask coroutine
let cancelContext = CancelContext()
let error: (Error) -> () = { error in
    print("Apple search error: \(error)")
}

do {
    beginAsync(context: cancelContext, error: error) {
        let urlSession = URLSession(configuration: .default)
        let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
        let result = await urlSession.dataTask(with: request)
        print("result: \(String(data: result.data, encoding: .utf8))")
    }
} catch {
    // Error is handled by the beginAsync 'error' callback
}

// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call 'cancel' to abort the request
cancelContext.cancel()
```

#### Here is the image loading example from the original Async/Await proposal, along with cancellation and timeout abilities (from [`main.swift`](https://github.com/dougzilla32/AsyncCancellation/blob/master/Source/main.swift)):

```swift
/// For the purpose of this example, send a simple web request rather than loading actual image data
func loadWebResource(_ name: String) throws -> Data {
    let urlSession = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://mydatarepo.com/\(name)")!)
    let result = await urlSession.dataTask(with: request)
    return result.data
}

func decodeImage(_ profile: Data, _ data: Data) throws -> Image

func dewarpAndCleanupImage(_ image : Image) async -> Image

/// Image loading example
func processImageData1a() async -> Image {
    let dataResource  = Future { await loadWebResource("dataprofile.txt") }
    let imageResource = Future { await loadWebResource("imagedata.dat") }
    
    // ... other stuff can go here to cover load latency...
    
    let imageTmp    = await decodeImage(try dataResource.get(), try imageResource.get())
    let imageResult = await dewarpAndCleanupImage(imageTmp)
    return imageResult
}

// Execute the image loading example
let queue = DispatchQueue.global(qos: .default)
let cancelContext = CancelContext()
let error: (Error) -> () = { error in
    print("Image loading error: \(error)")
}

do {
    try beginAsync(context: [cancelContext, queue], error: error) {
        let result = try processImageData1a()
        print("Image result: \(result)")
    }
} catch {
    // Error is handled by the beginAsync 'error' callback
}


// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call cancel to abort the request
cancelContext.cancel()
```
