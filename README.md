## Async/Await with Cancellation

This project contains experimental code demonstrating proposed 'cancellation' abilities for the upcoming async/await Swift language feature.  The 'cancellation' proposal is described below.

To try it out, clone this project and run it! Edit the 'main.swift' source file to try your own sample code and define your own cancellable asynchronous task.  Also, run the tests to see if it is working properly!

The 'Async/Await for Swift' proposal can be found here: https://gist.github.com/lattner/429b9070918248274f25b714dcfc7619

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

#### For 'cancellation' abilities the following additional primitives and protocols as proposed (and experimentally implemented by this project):

```swift
/// Represents a generic asynchronous task
public protocol AsyncTask {
    func cancel()
    var isCancelled: Bool { get }
}

/// A list of async tasks along with the associated error handler
public protocol AsyncTaskList: AsyncTask {
    var tasks: [(task: AsyncTask, error: (Error) -> ())] { get }
}

/// Begins an asynchronous coroutine, transferring control to `body` until it
/// either suspends itself for the first time with `suspendAsync` or completes,
/// at which point `beginAsync` returns. If the async process completes by
/// throwing an error before suspending itself, `beginAsync` rethrows the error.
/// Returns an 'AsyncTaskList' that can be used to cancel the enclosed
/// asynchronous task chain.
func beginAsyncTask(_ body: () async throws -> Void) rethrows -> AsyncTaskList

/// Suspends the current asynchronous task and invokes `body` with the task's
/// continuation and failure closures. Invoking `continuation` will resume the
/// coroutine by having `suspendAsync` return the value passed into the
/// continuation. Invoking `error` will resume the coroutine by having
/// `suspendAsync` throw the error passed into it. Only one of
/// `continuation` and `error` may be called; it is a fatal error if both are
/// called, or if either is called more than once. Invoking 'task' will add the
/// given 'AsyncTask' to the chain of tasks enclosed by 'beginAsyncTask', or
/// does nothing if enclosed by 'beginAsync'.
func suspendAsync<T>(
  _ body: (_ continuation: @escaping (T) -> (),
           _ error: @escaping (Error) -> (),
           _ task: @esccaping (AsyncTask) -> ()) -> ()
) async throws -> T
```

#### This code shows how to extend `AsyncTask` and how to define a cancellable async method:

```swift
/// Add 'suspend' and 'resume' capabilities to AsyncTaskList
extension AsyncTaskList {
    func suspend() { tasks.forEach { ($0.task as? URLSessionTask)?.suspend() } }
    func resume() { tasks.forEach { ($0.task as? URLSessionTask)?.resume() } }
}

/// Extend URLSessionTask to be an AsyncTask
extension URLSessionTask: AsyncTask {
    public var isCancelled: Bool {
        return state == .canceling || (error as NSError?)?.code == NSURLErrorCancelled
    }
}

/// Add async version of dataTask(with:) which uses suspendAsync to handle the callback
extension URLSession {
    func dataTask(with request: URLRequest) async -> (request: URLRequest, response: URLResponse, data: Data) {
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

#### This code demonstrates how to invoke the async varient of `URLSessionTask.dataTask`:

```swift
import Foundation

let taskList = beginAsyncTask {
    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "https://itunes.apple.com/search")!)
    do {
        let result = await session.dataTask(with: request)
        if let resultString = String(data: result.data, encoding: .utf8) {
            print("Apple search result: \(resultString)")
        } else {
            print("Apple search result: \(result)")
        }
    } catch {
        print("Apple search error: \(error)")
    }
}

// ...

taskList.cancel()
```
