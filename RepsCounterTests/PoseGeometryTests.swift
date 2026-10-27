//
//  PoseGeometryTests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import CoreGraphics
import CoreVideo
import XCTest
@testable import RepsCounter

final class PoseGeometryTests: XCTestCase {
    func testUprightVisionCornersMapBackToLegacyNinetyDegreeCaptureCoordinates() {
        let samples: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
            (CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0)),
            (CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 1)),
            (CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0)),
            (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5))
        ]
        for sample in samples {
            XCTAssertEqual(PoseGeometry.capturePoint(fromVisionPoint: sample.0), sample.1)
        }
    }

    func testCardinalRotationsUseDistinctInverseSensorMappings() {
        let visionPoint = CGPoint(x: 0.25, y: 0.6)
        let samples: [(CGFloat, CGPoint)] = [
            (0, CGPoint(x: 0.25, y: 0.4)),
            (90, CGPoint(x: 0.4, y: 0.75)),
            (180, CGPoint(x: 0.75, y: 0.6)),
            (270, CGPoint(x: 0.6, y: 0.25))
        ]
        for sample in samples {
            let capturePoint = PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: sample.0)
            XCTAssertEqual(capturePoint?.x ?? -1, sample.1.x, accuracy: 0.000_001)
            XCTAssertEqual(capturePoint?.y ?? -1, sample.1.y, accuracy: 0.000_001)
        }
    }

    func testCardinalRotationRoundTripKeepsAllVisionCornersAndCenter() throws {
        let samples = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)]
        for rotationAngle: CGFloat in [0, 90, 180, 270] {
            let converter = PreviewProjection(mirrored: false, imageAspectRatio: 0.5, bounds: CGRect(x: 0, y: 0, width: 200, height: 400), rotationAngle: rotationAngle)
            for visionPoint in samples {
                let point = try projectedPoint(visionPoint: visionPoint, using: converter, rotationAngle: rotationAngle)
                XCTAssertEqual(point.x, visionPoint.x * 200, accuracy: 0.000_001)
                XCTAssertEqual(point.y, (1 - visionPoint.y) * 400, accuracy: 0.000_001)
            }
        }
    }

    func testEquivalentAnglesNormalizeToCardinalSensorRotation() {
        let visionPoint = CGPoint(x: 0.25, y: 0.6)
        XCTAssertEqual(PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: -90), PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: 270))
        XCTAssertEqual(PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: 360), PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: 0))
        XCTAssertEqual(PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: 450), PoseGeometry.capturePoint(fromVisionPoint: visionPoint, rotationAngle: 90))
    }

    func testUnsupportedAndNonfiniteRotationsNeverReachPreviewConverter() {
        var conversions = 0
        for rotationAngle: CGFloat in [45, 89.5, .nan, .infinity, -.infinity] {
            let point = PoseGeometry.layerPoint(fromVisionPoint: CGPoint(x: 0.2, y: 0.8), rotationAngle: rotationAngle) { capturePoint in
                conversions += 1
                return capturePoint
            }
            XCTAssertNil(point)
        }
        XCTAssertEqual(conversions, 0)
    }

    func testLayerProjectionDelegatesPreviewConversionExactlyOnce() throws {
        var receivedPoints: [CGPoint] = []
        let point = try XCTUnwrap(PoseGeometry.layerPoint(fromVisionPoint: CGPoint(x: 0.25, y: 0.6)) { capturePoint in
            receivedPoints.append(capturePoint)
            return CGPoint(x: 41, y: 73)
        })
        XCTAssertEqual(receivedPoints.count, 1)
        XCTAssertEqual(receivedPoints.first?.x ?? 0, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(receivedPoints.first?.y ?? 0, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(point, CGPoint(x: 41, y: 73))
    }

    func testRearPreviewProjectionPreservesHorizontalDirection() throws {
        for rotationAngle: CGFloat in [0, 90, 180, 270] {
            let converter = PreviewProjection(mirrored: false, imageAspectRatio: 0.5, bounds: CGRect(x: 0, y: 0, width: 200, height: 400), rotationAngle: rotationAngle)
            let point = try projectedPoint(visionPoint: CGPoint(x: 0.2, y: 0.75), using: converter, rotationAngle: rotationAngle)
            XCTAssertEqual(point.x, 40, accuracy: 0.000_001)
            XCTAssertEqual(point.y, 100, accuracy: 0.000_001)
        }
    }

    func testFrontPreviewMirrorsExactlyOnceForBothSensorMountingExamples() throws {
        for rotationAngle: CGFloat in [0, 90] {
            let converter = PreviewProjection(mirrored: true, imageAspectRatio: 0.5, bounds: CGRect(x: 0, y: 0, width: 200, height: 400), rotationAngle: rotationAngle)
            let point = try projectedPoint(visionPoint: CGPoint(x: 0.2, y: 0.75), using: converter, rotationAngle: rotationAngle)
            XCTAssertEqual(point.x, 160, accuracy: 0.000_001)
            XCTAssertEqual(point.y, 100, accuracy: 0.000_001)
        }
    }

    func testAspectFillWideViewportCropsVerticallyThroughPreviewConversion() throws {
        let converter = PreviewProjection(mirrored: false, imageAspectRatio: 0.5, bounds: CGRect(x: 10, y: 20, width: 300, height: 300))
        let upperPoint = try projectedPoint(visionPoint: CGPoint(x: 0.5, y: 1), using: converter)
        let lowerPoint = try projectedPoint(visionPoint: CGPoint(x: 0.5, y: 0), using: converter)
        XCTAssertEqual(upperPoint.x, 160, accuracy: 0.000_001)
        XCTAssertEqual(upperPoint.y, -130, accuracy: 0.000_001)
        XCTAssertEqual(lowerPoint.y, 470, accuracy: 0.000_001)
    }

    func testAspectFillTallViewportCropsHorizontallyWithFrontMirroring() throws {
        let rearConverter = PreviewProjection(mirrored: false, imageAspectRatio: 0.5, bounds: CGRect(x: 0, y: 0, width: 100, height: 400))
        let frontConverter = PreviewProjection(mirrored: true, imageAspectRatio: 0.5, bounds: CGRect(x: 0, y: 0, width: 100, height: 400))
        let visionPoint = CGPoint(x: 0.25, y: 0.5)
        let rearPoint = try projectedPoint(visionPoint: visionPoint, using: rearConverter)
        let frontPoint = try projectedPoint(visionPoint: visionPoint, using: frontConverter)
        XCTAssertEqual(rearPoint.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(frontPoint.x, 100, accuracy: 0.000_001)
        XCTAssertEqual(rearPoint.y, 200, accuracy: 0.000_001)
        XCTAssertEqual(frontPoint.y, 200, accuracy: 0.000_001)
    }

    func testCenterIsStableAcrossSensorRotationMirroringAndAspectFillCrop() throws {
        for rotationAngle: CGFloat in [0, 90, 180, 270] {
            for mirrored in [false, true] {
                let converter = PreviewProjection(mirrored: mirrored, imageAspectRatio: 9.0 / 16.0, bounds: CGRect(x: 10, y: 20, width: 393, height: 852), rotationAngle: rotationAngle)
                let point = try projectedPoint(visionPoint: CGPoint(x: 0.5, y: 0.5), using: converter, rotationAngle: rotationAngle)
                XCTAssertEqual(point.x, 206.5, accuracy: 0.000_001)
                XCTAssertEqual(point.y, 446, accuracy: 0.000_001)
            }
        }
    }

    func testPoseRotationMetadataDoesNotChangeJointCoordinatesOrIdentity() {
        let location = CGPoint(x: 0.25, y: 0.6)
        for rotationAngle: CGFloat in [0, 90, 180, 270] {
            let pose = BodyPose(joints: [.leftHip: JointPoint(location: location, confidence: 1)], aspectRatio: 9.0 / 16.0, rotationAngle: rotationAngle)
            XCTAssertEqual(pose.rotationAngle, rotationAngle)
            XCTAssertEqual(pose.confidentPoint(for: .leftHip), location)
            XCTAssertNil(pose.confidentPoint(for: .rightHip))
        }
    }

    func testLegacyPoseConstructionKeepsNinetyDegreeMetadataDefault() {
        let pose = BodyPose(joints: [:], aspectRatio: 1)
        XCTAssertEqual(pose.rotationAngle, 90)
    }

    func testPortraitBufferAspectRatioDoesNotRotateDimensionsAgain() {
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelWidth: 720, pixelHeight: 1280), 9.0 / 16.0, accuracy: 0.000_001)
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelWidth: 1080, pixelHeight: 1920), 9.0 / 16.0, accuracy: 0.000_001)
    }

    func testSyntheticPortraitBufferUsesItsPhysicallyRotatedDimensions() throws {
        let pixelBuffer = try makePixelBuffer(width: 720, height: 1280)
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelBuffer: pixelBuffer), 9.0 / 16.0, accuracy: 0.000_001)
    }

    func testSyntheticLandscapeBufferDoesNotApplyAnImplicitQuarterTurn() throws {
        let pixelBuffer = try makePixelBuffer(width: 1280, height: 720)
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelBuffer: pixelBuffer), 16.0 / 9.0, accuracy: 0.000_001)
    }

    func testInvalidImageDimensionsDoNotProduceNonfiniteGeometry() {
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelWidth: 0, pixelHeight: 1280), 1)
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelWidth: 720, pixelHeight: 0), 1)
        XCTAssertEqual(PoseGeometry.aspectRatio(pixelWidth: -1, pixelHeight: 1280), 1)
    }

    private func projectedPoint(visionPoint: CGPoint, using converter: PreviewProjection, rotationAngle: CGFloat = 90) throws -> CGPoint {
        try XCTUnwrap(PoseGeometry.layerPoint(fromVisionPoint: visionPoint, rotationAngle: rotationAngle, converting: converter.layerPoint))
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }
}

