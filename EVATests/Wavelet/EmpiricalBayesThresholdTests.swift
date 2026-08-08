//
//  EmpiricalBayesThresholdTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Validates `EmpiricalBayesThreshold` — EVA's independent Swift implementation
//  of Johnstone & Silverman (2005) empirical Bayes thresholding, written from
//  the paper — against golden values produced by the authors' own R package,
//  EbayesThresh (CRAN, GPL >= 2), with `prior = "cauchy"`.
//
//  The package is used only as an external oracle: the fixture records numbers
//  it printed. No code was ported from it, and none of its source is reproduced
//  here or in the implementation, so EVA takes on no licence obligation. If a
//  comparison here fails, the fix belongs in the Swift, against the paper.
//
//  Regenerate the fixture with:
//      Rscript Tools/generate_ebayes_reference.R
//

import Testing
import Foundation
@testable import EVA

struct EmpiricalBayesThresholdTests {

    // MARK: - Fixture

    private struct Reference: Decodable {
        struct ScalarWeight: Decodable { let t: Double; let w: Double }
        struct ScalarThreshold: Decodable { let w: Double; let t: Double }
        struct Band: Decodable {
            let name: String
            let note: String
            let sigma: Double
            let weight: Double
            let normalizedThreshold: Double
            let threshold: Double
            let x: [Double]
        }
        let oracle: String
        let weightFromThreshold: [ScalarWeight]
        let thresholdFromWeight: [ScalarThreshold]
        let bands: [Band]
    }

    private static let reference: Reference = {
        let data = try! Data(contentsOf: Fixtures.url("ebayes-thresh-reference.json"))
        return try! JSONDecoder().decode(Reference.self, from: data)
    }()

    private func band(_ name: String) -> Reference.Band {
        let match = Self.reference.bands.first { $0.name == name }
        precondition(match != nil, "no reference band named \(name)")
        return match!
    }

    private func relativeError(_ value: Double, _ expected: Double) -> Double {
        abs(value - expected) / max(abs(expected), 1e-12)
    }

    // MARK: - Scalar relations against R

