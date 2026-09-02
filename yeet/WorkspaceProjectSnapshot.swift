//
//  WorkspaceProjectSnapshot.swift
//  kero
//

import Combine
import Foundation

/// Derived values for UI consumers that display more than one project.
struct WorkspaceProjectSnapshot: Identifiable {
    let project: Project
    let id: UUID
    let name: String
    let sessions: [TerminalSession]
    let pendingReview: PendingReview?
    let selectedSession: TerminalSession?
    let customDirectory: String?
}

@MainActor
final class WorkspaceProjectSnapshotStore: ObservableObject {
    @Published private(set) var projects: [WorkspaceProjectSnapshot] = []

    private var projectObservations: [UUID: AnyCancellable] = [:]
    private var refreshScheduled = false

    init(projects: [Project]) {
        updateProjects(projects)
    }

    func snapshot(for id: UUID?) -> WorkspaceProjectSnapshot? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func updateProjects(_ projects: [Project]) {
        let currentIDs = Set(projects.map(\.id))
        projectObservations = projectObservations.filter { currentIDs.contains($0.key) }
        for project in projects where projectObservations[project.id] == nil {
            projectObservations[project.id] = project.objectWillChange
                .sink { [weak self] _ in self?.scheduleRefresh() }
        }
        refresh(from: projects)
    }

    private func refresh(from sources: [Project]) {
        projects = sources.map { project in
            WorkspaceProjectSnapshot(
                project: project,
                id: project.id,
                name: project.name,
                sessions: project.sessions,
                pendingReview: project.pendingReview,
                selectedSession: project.selectedSession,
                customDirectory: project.customDirectory
            )
        }
    }

    /// Combine publishes `objectWillChange` before an `@Published` setter
    /// stores its new value. Defer one coalesced refresh so snapshots read the
    /// post-mutation state while bursts of project edits stay cheap.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            refresh(from: projects.map(\.project))
        }
    }
}
