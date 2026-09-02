import Combine
import XCTest
@testable import yeet

@MainActor
final class WorkspaceProjectSnapshotTests: XCTestCase {
    func testProjectNameRefreshesAfterPublishedMutation() async {
        let project = Project(fallbackName: "repo", createInitialSession: false)
        let store = WorkspaceProjectSnapshotStore(projects: [project])
        let expectation = expectation(description: "snapshot refresh")
        var values: [String] = []
        let observation = store.$projects.sink { snapshots in
            guard let name = snapshots.first?.name, name == "Renamed" else { return }
            values.append(name)
            expectation.fulfill()
        }

        project.customName = "Renamed"
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(values, ["Renamed"])
        withExtendedLifetime(observation) {}
    }

    func testRapidProjectMutationsPublishOnlyFinalSnapshot() async {
        let project = Project(fallbackName: "repo", createInitialSession: false)
        let store = WorkspaceProjectSnapshotStore(projects: [project])
        let expectation = expectation(description: "coalesced snapshot refresh")
        var values: [String] = []
        let observation = store.$projects.dropFirst().sink { snapshots in
            values.append(snapshots.first?.name ?? "")
            expectation.fulfill()
        }

        project.customName = "First"
        project.customName = "Final"
        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(values, ["Final"])
        withExtendedLifetime(observation) {}
    }

    func testProjectListAndRemovedProjectSubscriptionsStayCurrent() async {
        let first = Project(fallbackName: "first", createInitialSession: false)
        let second = Project(fallbackName: "second", createInitialSession: false)
        let store = WorkspaceProjectSnapshotStore(projects: [first])

        store.updateProjects([first, second])
        XCTAssertEqual(store.projects.map(\.id), [first.id, second.id])
        store.updateProjects([second, first])
        XCTAssertEqual(store.projects.map(\.id), [second.id, first.id])
        store.updateProjects([second])
        XCTAssertEqual(store.projects.map(\.id), [second.id])

        let expectation = expectation(description: "removed project ignored")
        expectation.isInverted = true
        let observation = store.$projects.dropFirst().sink { _ in expectation.fulfill() }
        first.customName = "Removed"
        await fulfillment(of: [expectation], timeout: 0.1)
        withExtendedLifetime(observation) {}
    }

    func testPendingReviewAndDirectoryRefreshAfterMutation() async {
        let project = Project(fallbackName: "repo", createInitialSession: false)
        let store = WorkspaceProjectSnapshotStore(projects: [project])
        let expectation = expectation(description: "project fields refresh")
        let observation = store.$projects.dropFirst().sink { snapshots in
            guard let snapshot = snapshots.first,
                  snapshot.pendingReview?.fileCount == 3,
                  snapshot.customDirectory == "/tmp/repo" else { return }
            expectation.fulfill()
        }

        project.pendingReview = PendingReview(fileCount: 3, sessionID: nil)
        project.customDirectory = "/tmp/repo"
        await fulfillment(of: [expectation], timeout: 1)
        withExtendedLifetime(observation) {}
    }

    func testStoreReleasesWithoutRetainingProjectSubscription() {
        let project = Project(fallbackName: "repo", createInitialSession: false)
        weak var weakStore: WorkspaceProjectSnapshotStore?
        var store: WorkspaceProjectSnapshotStore? = WorkspaceProjectSnapshotStore(projects: [project])
        weakStore = store
        store = nil
        XCTAssertNil(weakStore)
    }
}
