//
//  FIFDocument.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  What *is* this `.fif`?
//
//  FIF is a container, not a format: MNE writes recordings, head models,
//  coordinate transforms, digitizations, forward and inverse operators, source
//  spaces, covariances, ICA decompositions and event lists all with the same
//  extension, distinguished only by filename convention (`-epo`, `-bem-sol`,
//  `-trans`, …) and by which blocks are inside. Conventions get broken; block
//  structure does not, so this classifies on structure and uses the filename
//  only to break ties.
//
//  Everything that opens a `.fif` needs this: Quick Look, to decide what picture
//  to draw, and the recording importer, to say "this is a head model, not a
//  recording" instead of failing with a missing-tag error.
//

import Foundation

nonisolated enum FIFDocument {

    enum Kind: String, Sendable, CaseIterable {
        case continuousRecording
        case epochedRecording
        case averagedRecording
        case headModel
        case coordinateTransform
        case digitization
        case forwardSolution
        case inverseOperator
        case sourceSpace
        case covariance
        case independentComponents
        case events
        case unknown

        var displayName: String {
            switch self {
            case .continuousRecording: return "Continuous recording"
            case .epochedRecording: return "Epoched recording"
            case .averagedRecording: return "Averaged recording"
            case .headModel: return "BEM head model"
            case .coordinateTransform: return "Coordinate transform"
            case .digitization: return "Digitization"
            case .forwardSolution: return "Forward solution"
            case .inverseOperator: return "Inverse operator"
            case .sourceSpace: return "Source space"
            case .covariance: return "Covariance"
            case .independentComponents: return "ICA decomposition"
            case .events: return "Event list"
            case .unknown: return "FIF file"
            }
        }

        /// True for the three shapes `FIFRecording` reads.
        var isRecording: Bool {
            self == .continuousRecording || self == .epochedRecording || self == .averagedRecording
        }

        /// The kind as a noun phrase, for "X is a …" — `displayName` is a
        /// title and reads wrong mid-sentence, and lowercasing it would turn
        /// "BEM" and "ICA" into "bem" and "ica".
        var noun: String {
            switch self {
            case .continuousRecording: return "continuous recording"
            case .epochedRecording: return "epoched recording"
            case .averagedRecording: return "averaged recording"
            case .headModel: return "BEM head model"
            case .coordinateTransform: return "head↔MRI coordinate transform"
            case .digitization: return "digitization"
            case .forwardSolution: return "forward solution"
            case .inverseOperator: return "inverse operator"
            case .sourceSpace: return "source space"
            case .covariance: return "noise covariance matrix"
            case .independentComponents: return "saved ICA decomposition"
            case .events: return "event list"
            case .unknown: return "FIF file"
            }
        }

        /// `noun` with its article, so callers do not write "a event list".
        /// A first-letter vowel test is enough for every name here: "BEM" is
        /// spoken "bem" and takes "a", "ICA" is spoken "eye-see-ay" and takes
        /// "an", and both fall out correctly.
        var nounWithArticle: String {
            let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
            return (vowels.contains(Character(noun.prefix(1).lowercased())) ? "an " : "a ") + noun
        }

        /// What to *do* about it — advice only, since whatever shows this has
        /// already said what the file is.
        var importAdvice: String? {
            switch self {
            case .headModel:
                return "Open it in EVA Resolve's head-model window."
            case .coordinateTransform:
                return "It belongs to a head model rather than being one; open the head model instead."
            case .digitization:
                return "It holds electrode and fiducial positions, but no signal."
            case .forwardSolution, .inverseOperator, .sourceSpace:
                return "It is source-analysis output; EVA Resolve is where it belongs."
            case .covariance, .independentComponents:
                return "Open the recording it was computed from instead."
            case .events:
                return "Open the recording it belongs to; EVA reads its events from there."
            default:
                return nil
            }
        }
    }

    /// One block in the file, with how many of it there are — the outline shown
    /// for a file EVA has no dedicated picture for.
    struct BlockCount: Sendable, Identifiable, Equatable {
        var name: String
        var count: Int
        var id: String { name }
    }

    /// A named scalar worth putting on screen for a document with no picture —
    /// "Covariance dimension 12" says more about a `-cov.fif` than its byte
    /// count does.
    struct Value: Sendable, Identifiable, Equatable {
        var name: String
        var value: String
        var id: String { name }
    }

    struct Outline: Sendable {
        var kind: Kind
        var blocks: [BlockCount]
        var tagCount: Int
        /// The largest tag in the file, which for most FIF documents is the
        /// thing the file exists to carry.
        var largestTag: (name: String, bytes: Int)?
        /// Headline scalars the file happens to declare.
        var values: [Value]
    }

    /// Small scalar tags worth surfacing, whatever the document turns out to be.
    private static let scalarTags: [(kind: Int32, name: String, isFloat: Bool)] = [
        (FIF.nchan, "Channels", false),
        (FIF.sfreq, "Sampling rate", true),
        (3531, "Covariance dimension", false),
        (3530, "Covariance kind", false),
        (3512, "Source points", false),
        (3521, "Source orientation", false),
        (FIF.nave, "Averaged trials", false),
    ]

    static func classify(_ url: URL) throws -> Kind {
        try outline(FIFReader(url: url), filename: url.lastPathComponent).kind
    }

    static func outline(_ reader: FIFReader, filename: String) -> Outline {
        var counts: [Int32: Int] = [:]
        for tag in reader.tags where tag.kind == FIF.blockStart {
            counts[tag.int32(), default: 0] += 1
        }
        func has(_ block: Int32) -> Bool { (counts[block] ?? 0) > 0 }

        // Most specific first: an `-ave.fif` also has FIFFB_PROCESSED_DATA, and
        // an epochs file also has FIFFB_MEAS.
        let kind: Kind
        if has(FIF.blockMNEICA) { kind = .independentComponents }
        else if has(FIF.blockMNEInverseSolution) { kind = .inverseOperator }
        else if has(FIF.blockMNEForwardSolution) { kind = .forwardSolution }
        else if has(FIF.blockMNECovariance) { kind = .covariance }
        else if has(FIF.blockEvoked) { kind = .averagedRecording }
        else if has(FIF.blockMNEEpochs) { kind = .epochedRecording }
        else if has(FIF.blockRawData) || has(FIF.blockContinuousData) || has(FIF.blockIASRawData) {
            kind = .continuousRecording
        }
        else if has(FIF.blockBEM) || has(FIF.blockBEMSurf) { kind = .headModel }
        else if has(FIF.blockMNESourceSpace) { kind = .sourceSpace }
        else if has(FIF.blockMNEEvents) { kind = .events }
        else if has(FIF.blockIsotrak) { kind = .digitization }
        else if reader.first(kind: FIF.coordTrans) != nil { kind = .coordinateTransform }
        else if has(FIF.blockMeasInfo) {
            // Measurement info with no data block: a header-only file, but the
            // filename usually says what it was meant to be.
            kind = filename.lowercased().contains("-eve") ? .events : .unknown
        }
        else { kind = .unknown }

        var blocks: [BlockCount] = []
        blocks.reserveCapacity(counts.count)
        for (block, count) in counts {
            blocks.append(BlockCount(name: FIF.blockName(block), count: count))
        }
        blocks.sort { left, right in
            left.count == right.count ? left.name < right.name : left.count > right.count
        }

        var largest: (name: String, bytes: Int)?
        for tag in reader.tags where tag.kind != FIF.blockStart && tag.kind != FIF.blockEnd {
            if tag.data.count > (largest?.bytes ?? 0) {
                largest = (FIF.tagName(tag.kind), tag.data.count)
            }
        }
        var values: [Value] = []
        for entry in scalarTags {
            guard let tag = reader.first(kind: entry.kind), tag.data.count >= 4 else { continue }
            let text = entry.isFloat
                ? String(format: "%g", tag.floatValue)
                : String(tag.intValue)
            values.append(Value(name: entry.name, value: text))
        }

        return Outline(kind: kind, blocks: blocks, tagCount: reader.tags.count,
                       largestTag: largest, values: values)
    }
}

