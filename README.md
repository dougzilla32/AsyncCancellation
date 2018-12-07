## Async/Await with Cancellation

This project contains experimental code demonstrating proposed 'cancellation' abilities for the upcoming async/await Swift language feature.  The 'cancellation' proposal is described below.

To try it out, clone this project and run it!  Also, run the tests to see if it is working properly!

`main.swift` contains the image loading example from the ['Async/Await for Swift' proposal by Chris Lattner and Joe Groff](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619). 

#### The original proposal includes the following primitives, which are implemented (as experimental code) by this project:

```swift
/// Begins an asynchronous coroutine, transferring control to `body` until it
/// either suspends itself for the first time with `suspendAsync` or completes,
/// at which point `beginAsync` returns. If the async process completes by
/// throwing an error before suspending itself, `beginAsync` rethrows the error.
func beginAsync(_ body: () async throws -> Void) rethrows -> Void

/// Suspends the current asynchronous task and invokes `body` with the task's
/// continuation closure. Invoking `continuation` will resume the coroutine
/// by having `suspendAsync` return the value passed into the continuation.
/// It is a fatal error for `continuation` to be invoked more than once.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> ()) -> ()
) async -> T

/// Suspends the current asynchronous task and invokes `body` with the task's
/// continuation and failure closures. Invoking `continuation` will resume the
/// coroutine by having `suspendAsync` return the value passed into the
/// continuation. Invoking `error` will resume the coroutine by having
/// `suspendAsync` throw the error passed into it. Only one of
/// `continuation` and `error` may be called; it is a fatal error if both are
/// called, or if either is called more than once.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> (),
           _ error: @escaping (Error) -> ()) -> ()
) async throws -> T
```

#### For 'cancellation' abilities the following changes and additions are proposed (these are experimentally implemented by this project):

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

    /// Create a token that can be used to associate a task with this context
    public func makeCancelToken() -> CancelToken
    
    /// All associated unresolved tasks will be cancelled after the given timeout.
    /// Default is no timeout.
    public var timeout: TimeInterval
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

#### This example code shows how to define URLSession.dataTask as a coroutine that supports cancellation:

```swift
/// Add 'suspend' and 'resume' capabilities to CancelContext
extension CancelContext {
    func suspend() { tasks.forEach { ($0.task as? URLSessionTask)?.suspend() } }
    func resume() { tasks.forEach { ($0.task as? URLSessionTask)?.resume() } }
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

#### This example demonstrates the `URLSessionTask.dataTask` coroutine with cancellation and timeouts:

```swift
import Foundation


/// Example: how to make a cancellable web request with the URLSession.dataTask coroutine
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

    /// Set a timeout (seconds) to prevent hangs
    cancelContext.timeout = 30.0
} catch {
    print("Apple search error: \(error)")
}

...

/// Call 'cancel' to abort the request
cancelContext.cancel()
```

#### Here is the image loading example from the original proposal, along with cancellation and timeout abilities:

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

/// Execute the image loading example
let queue = DispatchQueue.global(qos: .default)
let cancelContext = CancelContext()
let error: (Error) -> () = { error in
    print("Image loading error: \(error)")
}

do {
    try beginAsync(context: [cancelContext, queue], error: error) {
        let result = try processImageData1a()
        print("image result: \(result)")
    }
} catch {
    print("Image loading error: \(error)")
}


/// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call cancel to abort the request
cancelContext.cancel()
```
