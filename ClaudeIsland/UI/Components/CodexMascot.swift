//
//  CodexMascot.swift
//  ClaudeIsland
//
//  Pixel-art Codex mascot: a small terminal cloud with a `>_` prompt face.
//  The cloud silhouette, prompt glyph, and pose choreography are adapted
//  from NotchCove's DexView (https://github.com/fantasynovel/NotchCove),
//  used under the MIT License:
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

/// Pixel-art Codex mascot ("Dex"): an off-white cloud with a black `>_`
/// terminal prompt face. Poses mirror `CrabPose`: idle (sleeping, floating
/// "z"s, dim cursor), working (bouncing, typing on a tiny keyboard), alert
/// (startled jump + shake + amber `!`), happy (calm bounce, green prompt).
struct CodexMascotView: View {
    let pose: CrabPose
    var size: CGFloat = 16

    private static let cloud = Color(white: 0.93)
    private static let cloudDark = Color(white: 0.72)
    private static let prompt = Color.black

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
        .frame(width: size * (66.0 / 52.0), height: size)
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

    /// Rounded cloud made of overlapping rows (8-bit blob silhouette).
    private func drawCloud(_ c: GraphicsContext, _ v: V, dy: CGFloat) {
        let rows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (14, 4, 7), (13, 3, 9), (12, 2, 11), (11, 1, 13), (10, 1, 13),
            (9, 1, 13), (8, 2, 11), (7, 2, 11),
            (6, 3, 3), (6, 6, 3), (6, 9, 3),
            (5, 4, 2), (5, 6.5, 2), (5, 9, 2),
        ]
        for row in rows {
            c.fill(Path(v.r(row.x, row.y, row.w, 1, dy: dy)), with: .color(Self.cloud))
        }
    }

    private func drawPrompt(_ c: GraphicsContext, _ v: V, dy: CGFloat, color: Color, cursorOn: Bool) {
        c.fill(Path(v.r(3, 10, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(4, 11, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(3, 12, 1, 1, dy: dy)), with: .color(color))
        if cursorOn {
            c.fill(Path(v.r(6, 12, 3, 1, dy: dy)), with: .color(color))
        }
    }

    private func drawLegs(_ c: GraphicsContext, _ v: V) {
        c.fill(Path(v.r(5, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
        c.fill(Path(v.r(9, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
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
                    .foregroundColor(Self.prompt.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    // MARK: - Poses

    /// Idle: gentle float, cursor blinks slowly, mouth (chevron) hidden.
    private func drawSleep(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 15, boardH: 12, y0: 4)
        let float = sin(t.truncatingRemainder(dividingBy: 4.0) / 4.0 * .pi * 2) * 1.4
        let cursorOn = t.truncatingRemainder(dividingBy: 1.2) < 0.6

        drawShadow(c, v, width: 7, opacity: 0.2)
        drawLegs(c, v)
        drawCloud(c, v, dy: float)
        if cursorOn {
            c.fill(Path(v.r(6, 12, 3, 1, dy: float)), with: .color(Self.prompt.opacity(0.3)))
        }
    }

    /// Working: rapid bounce, blinking cursor, a key flashes on the keyboard.
    private func drawWork(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.5
        let cursorOn = t.truncatingRemainder(dividingBy: 0.3) < 0.15
        let keyPhase = Int(t / 0.1) % 6

        let shadowW: CGFloat = 8 - abs(bounce) * 0.3
        drawShadow(c, v, width: shadowW, opacity: max(0.1, 0.35 - abs(bounce) * 0.03))
        drawLegs(c, v)

        c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Color(white: 0.15)))
        for row in 0..<2 {
            let ky = 13.5 + CGFloat(row) * 1.2
            for col in 0..<6 {
                let kx = 0.5 + CGFloat(col) * 2.4
                c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Color(white: 0.4)))
            }
        }
        let fkx = 0.5 + CGFloat(keyPhase % 6) * 2.4
        let fky = 13.5 + CGFloat(keyPhase / 3) * 1.2
        c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(.white.opacity(0.9)))

        drawCloud(c, v, dy: bounce)
        drawPrompt(c, v, dy: bounce, color: Self.prompt, cursorOn: cursorOn)
    }

    /// Alert: startled jump with squash/stretch, shake, flashing prompt, `!` mark.
    private func drawAlert(_ c: inout GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -9), (0.20, -9), (0.25, 1.5),
            (0.275, -7), (0.30, -7), (0.35, 1.0),
            (0.375, -5), (0.40, -5), (0.45, 0.8),
            (0.475, -2.5), (0.50, -2.5), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 1.4 : 0
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let promptColor = flash > 0.5 ? TerminalColors.amber : Self.prompt

        let bangOp = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.03)
        drawShadow(c, v, width: shadowW, opacity: max(0.08, 0.4 - abs(min(0, jumpY)) * 0.03))
        drawLegs(c, v)

        c.translateBy(x: shakeX * v.s, y: 0)
        drawCloud(c, v, dy: jumpY)
        drawPrompt(c, v, dy: jumpY, color: promptColor, cursorOn: true)
        c.translateBy(x: -shakeX * v.s, y: 0)

        if bangOp > 0.01 {
            let bw = 2 * bangScale
            let bx: CGFloat = 13
            let by: CGFloat = 2.5 + jumpY * 0.15
            c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale)), with: .color(TerminalColors.amber.opacity(bangOp)))
            c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale)), with: .color(TerminalColors.amber.opacity(bangOp)))
        }
    }

    /// Happy: calm bounce, green "done" prompt, solid cursor — ready for the next turn.
    private func drawHappy(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 16, boardH: 14, y0: 3)
        let bounce = -abs(sin(t * 2 * .pi / 0.8)) * 2.0

        let shadowW: CGFloat = 8 - abs(bounce) * 0.2
        drawShadow(c, v, width: shadowW, opacity: max(0.12, 0.35 - abs(bounce) * 0.02))
        drawLegs(c, v)
        drawCloud(c, v, dy: bounce)
        drawPrompt(c, v, dy: bounce, color: TerminalColors.green, cursorOn: true)
    }
}
