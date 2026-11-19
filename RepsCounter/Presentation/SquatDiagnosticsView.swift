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
        if let bilateral = diagnostics.bilateral {
            renderBilateral(bilateral, frameRate: diagnostics.poseFramesPerSecond)
            return
        }
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
        let attempt = diagnostics.activeDepthAttempt ?? diagnostics.lastDepthAttempt
        let attemptStatus = diagnostics.activeDepthAttempt == nil
            ? depthOutcomeText(attempt?.outcome)
            : "в ходе"
        let attemptNumber = attempt.map { "#\($0.number)" } ?? "—"
        let lines = [
            "Обработано поз/с: \(frameRateText(diagnostics.poseFramesPerSecond))",
            "Сбросы И:\(diagnostics.measurementLossCount) Н:\(diagnostics.legChangeCount) Г:\(diagnostics.observationGapCount)",
            "raw \(angleText(analysis?.measuredAngle)) · EMA \(angleText(analysis?.smoothedAngle))",
            "Таз−колено: \(hipKneeText(analysis?.hipKneeHeightRatio)) бедра",
            "Попытка \(attemptNumber): пик \(attempt?.maxDepthFrames ?? 0)/\(diagnostics.requiredFrames) · срывы \(attempt?.depthBreakCount ?? 0)",
            "Мин raw \(angleText(attempt?.minRawAngle)) · EMA \(angleText(attempt?.minSmoothedAngle)) · ТК \(hipKneeText(attempt?.minHipKneeHeightRatio))",
            "Макс интервал: \(poseIntervalText(attempt?.maxPoseInterval)) · итог: \(attemptStatus)",
            "Срыв: \(depthBreakText(attempt?.lastBreak)) · нижняя фаза: \(attempt?.depthConfirmed == true ? "да" : "нет")",
            "Нога: \(selectedName) · confidence \(minimumConfidenceText(selectedMeasurement))",
            "Фаза: \(phaseName) · кадры \(diagnostics.consecutiveFrames)/\(diagnostics.requiredFrames)",
            "Результат: \(decisionText(diagnostics))",
            "Последняя потеря: \(measurementIssueText(diagnostics.latestMeasurementIssue))"
        ]
        textLabel.text = lines.joined(separator: "\n")
    }

    private func renderBilateral(_ telemetry: BilateralCounterTelemetry, frameRate: Double?) {
        let lines = [
            "2Н · Обработано поз/с: \(frameRateText(frameRate))",
            "Повторы: \(telemetry.repetitions) · ожидают: \(telemetry.pendingCount) · пары: \(telemetry.mergedDuplicates)",
            legSummary("Л", telemetry: telemetry.left),
            legPhase("Л", telemetry: telemetry.left),
            legEvent("Л", telemetry: telemetry.left),
            legSummary("П", telemetry: telemetry.right),
            legPhase("П", telemetry: telemetry.right),
            legEvent("П", telemetry: telemetry.right)
        ]
        textLabel.text = lines.joined(separator: "\n")
    }

    private func legSummary(_ label: String, telemetry: BilateralLegTelemetry) -> String {
        "\(label): raw \(angleText(telemetry.measuredAngle)) EMA \(angleText(telemetry.smoothedAngle))"
            + " · ТК \(hipKneeText(telemetry.hipKneeHeightRatio))"
            + " · c \(confidenceText(telemetry.confidence))"
    }

    private func legPhase(_ label: String, telemetry: BilateralLegTelemetry) -> String {
        "\(label): \(telemetry.phase) · \(telemetry.decision)"
            + " · пропуск \(telemetry.missedFrames)"
    }

    private func legEvent(_ label: String, telemetry: BilateralLegTelemetry) -> String {
        let lastReset = telemetry.lastReset.map { resetText($0) } ?? "—"
        return "\(label): \(eventText(telemetry.event))"
            + " · сброс \(lastReset) [\(telemetry.resetCount)]"
            + " · кандид. \(telemetry.candidateCount)"
    }

    private func eventText(_ event: BilateralTrackingEvent) -> String {
        switch event {
        case .waiting: return "ожидание"
        case .tracking: return "наблюдение"
        case .briefLoss: return "1 пропуск сохранён"
        case .candidate: return "кандидат подтверждён"
        case .reset(let reason): return "сброс: \(resetText(reason))"
        }
    }

    private func resetText(_ reason: BilateralTrackingResetReason) -> String {
        switch reason {
        case .observationGap: return "разрыв времени"
        case .missingJoint: return "нет сустава"
        case .lowConfidence: return "низкая уверенность"
        case .invalidGeometry: return "геометрия"
        case .externalReset: return "пауза/перезапуск"
        }
    }

    private func confidenceText(_ confidence: Float?) -> String {
        guard let confidence, confidence.isFinite else { return "—" }
        return String(format: "%.2f", confidence)
    }

    private func frameRateText(_ frameRate: Double?) -> String {
        guard let frameRate, frameRate.isFinite else { return "—" }
        return String(format: "%.1f", frameRate)
    }

    private func angleText(_ angle: Double?) -> String {
        guard let angle, angle.isFinite else { return "—" }
        return String(format: "%.1f°", angle)
    }

    private func hipKneeText(_ ratio: Double?) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        return String(format: "%+.2f", ratio)
    }

    private func measurementIssueText(_ issue: LegMeasurementIssue?) -> String {
        switch issue {
        case .missingJoint: return "не найден сустав"
        case .lowConfidence: return "низкая достоверность"
        case .invalidGeometry: return "некорректная геометрия"
        case nil: return "—"
        }
    }

    private func poseIntervalText(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite else { return "—" }
        return String(format: "%.0f мс", interval * 1000)
    }

    private func depthBreakText(_ reason: SquatDepthBreak?) -> String {
        switch reason {
        case .kneeAngle: return "угол колена"
        case .hipHeight: return "высота таза"
        case .invalidMeasurement: return "невалидное измерение"
        case .measurementLost: return "потеря суставов"
        case .legChanged: return "смена ноги"
        case .observationGap: return "разрыв наблюдений"
        case nil: return "—"
        }
    }

    private func depthOutcomeText(_ outcome: SquatDepthOutcome?) -> String {
        switch outcome {
        case .counted: return "засчитано"
        case .returnedWithoutDepth: return "возврат без глубины"
        case .invalidMeasurement: return "сбой измерения"
        case .measurementLost: return "потеря суставов"
        case .legChanged: return "смена ноги"
        case .observationGap: return "разрыв наблюдений"
        case .paused: return "пауза"
        case .cameraUnavailable: return "камера недоступна"
        case .finished: return "тренировка завершена"
        case .trackingReset: return "сброс отслеживания"
        case nil: return "—"
        }
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
        case .ready: return "настройка ракурса; подсчёт ещё не начат"
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
        case .awaitingHipKneeDepth: return "таз слишком высоко: глубина не подтверждена (порог +0.35)"
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
