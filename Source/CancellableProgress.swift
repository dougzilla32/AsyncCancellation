//
//  CancellableProgress.swift
//  AsyncCancellation
//
//  Created by Doug on 12/10/18.
//

import Foundation

extension Progress: Cancellable { }

extension CancelToken {
    var progressables: [Progress] { return cancellables() }
    
    func pauseProgress() { progressables.forEach { $0.pause() } }

    func resumeProgress() { progressables.forEach { $0.resume() } }

    var isProgressPaused: Bool {
        var rval = true
        progressables.forEach {
            if !$0.isPaused {
                rval = false
                return
            }
        }
        return rval
    }
}
