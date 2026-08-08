//
//  main.swift
//  EVA BIDS
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Command-line converter between EVA's native MFF format and BIDS-EEG
//  datasets: `to-bids` (MFF -> BIDS/EDF), `from-bids` (BIDS/EDF -> MFF), and
//  `inspect-bids` (verify a BIDS-EEG recording's sidecars).
//

import Foundation

func usage() -> String {
    """
    Usage:
      eva-bids to-bids <input.mff> --bids-root <dir> --subject <label> [options]
      eva-bids from-bids <eeg-file-or-directory> --output <output.mff> [options]
      eva-bids inspect-bids <eeg-file-or-directory> [options]

    to-bids:
      --bids-root <dir>           BIDS dataset root to write into. Required.
      --subject <label>           Subject label, no "sub-" prefix (e.g. 01). Required.
      --session <label>           Session label, no "ses-" prefix.
      --task <label>              Task label (default "task").
      --run <n>                  Run index, written as run-<NN>.
      --power-line-freq <hz>      PowerLineFrequency for eeg.json (default 60).
      --eeg-reference <name>      EEGReference for eeg.json (default "n/a").
      --overwrite                 Replace an existing EDF/sidecars.
      --verbose                   Print step-by-step detail.

    from-bids:
      <eeg-file-or-directory>     A *_eeg.edf file, or a directory to search
                                   for exactly one (e.g. a sub-XX/eeg folder).
      --output <output.mff>       Output MFF package path. Required.
      --overwrite                 Replace an existing output package.
      --verbose                   Print step-by-step detail.

    inspect-bids:
      <eeg-file-or-directory>     A *_eeg.edf file, or a directory to search
                                   (recursively) for one or more recordings.
      --subject <label>           Only inspect recordings for this subject.
      --session <label>           Only inspect recordings for this session.
      --task <label>              Only inspect recordings for this task.
      --run <n>                  Only inspect recordings for this run.
      --verbose                   Print step-by-step detail.

    Notes:
      BIDS metadata (channels.tsv/events.tsv/electrodes.tsv/coordsystem.json)
      carries channel types and events; the EDF itself has no EDF+ annotations
      channel. eva.xml and log_eva_*.txt are stashed under
      code/eva/sub-.../[ses-.../]eeg/ by to-bids, outside the validated BIDS
      tree, and restored by from-bids when present.
    """
}

func value(at index: Int, in arguments: [String], flag: String) throws -> String {
    guard arguments.indices.contains(index) else {
        throw EVABIDSError.usage("Missing value for \(flag).")
    }
    return arguments[index]
}

func doubleValue(at index: Int, in arguments: [String], flag: String) throws -> Double {
    let raw = try value(at: index, in: arguments, flag: flag)
    guard let value = Double(raw) else {
        throw EVABIDSError.usage("Expected a number for \(flag), got \(raw).")
    }
    return value
}

func intValue(at index: Int, in arguments: [String], flag: String) throws -> Int {
    let raw = try value(at: index, in: arguments, flag: flag)
    guard let value = Int(raw) else {
        throw EVABIDSError.usage("Expected an integer for \(flag), got \(raw).")
    }
    return value
}

func parseToBIDS(_ arguments: [String]) throws -> ToBIDSOptions {
    var inputPath: String?
    var bidsRoot: String?
    var subject: String?
    var session: String?
    var task = "task"
    var run: Int?
    var powerLineFrequency = 60.0
    var eegReference = "n/a"
    var overwrite = false
    var verbose = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help": throw EVABIDSError.helpRequested
        case "--bids-root": index += 1; bidsRoot = try value(at: index, in: arguments, flag: argument)
        case "--subject": index += 1; subject = try value(at: index, in: arguments, flag: argument)
        case "--session": index += 1; session = try value(at: index, in: arguments, flag: argument)
        case "--task": index += 1; task = try value(at: index, in: arguments, flag: argument)
        case "--run": index += 1; run = try intValue(at: index, in: arguments, flag: argument)
        case "--power-line-freq": index += 1; powerLineFrequency = try doubleValue(at: index, in: arguments, flag: argument)
        case "--eeg-reference": index += 1; eegReference = try value(at: index, in: arguments, flag: argument)
        case "--overwrite": overwrite = true
        case "--verbose": verbose = true
        default:
            if argument.hasPrefix("-") { throw EVABIDSError.usage("Unknown flag: \(argument)") }
            guard inputPath == nil else { throw EVABIDSError.usage("Unexpected extra argument: \(argument)") }
            inputPath = argument
        }
        index += 1
    }

    guard let inputPath else { throw EVABIDSError.usage("Missing input .mff path.") }
    guard let bidsRoot else { throw EVABIDSError.usage("Missing required --bids-root.") }
    guard let subject, !subject.isEmpty else { throw EVABIDSError.usage("Missing required --subject.") }

    return ToBIDSOptions(
        inputURL: absoluteFileURL(inputPath),
        bidsRootURL: absoluteFileURL(bidsRoot),
        entities: BIDSEntities(subject: subject, session: session, task: task, run: run),
        powerLineFrequency: powerLineFrequency,
        eegReference: eegReference,
        overwrite: overwrite,
        verbose: verbose
    )
}