    /// w(t), the closed-form inverse of the posterior-median threshold. Both
    /// sides evaluate a formula rather than searching, so agreement should be
    /// near machine precision.
    @Test func weightFromThresholdMatchesR() {
        for row in Self.reference.weightFromThreshold {
            let w = EmpiricalBayesThreshold.weight(forThreshold: row.t)
            #expect(
                relativeError(w, row.w) < 1e-11,
                "t=\(row.t): got \(w), R gives \(row.w)"
            )
        }
    }

    /// t(w). Both sides bisect, so the tolerance covers the two search
    /// terminations rather than the mathematics.
    @Test func thresholdFromWeightMatchesR() {
        for row in Self.reference.thresholdFromWeight {
            let t = EmpiricalBayesThreshold.threshold(forWeight: row.w, upperBound: 8)
            #expect(
                relativeError(t, row.t) < 1e-6,
                "w=\(row.w): got \(t), R gives \(row.t)"
            )
        }
    }

    /// The two relations invert each other over the whole practical range.
    /// A pure self-consistency check — it holds even if both are wrong — but it
    /// pins the closed form and the root-find to each other.
    @Test func weightAndThresholdInvertEachOther() {
        for t in stride(from: 0.1, through: 5.5, by: 0.1) {
            let w = EmpiricalBayesThreshold.weight(forThreshold: t)
            let back = EmpiricalBayesThreshold.threshold(forWeight: w, upperBound: 8)
            #expect(relativeError(back, t) < 1e-6, "t=\(t) round-tripped to \(back)")
        }
    }

    // MARK: - Per-band agreement with R

    /// σ must match R's `mad()` — the fit is read off the standardised band, so
    /// a different scale estimate would move everything downstream.
    @Test func robustSigmaMatchesRMad() {
        for band in Self.reference.bands {
            let sigma = EmpiricalBayesThreshold.robustSigma(band.x)
            #expect(
                relativeError(sigma, band.sigma) < 1e-12,
                "\(band.name): sigma \(sigma), R gives \(band.sigma)"
            )
        }
    }

    /// The marginal-MLE weight, the substantive step. Tolerance is looser than
    /// the closed forms because both sides locate the root of S(w) by their own
    /// bisection.
    @Test func fittedWeightMatchesR() {
        for band in Self.reference.bands {
            let sigma = EmpiricalBayesThreshold.robustSigma(band.x)
            let weight = EmpiricalBayesThreshold.fittedWeight(
                band.x.map { $0 / sigma }, populationCount: band.x.count)
            #expect(
                relativeError(weight, band.weight) < 1e-6,
                "\(band.name) (\(band.note)): weight \(weight), R gives \(band.weight)"
            )
        }
    }

    /// The whole pipeline — σ, weight, threshold, rescale — end to end.
    ///
    /// `offset-noise` is excluded and checked separately: there the fit
    /// saturates at w = 1, where the estimator's threshold is 0. R's `tfromw`
    /// reports the floor of its own search bracket (1e-5) rather than 0, so the
    /// two are not comparable as numbers; see `saturatedFitReportsNoEstimate`.
    @Test func thresholdMatchesR() {
        for band in Self.reference.bands where band.name != "offset-noise" {
            let threshold = EmpiricalBayesThreshold.threshold(for: band.x)
            #expect(
                relativeError(threshold, band.threshold) < 1e-6,
                "\(band.name) (\(band.note)): threshold \(threshold), R gives \(band.threshold)"
            )
        }
    }

    /// A band in which nothing looks null drives the weight to its upper limit,
    /// w = 1 — a prior with no atom at zero, whose posterior median never hits
    /// zero and whose threshold is therefore 0. EVA reports that as "no
    /// estimate" (0) so callers fall back rather than gating the entire band.
    @Test func saturatedFitReportsNoEstimate() {
        let band = band("offset-noise")
        #expect(band.weight == 1, "fixture no longer saturates; pick another band")
        let sigma = EmpiricalBayesThreshold.robustSigma(band.x)
        let weight = EmpiricalBayesThreshold.fittedWeight(
            band.x.map { $0 / sigma }, populationCount: band.x.count)
        #expect(weight == 1)
        #expect(EmpiricalBayesThreshold.threshold(for: band.x) == 0)
    }

    /// The threshold is equivariant in the band's units: the fixture holds one
    /// band and the same band scaled by 137, and R fits them to the same weight.
    @Test func thresholdScalesWithTheBand() {
        let base = band("scale-base")
        let scaled = band("scale-137x")
        let baseThreshold = EmpiricalBayesThreshold.threshold(for: base.x)
        let scaledThreshold = EmpiricalBayesThreshold.threshold(for: scaled.x)
        #expect(relativeError(scaledThreshold, 137 * baseThreshold) < 1e-9)
        #expect(relativeError(scaledThreshold, scaled.threshold) < 1e-6)
    }

    // MARK: - Behaviour that motivated the work

    /// On pure noise the constrained maximum sits at the lower end of the
    /// weight bracket, so the gate is exactly the universal threshold — several
    /// σ out, keeping essentially nothing. This is the property that keeps the
    /// Reducer from subtracting ongoing EEG.
    @Test(arguments: ["gaussian-64", "gaussian-256", "gaussian-1024", "gaussian-4096"])
    func pureNoiseGatesAtTheUniversalThreshold(name: String) {
        let band = band(name)
        let sigma = EmpiricalBayesThreshold.robustSigma(band.x)
        let universal = EmpiricalBayesThreshold.universalThreshold(populationCount: band.x.count)
        let threshold = EmpiricalBayesThreshold.threshold(for: band.x)

        #expect(relativeError(threshold, sigma * universal) < 1e-9)
        #expect(threshold / sigma > 2.8, "gate should sit well out in the tail")

        let survivors = band.x.filter { abs($0) > threshold }.count
        #expect(
            Double(survivors) / Double(band.x.count) < 0.01,
            "\(name): \(survivors) of \(band.x.count) noise coefficients cleared the gate"
        )
    }

    /// Sparse outliers are what the Reducer is meant to catch, and they must
    /// clear the fitted gate while the surrounding noise does not.
    @Test(arguments: ["sparse-1", "sparse-5", "sparse-25"])
    func sparseOutliersClearTheGate(name: String) {
        let band = band(name)
        let threshold = EmpiricalBayesThreshold.threshold(for: band.x)
        let survivors = band.x.enumerated().filter { abs($0.element) > threshold }
        let injected = band.x.filter { abs($0) >= 4.9 }.count

        #expect(survivors.count >= injected, "\(name): the injected spikes must survive")
        #expect(
            survivors.count <= injected + 3,
            "\(name): \(survivors.count) survivors for \(injected) spikes — gate too low"
        )
    }

    /// The reason empirical Bayes replaced BayesShrink as the Reducer's default:
    /// on an artifact-laden band BayesShrink's T = σ_n²/σ_s collapses toward
    /// zero and classifies nearly everything as artifact, while the fitted gate
    /// stays out in the tail.
    @Test func gateSitsFarAboveBayesShrinkOnArtifactHeavyBands() {
        let band = band("sparse-100")
        let values = band.x
        let sigma = EmpiricalBayesThreshold.robustSigma(values)
        let empiricalBayes = EmpiricalBayesThreshold.threshold(for: values)

        // Mirrors `WaveletReducer.coefficientThreshold`'s BayesShrink branch.
        let mean = values.reduce(0, +) / Double(values.count)
        let observedVariance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let signalVariance = max(observedVariance - sigma * sigma, 0)
        let bayesShrink = sigma * sigma / signalVariance.squareRoot()

        #expect(empiricalBayes > 2 * bayesShrink)
    }

    /// End-to-end on a channel whose EEG and artifact are known separately, so
    /// the question is how well each model recovers the EEG rather than how much
    /// variance survives — on artifact-laden data the artifact *is* most of the
    /// variance, and "retained less" can mean either "cleaned well" or "gutted
    /// the signal".
    ///
    /// Error is reported relative to the EEG's own RMS: 0 = perfect recovery,
    /// 1 = as wrong as returning a flat line.
    @Test func reducerRecoversTheEEGBetterThanBayesShrink() {
        let samplingRate = 250.0
        let noise = band("gaussian-4096").x
        let count = noise.count

        var eeg = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / samplingRate
            eeg[index] =
                20 * sin(2 * .pi * 10 * t)      // alpha
                + 8 * sin(2 * .pi * 4.5 * t)    // theta
                + 4 * sin(2 * .pi * 22 * t)     // beta
                + 3 * noise[index]              // broadband background
        }

        // Three eye-blink-scale transients — sparse, large, broadband.
        var samples = eeg
        for center in [700, 1900, 3300] {
            for offset in -30...30 {
                let taper = cos(Double(offset) / 30 * .pi / 2)
                samples[center + offset] += 180 * taper * taper
            }
        }

        func recoveryError(_ model: WaveletCleaningThresholdModel) -> Double {
            var configuration = WaveletReductionConfiguration()
            configuration.levelCount = 6
            configuration.thresholdModel = model
            configuration.useGPU = false
            let result = WaveletReducer.reduceChannel(
                samples, configuration: configuration, samplingRate: samplingRate)
            let residual = zip(result.cleaned, eeg).map { $0 - $1 }
            return rms(residual) / rms(eeg)
        }

        let empiricalBayes = recoveryError(.empiricalBayes)
        let bayesShrink = recoveryError(.bayesShrink)
        let uncleaned = rms(zip(samples, eeg).map { $0 - $1 }) / rms(eeg)

        #expect(empiricalBayes < uncleaned, "cleaning made the channel worse")
        #expect(empiricalBayes < 0.5, "empirical Bayes recovery error \(empiricalBayes)")
        #expect(
            empiricalBayes < bayesShrink,
            "empirical Bayes error \(empiricalBayes) vs BayesShrink \(bayesShrink)"
        )
    }

    private func rms(_ values: [Double]) -> Double {
        (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    // MARK: - Degenerate inputs

    @Test func degenerateBandsReportNoEstimate() {
        #expect(EmpiricalBayesThreshold.threshold(for: []) == 0)
        #expect(EmpiricalBayesThreshold.threshold(for: [1, 2]) == 0)
        #expect(EmpiricalBayesThreshold.threshold(for: [Double](repeating: 3, count: 256)) == 0)
        #expect(EmpiricalBayesThreshold.threshold(for: [Double](repeating: 0, count: 256)) == 0)
    }

    /// Non-finite coefficients must not poison the fit — the GPU path reads raw
    /// device memory, and a NaN there should cost the band its outlier, not the
    /// whole threshold.
    @Test func nonFiniteCoefficientsDoNotProduceNaN() {
        var values = band("gaussian-1024").x
        values[10] = .nan
        values[20] = .infinity
        let threshold = EmpiricalBayesThreshold.threshold(for: values)
        #expect(threshold.isFinite)
        #expect(threshold > 0)
    }

    /// `populationCount` is the band length a subsample stands in for, and it
    /// sets the universal bound. A subsample fitted with the full length must
    /// land near the full band's own threshold, not systematically below it.
    @Test func subsampleWithPopulationCountTracksTheFullBand() {
        let values = band("gaussian-4096").x
        let full = EmpiricalBayesThreshold.threshold(for: values)
        let subsample = stride(from: 0, to: values.count, by: 4).map { values[$0] }

        let corrected = EmpiricalBayesThreshold.threshold(
            for: subsample, populationCount: values.count)
        let uncorrected = EmpiricalBayesThreshold.threshold(for: subsample)

        #expect(relativeError(corrected, full) < 0.1)
        #expect(uncorrected < corrected, "the shorter N should give a lower bound")
    }
}