extension FIF {
    nonisolated static let blockMNE: Int32 = 350
    nonisolated static let blockMNESourceSpace: Int32 = 351
    nonisolated static let blockMNEForwardSolution: Int32 = 352
    nonisolated static let blockMNECovariance: Int32 = 355
    nonisolated static let blockMNEInverseSolution: Int32 = 356
    nonisolated static let blockMNENamedMatrix: Int32 = 357
    nonisolated static let blockMNEICA: Int32 = 374
    nonisolated static let blockMNEMetadata: Int32 = 3811

    /// Human-readable names for the blocks and tags a preview is likely to show.
    /// Anything unnamed prints its number, which is still more use than nothing.
    /// A table rather than a `switch`: the switch form of this compiled so
    /// slowly the type checker gave up on it.
    private nonisolated static let blockNames: [Int32: String] = [
        blockMeas: "Measurement",
        blockMeasInfo: "Measurement info",
        blockRawData: "Raw data",
        blockProcessedData: "Processed data",
        blockEvoked: "Evoked",
        blockAspect: "Aspect",
        blockSubject: "Subject",
        blockIsotrak: "Digitization",
        blockContinuousData: "Continuous data",
        blockIASRawData: "IAS raw data",
        blockProj: "Projections",
        blockProjItem: "Projection item",
        blockBEM: "BEM",
        blockBEMSurf: "BEM surface",
        blockBadChannels: "Bad channels",
        blockMNE: "MNE",
        blockMNESourceSpace: "Source space",
        blockMNEForwardSolution: "Forward solution",
        blockMNECovariance: "Covariance",
        blockMNEInverseSolution: "Inverse operator",
        blockMNENamedMatrix: "Named matrix",
        blockMNEEvents: "Events",
        blockMNEEpochs: "Epochs",
        blockMNEICA: "ICA",
        blockMNEAnnotations: "Annotations",
        blockMNEMetadata: "Epoch metadata",
    ]

    private nonisolated static let tagNames: [Int32: String] = [
        dataBuffer: "Data buffer",
        epochData: "Epoch data",
        chInfo: "Channel info",
        bemPotSolution: "BEM solution",
        bemSurfNodes: "Surface vertices",
        bemSurfTriangles: "Surface triangles",
        coordTrans: "Coordinate transform",
        digPoint: "Digitizer point",
        3520: "Forward solution",
        3607: "ICA matrix",
        mneChNameList: "Channel names",
        mneRowNames: "Row names",
        mneEventList: "Event list",
        bemSurfNormals: "Surface normals",
        3530: "Covariance kind",
        3531: "Covariance dimension",
        3532: "Covariance matrix",
        3533: "Covariance diagonal",
        3512: "Source-space points",
        3521: "Source orientation",
    ]

    nonisolated static func blockName(_ kind: Int32) -> String { blockNames[kind] ?? "Block \(kind)" }
    nonisolated static func tagName(_ kind: Int32) -> String { tagNames[kind] ?? "Tag \(kind)" }
}