func parseFromBIDS(_ arguments: [String]) throws -> FromBIDSOptions {
    var inputPath: String?
    var outputPath: String?
    var overwrite = false
    var verbose = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help": throw EVABIDSError.helpRequested
        case "--output": index += 1; outputPath = try value(at: index, in: arguments, flag: argument)
        case "--overwrite": overwrite = true
        case "--verbose": verbose = true
        default:
            if argument.hasPrefix("-") { throw EVABIDSError.usage("Unknown flag: \(argument)") }
            guard inputPath == nil else { throw EVABIDSError.usage("Unexpected extra argument: \(argument)") }
            inputPath = argument
        }
        index += 1
    }

    guard let inputPath else { throw EVABIDSError.usage("Missing input EEG file or directory path.") }
    guard let outputPath else { throw EVABIDSError.usage("Missing required --output.") }

    return FromBIDSOptions(
        inputURL: absoluteFileURL(inputPath),
        outputURL: absoluteFileURL(outputPath),
        overwrite: overwrite,
        verbose: verbose
    )
}

func parseInspectBIDS(_ arguments: [String]) throws -> InspectBIDSOptions {
    var inputPath: String?
    var subject: String?
    var session: String?
    var task: String?
    var run: Int?
    var verbose = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help": throw EVABIDSError.helpRequested
        case "--subject": index += 1; subject = try value(at: index, in: arguments, flag: argument)
        case "--session": index += 1; session = try value(at: index, in: arguments, flag: argument)
        case "--task": index += 1; task = try value(at: index, in: arguments, flag: argument)
        case "--run": index += 1; run = try intValue(at: index, in: arguments, flag: argument)
        case "--verbose": verbose = true
        default:
            if argument.hasPrefix("-") { throw EVABIDSError.usage("Unknown flag: \(argument)") }
            guard inputPath == nil else { throw EVABIDSError.usage("Unexpected extra argument: \(argument)") }
            inputPath = argument
        }
        index += 1
    }

    guard let inputPath else { throw EVABIDSError.usage("Missing EEG file or directory path.") }

    return InspectBIDSOptions(
        inputURL: absoluteFileURL(inputPath),
        subject: subject,
        session: session,
        task: task,
        run: run,
        verbose: verbose
    )
}

func run() throws -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { throw EVABIDSError.usage("Missing subcommand.") }
    let subcommand = arguments.removeFirst()

    switch subcommand {
    case "to-bids":
        try ToBIDS.run(try parseToBIDS(arguments))
        return 0
    case "from-bids":
        try FromBIDS.run(try parseFromBIDS(arguments))
        return 0
    case "inspect-bids":
        let passed = try InspectBIDS.run(try parseInspectBIDS(arguments))
        return passed ? 0 : 1
    case "-h", "--help":
        throw EVABIDSError.helpRequested
    default:
        throw EVABIDSError.usage("Unknown subcommand: \(subcommand)")
    }
}

do {
    let exitCode = try run()
    Foundation.exit(exitCode)
} catch EVABIDSError.helpRequested {
    writeStdoutLine(usage())
} catch {
    writeStderr("error: \(error.localizedDescription)\n\n")
    writeStderr(usage())
    writeStderr("\n")
    Foundation.exit(1)
}
