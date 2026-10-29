//
//  WorkoutHistoryUITests.swift
//  RepsCounter
//
//  Maintainer: Alexander Shevtsov
//  Copyright © 2026 Alexander Shevtsov.

import UIKit
import XCTest
@testable import RepsCounter

final class WorkoutHistoryUITests: XCTestCase {
    @MainActor
    func testEmptyHistoryShowsEmptyStateAndReadsStorageOnce() throws {
        let store = HistoryUIStore()
        let controller = WorkoutHistoryViewController(persistence: store)
        controller.loadViewIfNeeded()
        let configuration = try XCTUnwrap(controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(configuration.text, "Пока нет тренировок")
        XCTAssertEqual(controller.view.accessibilityValue, "Пустая история")
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 0)
        XCTAssertEqual(store.historyReads, 1)
        XCTAssertTrue(store.savedSummaries.isEmpty)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, "Готово")
    }

    @MainActor
    func testStoredWorkoutDisplaysActualValuesAndRussianDate() throws {
        let store = HistoryUIStore()
        store.records = [summary(repetitions: 24, duration: 65, sets: 3)]
        let controller = WorkoutHistoryViewController(persistence: store)
        controller.loadViewIfNeeded()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 1)
        XCTAssertEqual(try label("historyWorkoutRepetitions", inside: cell).text, "24 повторений")
        XCTAssertEqual(try label("historyWorkoutDuration", inside: cell).text, "Время · 1 мин 5 сек")
        XCTAssertEqual(try label("historyWorkoutSets", inside: cell).text, "Подходы · 3")
        let dateText = try XCTUnwrap(try label("historyWorkoutDate", inside: cell).text)
        XCTAssertTrue(dateText.contains("2026"))
        XCTAssertFalse(dateText.contains("Oct"))
        XCTAssertNil(controller.contentUnavailableConfiguration)
        XCTAssertTrue(store.savedSummaries.isEmpty)
    }

    @MainActor
    func testStorageFailureIsDistinctFromEmptyHistoryAndPreservesMessage() throws {
        let store = HistoryUIStore()
        store.failure = HistoryUIError.unavailable
        let controller = WorkoutHistoryViewController(persistence: store)
        controller.loadViewIfNeeded()
        let configuration = try XCTUnwrap(controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        XCTAssertEqual(configuration.text, "История недоступна")
        XCTAssertEqual(configuration.secondaryText, HistoryUIError.unavailable.localizedDescription)
        XCTAssertEqual(controller.view.accessibilityValue, "Ошибка загрузки истории")
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 0)
        XCTAssertEqual(store.historyReads, 1)
        XCTAssertTrue(store.savedSummaries.isEmpty)
    }

    @MainActor
    func testHistoryPreservesStorageOrderAndDoesNotInsertRecords() throws {
        let store = HistoryUIStore()
        store.records = [summary(repetitions: 36, duration: 180, sets: 4), summary(repetitions: 7, duration: 37, sets: 1)]
        let controller = WorkoutHistoryViewController(persistence: store)
        controller.loadViewIfNeeded()
        controller.tableView.reloadData()
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 2)
        let firstCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        let secondCell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(try label("historyWorkoutRepetitions", inside: firstCell).text, "36 повторений")
        XCTAssertEqual(try label("historyWorkoutRepetitions", inside: secondCell).text, "7 повторений")
        XCTAssertEqual(store.historyReads, 1)
        XCTAssertTrue(store.savedSummaries.isEmpty)
    }

    @MainActor
    func testHistoryCardsSupportAllTextSizesWithoutHorizontalClipping() async throws {
        let store = HistoryUIStore()
        store.records = [summary(repetitions: 24, duration: 65, sets: 3)]
        let controller = WorkoutHistoryViewController(persistence: store)
        let navigation = HistoryRenderNavigationController(rootViewController: controller)
        let appeared = expectation(description: "History renderer appeared")
        navigation.onAppear = { appeared.fulfill() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.isHidden = false
        await fulfillment(of: [appeared], timeout: 3)
        window.layoutIfNeeded()
        let nativeInsets = navigation.view.safeAreaInsets
        navigation.additionalSafeAreaInsets = UIEdgeInsets(top: 59 - nativeInsets.top, left: -nativeInsets.left,
                                                          bottom: 34 - nativeInsets.bottom, right: -nativeInsets.right)
        defer { window.isHidden = true }
        let categories: [UIContentSizeCategory] = [.extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge,
                                                  .extraExtraExtraLarge, .accessibilityMedium, .accessibilityLarge,
                                                  .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
        for size in [CGSize(width: 375, height: 667), CGSize(width: 393, height: 852), CGSize(width: 430, height: 932)] {
            window.frame.size = size
            for category in categories {
                navigation.traitOverrides.preferredContentSizeCategory = category
                controller.tableView.reloadData()
                window.setNeedsLayout()
                window.layoutIfNeeded()
                controller.tableView.layoutIfNeeded()
                let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: 0, section: 0)))
                let expectedFont = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
                XCTAssertEqual(try label("historyWorkoutRepetitions", inside: cell).font.pointSize, expectedFont.pointSize, category.rawValue)
                XCTAssertLessThanOrEqual(controller.tableView.contentSize.width, controller.tableView.bounds.width + 0.5)
                for content in descendants(cell.contentView).compactMap({ $0 as? UILabel }) where content.text?.isEmpty == false {
                    let needed = content.sizeThatFits(CGSize(width: content.bounds.width, height: .greatestFiniteMagnitude))
                    XCTAssertGreaterThan(content.bounds.width, 0, category.rawValue)
                    XCTAssertGreaterThanOrEqual(content.bounds.height + 0.5, needed.height, "\(size) \(category.rawValue) \(content.text ?? "")")
                    let frame = content.convert(content.bounds, to: cell.contentView)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, cell.contentView.bounds.width + 0.5)
                    XCTAssertGreaterThanOrEqual(frame.minY, 0)
                    XCTAssertLessThanOrEqual(frame.maxY, cell.contentView.bounds.height + 0.5)
                }
                if size.width == 393 && (category == .large || category == .accessibilityExtraExtraExtraLarge) {
                    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Rendered UIKit history · synthetic fixture · \(category.rawValue)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        XCTAssertEqual(store.historyReads, 1)
    }

    @MainActor
    private func label(_ identifier: String, inside contents: UIView) throws -> UILabel {
        try XCTUnwrap(descendants(contents).first { $0.accessibilityIdentifier == identifier } as? UILabel)
    }

    @MainActor
    private func descendants(_ contents: UIView) -> [UIView] {
        [contents] + contents.subviews.flatMap { descendants($0) }
    }

    private func summary(repetitions: Int, duration: Int, sets: Int) -> WorkoutSummary {
        WorkoutSummary(date: Date(timeIntervalSince1970: 1_793_188_800), duration: duration, repetitions: repetitions, sets: sets)
    }
}

private final class HistoryRenderNavigationController: UINavigationController {
    var onAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }

}

@MainActor
private final class HistoryUIStore: WorkoutStoring {
    var records: [WorkoutSummary] = []
    var failure: Error?
    var historyReads = 0
    var savedSummaries: [WorkoutSummary] = []

    func save(_ summary: WorkoutSummary) throws { savedSummaries.append(summary) }

    func history() throws -> [WorkoutSummary] {
        historyReads += 1
        if let failure { throw failure }
        return records
    }
}

private enum HistoryUIError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Контрольная ошибка хранилища." }
}
