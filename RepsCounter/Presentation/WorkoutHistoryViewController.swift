//
//  WorkoutHistoryViewController.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit

final class WorkoutHistoryViewController: UITableViewController {
    var onDismiss: (() -> Void)?

    private let persistence: any WorkoutStoring
    private var workouts: [WorkoutSummary] = []

    init(persistence: any WorkoutStoring) {
        self.persistence = persistence
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "История"
        view.backgroundColor = WorkoutAppearance.background
        view.accessibilityIdentifier = "workoutHistoryScreen"
        tableView.accessibilityIdentifier = "workoutHistoryTable"
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 210
        tableView.register(WorkoutHistoryCell.self, forCellReuseIdentifier: "workout")
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = view.backgroundColor
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Готово", style: .done, target: self, action: #selector(close)
        )
        navigationItem.rightBarButtonItem?.tintColor = WorkoutAppearance.accent
        do {
            workouts = try persistence.history()
            if workouts.isEmpty {
                showUnavailable(title: "Пока нет тренировок", message: "Завершите и сохраните тренировку — она появится здесь.", symbol: "clock.arrow.circlepath")
                view.accessibilityValue = "Пустая история"
            }
        } catch {
            showUnavailable(title: "История недоступна", message: error.localizedDescription, symbol: "exclamationmark.triangle")
            view.accessibilityValue = "Ошибка загрузки истории"
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        workouts.isEmpty ? nil : "Сохранённые тренировки · \(workouts.count)"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        workouts.count
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "workout", for: indexPath)
        (cell as? WorkoutHistoryCell)?.render(workouts[indexPath.row])
        return cell
    }

    private func showUnavailable(title: String, message: String, symbol: String) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: symbol)
        configuration.imageProperties.tintColor = WorkoutAppearance.accent
        configuration.text = title
        configuration.textProperties.color = .white
        configuration.textProperties.font = .preferredFont(forTextStyle: .title2)
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryText = message
        configuration.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.75)
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        configuration.secondaryTextProperties.numberOfLines = 0
        contentUnavailableConfiguration = configuration
    }

    @objc private func close() { dismiss(animated: true, completion: onDismiss) }
}

private final class WorkoutHistoryCell: UITableViewCell {
    private let dateLabel = UILabel()
    private let repetitionsLabel = UILabel()
    private let durationLabel = UILabel()
    private let setsLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        let surface = UIView()
        surface.backgroundColor = WorkoutAppearance.historySurface
        surface.layer.cornerRadius = 20
        surface.layer.cornerCurve = .continuous
        surface.layer.borderWidth = 1
        surface.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        let symbol = UIImageView(image: UIImage(systemName: "figure.strengthtraining.traditional"))
        symbol.tintColor = WorkoutAppearance.accent
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        symbol.widthAnchor.constraint(equalToConstant: 44).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let titleLabel = UILabel()
        titleLabel.text = "Приседания"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        dateLabel.font = .preferredFont(forTextStyle: .subheadline)
        dateLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        dateLabel.accessibilityIdentifier = "historyWorkoutDate"
        let heading = UIStackView(arrangedSubviews: [titleLabel, dateLabel])
        heading.axis = .vertical
        heading.spacing = 4
        let header = UIStackView(arrangedSubviews: [symbol, heading])
        header.alignment = .top
        header.spacing = 12
        repetitionsLabel.font = .preferredFont(forTextStyle: .title2)
        repetitionsLabel.textColor = .white
        repetitionsLabel.accessibilityIdentifier = "historyWorkoutRepetitions"
        durationLabel.accessibilityIdentifier = "historyWorkoutDuration"
        setsLabel.accessibilityIdentifier = "historyWorkoutSets"
        for label in [durationLabel, setsLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = UIColor.white.withAlphaComponent(0.75)
        }
        for label in [dateLabel, repetitionsLabel, durationLabel, setsLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        let contents = UIStackView(arrangedSubviews: [header, repetitionsLabel, durationLabel, setsLabel])
        contents.axis = .vertical
        contents.spacing = 10
        contents.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(contents)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contents.topAnchor.constraint(equalTo: surface.topAnchor, constant: 18),
            contents.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -18),
            contents.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 18),
            contents.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(_ workout: WorkoutSummary) {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "ru_RU")
        dateFormatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy HHmm")
        dateLabel.text = dateFormatter.string(from: workout.date)
        repetitionsLabel.text = "\(workout.repetitions) повторений"
        durationLabel.text = "Время · \(workout.duration / 60) мин \(workout.duration % 60) сек"
        setsLabel.text = "Подходы · \(workout.sets)"
        accessibilityIdentifier = "historyWorkoutCard"
    }
}