private struct PreviewProjection {
    let mirrored: Bool
    let imageAspectRatio: CGFloat
    let bounds: CGRect
    let rotationAngle: CGFloat

    init(mirrored: Bool, imageAspectRatio: CGFloat, bounds: CGRect, rotationAngle: CGFloat = 90) {
        self.mirrored = mirrored
        self.imageAspectRatio = imageAspectRatio
        self.bounds = bounds
        self.rotationAngle = rotationAngle
    }

    func layerPoint(_ capturePoint: CGPoint) -> CGPoint {
        let portraitPoint: CGPoint
        switch rotationAngle {
        case 0: portraitPoint = capturePoint
        case 90: portraitPoint = CGPoint(x: 1 - capturePoint.y, y: capturePoint.x)
        case 180: portraitPoint = CGPoint(x: 1 - capturePoint.x, y: 1 - capturePoint.y)
        default: portraitPoint = CGPoint(x: capturePoint.y, y: 1 - capturePoint.x)
        }
        let displayWidth = max(bounds.width, bounds.height * imageAspectRatio)
        let displayHeight = displayWidth / imageAspectRatio
        let horizontalPoint = mirrored ? 1 - portraitPoint.x : portraitPoint.x
        return CGPoint(
            x: bounds.midX + (horizontalPoint - 0.5) * displayWidth,
            y: bounds.midY + (portraitPoint.y - 0.5) * displayHeight
        )
    }
}
