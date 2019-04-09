## Async/Await with Cancellation

This is an experimental implementation of the [Proposal to add cancellation abilities for Async/Await](https://forums.swift.org/t/proposal-to-add-cancellation-abilities-for-async-await/18419/12) for the Swift language.

This project demonstrates 'cancellation' and 'timeout' abilities for Async/Await.  The Async/Await feature is described in ['Async/Await for Swift' by Chris Lattner and Joe Groff](https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619) and further discussed in [Contextualizing async coroutines](https://forums.swift.org/t/contextualizing-async-coroutines/6588).  The addition of 'cancellation' and 'timeout' is proposed and discussed below.

To try it out, clone this project and run it!  And run the tests to see if it is working properly!

### Overview

In this proposal, the cancellation and timeout features are implemented using coroutine contexts:

* A cancel context (class  `CancelContext`) is used to track cancellable asynchronous tasks within coroutines.
* Tasks are manually added to the cancel context as they are created, and are automatically removed from the cancel context when their associated coroutine is resolved (i.e. the coroutine produces a result or an error).
* The cancel context has a `cancel()` method that can be used to explicitly cancel all unresolved tasks.
* When `cancel()` is called on a cancel context, all of its unresolved coroutines are immediately resolved with the error `AsyncError.cancelled`.  Unwinding and cleanup for the associated task(s) happens in the background after the cancellation error is thrown.
* The cancel context is thread safe, therefore the same instance can be used in multiple calls to `beginAsync`
* The cancel context can produce cancel tokens for finer granularity of cancellation and timeouts.
* The cancel context has a `timeout: TimeInterval` property for setting a timeout to cancel all unresolved tasks.

### Timer example

Here is a simple example using cancellation with async/await:

```swift
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
            if let cancelToken: CancelToken = getCoroutineContext() {
                cancelToken.add(cancellable: workItem)
            }
        }
        if theMeaningOfLife == 42 {
            print("The Meaning Of Life is 42!!")
        } else {
            print("Wait, what?")
        }
    }
} catch {
    print(error)
}

// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call 'cancel' to abort the request
cancelContext.cancel()
```

### API

For 'cancellation' abilities the following changes and additions are proposed and are experimentally implemented in this project:

```swift
/// 'Cancellable' tasks that conform to this protocol can be added to a 'CancelContext'
public protocol Cancellable {
    func cancel()

    var isCancelled: Bool { get }
}

/// The 'CancelToken' determines a cancellation scope within a 'CancelContext'
public protocol CancelToken {
    /// Cancel all unresolved cancellables associated with this token
    func cancel()

    /// Returns true if all cancellables associated with this token are either cancelled or resolved
    var isCancelled: Bool { get }

    /// Add a cancellable to the associated cancel context, marked with this token
    func add(cancellable: Cancellable)

    /// The list of unresolved cancellables conforming to type 'T' and marked with this token for the associated cancel context
    func cancellables<T: Cancellable>() -> [T]    
}

/// Cancellation error
public enum AsyncError: Error {
    case cancelled
}

/**
 The 'CancelContext' serves to:
 - Track a set of cancellables, providing the ability to cancel the set from any thread at any time
 - Provides cancel tokens ('CancelToken') for finer grained control over cancellation scope
 - Provide the current list of cancellables, allowing extensions of 'CancelContext' to invoke other methods by casting
 - Optionally specify a timeout for its associated cancellables
 Note: A cancellable is considered resolved if either its 'continuation' or its 'error' closure has been invoked.
 */
public class CancelContext: CancelToken {
    /// Cancel all unresolved cancellables
    public func cancel()
    
    /// Returns true if all cancellables are either cancelled or resolved
    public var isCancelled: Bool { get }

    /// Add a cancellable to the cancel context
    public func add(cancellable: Cancellable)

    /// The list of unresolved cancellables conforming to type 'T' for this cancel context
    public func cancellables<T: Cancellable>() -> [T]

    /// Create a token that can be used to associate a task with this context, and can be used
    /// to cancel or set a timeout on only the token's tasks (as a subset of the CancelContext tasks).
    public func makeCancelToken() -> CancelToken
    
    /// All associated unresolved tasks will be cancelled after the given timeout.
    /// Default is no timeout.
    public var timeout: TimeInterval
}

/**
 Return a coroutime context matching the given type 'T' by applying the following checks in sequential order:
 1. If the coroutine context matches type 'T', then it is returned
 2. If the coroutine context is an array, then return the first item in the array matching 'T'
 3. Return 'nil' if there are no matches
 */
public func getCoroutineContext<T>() -> T?

/**
 Begins an asynchronous coroutine, transferring control to 'body' until it
 either suspends itself for the first time with 'suspendAsync' or completes,
 at which point 'beginAsync' returns. If the async process completes by
 throwing an error before suspending itself, 'beginAsync' rethrows the error.

 Calls to 'beginAsync' may be nested, which can be used to provide additional
 coroutine contexts.  Coroutine contexts from outer scopes are inherited by
 concantenating all contexts as an array.  The 'getCoroutineContext' function
 runs through this array looking for a matching type.

 - Parameter asyncContext: the context to use for all encapsulated corotines
 - Parameter error: invoked if 'body' throws an error
 */
public func beginAsync(
    asyncContext: Any? = nil,
    error: ((Error) -> ())? = nil,
    _ body: @escaping () throws -> Void) rethrows

/**
 Suspends the current coroutine and invokes 'body' with the coroutines's
 continuation closure. Invoking 'continuation' will resume the coroutine
 by having 'suspendAsync' return the value passed into the continuation.
 It is a fatal error for 'continuation' to be invoked more than once.
 
 - Note: Cancellation is not supported with this flavor of 'suspendAsync'
 and attempts to access the 'cancelToken' will trigger a fatal error.
 */
public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> ()) -> ()
    ) -> T

/**
 Suspends the current coroutine and invokes 'body' with
 a continuation closure and a failure closure. The coroutine is resumed
 when either the continuation closure or the failure closure is invoked
 by 'body'.  If 'body' invokes the continuation closure then 'suspendAsync'
 will return the provided value.  And if 'body' invokes the failure closure
 then 'suspendAsync' will throw the provided error.
 
 Only one of either the continuation closure or the failure closure may be
 called. It is a fatal error if both are called, or if either is called more
 than once.
 
 Code inside 'body' can support cancellation as follows:
 
     let cancellable: Cancellable = MyCancellableTask()
 
     ...

     // Add 'cancellable' to the 'CancelToken' coroutine context
     if let cancelToken: CancelToken = getCoroutineContext() {
       cancelToken.add(cancellable: cancellable)
     }
 */
public func suspendAsync<T>(
    _ body: @escaping (_ continuation: @escaping (T) -> (),
    _ error: @escaping (Error) -> ()) -> ()
    ) throws -> T
```

### This example shows how to define `URLSession.dataTask` as a coroutine that supports cancellation:

```swift
/// Extend 'URLSessionTask' to be 'Cancellable'
extension URLSessionTask: Cancellable {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

/// Add suspend and resume capabilities to 'CancelToken'
extension CancelToken {
    var urlSessionTasks: [URLSessionTask] { return cancellables() }

    func suspendTasks() { urlSessionTasks.forEach { $0.suspend() } }

    func resumeTasks() { urlSessionTasks.forEach { $0.resume() } }
}

/// Add async version of dataTask(with:) which uses suspendAsync to handle the callback
extension URLSession {
    func dataTask(with request: URLRequest) async
        -> (request: URLRequest, response: URLResponse, data: Data) {
        return await suspendAsync { continuation, error in
            let task = self.dataTask(with: request) { data, response, err in
                if let err = err {
                    error(err)
                } else if let response = response, let data = data {
                    continuation((request, response, data))
                }
            }
            if let cancelToken: CancelToken = getCoroutineContext() {
                cancelToken.add(cancellable: task)
            }
            task.resume()
        }
    }
}
```

### This example demonstrates usage of the `URLSessionTask.dataTask` coroutine including cancellation and timeout 
(from [`main.swift`](https://github.com/dougzilla32/AsyncCancellation/blob/master/Source/main.swift)):

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
        print("Apple search result: \(String(data: result.data, encoding: .utf8))")
    }
} catch {
    print("Apple search error: \(error)")
}

// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call 'cancel' to abort the request
cancelContext.cancel()
```

### Here is the image loading example from the original Async/Await proposal, along with cancellation and timeout abilities
(from [`main.swift`](https://github.com/dougzilla32/AsyncCancellation/blob/master/Source/main.swift)):

```swift
/// For the purpose of this example, send a simple web request rather than loading actual image data
func loadWebResource(_ name: String) throws -> Data {
    let urlSession = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://mydatarepo.com/\(name)")!)
    let result = await urlSession.dataTask(with: request)
    return result.data
}

func decodeImage(_ profile: Data, _ data: Data) async -> Image

func dewarpAndCleanupImage(_ image : Image) async -> Image

/// Image loading example
func processImageData1a() async -> Image {
    let dataResource = Future { await loadWebResource("dataprofile.txt") }
    let imageResource = Future { await loadWebResource("imagedata.dat") }
    
    // ... other stuff can go here to cover load latency...
    
    let imageTmp = await decodeImage(try dataResource.get(), try imageResource.get())
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
    print("Image loading error: \(error)")
}


// Set a timeout (seconds) to prevent hangs
cancelContext.timeout = 30.0

...

// Call cancel to abort the request
cancelContext.cancel()
```

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
