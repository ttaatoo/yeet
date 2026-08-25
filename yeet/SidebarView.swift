//
//  SidebarView.swift
//  kero
//

import AppKit
import SwiftUI

enum SidebarMetrics {
    static let defaultWidth: Double = 180
}

/// Vertical tab strip listing projects, otty-style. Each row is a project;
/// its sessions show as horizontal tabs in the main header. `placement`
/// is the physical edge; ⌘B and the width key stay bound to this panel.
struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    let bottomBarHeight: CGFloat
    var placement: HorizontalEdge = .leading
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var themeChanges = Theme.changes
    @Environment(\.openSettings) private var openSettings
    @AppStorage("leftSidebarWidth") private var width: Double = SidebarMetrics.defaultWidth
    @State private var draggedProjectID: UUID?
    @State private var projectFrames: [UUID: CGRect] = [:]

    private var isLeading: Bool { placement == .leading }

    private var innerAlignment: Alignment { isLeading ? .trailing : .leading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header-height strip. On the leading edge this also hosts the
            // traffic-light drag area; on the trailing edge it stays a
            // collapse control and window-drag strip only.
            HStack(spacing: 0) {
                if !isLeading {
                    projectSidebarToggle
                    if manager.isFPSCounterVisible {
                        FPSBadge()
                            .padding(.leading, 8)
                    }
                }
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                if isLeading {
                    if manager.isFPSCounterVisible {
                        FPSBadge()
                            .padding(.trailing, 8)
                    }
                    projectSidebarToggle
                }
            }
            .padding(isLeading ? .trailing : .leading, 8)
            .frame(height: 38)
            .background(Color(nsColor: Theme.chromeHeader))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: Theme.chromeDivider))
                    .frame(height: 1)
            }

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(Array(manager.projects.enumerated()), id: \.element.id) { index, project in
                        SidebarProjectRow(
                            project: project,
                            index: index,
                            isSelected: project.id == manager.selectedProjectID,
                            select: { manager.selectedProjectID = project.id },
                            close: { manager.close(project) },
                            isDragging: draggedProjectID == project.id,
                            onDrag: { updateProjectDrag(source: project.id, location: $0) },
                            onDragEnded: endProjectDrag,
                            fontSize: settings.sidebarFontSize
                        )
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ProjectFramePreferenceKey.self,
                                    value: [project.id: proxy.frame(in: .global)]
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            HStack(spacing: 2) {
                SidebarFooterButton(
                    systemImage: "plus",
                    tooltip: "New Project (⌘N)"
                ) { manager.newProject() }
                Spacer()
                SidebarFooterButton(
                    systemImage: "gearshape",
                    tooltip: "Settings (⌘,)",
                    tooltipAlignment: .trailing
                ) { openSettings() }
            }
            .padding(.horizontal, 8)
            .frame(height: bottomBarHeight)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: Theme.chromeDivider))
                    .frame(height: 1)
            }
        }
        .frame(width: width)
        // Opaque lifted near-black frame (or the light theme's solid fill).
        // Vibrancy made this column look like a different app from the
        // inspector after Swap sidebars.
        .background(Color(nsColor: Theme.sidebar))
        .overlay(alignment: innerAlignment) {
            Rectangle()
                .fill(Color(nsColor: Theme.chromeDivider))
                .frame(width: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: innerAlignment) {
            SidebarResizeHandle(
                edge: isLeading ? .trailing : .leading,
                width: $width,
                range: 160...400,
                defaultWidth: SidebarMetrics.defaultWidth
            )
        }
        .onPreferenceChange(ProjectFramePreferenceKey.self) { frames in
            afterViewUpdate { projectFrames = frames }
        }
    }

    private var projectSidebarToggle: some View {
        ChromeIconButton(
            systemImage: isLeading ? "sidebar.left" : "sidebar.right",
            tooltip: "Toggle Project Sidebar (⌘B)",
            tooltipAlignment: isLeading ? .trailing : .leading
        ) {
            manager.toggleLeftSidebar()
        }
    }

    private func updateProjectDrag(source: UUID, location: CGPoint) {
        draggedProjectID = source
        NSCursor.closedHand.set()
        guard let target = projectFrames.first(where: {
            $0.key != source && $0.value.contains(location)
        })?.key else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            manager.moveProject(source, to: target)
        }
    }

    private func endProjectDrag() {
        draggedProjectID = nil
        NSCursor.arrow.set()
    }
}

struct ChromeIconButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    var font: Font = .system(size: 12, weight: .medium)
    var iconSize: CGFloat = 16
    var tooltipEdge: TooltipEdge = .below
    var tooltipAlignment: HorizontalAlignment = .trailing
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .tooltip(tooltip, edge: tooltipEdge, alignment: tooltipAlignment)
        .accessibilityLabel(Text(tooltip))
    }
}

/// Live frames-per-second readout in the header strip, fed by `FPSCounter`.
/// It exists only while the manager's toggle is on, so the counter starts
/// when the badge appears and stops when it leaves the hierarchy.
private struct FPSBadge: View {
    @StateObject private var counter = FPSCounter()

    var body: some View {
        Text("\(counter.fps) fps")
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.07))
            )
            .onAppear { counter.start() }
            .onDisappear { counter.stop() }
    }
}

private struct SidebarFooterButton: View {
    let systemImage: String
    let tooltip: LocalizedStringKey
    /// Buttons near the sidebar's right edge anchor `.trailing` so the label
    /// grows inward instead of off-panel.
    var tooltipAlignment: HorizontalAlignment = .leading
    let action: () -> Void

    var body: some View {
        ChromeIconButton(
            systemImage: systemImage,
            tooltip: tooltip,
            tooltipEdge: .above,
            tooltipAlignment: tooltipAlignment,
            action: action
        )
    }
}

private struct ProjectFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SidebarProjectRow: NSViewRepresentable {
    let project: Project
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let isDragging: Bool
    let onDrag: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let fontSize: Double

    func makeNSView(context: Context) -> AppKitSidebarProjectRowView {
        let view = AppKitSidebarProjectRowView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ view: AppKitSidebarProjectRowView, context: Context) {
        update(view)
    }

    private func update(_ view: AppKitSidebarProjectRowView) {
        view.update(
            project: project,
            index: index,
            isSelected: isSelected,
            isDragging: isDragging,
            fontSize: fontSize,
            onSelect: select,
            onClose: close,
            onDrag: onDrag,
            onDragEnded: onDragEnded
        )
    }
}
