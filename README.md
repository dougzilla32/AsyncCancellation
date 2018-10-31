# Async Cancellation

This project contains experimental code demonstrating 'cancellation' abilities for the upcoming async/await Swift language feature.  The new 'cancellation' feature is described below.

To try it out, clone this project and edit the 'main.swift' source file to add your own sample code.  Also, run the tests to see if it works!

The 'Async/Await for Swift' proposal can be found here: https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619

The original proposal includes the following primitives:

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

For 'cancellation' abilities, I am proposing the following additional primitives and protocols:

```swift
/// Represents a generic asynchronous task
public protocol AsyncTask {
    func cancel()
    var isCancelled: Bool { get }
    func suspend()
    func resume()
}

/// 'suspend' and 'resume' are optional
extension AsyncTask {
    func suspend() { }
    func resume() { }
}

public enum AsyncError: Error {
    case cancelled
}

/// Same as 'beginAsync(_ body:)', with the addition of an 'AsyncTask' return value.
/// The returned 'AsyncTask' can be used to 'cancel', 'suspend' or 'resume' the enclosed
/// chain of asynchronous tasks.
@discardableResult
public func beginAsyncTask(_ body: () async throws -> Void) rethrows -> AsyncTask

/// Same as suspendAsync(_ body: (_ continuation:_ error:)), with the addition of a 'task'
/// parameter to the 'body' function.  Invoking 'task' will add the given 'AsyncTask' to
/// the chain of tasks within the current 'beginAsync' closure.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> (),
           _ error: @escaping (Error) -> (),
           _ task: @escaping (AsyncTask) -> ()) -> ()
) async throws -> T
```

The 'cancellation' extension is demonstrated by this example adding async/await with cancellation to URLSessionTask:

```swift
/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: AsyncTask {
    // URLSessionTask defines a 'cancel' function, so no need to define one here
    
    // Add an 'isCancelled' property to indicate if the URLSessionTask has been successfully cancelled
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

extension URLSession {
    func asyncDataTask(with request: URLRequest) throws -> (URLRequest, URLResponse, Data) {
        return await suspendAsync { continuation, error, task in
            let dataTask = self.dataTask(with: request) { data, response, err in
                if let err = err {
                    error(err)
                } else if let response = response, let data = data {
                    continuation((request, response, data))
                }
            }
            task(dataTask)
            dataTask.resume()
        }
    }
}
```