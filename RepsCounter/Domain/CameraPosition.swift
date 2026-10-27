//
//  CameraPosition.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics

enum CameraPosition: Sendable, Equatable {
    case front
    case back

    var opposite: CameraPosition { self == .front ? .back : .front }
}

struct CameraConfiguration: Sendable, Equatable {
    let position: CameraPosition
    let rotationAngle: CGFloat
}
