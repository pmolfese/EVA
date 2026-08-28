//
//  CleaningVarianceLedger.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Chronological record of what each cleaning stage removed from this
//  recording. See [[CleaningVarianceAccount]] for the metric itself.
//
//  ## Why a ledger rather than a property per stage
//
//  Every cleaning stage could carry its own account, and the audit log could
//  ask each view model in turn. That was the first design and it was worse in
//  two ways. It puts the ordering in the reader — the audit log would decide
//  what order stages ran in, which it does not know — and it makes "add a
//  stage" mean "add a parameter to every reader". A single append-only ledger
//  keeps the order the stages actually ran in, which is the only order worth
//  reporting, and leaves readers untouched when a stage is added.
//
//  ## Lifetime
//
//  Entries describe a specific signal. When the base signal changes underneath
//  the pipeline, they describe data that no longer exists, so
//  `PipelineInvalidation` clears them along with the stage outputs they belong
//  to. A stale variance line is worse than a missing one: it looks like
//  provenance.
//

import Foundation

@Observable
final class CleaningVarianceLedger {

    /// Accounts in the order the stages ran.
    private(set) var accounts: [CleaningVarianceAccount] = []

    /// Appends an account, replacing any earlier one from the same stage.
    ///
    /// Re-running a stage supersedes its previous result rather than adding a
    /// second line: the log describes the recording's current state, and two
    /// lines for one stage read as two passes having been applied. The
    /// replacement keeps the *new* position in the order, because a re-run is
    /// when the stage most recently touched the data.
    func record(_ account: CleaningVarianceAccount) {
        accounts.removeAll { $0.stageName == account.stageName }
        accounts.append(account)
    }

    /// Drops the account for one stage, for when that stage's output is
    /// invalidated on its own.
    func clear(stageName: String) {
        accounts.removeAll { $0.stageName == stageName }
    }

    func removeAll() {
        accounts.removeAll()
    }

    var isEmpty: Bool { accounts.isEmpty }

    /// Audit-log lines, in stage order, in the `log_eva_*.txt` house style.
    var auditLogLines: [String] {
        accounts.map(\.auditLogLine)
    }
}
