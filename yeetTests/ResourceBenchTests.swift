//
//  ResourceBenchTests.swift
//  yeetTests
//

import XCTest
@testable import yeet

final class ResourceBenchTests: XCTestCase {
    func testFixtureRestoresExpectedProjectsTabsPanesAndHistory() {
        let fixture = ResourceBenchFixture.make(workingDirectory: "/tmp")

        XCTAssertEqual(fixture.snapshot.projects.count, 8)
        XCTAssertEqual(
            fixture.snapshot.projects.reduce(0) { $0 + $1.tabs.count },
            10
        )
        XCTAssertEqual(
            fixture.snapshot.projects.reduce(0) { total, project in
                total + project.tabs.reduce(0) { $0 + paneCount(in: $1.layout) }
            },
            15
        )
        XCTAssertEqual(fixture.histories.count, 15)
        XCTAssertTrue(fixture.histories.values.allSatisfy {
            $0.split(separator: "\n").count == 500
        })
    }

    func testGateAcceptsBudgetBoundary() {
        let failures = ResourceBenchGate.failures(for: ResourceBenchObservation(
            projectCount: 8,
            tabCount: 10,
            paneCount: 15,
            windowReadyMilliseconds: ResourceBenchBudget.startupTimeoutMilliseconds,
            peakPhysicalFootprintBytes: ResourceBenchBudget.maximumPhysicalFootprintBytes
        ))

        XCTAssertTrue(failures.isEmpty)
    }

    func testGateRejectsMissingReadinessAndMemoryOverBudget() {
        let failures = ResourceBenchGate.failures(for: ResourceBenchObservation(
            projectCount: 8,
            tabCount: 10,
            paneCount: 15,
            windowReadyMilliseconds: nil,
            peakPhysicalFootprintBytes: ResourceBenchBudget.maximumPhysicalFootprintBytes + 1
        ))

        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.contains("window did not become ready"))
        XCTAssertTrue(failures.contains { $0.contains("physical footprint") })
    }

    private func paneCount(
        in layout: SessionSnapshot.ProjectSnapshot.LayoutSnapshot
    ) -> Int {
        switch layout {
        case .pane:
            return 1
        case .split(_, _, let first, let second):
            return paneCount(in: first) + paneCount(in: second)
        }
    }
}
