//
//  DipoleEEGGenerator.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Explicit neural sources projected through a concentric-sphere lead field.
//  Source streams are independently seeded so adding source N+1 cannot change
//  the uncalibrated waveforms/topographies of sources 1...N or any artifact
//  realization. The final common calibration factor can change, deliberately,
//  because total sensor-space EEG variance remains fixed across source counts.
//

import Foundation

nonisolated enum SimulationSeedStreams {
    private static func mixed(_ base: UInt64, domain: UInt64, index: UInt64 = 0) -> UInt64 {
        var value = base ^ domain ^ (index &* 0x9E37_79B9_7F4A_7C15)
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    static func dipoleSource(base: UInt64, index: Int) -> UInt64 {
        mixed(base, domain: 0xD1F0_1E50_0ACE_0001, index: UInt64(index))
    }
    static func bcg(base: UInt64) -> UInt64 { mixed(base, domain: 0xBC60_BC60_BC60_BC60) }
    /// One stream per BCG generator, so adding or removing a generator cannot
    /// move any other generator's per-beat weights or any other artifact layer.
    static func bcgGenerator(base: UInt64, index: Int) -> UInt64 {
        mixed(base, domain: 0xBC60_6E11_0000_0001, index: UInt64(index))
    }
    static func ocular(base: UInt64) -> UInt64 { mixed(base, domain: 0x0C01_AA00_0C01_AA00) }
    static func emg(base: UInt64) -> UInt64 { mixed(base, domain: 0xE060_E060_E060_E060) }
    static func chewing(base: UInt64) -> UInt64 { mixed(base, domain: 0xC4E0_C4E0_C4E0_C4E0) }
    static func swallowing(base: UInt64) -> UInt64 { mixed(base, domain: 0x5A10_5A10_5A10_5A10) }
    static func cableMovement(base: UInt64) -> UInt64 { mixed(base, domain: 0xCAB1_E000_CAB1_E000) }
    static func sweat(base: UInt64) -> UInt64 { mixed(base, domain: 0x5E47_5E47_5E47_5E47) }
    static func badReference(base: UInt64) -> UInt64 { mixed(base, domain: 0xBAD0_0EED_BAD0_0EED) }
    static func lineNoise(base: UInt64) -> UInt64 { mixed(base, domain: 0x11AE_0015_EED0_0001) }
    static func defects(base: UInt64) -> UInt64 { mixed(base, domain: 0xDEFE_C750_DEFE_C750) }
    static func impedance(base: UInt64) -> UInt64 { mixed(base, domain: 0x1A9E_DA4C_E000_0001) }
    static func impedanceNoise(base: UInt64) -> UInt64 { mixed(base, domain: 0x1A9E_0015_E000_0002) }
    static func erpLatency(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xE2F0_1A7E_E2F0_1A7E)
    }
    static func erpAmplitude(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xE2F0_AA90_E2F0_AA90)
    }
    static func erpConditionOrder(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xE2F0_C0D0_E2F0_C0D0)
    }
    static func erpOnsetJitter(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xE2F0_0151_E2F0_0151)
    }
    static func erpOmission(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xE2F0_0A17_E2F0_0A17)
    }
    static func alphaBursts(base: UInt64) -> UInt64 { mixed(base, domain: 0xA17A_BA57_A17A_BA57) }
    static func spectralDynamics(base: UInt64, index: Int) -> UInt64 {
        mixed(base, domain: 0x5EEC_7A11_5EEC_7A11, index: UInt64(index))
    }
    static func microstates(base: UInt64) -> UInt64 { mixed(base, domain: 0xA11C_2057_A11C_2057) }
    static func microstateCarrier(base: UInt64) -> UInt64 { mixed(base, domain: 0xA11C_CA22_A11C_CA22) }
    static func phaseAmplitudeCoupling(base: UInt64) -> UInt64 {
        mixed(base, domain: 0xFACE_C0A1_FACE_C0A1)
    }
}

