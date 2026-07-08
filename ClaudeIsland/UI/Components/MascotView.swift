//
//  MascotView.swift
//  ClaudeIsland
//
//  Routes a session's agent source to its mascot character.
//

import SwiftUI

/// Picks the right pixel-art mascot for a session's `AgentSource`, sharing
/// one pose vocabulary (`CrabPose`) and frame size across characters.
struct MascotView: View {
    let source: AgentSource
    let pose: CrabPose
    var size: CGFloat = 16

    var body: some View {
        switch source {
        case .codex:
            CodexMascotView(pose: pose, size: size - 6)
        case .copilot:
            CopilotMascotView(pose: pose, size: size)
        case .claude:
            CrabMascotView(pose: pose, size: size)
        }
    }
}

#Preview {
    VStack {
        MascotView(source: .codex, pose: .idle, size: 32)
        MascotView(source: .codex, pose: .working, size: 32)
        MascotView(source: .codex, pose: .alert, size: 32)
        MascotView(source: .codex, pose: .happy, size: 32)
        
        
        MascotView(source: .copilot, pose: .idle, size: 32)
        MascotView(source: .copilot, pose: .working, size: 32)
        MascotView(source: .copilot, pose: .alert, size: 32)
        MascotView(source: .copilot, pose: .happy, size: 32)
        
        MascotView(source: .claude, pose: .idle, size: 32)
        MascotView(source: .claude, pose: .working, size: 32)
        MascotView(source: .claude, pose: .alert, size: 32)
        MascotView(source: .claude, pose: .happy, size: 32)
    }
}
