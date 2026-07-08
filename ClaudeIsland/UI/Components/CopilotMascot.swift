//
//  CopilotMascot.swift
//  ClaudeIsland
//
//  Pixel-art GitHub Copilot CLI mascot: a rose-shelled bot with two hollow
//  ear loops and gold dot eyes. The ear/body/eye silhouettes and pose
//  choreography are adapted from NotchCove's CopilotView
//  (https://github.com/fantasynovel/NotchCove), used under the MIT License:
//
//    MIT License
//    Copyright (c) 2026 wxtsky
//    Copyright (c) 2026 fantasynovel
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, subject to including the above copyright notice and
//    this permission notice in all copies or substantial portions of the Software.
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//

import SwiftUI

/// Pixel-art Copilot mascot: a rose-shelled bot with two hollow ear loops and
/// gold dot eyes. Poses mirror `CrabPose`: idle (sleeping, floating "z"s, dim
/// shell), working (bounce, blinking eyes, ear signal pulse, tiny keyboard),
/// alert (startled jump + shake + amber flash + "!"), happy (calm bounce,
/// green eyes — NotchCove's source has no done/happy state, so this pose is
/// this app's own addition, matching CodexMascotView's approach).
struct CopilotMascotView: View {
    let pose: CrabPose
    var size: CGFloat = 16

    private static let earC = Color(red: 0.20, green: 0.20, blue: 0.20)
    private static let bodyC = Color(red: 0.80, green: 0.20, blue: 0.40)
    private static let faceC = Color(red: 0.13, green: 0.13, blue: 0.16)
    private static let eyeC = Color(red: 1.00, green: 0.84, blue: 0.00)
    private static let kbBase = Color(red: 0.12, green: 0.08, blue: 0.10)
    private static let kbKey = Color(red: 0.35, green: 0.15, blue: 0.22)
    private static let kbHi = Color.white

