//
//  PoseComparisonView.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

#if DEBUG
import UIKit

final class PoseComparisonView: UIVisualEffectView {
    var onClose: (() -> Void)?
    var onSeries: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onViewpoint: ((ExperimentViewpoint) -> Void)?
    private let textLabel = UILabel()
    private let seriesButton = UIButton(type: .system)
    private let annotationButton = UIButton(type: .system)
    private let viewpointControl = UISegmentedControl(items: ["Лицом", "45°", "Боком"])

    init() {
        super.init(effect: UIBlurEffect(style: .systemThickMaterialDark))
        accessibilityIdentifier = "poseComparisonPanel"
        layer.cornerRadius = 14
        clipsToBounds = true
        isHidden = true
        let closeButton = UIButton(type: .system)
        closeButton.setTitle("К диагностике 2D", for: .normal)
        closeButton.addTarget(self, action: #selector(closePanel), for: .touchUpInside)
        closeButton.accessibilityIdentifier = "poseComparisonCloseButton"
        seriesButton.addTarget(self, action: #selector(toggleSeries), for: .touchUpInside)
        seriesButton.accessibilityIdentifier = "poseComparisonSeriesButton"
        annotationButton.setTitle("Ручная оценка серии", for: .normal)
        annotationButton.addTarget(self, action: #selector(annotateSeries), for: .touchUpInside)
        annotationButton.accessibilityIdentifier = "poseComparisonAnnotationButton"
        for button in [closeButton, seriesButton, annotationButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.tintColor = .systemCyan
        }
        textLabel.font = .preferredFont(forTextStyle: .caption1)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .white
        textLabel.numberOfLines = 0
        textLabel.accessibilityIdentifier = "poseComparisonText"
        viewpointControl.accessibilityLabel = "Ракурс контрольной серии, задаётся вручную"
        viewpointControl.addTarget(self, action: #selector(changeViewpoint), for: .valueChanged)
        let contents = UIStackView(arrangedSubviews: [closeButton, viewpointControl, seriesButton, annotationButton, textLabel])
        contents.axis = .vertical
        contents.spacing = 8
        contents.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        scrollView.addSubview(contents)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contents.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            contents.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            contents.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            contents.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            contents.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ model: PoseComparisonViewModel) {
        seriesButton.setTitle(model.isRecording ? "Завершить серию" : "Начать новую серию", for: .normal)
        seriesButton.isEnabled = model.isRecording || model.canStartSeries
        viewpointControl.isEnabled = !model.isRecording
        annotationButton.isEnabled = !model.isRecording && !model.series.isEmpty
        let counters = model.statistics
        var lines = [
            "ЭКСПЕРИМЕНТ 2D / 3D · DEBUG",
            "Рабочий 2D: \(model.productionRepetitions)",
            "3D: — · полный присед не определён",
            "2D эксперимента: \(model.latestPlanar?.analysis.repetitions ?? 0) · отдельный счётчик",
            model.isAvailable ? "3D ≤2 Гц · одна операция · предел возраста 750 мс" : "Экспериментальный источник недоступен",
            "Кадры: вход \(counters.sourceFrames), 2D \(counters.analyzed2D), ответов 3D \(counters.completed3D), сопоставимых пар \(counters.comparablePairs)",
            "Пригодны: 2D \(counters.usable2D), 3D \(counters.usable3D) · coverage \(Int(counters.coverage * 100))%",
            String(format: "FPS 2D %.1f · 3D %.1f · пригодных 3D %.1f", model.planarFPS, model.spatialFPS, model.usableFPS),
            "Пропуски: частота \(counters.rateLimited), занят \(counters.busyDropped), захват \(counters.captureDropped)",
            "Устарели \(counters.staleDropped), отменены \(counters.cancelled), тайм-ауты \(counters.timeouts), доставка \(counters.deliveryDropped), вход \(counters.invalidInput), UI-отказ \(model.rejectedResults)"
        ]
        if let pair = model.latestPair {
            let metadata = pair.source.metadata
            lines += [
                "ПОСЛЕДНЯЯ ПАРА · \(model.isLatestPairFresh ? "актуальна" : "устарела")",
                pair.isComparable ? "Есть пригодные углы одной и той же ноги обоих методов" : "Нет пригодных углов одной ноги обоих методов; сравнение недоступно",
                "Кадр \(metadata.identity.generation):\(metadata.identity.sequence) · \(metadata.position == .front ? "front" : "back")",
                String(format: "PTS %.3f с · поворот %.0f° · EXIF %u", metadata.timestamp, metadata.rotationAngle, metadata.orientation),
                "2D Л \(angle(pair.source.analysis.leftAngle)) \(pair.source.analysis.leftUsable ? "✓" : "✕") · П \(angle(pair.source.analysis.rightAngle)) \(pair.source.analysis.rightUsable ? "✓" : "✕")",
                "3D Л \(angle(pair.spatial.leftLeg.angle)) · П \(angle(pair.spatial.rightLeg.angle))",
                "2D: \(pair.source.analysis.phase) / \(pair.source.analysis.decision)",
                "3D: \(pair.spatial.phase.rawValue) / \(pair.spatial.decision.rawValue)",
                String(format: "Обработка 2D %.0f мс · 3D %.0f мс", pair.source.latency * 1000, pair.latency * 1000),
                String(format: "Получение → готовность 3D: %.0f мс", pair.totalLatency * 1000),
                "3D отказ: \(pair.detection.issue?.rawValue ?? "нет") · Л \(pair.spatial.leftLeg.issue?.rawValue ?? "нет") · П \(pair.spatial.rightLeg.issue?.rawValue ?? "нет")",
                "ΔY hip−knee (model): Л \(number(pair.spatial.leftLeg.hipMinusKneeModelY)) · П \(number(pair.spatial.rightLeg.hipMinusKneeModelY)) м",
                "ΔY / бедро: Л \(number(pair.spatial.leftLeg.normalizedHipOffset)) · П \(number(pair.spatial.rightLeg.normalizedHipOffset))",
                "Depth data: \(metadata.depthDataProvided ? "переданы" : "приложением не переданы")",
                "Оценка роста: \(pair.detection.pose?.heightEstimation.rawValue ?? "—") · revision \(pair.detection.pose?.requestRevision.description ?? "—")",
                "3D confidence суставов: API не предоставляет",
                "Один кадр ≠ доказательство одного человека. В кадре должен быть один участник."
            ]
            if let detail = pair.detection.detail { lines.append(detail) }
        } else {
            lines.append("Ожидание парного наблюдения; камера и тренировка должны быть активны.")
        }
        if let series = model.series.last {
            lines.append("Серия: \(model.isRecording ? "идёт" : "завершена") · \(series.viewpoint.rawValue) · пар \(series.pairs.count), вытеснено \(series.evictedPairs)")
            if let endCount = series.productionEndCount {
                lines.append("Рабочий 2D за серию: \(endCount - series.productionStartCount)")
            }
            if let annotation = series.annotation {
                lines.append("РУЧНАЯ: полных \(annotation.fullRepetitions), неполных \(annotation.partialRepetitions), спорных \(annotation.uncertainRepetitions)")
            } else {
                lines.append("Ручная оценка не введена. Vision её не заполняет.")
            }
        }
        lines.append("ΔY сустава не равна глубине тазобедренного сгиба. 3D-пороги не валидированы. Видео и изображения не сохраняются; числа только в памяти.")
        textLabel.text = lines.joined(separator: "\n\n")
    }

    private func angle(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f°", value)
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.3f", value)
    }

    @objc private func closePanel() { onClose?() }
    @objc private func toggleSeries() { onSeries?() }
    @objc private func annotateSeries() { onAnnotate?() }
    @objc private func changeViewpoint() {
        let viewpoints: [ExperimentViewpoint] = [.frontal, .diagonal, .side]
        guard viewpoints.indices.contains(viewpointControl.selectedSegmentIndex) else { return }
        onViewpoint?(viewpoints[viewpointControl.selectedSegmentIndex])
    }
}
#endif
