//
//  WorkoutTimeSource.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import Foundation

@MainActor
protocol WorkoutTimeSource {
    var currentTime: TimeInterval { get }
    var date: Date { get }
}

struct SystemWorkoutTimeSource: WorkoutTimeSource {
    private let origin = ContinuousClock.now

    var currentTime: TimeInterval {
        let components = origin.duration(to: ContinuousClock.now).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var date: Date { Date() }
}
