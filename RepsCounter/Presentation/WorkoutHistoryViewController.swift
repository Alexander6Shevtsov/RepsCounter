import UIKit

final class WorkoutHistoryViewController: UITableViewController {
    private let persistence: WorkoutPersistence
    private var workouts: [WorkoutSummary] = []

    init(persistence: WorkoutPersistence) {
        self.persistence = persistence
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "История"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close)
        )
        do {
            workouts = try persistence.history()
        } catch {
            let alert = UIAlertController(
                title: "Ошибка", message: error.localizedDescription, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Закрыть", style: .default))
            present(alert, animated: true)
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "workout")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        workouts.count
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "workout", for: indexPath)
        let workout = workouts[indexPath.row]
        let duration = "\(workout.duration / 60) мин \(workout.duration % 60) сек"
        var configuration = cell.defaultContentConfiguration()
        configuration.text = workout.date.formatted(date: .abbreviated, time: .shortened)
        configuration.secondaryText = "\(workout.repetitions) повторений · \(workout.sets) подходов · \(duration)"
        cell.contentConfiguration = configuration
        return cell
    }

    @objc private func close() { dismiss(animated: true) }
}
