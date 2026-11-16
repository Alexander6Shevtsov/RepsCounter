//
//  SquatDiagnosticsView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import UIKit

final class SquatDiagnosticsView: UIVisualEffectView {
    private let textLabel = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterialDark))
        accessibilityIdentifier = "squatDiagnosticsPanel"
        layer.cornerRadius = 14
        clipsToBounds = true
        isHidden = true
        contentView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        textLabel.font = .preferredFont(forTextStyle: .caption1)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .white
        textLabel.numberOfLines = 0
        textLabel.accessibilityIdentifier = "squatDiagnosticsText"
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(textLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            textLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            textLabel.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            textLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            textLabel.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ diagnostics: SquatDiagnostics) {
        let analysis = diagnostics.analysis
        let selectedName: String
        let selectedMeasurement: LegMeasurement?
        switch analysis?.selectedLeg {
        case .left:
            selectedName = "левая"
            selectedMeasurement = analysis?.leftMeasurement
        case .right:
            selectedName = "правая"
            selectedMeasurement = analysis?.rightMeasurement
        case nil:
            selectedName = "нет данных"
            selectedMeasurement = nil
        }
        let phaseName: String
        switch diagnostics.phase {
        case .seekingStanding: phaseName = "seekingStanding"
        case .standing: phaseName = "standing"
        case .lowered: phaseName = "lowered"
        }
        let lines = [
            "Нога: \(selectedName) · confidence \(minimumConfidenceText(selectedMeasurement))",
            "raw \(angleText(analysis?.measuredAngle)) · EMA \(angleText(analysis?.smoothedAngle))",
            "Таз−колено: \(hipKneeText(analysis?.hipKneeHeightRatio)) бедра",
            "Фаза: \(phaseName) · кадры \(diagnostics.consecutiveFrames)/\(diagnostics.requiredFrames)",
            "Результат: \(decisionText(diagnostics))"
        ]
        textLabel.text = lines.joined(separator: "\n")
    }

    private func angleText(_ angle: Double?) -> String {
        guard let angle, angle.isFinite else { return "—" }
        return String(format: "%.1f°", angle)
    }

    private func hipKneeText(_ ratio: Double?) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        return String(format: "%+.2f", ratio)
    }

    private func minimumConfidenceText(_ measurement: LegMeasurement?) -> String {
        let confidences = [measurement?.hipConfidence, measurement?.kneeConfidence, measurement?.ankleConfidence]
            .compactMap { confidence in confidence?.isFinite == true ? confidence : nil }
        guard let minimumConfidence = confidences.min() else { return "—" }
        return String(format: "%.2f", minimumConfidence)
    }

    private func decisionText(_ diagnostics: SquatDiagnostics) -> String {
        switch diagnostics.status {
        case .waitingForCamera: return "ожидание камеры; подсчёт остановлен"
        case .paused: return "пауза; подсчёт остановлен"
        case .resting: return "отдых; подсчёт остановлен"
        case .finished: return "тренировка завершена; подсчёт остановлен"
        case .tracking: break
        }
        switch diagnostics.resetReason {
        case .legChanged: return "смена анализируемой ноги; нужно заново подтвердить стоя"
        case .measurementLost: return "потеря надёжного угла; нужно заново подтвердить стоя"
        case .observationGap: return "разрыв наблюдений >250 мс; нужно заново подтвердить стоя"
        case nil: break
        }
        switch diagnostics.decision {
        case .awaitingStanding: return "нужно исходное положение ≥160°"
        case .confirmingStanding: return "недостаточно raw-кадров исходного положения"
        case .awaitingStandingSmoothing: return "raw стоя подтверждено; EMA ещё <160°"
        case .standingConfirmed: return "стоя подтверждено; ожидается полный присед"
        case .awaitingDepth: return "глубина ≤105° не достигнута"
        case .confirmingDepth: return "недостаточно raw-кадров глубины ≤105°"
        case .awaitingDepthSmoothing: return "raw глубина подтверждена; EMA ещё >105°"
        case .loweredConfirmed: return "глубина подтверждена; нужно вернуться стоя"
        case .awaitingReturn: return "возврат ≥160° не достигнут"
        case .confirmingReturn: return "недостаточно raw-кадров возврата ≥160°"
        case .awaitingReturnSmoothing: return "raw возврат подтверждён; EMA ещё <160°"
        case .repetitionCounted: return "повторение засчитано"
        case .invalidMeasurement: return "нет надёжного угла; движение сброшено, нужно стоя"
        }
    }
}
#endif
