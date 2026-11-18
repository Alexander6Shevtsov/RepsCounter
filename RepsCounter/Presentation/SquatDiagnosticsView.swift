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
        let attempt = diagnostics.activeDepthAttempt ?? diagnostics.lastDepthAttempt
        let attemptStatus = diagnostics.activeDepthAttempt == nil
            ? depthOutcomeText(attempt?.outcome)
            : "в ходе"
        let attemptNumber = attempt.map { "#\($0.number)" } ?? "—"
        let enabled = Vision3DProbeControl.isEnabled
        let currentProbe = diagnostics.vision3DProbe
        let synchronizedPair = enabled ? diagnostics.vision3DSynchronizedPair : nil
        let pairedProbe = synchronizedPair?.probe
        let threeDimensionalStatus = !enabled ? "выкл" : (synchronizedPair == nil ? "ожидание" : (pairedProbe?.observationAvailable == true ? "есть" : "нет позы"))
        let experimental = diagnostics.vision3DExperimentalCounter
        let standingShadow = diagnostics.vision3DReturnShadow
        let experimentalAttempt = experimental.activeAttempt ?? experimental.lastAttempt
        let experimentalAttemptState = experimental.activeAttempt != nil
            ? "в ходе" : experimentalOutcomeText(experimentalAttempt?.outcome)
        let experimentalPhase: String
        switch experimental.phase {
        case .seekingStanding: experimentalPhase = "ожидает стоя"
        case .standing: experimentalPhase = "стоя"
        case .lowered: experimentalPhase = "внизу"
        }
        let experimentalLeg: String
        switch experimental.selectedLeg {
        case .left: experimentalLeg = "Л"
        case .right: experimentalLeg = "П"
        case nil: experimentalLeg = "—"
        }
        let pairedLeg: String
        switch synchronizedPair?.selectedLeg {
        case .left: pairedLeg = "Л"
        case .right: pairedLeg = "П"
        case nil: pairedLeg = "—"
        }
        let lines = [
            "3D ТЕСТ счёт: \(enabled ? String(experimental.repetitions) : "—") · \(experimentalPhase)",
            "3D нога: \(experimentalLeg) · \(experimentalDecisionText(experimental.decision))",
            "3D выбор: \(experimentalSelectionText(experimental.selectionSource)) · 2D Л \(confidenceText(experimental.leftTwoDimensionalConfidence)) П \(confidenceText(experimental.rightTwoDimensionalConfidence))",
            "3D база ТК \(hipKneeText(experimental.standingHipKneeRatio)) · спуск \(hipKneeText(experimental.relativeDescent)) / 0.55 · сбросы \(experimental.interruptions)",
            "3D попытка #\(experimentalAttempt?.number ?? 0): мин угол \(angleText(experimentalAttempt?.minimumKneeAngle)) · пик спуска \(hipKneeText(experimentalAttempt?.maximumRelativeDescent))",
            "3D внизу: \(threeDimensionalDurationText(experimentalAttempt?.loweredDuration)) / 5 с · итог: \(experimentalAttemptState) · история \(experimental.recentAttempts.count)/20",
            "Возврат 2D/3D: \(shadowAgreementText(standingShadow.agreement))",
            "Тест возврата: совпадений нет \(standingShadow.consecutiveDisagreements)/2 · устойчивое расхождение \(standingShadow.isStableDisagreement ? "ДА" : "нет")",
            "Кадр #\(standingShadow.sampleNumber): угол 2D \(angleText(standingShadow.twoDimensionalAngle)) · 3D \(angleText(standingShadow.threeDimensionalAngle)) · Δ \(angleText(standingShadow.angleDifference))",
            "ТК: 2D \(hipKneeText(standingShadow.twoDimensionalHipKneeRatio)) · 3D \(hipKneeText(standingShadow.threeDimensionalHipKneeRatio)) · база \(hipKneeText(standingShadow.standingReference))",
            "Vision 3D: \(threeDimensionalStatus) · пара #\(synchronizedPair?.sampleNumber ?? 0)",
            "Скорость: 2D \(rateText(currentProbe?.twoDimensionalFramesPerSecond)) · 3D \(rateText(enabled ? currentProbe?.threeDimensionalSamplesPerSecond : nil))",
            "Время: 2D сейчас \(latencyText(diagnostics.vision2DLatencyMs)) · 3D пары \(latencyText(pairedProbe?.threeDimensionalLatencyMs))",
            "Пара 2D Л \(angleText(synchronizedPair?.twoDimensionalLeftAngle)) · П \(angleText(synchronizedPair?.twoDimensionalRightAngle))",
            "Пара 3D Л \(angleText(pairedProbe?.leftKneeAngle)) · П \(angleText(pairedProbe?.rightKneeAngle))",
            "ТК пары: 2D[\(pairedLeg)] \(hipKneeText(synchronizedPair?.twoDimensionalSelectedHeightRatio)) · 3D Л \(hipKneeText(pairedProbe?.leftHipKneeHeightRatio)) П \(hipKneeText(pairedProbe?.rightHipKneeHeightRatio))",
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

    private func shadowAgreementText(_ agreement: Vision3DStandingAgreement) -> String {
        switch agreement {
        case .awaitingSelectedLeg: return "ожидается выбор 3D-ноги"
        case .awaitingStandingReference: return "ожидается калибровка стоя"
        case .insufficientTwoDimensionalData: return "не хватает 2D данных той же ноги"
        case .insufficientThreeDimensionalData: return "не хватает 3D данных"
        case .bothStanding: return "обе модели видят стойку"
        case .bothMoving: return "обе модели не видят стойку"
        case .twoDimensionalStandingOnly: return "2D стоя, 3D не подтверждает"
        case .threeDimensionalStandingOnly: return "3D стоя, 2D не подтверждает"
        }
    }

    private func confidenceText(_ confidence: Double?) -> String {
        guard let confidence, confidence.isFinite else { return "—" }
        return String(format: "%.2f", confidence)
    }

    private func experimentalSelectionText(_ source: Vision3DLegSelectionSource) -> String {
        switch source {
        case .awaitingEvidence: return "ожидание"
        case .twoDimensionalConfidence: return "2D confidence"
        case .singleThreeDimensionalLeg: return "единственная 3D"
        }
    }

    private func threeDimensionalDurationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite else { return "—" }
        return String(format: "%.1f с", duration)
    }

    private func experimentalOutcomeText(_ outcome: Vision3DAttemptOutcome?) -> String {
        switch outcome {
        case .counted: return "засчитано"
        case .returnedWithoutDepth: return "возврат без глубины"
        case .loweredTimeout: return "тайм-аут нижней фазы"
        case .invalidMeasurement: return "нет достоверной 3D позы"
        case .observationGap: return "разрыв 3D наблюдений"
        case .trackingReset: return "сброс отслеживания"
        case nil: return "—"
        }
    }

    private func experimentalDecisionText(_ decision: Vision3DExperimentalDecision) -> String {
        switch decision {
        case .waitingForSample: return "ожидание 3D"
        case .awaitingLegEvidence: return "нет однозначной ноги"
        case .awaitingStanding: return "нужно исходное стоя"
        case .confirmingStanding: return "подтверждение стоя"
        case .standingConfirmed: return "стоя подтверждено"
        case .awaitingDepth: return "ждём сгибание"
        case .insufficientDescent: return "таз опущен недостаточно"
        case .confirmingDepth: return "подтверждение глубины"
        case .loweredConfirmed: return "глубина подтверждена"
        case .awaitingReturn: return "ждём возврат"
        case .confirmingReturn: return "подтверждение возврата"
        case .counted: return "повторение засчитано"
        case .invalidMeasurement: return "нет надёжной 3D позы"
        case .observationGap: return "разрыв 3D измерений"
        case .loweredTimeout: return "тайм-аут нижней фазы (>5 с)"
        }
    }

    private func rateText(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return "—" }
        return String(format: "%.1f/с", rate)
    }

    private func latencyText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite else { return "—" }
        return String(format: "%.1f мс", duration)
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