    var body: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.03)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, canvasSize in
                    draw(context: &context, canvasSize: canvasSize, t: t)
                }
            }
            if pose == .idle {
                TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                    floatingZs(t: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Coordinate helper (maps a pose's own art board onto canvasSize)

    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, boardW: CGFloat, boardH: CGFloat, y0: CGFloat) {
            s = min(sz.width / boardW, sz.height / boardH)
            ox = (sz.width - boardW * s) / 2
            oy = (sz.height - boardH * s) / 2
            self.y0 = y0
        }

        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count where pct <= keyframes[i].0 {
            let t = (pct - keyframes[i - 1].0) / (keyframes[i].0 - keyframes[i - 1].0)
            return keyframes[i - 1].1 + (keyframes[i].1 - keyframes[i - 1].1) * t
        }
        return keyframes.last?.1 ?? 0
    }

    private func draw(context: inout GraphicsContext, canvasSize: CGSize, t: Double) {
        switch pose {
        case .idle: drawSleep(context, canvasSize, t)
        case .working: drawWork(context, canvasSize, t)
        case .alert: drawAlert(&context, canvasSize, t)
        case .happy: drawHappy(context, canvasSize, t)
        }
    }

    // MARK: - Shared parts

    /// Two hollow rounded-rect ear loops on top, with stems into the body.
    private func drawEars(_ c: GraphicsContext, _ v: V, dy: CGFloat, color: Color? = nil, signal: Bool = false) {
        let ec = color ?? Self.earC
        c.fill(Path(v.r(3, 5, 3, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(3, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(5, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(3, 7, 3, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 5, 3, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(11, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 7, 3, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(4, 8, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(10, 8, 1, 1, dy: dy)), with: .color(ec))
        if signal {
            c.fill(Path(v.r(4, 6, 1, 1, dy: dy)), with: .color(Self.eyeC.opacity(0.5)))
            c.fill(Path(v.r(10, 6, 1, 1, dy: dy)), with: .color(Self.eyeC.opacity(0.5)))
        }
    }

    /// Rose shell frame with a dark face screen between the cheeks.
    private func drawBody(_ c: GraphicsContext, _ v: V, dy: CGFloat, shellColor: Color? = nil) {
        let bc = shellColor ?? Self.bodyC
        c.fill(Path(v.r(2, 9, 11, 1, dy: dy)), with: .color(bc))
        c.fill(Path(v.r(2, 10, 2, 3, dy: dy)), with: .color(bc))
        c.fill(Path(v.r(11, 10, 2, 3, dy: dy)), with: .color(bc))
        c.fill(Path(v.r(4, 10, 7, 3, dy: dy)), with: .color(Self.faceC))
        c.fill(Path(v.r(2, 13, 11, 1, dy: dy)), with: .color(bc))
        c.fill(Path(v.r(4, 14, 7, 1, dy: dy)), with: .color(bc))
    }

    private func drawEyes(_ c: GraphicsContext, _ v: V, dy: CGFloat, color: Color? = nil, height: CGFloat = 1) {
        let ec = color ?? Self.eyeC
        c.fill(Path(v.r(5, 10, 1, height, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 10, 1, height, dy: dy)), with: .color(ec))
    }

    private func drawLegs(_ c: GraphicsContext, _ v: V) {
        c.fill(Path(v.r(6, 14.5, 1, 1.5)), with: .color(Self.bodyC.opacity(0.6)))
        c.fill(Path(v.r(8, 14.5, 1, 1.5)), with: .color(Self.bodyC.opacity(0.6)))
    }

    private func drawShadow(_ c: GraphicsContext, _ v: V, width: CGFloat, opacity: Double) {
        c.fill(Path(v.r(7.5 - width / 2, 15.5, width, 1)), with: .color(.black.opacity(opacity)))
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(5, size * CGFloat(0.16 + phase * 0.10))
                let baseOpacity = 0.7 - ci * 0.15
                let opacity = phase < 0.8 ? baseOpacity : (1.0 - phase) * 3.5 * baseOpacity
                let xOff = size * CGFloat(0.15 + ci * 0.10 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.05 + phase * 0.5)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundColor(Color.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    // MARK: - Poses

    /// Idle: gentle float, dimmed shell, no eyes lit.
    private func drawSleep(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 15, boardH: 12, y0: 4)
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.8

        drawShadow(c, v, width: 7 + abs(float) * 0.3, opacity: 0.2)
        drawLegs(c, v)
        drawEars(c, v, dy: float)
        drawBody(c, v, dy: float, shellColor: Self.bodyC.opacity(0.4))
    }

    /// Working: rapid bounce, blinking eyes, an ear signal pulse, a key flashes.
    private func drawWork(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0
        let keyPhase = Int(t / 0.1) % 6
        let blinkCycle = t.truncatingRemainder(dividingBy: 3.2)
        let showEyes = !(blinkCycle > 1.5 && blinkCycle < 1.6)
        let sigPhase = t.truncatingRemainder(dividingBy: 2.5)
        let earSignal = sigPhase > 2.0 && sigPhase < 2.3

        let shadowW: CGFloat = 8 - abs(bounce) * 0.3
        drawShadow(c, v, width: shadowW, opacity: max(0.1, 0.35 - abs(bounce) * 0.03))
        drawLegs(c, v)

        c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
        for row in 0..<2 {
            let ky = 13.5 + CGFloat(row) * 1.2
            for col in 0..<6 {
                let kx = 0.5 + CGFloat(col) * 2.4
                c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
            }
        }
        let fkx = 0.5 + CGFloat(keyPhase % 6) * 2.4
        let fky = 13.5 + CGFloat(keyPhase / 3) * 1.2
        c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(Self.kbHi.opacity(0.9)))

        drawEars(c, v, dy: bounce, signal: earSignal)
        drawBody(c, v, dy: bounce)
        if showEyes { drawEyes(c, v, dy: bounce) }
    }

    /// Alert: startled jump with shake, ear/shell flash to amber, widened eyes, "!" mark.
    private func drawAlert(_ c: inout GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -8), (0.20, -8), (0.25, 1.5),
            (0.275, -6), (0.30, -6), (0.35, 1.0),
            (0.375, -4), (0.40, -4), (0.45, 0.8),
            (0.475, -2), (0.50, -2), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 1.0 : 0
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let earColor = flash > 0.5 ? TerminalColors.amber : Self.earC
        let shellColor = flash > 0.5 ? TerminalColors.amber : Self.bodyC
        let eyeH: CGFloat = (pct > 0.03 && pct < 0.55) ? 2 : 1

        let bangOp = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
        drawShadow(c, v, width: shadowW, opacity: max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))
        drawLegs(c, v)

        c.translateBy(x: shakeX * v.s, y: 0)
        drawEars(c, v, dy: jumpY, color: earColor)
        drawBody(c, v, dy: jumpY, shellColor: shellColor)
        drawEyes(c, v, dy: jumpY, height: eyeH)
        c.translateBy(x: -shakeX * v.s, y: 0)

        if bangOp > 0.01 {
            let bw = 2 * bangScale
            let bx: CGFloat = 13
            let by: CGFloat = 4 + jumpY * 0.15
            c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale)), with: .color(TerminalColors.amber.opacity(bangOp)))
            c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale)), with: .color(TerminalColors.amber.opacity(bangOp)))
        }
    }

    /// Happy: calm bounce, green "done" eyes — ready for the next turn.
    private func drawHappy(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let bounce = -abs(sin(t * 2 * .pi / 0.8)) * 4.0

        let shadowW: CGFloat = 8 - abs(bounce) * 0.2
        drawShadow(c, v, width: shadowW, opacity: max(0.12, 0.35 - abs(bounce) * 0.02))
        drawLegs(c, v)
        drawEars(c, v, dy: bounce)
        drawBody(c, v, dy: bounce)
        drawEyes(c, v, dy: bounce, color: TerminalColors.green)
    }
}
