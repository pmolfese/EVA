//
//  HistoryTransportCommands.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ⌘Z and ⇧⌘Z, routed to the history rail's transport (ROADMAP RW-1 item 9).
//
//  ## Why the menu, and why this shape
//
//  `EVAHistory`'s header asks for undo to be *navigation* — `stepBack()`, never
//  an appended inverse — and the rail has had working back/forward buttons since
//  it shipped. What it did not have was the keyboard, which on a Mac is where
//  undo actually lives: an operator who applies a filter and immediately wants it
//  gone reaches for ⌘Z, not for a popover.
//
//  Routed through `focusedSceneValue`, the same mechanism `RecordingWindowActions`
//  uses for ⌘W, because the command lives in the menu bar (one per app) while the
//  history lives in a window (one per recording). The focused value is what makes
//  the menu item act on the window the operator is looking at.
//
//  ## Undo *what*, exactly
//
//  Stepping back moves the pointer to the parent node — one step of the
//  processing chain — which is the unit the rail shows and the unit `record()`
//  creates. It is deliberately not a finer-grained edit history: EVA's undoable
//  actions are pipeline stages, and a ⌘Z that sometimes meant "un-apply the
//  filter" and sometimes "un-type that character" would be worse than one that
//  always means the same thing.
//
//  ## The text-field question
//
//  `CommandGroup(replacing: .undoRedo)` takes over the standard Edit-menu items
//  app-wide. EVA's text entry is numeric parameter fields and a handful of name
//  fields, all of which keep AppKit's own field-editor undo (⌘Z inside an active
//  field is handled by the field editor before the menu sees it); what changes is
//  that the *menu items* no longer say "Undo Typing". The trade is deliberate:
//  the menu now describes the thing this app is actually about undoing, and it
//  names the step so there is no ambiguity about what will happen — "Undo Filter"
//  rather than a bare "Undo".
//

import SwiftUI

/// The focused window's history transport, as commands can see it.
///
/// A small struct of two labels and two closures rather than the model itself:
/// the menu needs to know whether each direction is possible and what it is
/// called, and nothing else. Keeping the model out of `FocusedValues` also keeps
/// the menu from being able to mutate history in ways the rail cannot.
struct HistoryTransportActions {
    /// Name of the step stepping back would leave — nil when there is nothing
    /// to undo.
    var undoStepName: String?
    /// Name of the step stepping forward would re-enter — nil when there is
    /// nothing to redo.
    var redoStepName: String?
    var stepBack: () -> Void
    var stepForward: () -> Void

    var canUndo: Bool { undoStepName != nil }
    var canRedo: Bool { redoStepName != nil }

    /// "Undo Filter", or plain "Undo" when there is nothing to name.
    var undoTitle: String {
        undoStepName.map { "Undo \($0)" } ?? "Undo"
    }

    var redoTitle: String {
        redoStepName.map { "Redo \($0)" } ?? "Redo"
    }
}

extension FocusedValues {
    var historyTransportActions: HistoryTransportActions? {
        get { self[HistoryTransportActionsKey.self] }
        set { self[HistoryTransportActionsKey.self] = newValue }
    }

    private struct HistoryTransportActionsKey: FocusedValueKey {
        typealias Value = HistoryTransportActions
    }
}

/// The Edit menu's Undo/Redo pair.
///
/// Disabled — not hidden — when no recording window is focused, so the items
/// stay where a Mac user expects to find them and the shortcut does nothing
/// rather than doing something surprising.
struct HistoryTransportCommands: View {
    @FocusedValue(\.historyTransportActions) private var transport

    var body: some View {
        Button(transport?.undoTitle ?? "Undo") {
            transport?.stepBack()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(transport?.canUndo != true)

        Button(transport?.redoTitle ?? "Redo") {
            transport?.stepForward()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(transport?.canRedo != true)
    }
}
