//
//  PoseGeometry.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import CoreVideo
import ImageIO

struct PoseGeometry {
    static let visionOrientation: CGImagePropertyOrientation = .up

    static func aspectRatio(pixelBuffer: CVPixelBuffer) -> CGFloat {
        aspectRatio(pixelWidth: CVPixelBufferGetWidth(pixelBuffer), pixelHeight: CVPixelBufferGetHeight(pixelBuffer))
    }

    static func aspectRatio(pixelWidth: Int, pixelHeight: Int) -> CGFloat {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1 }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    static func capturePoint(fromVisionPoint point: CGPoint, rotationAngle: CGFloat = 90) -> CGPoint? {
        guard rotationAngle.isFinite else { return nil }
        let normalizedAngle = (rotationAngle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch normalizedAngle {
        case 0: return CGPoint(x: point.x, y: 1 - point.y)
        case 90: return CGPoint(x: 1 - point.y, y: 1 - point.x)
        case 180: return CGPoint(x: 1 - point.x, y: point.y)
        case 270: return CGPoint(x: point.y, y: point.x)
        default: return nil
        }
    }

    static func layerPoint(
        fromVisionPoint point: CGPoint,
        rotationAngle: CGFloat = 90,
        converting converter: (CGPoint) -> CGPoint
    ) -> CGPoint? {
        guard let capturePoint = capturePoint(fromVisionPoint: point, rotationAngle: rotationAngle) else { return nil }
        return converter(capturePoint)
    }
}
