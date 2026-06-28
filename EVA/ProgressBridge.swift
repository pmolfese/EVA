//
//  ProgressBridge.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

nonisolated enum ProgressBridge {
    @MainActor
    static func make<Value: Sendable>(
        apply: @escaping @MainActor (Value) -> Void
    ) -> (continuation: AsyncStream<Value>.Continuation, task: Task<Void, Never>) {
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        let task = Task { @MainActor in
            for await value in stream {
                apply(value)
            }
        }
        return (continuation, task)
    }
}