nonisolated struct GeneratedSourceSpace: Sendable {
    var headModel: SphericalHeadModel
    var sources: [SimulatedSource]
    var leadField: LeadField
    var calibrationFactor: Double
    /// sources x samples, in nA·m. Kept in memory for validation and future ICA scoring.
    var timecoursesNanoampereMeters: [[Double]]
    var sourceCorrelationMatrix: [[Double]]
    var topographicCorrelationMatrix: [[Double]]
    var motions: [SourceMotionTruth]
}

nonisolated enum DipoleEEGGenerator {
    static func generate(config: SimulationConfig, montage: Montage) throws -> GeneratedEEG {
        let nonstationarity = NonstationaryEEGModel.makePlan(config: config, montage: montage)
        let alphaEnvelope = nonstationarity?.alphaEnvelope ?? EEGGenerator.alphaEnvelope(config: config)
        var sources = makeSources(config: config)
        var timecourses = [[Double]]()
        timecourses.reserveCapacity(sources.count)

        for index in sources.indices {
            let band = config.eegBands.first { $0.name == sources[index].bandName }
                ?? config.eegBands[index % config.eegBands.count]
            var random = GaussianSource(seed: sources[index].seed)
            var signal = SpectralNoise.bandLimited(
                sampleCount: config.sampleCount,
                samplingRate: config.samplingRate,
                lowHz: band.lowHz,
                highHz: band.highHz,
                source: &random
            )
            nonstationarity?.applySpectralAndPAC(to: &signal, band: band)
            if band.isAlpha {
                for sample in signal.indices { signal[sample] *= alphaEnvelope[sample] }
            } else {
                let amplitude = band.amplitudeMicrovolts ?? 0
                for sample in signal.indices { signal[sample] *= amplitude }
            }
            timecourses.append(signal)
        }

        if abs(config.dipoleSourceCorrelation) > 0, timecourses.count >= 2 {
            imposeCorrelation(
                master: timecourses[0],
                slave: &timecourses[1],
                coefficient: config.dipoleSourceCorrelation
            )
            sources[0].scenarioRole = appending(
                sources[0].scenarioRole, "correlation master for S002"
            )
            sources[1].scenarioRole = appending(
                sources[1].scenarioRole,
                String(
                    format: "correlated with S001 at r=%.6f; drawn from S001's %@ band so the "
                        + "pair shares one spectrum",
                    config.dipoleSourceCorrelation,
                    band(forSourceIndex: 0, config: config).name
                )
            )
        }

        let leadField = try SphericalForwardModel.leadField(
            head: config.sphericalHeadModel,
            montage: montage,
            sources: sources,
            reference: config.effectiveRecordingReference,
            terms: config.leadFieldTerms
        )
        var channels = project(leadField: leadField, timecourses: timecourses, sampleCount: config.sampleCount)
        let motions = try applyMotionIfNeeded(
            to: &channels,
            sources: &sources,
            timecourses: timecourses,
            baseLeadField: leadField,
            config: config,
            montage: montage
        )
        nonstationarity?.addMicrostates(
            to: &channels,
            amplitudeMicrovolts: config.neuralNonstationarity?.microstates?.amplitudeMicrovolts
        )

        // The raw band amplitudes are relative source moments. Calibrate every
        // source by one recorded factor so the requested sensor-space standard
        // deviation is met without destroying the physical linear relationship.
        let rawStd = EEGGenerator.pooledStandardDeviation(channels)
        let calibration = rawStd > 1e-12 ? config.eegTargetStdMicrovolts / rawStd : 1
        for source in timecourses.indices {
            for sample in timecourses[source].indices { timecourses[source][sample] *= calibration }
            sources[source].rmsMomentNanoampereMeters = rootMeanSquare(timecourses[source])
        }
        for channel in channels.indices {
            for sample in channels[channel].indices { channels[channel][sample] *= calibration }
        }

        return GeneratedEEG(
            channels: channels,
            alphaEnvelope: nonstationarity?.reportedAlphaEnvelope ?? alphaEnvelope,
            standardDeviation: EEGGenerator.pooledStandardDeviation(channels),
            sourceSpace: GeneratedSourceSpace(
                headModel: config.sphericalHeadModel,
                sources: sources,
                leadField: leadField,
                calibrationFactor: calibration,
                timecoursesNanoampereMeters: timecourses,
                sourceCorrelationMatrix: correlationMatrix(timecourses),
                topographicCorrelationMatrix: correlationMatrix(
                    columnsOf: leadField.matrixMicrovoltsPerNanoampereMeter
                ),
                motions: motions
            ),
            neuralNonstationarity: nonstationarity?.truth(calibrationFactor: calibration)
        )
    }

    static func project(leadField: LeadField, timecourses: [[Double]], sampleCount: Int) -> [[Double]] {
        var channels = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: leadField.matrixMicrovoltsPerNanoampereMeter.count
        )
        for channel in channels.indices {
            for source in timecourses.indices {
                let gain = leadField.matrixMicrovoltsPerNanoampereMeter[channel][source]
                guard gain != 0 else { continue }
                for sample in 0..<min(sampleCount, timecourses[source].count) {
                    channels[channel][sample] += gain * timecourses[source][sample]
                }
            }
        }
        return channels
    }

    /// Which band a source draws from.
    ///
    /// A correlated pair shares one band. Sources otherwise cycle through
    /// `eegBands`, so S001 and S002 land in different bands — and imposing a
    /// correlation then mixes S001's spectrum into S002, leaving S002 no longer
    /// band-limited while the per-band scoring in `SNRMetrics` still assumes
    /// that it is. Two genuinely correlated cortical sources share spectral
    /// content anyway, so drawing the pair from one band is both the honest fix
    /// and the more physical one. It is declared in `scenarioRole` and the truth
    /// sidecar rather than done silently.
    static func band(forSourceIndex index: Int, config: SimulationConfig) -> EEGBand {
        guard let first = config.eegBands.first else {
            return EEGBand(name: "none", lowHz: 0, highHz: 0, amplitudeMicrovolts: 0)
        }
        if index == 1, abs(config.dipoleSourceCorrelation) > 0, config.dipoleSourceCount >= 2 {
            return first
        }
        return config.eegBands[index % config.eegBands.count]
    }

    static func makeSources(config: SimulationConfig) -> [SimulatedSource] {
        let radius = config.sphericalHeadModel.brainRadiusMeters * config.dipoleSourceRadiusFraction
        var sources = (0..<config.dipoleSourceCount).map { index in
            let direction = stableDirection(index: index)
            let orientation = sourceOrientation(index: index, radial: direction, pattern: config.dipoleOrientationPattern)
            let band = band(forSourceIndex: index, config: config)
            return SimulatedSource(
                id: String(format: "S%03d", index + 1),
                positionMeters: config.sphericalHeadModel.centerMeters + direction * radius,
                orientation: orientation,
                bandName: band.name,
                seed: SimulationSeedStreams.dipoleSource(base: config.seed, index: index),
                rmsMomentNanoampereMeters: 0
            )
        }
        if config.dipoleNearPairSeparationDegrees > 0, sources.count >= 2 {
            let center = config.sphericalHeadModel.centerMeters
            let firstDirection = (sources[0].positionMeters - center).normalized()
            let reference = abs(firstDirection.z) < 0.9
                ? Vector3D(x: 0, y: 0, z: 1)
                : Vector3D(x: 1, y: 0, z: 0)
            let axis = firstDirection.cross(reference).normalized()
            let radians = config.dipoleNearPairSeparationDegrees * Double.pi / 180
            let secondDirection = firstDirection.rotated(around: axis, radians: radians).normalized()
            sources[1].positionMeters = center + secondDirection * radius
            sources[1].orientation = sources[0].orientation.rotated(around: axis, radians: radians).normalized()
            sources[0].scenarioRole = appending(
                sources[0].scenarioRole, "near-degenerate pair anchor for S002"
            )
            sources[1].scenarioRole = appending(
                sources[1].scenarioRole,
                String(format: "%.6f° from S001", config.dipoleNearPairSeparationDegrees)
            )
        }
        if abs(config.dipoleSourceCorrelation) > 0, sources.count >= 2 {
            // A correlation construction mixes the master waveform into the
            // slave. Assigning both sources to the same configured band keeps
            // that mixture inside its declared passband instead of silently
            // turning S002 into a cross-band source.
            sources[1].bandName = sources[0].bandName
            sources[1].scenarioRole = appending(
                sources[1].scenarioRole,
                "band matched to S001 for within-band correlation"
            )
        }
        return sources
    }

    /// Prefix-stable low-discrepancy points. Source 1...N do not move when N+1
    /// is requested, which is essential for interpretable source-count sweeps.
    private static func stableDirection(index: Int) -> Vector3D {
        let n = Double(index + 1)
        let z = 1 - 2 * fractionalPart(n * 0.618_033_988_749_894_9)
        let azimuth = 2 * Double.pi * fractionalPart(n * 0.754_877_666_246_692_7)
        let radius = max(0, 1 - z * z).squareRoot()
        return Vector3D(x: radius * cos(azimuth), y: radius * sin(azimuth), z: z)
    }

    private static func fractionalPart(_ value: Double) -> Double { value - floor(value) }

    private static func sourceOrientation(
        index: Int,
        radial: Vector3D,
        pattern: DipoleOrientationPattern
    ) -> Vector3D {
        let reference = abs(radial.z) < 0.9
            ? Vector3D(x: 0, y: 0, z: 1)
            : Vector3D(x: 1, y: 0, z: 0)
        let tangentA = reference.cross(radial).normalized()
        let tangentB = radial.cross(tangentA).normalized()
        switch pattern {
        case .radial: return radial
        case .tangential: return index.isMultiple(of: 2) ? tangentA : tangentB
        case .mixed:
            switch index % 3 {
            case 0: return radial
            case 1: return tangentA
            default: return tangentB
            }
        case .free:
            let phase = Double(index + 1) * 0.731
            return (radial * (0.35 + 0.2 * sin(phase))
                    + tangentA * cos(phase)
                    + tangentB * sin(phase)).normalized()
        }
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0.0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    private static func imposeCorrelation(master: [Double], slave: inout [Double], coefficient: Double) {
        let count = min(master.count, slave.count)
        guard count > 1 else { return }
        let xMean = master.prefix(count).reduce(0, +) / Double(count)
        let yMean = slave.prefix(count).reduce(0, +) / Double(count)
        var x = [Double](repeating: 0, count: count)
        var residual = [Double](repeating: 0, count: count)
        var xSquares = 0.0
        var ySquares = 0.0
        for index in 0..<count {
            x[index] = master[index] - xMean
            residual[index] = slave[index] - yMean
            xSquares += x[index] * x[index]
            ySquares += residual[index] * residual[index]
        }
        let xRMS = (xSquares / Double(count)).squareRoot()
        let yRMS = (ySquares / Double(count)).squareRoot()
        guard xRMS > 1e-15, yRMS > 1e-15 else { return }
        for index in 0..<count { x[index] /= xRMS }

        let projection = zip(x, residual).reduce(0.0) { $0 + $1.0 * $1.1 } / Double(count)
        var residualSquares = 0.0
        for index in 0..<count {
            residual[index] -= projection * x[index]
            residualSquares += residual[index] * residual[index]
        }
        let residualRMS = (residualSquares / Double(count)).squareRoot()
        let independentWeight = max(0, 1 - coefficient * coefficient).squareRoot()
        for index in 0..<count {
            let orthogonal = residualRMS > 1e-15 ? residual[index] / residualRMS : 0
            slave[index] = yRMS * (coefficient * x[index] + independentWeight * orthogonal)
        }
    }

    private static func applyMotionIfNeeded(
        to channels: inout [[Double]],
        sources: inout [SimulatedSource],
        timecourses: [[Double]],
        baseLeadField: LeadField,
        config: SimulationConfig,
        montage: Montage
    ) throws -> [SourceMotionTruth] {
        guard config.dipoleMotionDegrees > 0, !sources.isEmpty, !timecourses.isEmpty else { return [] }
        let center = config.sphericalHeadModel.centerMeters
        let direction = (sources[0].positionMeters - center).normalized()
        let reference = abs(direction.z) < 0.9
            ? Vector3D(x: 0, y: 0, z: 1)
            : Vector3D(x: 1, y: 0, z: 0)
        let axis = direction.cross(reference).normalized()
        let radians = config.dipoleMotionDegrees * Double.pi / 180
        var endSource = sources[0]
        endSource.positionMeters = center
            + direction.rotated(around: axis, radians: radians).normalized()
                * (sources[0].positionMeters - center).norm
        endSource.orientation = sources[0].orientation.rotated(around: axis, radians: radians).normalized()
        endSource.scenarioRole = "motion endpoint"
        let endField = try SphericalForwardModel.leadField(
            head: config.sphericalHeadModel,
            montage: montage,
            sources: [endSource],
            reference: config.effectiveRecordingReference,
            terms: config.leadFieldTerms
        )

        let startTime = config.durationSeconds * config.dipoleMotionStartFraction
        let endTime = min(
            config.durationSeconds,
            startTime + config.durationSeconds * config.dipoleMotionTransitionFraction
        )
        let startSample = Int((startTime * config.samplingRate).rounded())
        let endSample = Int((endTime * config.samplingRate).rounded())
        for channel in channels.indices {
            let startGain = baseLeadField.matrixMicrovoltsPerNanoampereMeter[channel][0]
            let endGain = endField.matrixMicrovoltsPerNanoampereMeter[channel][0]
            let delta = endGain - startGain
            for sample in max(0, startSample)..<min(config.sampleCount, timecourses[0].count) {
                let fraction: Double
                if endSample <= startSample || sample >= endSample {
                    fraction = 1
                } else {
                    fraction = Double(sample - startSample) / Double(endSample - startSample)
                }
                channels[channel][sample] += fraction * delta * timecourses[0][sample]
            }
        }
        sources[0].scenarioRole = appending(
            sources[0].scenarioRole,
            String(format: "moves %.6f° from %.6f-%.6f s", config.dipoleMotionDegrees,
                   startTime, endTime)
        )
        return [
            SourceMotionTruth(
                sourceID: sources[0].id,
                startTimeSeconds: startTime,
                endTimeSeconds: endTime,
                endPositionMeters: endSource.positionMeters,
                endOrientation: endSource.orientation,
                endLeadField: endField
            )
        ]
    }

    static func correlationMatrix(_ signals: [[Double]]) -> [[Double]] {
        signals.map { left in signals.map { pearson(left, $0) } }
    }

    static func correlationMatrix(columnsOf matrix: [[Double]]) -> [[Double]] {
        guard let width = matrix.first?.count else { return [] }
        let columns = (0..<width).map { column in matrix.map { $0[column] } }
        return correlationMatrix(columns)
    }

    static func pearson(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 0 }
        let leftMean = lhs.prefix(count).reduce(0, +) / Double(count)
        let rightMean = rhs.prefix(count).reduce(0, +) / Double(count)
        var numerator = 0.0
        var leftSquares = 0.0
        var rightSquares = 0.0
        for index in 0..<count {
            let left = lhs[index] - leftMean
            let right = rhs[index] - rightMean
            numerator += left * right
            leftSquares += left * left
            rightSquares += right * right
        }
        let denominator = (leftSquares * rightSquares).squareRoot()
        return denominator > 1e-30 ? numerator / denominator : 0
    }

    private static func appending(_ existing: String?, _ addition: String) -> String {
        existing.map { $0 + "; " + addition } ?? addition
    }
}
