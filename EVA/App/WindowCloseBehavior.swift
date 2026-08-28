//
//  WindowCloseBehavior.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Quitting when the last window closes — the second half of a two-step exit.
//
//  The whole flow is:
//
//    recording open → "discard unsaved work?" → blank drop window → close → quit
//
//  The first three steps were already built: `ContentView`'s `WindowAccessor`
//  intercepts `windowShouldClose`, raises the discard sheet while a recording is
//  open, and vetoes the close so the window survives as an empty drop target.
//  Only the last step was missing, and it is this file.
//
//  ## Why turning this on is safe here
//
//  `applicationShouldTerminateAfterLastWindowClosed` is normally a blunt setting:
//  it makes one click on the close button end the app, discarding whatever was
//  open. Here it cannot, because `WindowAccessor` has already refused to close a
//  window with a recording in it. Termination is reachable only from the empty
//  state, which the user got to by answering a confirmation.
//
//  The two pieces have to stay paired. Remove the interception and this flag
//  becomes a way to lose a session's processing to one misplaced click.
//
//  ## Do not add a second window delegate
//
//  The first version of this file carried its own `windowShouldClose`
//  interceptor, written without having found `WindowAccessor` first. Both
//  installed themselves as the window delegate and each forwarded unknown
//  selectors to the other, so `responds(to:)` recursed until the stack
//  overflowed: EVA took a SIGSEGV during launch, and the test host died before
//  XCTest could connect to it — which surfaces as "the test runner crashed before
//  establishing connection" rather than as anything mentioning windows.
//
//  `WindowAccessor.Coordinator` is the one window delegate. Anything else that
//  needs a window callback belongs inside it.
//

import AppKit

/// Quits when the last window closes.
final class EVAAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
