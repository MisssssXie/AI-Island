//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var isVisible: Bool = true
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Mascot pose reflecting the most urgent status across all sessions
    /// (approval > processing > waiting for input > idle).
    private var aggregatePose: CrabPose {
        if hasPendingPermission { return .alert }
        if isAnyProcessing { return .working }
        if hasWaitingForInput { return .happy }
        return .idle
    }

    /// Whether any Claude session is waiting for user input (done/ready state)
    /// — mirrors `phase` directly so the notch stays in sync with the real
    /// session state instead of expiring on its own after a fixed window.
    private var hasWaitingForInput: Bool {
        sessionMonitor.instances.contains { $0.phase == .waitingForInput }
    }

    /// Agent source of whichever session is driving `aggregatePose`, so the
    /// header mascot shows the right character (same priority order).
    private var aggregateSource: AgentSource {
        if let s = sessionMonitor.instances.first(where: { $0.phase.isWaitingForApproval }) {
            return s.source
        }
        if let s = sessionMonitor.instances.first(where: { $0.phase == .processing || $0.phase == .compacting }) {
            return s.source
        }
        if let s = sessionMonitor.instances.first(where: { $0.phase == .waitingForInput }) {
            return s.source
        }
        return .claude
    }

    /// Every agent source with at least one live session, in a stable order —
    /// the header shows one mascot per source so a Codex session sitting
    /// alongside a Claude one doesn't get hidden behind the aggregate icon.
    private var activeSources: [AgentSource] {
        let present = Set(sessionMonitor.instances.map(\.source))
        return AgentSource.allCases.filter(present.contains)
    }

    /// Pose for just one source's sessions (same urgency priority as
    /// `aggregatePose`, scoped to that source).
    private func aggregatePose(for source: AgentSource) -> CrabPose {
        let sessions = sessionMonitor.instances.filter { $0.source == source }
        if sessions.contains(where: { $0.phase.isWaitingForApproval }) { return .alert }
        if sessions.contains(where: { $0.phase == .processing || $0.phase == .compacting }) { return .working }
        if sessions.contains(where: { $0.phase == .waitingForInput }) { return .happy }
        return .idle
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0
        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude:
                let baseWidth = 2 * max(0, closedNotchSize.height - 12) + 20
                return baseWidth + permissionIndicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return 2 * max(0, closedNotchSize.height - 12) + 20 + permissionIndicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return 2 * max(0, closedNotchSize.height - 12) + 20
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible && !viewModel.isManuallyHidden ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            viewModel.sessionCount = instances.count
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    /// Whether there's an active state (processing, pending permission, or waiting for input)
    private var hasActiveState: Bool {
        isProcessing || hasPendingPermission || hasWaitingForInput
    }

    /// Always show closed content (crab + count) when notch is closed
    private var showClosedActivity: Bool {
        true
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            // Left side - crab + optional permission indicator (visible when processing, pending, or waiting for input)
            if showClosedActivity {
                HStack(spacing: 4) {
                    ForEach(headerMascotSources, id: \.self) { source in
                        MascotView(source: source, pose: aggregatePose(for: source), size: 24)
                            .matchedGeometryEffect(id: "crab-\(source.rawValue)", in: activityNamespace, isSource: showClosedActivity)
                    }

                    // Permission indicator only (amber) - waiting for input shows checkmark on right
                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
                .frame(width: viewModel.status == .opened ? nil : mascotRowWidth + (hasPendingPermission ? 18 : 0))
                .padding(.leading, viewModel.status == .opened ? 8 : 0)
                .animation(.smooth, value: headerMascotSources)
            }

            // Center content
            if viewModel.status == .opened {
                // Opened: show header content
                openedHeaderContent
            } else if !showClosedActivity {
                // Closed without activity: empty space
                Rectangle()
                    .fill(.clear)
                    .frame(width: closedNotchSize.width - 20)
            } else {
                // Closed with activity: black spacer over physical notch
                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))
            }

            // Right side - spinner/checkmark + session count
            if showClosedActivity {
                HStack(spacing: 4) {
                    if isProcessing || hasPendingPermission {
                        ProcessingSpinner()
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: hasActiveState)
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: hasActiveState)
                    }

                    if viewModel.status != .opened && sessionMonitor.instances.count > 0 {
                        Text("\(sessionMonitor.instances.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .frame(width: viewModel.status == .opened ? 20 : sideWidth + 8)
                .padding(.trailing, viewModel.status == .opened ? 0 : 4)
            }
        }
        .frame(height: closedNotchSize.height)
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    /// Active sources that are actually busy (not idle) right now — the
    /// header should only crowd in extra mascots for agents doing something,
    /// not every source that merely has a session sitting open.
    private var busySources: [AgentSource] {
        activeSources.filter { aggregatePose(for: $0) != .idle }
    }

    /// Same urgency order as `aggregatePose`: alert > working > happy.
    private func posePriority(_ pose: CrabPose) -> Int {
        switch pose {
        case .alert: return 0
        case .working: return 1
        case .happy: return 2
        case .idle: return 3
        }
    }

    /// Sources to render as mascots in the header — falls back to a single
    /// idle Claude crab when nothing is busy, so the pill is never empty.
    /// Capped at 2 so the pill doesn't keep growing as more agents pile on;
    /// when there's overflow, the most urgent sources (alert > working >
    /// happy) win the two slots.
    private var headerMascotSources: [AgentSource] {
        guard !busySources.isEmpty else { return [.claude] }
        return Array(
            busySources
                .sorted { posePriority(aggregatePose(for: $0)) < posePriority(aggregatePose(for: $1)) }
                .prefix(2)
        )
    }

    /// Reserved width for the header mascot row: one icon's worth of space
    /// plus 24pt (20pt icon + 4pt HStack spacing) for each additional
    /// character beyond the first.
    private var mascotRowWidth: CGFloat {
        sideWidth + CGFloat(max(0, headerMascotSources.count - 1)) * 24
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                MascotView(source: aggregateSource, pose: aggregatePose, size: 20)
                    .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                    .padding(.leading, 8)
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            // Minimize button - hide the notch
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.notchClose()
                    viewModel.isManuallyHidden = true
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                // Force a fresh ChatView when switching sessions — otherwise
                // @State (history, session, scroll position) leaks from the
                // previous session and the view shows the wrong conversation.
                // Keyed on sessionId only (not the whole SessionState) so
                // per-event updates still reuse the view.
                .id(session.sessionId)
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            activityCoordinator.showActivity(type: .claude)
            // Manual hide stays in effect through activity changes - only
            // explicit user action (shortcut, hover, click) should reveal it.
        } else {
            activityCoordinator.hideActivity()
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            // Only hover/click are explicit user intent to reveal a manually
            // hidden island - a silent notification-triggered open must not.
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                viewModel.isManuallyHidden = false
            }
        case .closed:
            break
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !viewModel.isManuallyHidden &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }
        }

        previousWaitingForInputIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
