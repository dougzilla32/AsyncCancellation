//
// 'Future' example proof of concept from 'Async/Await for Swift' by Chris Lattner and Joe Groff
// https://gist.github.com/dougzilla32/ce47a72067f9344742e10020ad4c8c41
//
import Foundation

class Future<T> {
    private enum Result { case error(Error), value(T) }
    private var result: Result? = nil
    private var awaiters: [(Result) -> Void] = []
    
    // Fulfill the future, and resume any coroutines waiting for the value.
    func fulfill(_ value: T) {
        precondition(self.result == nil, "can only be fulfilled once")
        let result: Result = .value(value)
        self.result = result
        for awaiter in awaiters {
           DispatchQueue.global(qos: .default).async {
                awaiter(result)
           }
        }
        awaiters = []
    }
    
    // Mark the future as having failed to produce a result.
    func fail(_ error: Error) {
        precondition(self.result == nil, "can only be fulfilled once")
        let result: Result = .error(error)
        self.result = result
        for awaiter in awaiters {
            awaiter(result)
        }
        awaiters = []
    }
    
    func get() /* async */ throws -> T {
        switch result {
        // Throw/return the result immediately if available.
        case .error(let e)?:
            throw e
        case .value(let v)?:
            return v
        // Wait for the future if no result has been fulfilled.
        case nil:
            return try /* await */ suspendAsync { continuation, error in
                self.awaiters.append({
                    switch $0 {
                    case .error(let e): error(e)
                    case .value(let v): continuation(v)
                    }
                })
            }
        }
    }
    
    // Create an unfulfilled future.
    init() {}
    
    // Begin a coroutine by invoking `body`, and create a future representing
    // the eventual result of `body`'s completion.
    convenience init(_ body: @escaping () throws /* async */ -> T) {
        self.init()
        beginAsync {
            do {
                self.fulfill(try /* await */ body())
            } catch {
                self.fail(error)
            }
        }
    }
}
