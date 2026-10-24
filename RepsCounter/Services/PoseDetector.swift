import CoreVideo
import ImageIO
import CoreGraphics
import Vision

final class PoseDetector {
    private let request = VNDetectHumanBodyPoseRequest()

    func detect(pixelBuffer: CVPixelBuffer) -> BodyPose? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }

            let mappings: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
                (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
                (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
                (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
                (.leftHip, .leftHip), (.rightHip, .rightHip),
                (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
                (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
            ]

            var joints: [BodyJoint: JointPoint] = [:]
            for mapping in mappings {
                guard let recognizedPoint = try? observation.recognizedPoint(mapping.1) else {
                    continue
                }
                joints[mapping.0] = JointPoint(
                    location: recognizedPoint.location,
                    confidence: recognizedPoint.confidence
                )
            }
            let portraitWidth = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
            let portraitHeight = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            return BodyPose(joints: joints, aspectRatio: portraitWidth / max(portraitHeight, 1))
        } catch {
            return nil
        }
    }
}
