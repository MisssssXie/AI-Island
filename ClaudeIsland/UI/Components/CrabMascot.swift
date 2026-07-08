//
//  CrabMascot.swift
//  ClaudeIsland
//
//  Pixel-art Claude mascot ("Clawd"): a small crab that sleeps in a flat
//  "sploot" when idle, curls dumbbells when working, and startles when
//  waiting on approval. The pose choreography and proportions are adapted
//  from NotchCove's PixelCharacterView.swift (ClawdView)
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

/// Mascot pose derived from a session's lifecycle phase.
enum CrabPose: Equatable {
    case idle
    case working
    case alert
    case happy
}

extension SessionPhase {
    /// Maps the state machine phase to a mascot pose.
    var crabPose: CrabPose {
        switch self {
        case .idle, .ended:
            return .idle
        case .processing, .compacting:
            return .working
        case .waitingForApproval:
            return .alert
        case .waitingForInput:
            return .happy
        }
    }
}

/// Pixel-art Claude mascot ("Clawd"): idle (flat "sploot" sleeping pose,
/// breathing, floating z's), working (alternating dumbbell curls), alert
/// (startled jump + arm wave + amber `!`), happy (standing, arms raised in
/// a cheerful wave, green "ready" eyes).
struct CrabMascotView: View {
    let pose: CrabPose
    var size: CGFloat = 16

    private static let bodyC = Color(red: 0.871, green: 0.533, blue: 0.427) // #DE886D
    private static let armC  = Color(red: 0.788, green: 0.459, blue: 0.353) // #C9755A
    private static let eyeC  = Color.black
    private static let dumbbellC = Color(red: 0.251, green: 0.835, blue: 0.651) // #40D5A6

    // Work-pose tuning (fixed equivalents of NotchCove's Mascot Lab sliders).
    private static let curlCycle: Double = 0.6
    private static let curlArmRaise: CGFloat = 3.0
    private static let curlSway: CGFloat = 0.3
    private static let dumbbellSize: CGFloat = 1.0

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

        init(_ sz: CGSize, boardW: CGFloat, boardH: CGFloat, x0: CGFloat = 0, y0: CGFloat) {
            s = min(sz.width / boardW, sz.height / boardH)
            ox = (sz.width - boardW * s) / 2 + x0 * s
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

    /// Rotated-rect path around a pivot, used for the alert/happy arm waves.
    private func armPath(_ v: V, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                          pivotX: CGFloat, pivotY: CGFloat, angle: CGFloat, dy: CGFloat) -> Path {
        let a = angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let corners: [(CGFloat, CGFloat)] = [
            (x - pivotX, y - pivotY),
            (x + w - pivotX, y - pivotY),
            (x + w - pivotX, y + h - pivotY),
            (x - pivotX, y + h - pivotY),
        ]
        var path = Path()
        for (i, (cx, cy)) in corners.enumerated() {
            let rx = cx * ca - cy * sa + pivotX
            let ry = cx * sa + cy * ca + pivotY
            let pt = CGPoint(x: v.ox + rx * v.s, y: v.oy + (ry - v.y0 + dy) * v.s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    private func draw(context: inout GraphicsContext, canvasSize: CGSize, t: Double) {
        switch pose {
        case .idle: drawSleep(context, canvasSize, t)
        case .working: drawWork(context, canvasSize, t)
        case .alert: drawAlert(&context, canvasSize, t)
        case .happy: drawHappy(&context, canvasSize, t)
        }
    }

    // MARK: - Idle: flat "sploot" sleeping pose, breathing

    private func drawSleep(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 17, boardH: 7, y0: 9)
        let phase = t.truncatingRemainder(dividingBy: 4.5) / 4.5
        let breathe: CGFloat = phase < 0.4 ? sin(phase / 0.4 * .pi) : 0

        let shadowScale = 1.0 + breathe * 0.03
        c.fill(Path(v.r(-1, 15, 17 * shadowScale, 1)), with: .color(.black.opacity(0.35 + breathe * 0.08)))

        for x: CGFloat in [3, 5, 9, 11] {
            c.fill(Path(v.r(x, 8.5, 1, 1.5)), with: .color(Self.bodyC))
        }

        let puff = max(0, breathe) * 0.25
        let torsoH: CGFloat = 5 * (1.0 + puff)
        let torsoY: CGFloat = 15 - torsoH
        let torsoW: CGFloat = 13 * (1.0 + breathe * 0.015)
        let torsoX: CGFloat = 1 - (torsoW - 13) / 2
        c.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH)), with: .color(Self.bodyC))

        c.fill(Path(v.r(-1, 13, 2, 2)), with: .color(Self.bodyC))
        c.fill(Path(v.r(14, 13, 2, 2)), with: .color(Self.bodyC))

        let eyeY: CGFloat = 12.2 - puff * 2.5
        c.fill(Path(v.r(3, eyeY, 2.5, 1.0)), with: .color(Self.eyeC))
        c.fill(Path(v.r(9.5, eyeY, 2.5, 1.0)), with: .color(Self.eyeC))
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
                let xOff = size * CGFloat(0.10 + ci * 0.08 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.15 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    // MARK: - Working: alternating dumbbell curls

    private func drawWork(_ c: GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 18, boardH: 11, x0: 1, y0: 4.8)

        let leftRaw = sin(t * 2 * .pi / Self.curlCycle)
        let rightRaw = sin(t * 2 * .pi / Self.curlCycle + .pi)
        let leftRaise: CGFloat = (leftRaw + 1) / 2
        let rightRaise: CGFloat = (rightRaw + 1) / 2

        let sway = CGFloat(leftRaw - rightRaw) * Self.curlSway
        let breathe = (leftRaise + rightRaise - 1) * 0.5

        let blinkPhase = t.truncatingRemainder(dividingBy: 3.2)
        let eyeH: CGFloat = (blinkPhase > 1.4 && blinkPhase < 1.55) ? 0.2 : 1.6

        c.fill(Path(v.r(3, 15, 9, 1)), with: .color(.black.opacity(0.32)))

        for x: CGFloat in [3, 5, 9, 11] {
            c.fill(Path(v.r(x, 13, 1, 2)), with: .color(Self.bodyC))
        }

        drawCurl(c, v: v, shoulderX: 1.5 + sway, raise: leftRaise)
        drawCurl(c, v: v, shoulderX: 13.5 + sway, raise: rightRaise)

        let bScale = 1.0 + breathe * 0.03
        let torsoW = 11 * bScale
        let torsoX = 2 - (torsoW - 11) / 2 + sway
        c.fill(Path(v.r(torsoX, 6, torsoW, 7)), with: .color(Self.bodyC))

        let eyeY = 8 + (1.6 - eyeH) / 2
        c.fill(Path(v.r(4.3 + sway, eyeY, 1, eyeH)), with: .color(Self.eyeC))
        c.fill(Path(v.r(9.7 + sway, eyeY, 1, eyeH)), with: .color(Self.eyeC))
    }

    private func drawCurl(_ c: GraphicsContext, v: V, shoulderX: CGFloat, raise: CGFloat) {
        let shoulderY: CGFloat = 9
        let fistY: CGFloat = 12 - raise * Self.curlArmRaise
        let top = min(shoulderY, fistY)
        let armH = abs(shoulderY - fistY) + 1.7
        c.fill(Path(v.r(shoulderX, top, 1.2, armH)), with: .color(Self.armC))

        let fistCenter = shoulderX + 0.6
        let sizeMul = Self.dumbbellSize
        let weightW: CGFloat = 1.9 * sizeMul
        let weightH: CGFloat = 2.6 * sizeMul
        let gap: CGFloat = 1.0 * sizeMul
        let dumbbellW = weightW * 2 + gap
        let dbX = fistCenter - dumbbellW / 2
        let dbY = fistY - weightH / 2 + 0.3
        let corner = v.s * 0.55 * sizeMul
        c.fill(Path(roundedRect: v.r(dbX, dbY, weightW, weightH), cornerRadius: corner), with: .color(Self.dumbbellC))
        let barH: CGFloat = 0.8 * sizeMul
        c.fill(Path(v.r(dbX + weightW, dbY + (weightH - barH) / 2, gap, barH)), with: .color(Self.dumbbellC))
        c.fill(Path(roundedRect: v.r(dbX + weightW + gap, dbY, weightW, weightH), cornerRadius: corner), with: .color(Self.dumbbellC))
    }

    // MARK: - Alert: startled jump with arm wave and amber `!`

    private func drawAlert(_ c: inout GraphicsContext, _ sz: CGSize, _ t: Double) {
        let v = V(sz, boardW: 15, boardH: 12, y0: 4)
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -10), (0.20, -10), (0.25, 1.5),
            (0.275, -8), (0.30, -8), (0.35, 1.2),
            (0.375, -5), (0.40, -5), (0.45, 1.0),
            (0.475, -3), (0.50, -3), (0.55, 0.5),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let scaleX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.05 : 1.0
        let scaleY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.04 : 1.0

        let armL = lerp([
            (0, 0), (0.03, 0), (0.10, 25),
            (0.15, 30), (0.20, 155), (0.25, 115),
            (0.30, 140), (0.35, 100), (0.40, 115),
            (0.45, 80), (0.50, 80), (0.55, 40),
            (0.62, 0), (1.0, 0),
        ], at: pct)
        let armR = -lerp([
            (0, 0), (0.03, 0), (0.10, 30),
            (0.15, 30), (0.20, 155), (0.25, 115),
            (0.30, 140), (0.35, 100), (0.40, 115),
            (0.45, 80), (0.50, 80), (0.55, 40),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let eyeScale: CGFloat = (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0
        let eyeDY: CGFloat = (pct > 0.03 && pct < 0.15) ? -0.5 : 0

        let bangOpacity = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        let shadowW: CGFloat = 9 * (1.0 - abs(min(0, jumpY)) * 0.04)
        let shadowOp = max(0.08, 0.5 - abs(min(0, jumpY)) * 0.04)
        c.fill(Path(v.r(3 + (9 - shadowW) / 2, 15, shadowW, 1)), with: .color(.black.opacity(shadowOp)))

        for x: CGFloat in [3, 5, 9, 11] {
            c.fill(Path(v.r(x, 11, 1, 4)), with: .color(Self.bodyC))
        }

        let torsoW = 11 * scaleX
        let torsoH = 7 * scaleY
        let torsoX = 2 - (torsoW - 11) / 2
        let torsoY = 6 + (7 - torsoH)
        c.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH, dy: jumpY)), with: .color(Self.bodyC))

        let eyeH = 2 * eyeScale
        let eyeYPos = 8 + (2 - eyeH) / 2 + eyeDY
        c.fill(Path(v.r(4, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))
        c.fill(Path(v.r(10, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))

        c.fill(armPath(v, x: 0, y: 9, w: 2, h: 2, pivotX: 2, pivotY: 10, angle: armL, dy: jumpY), with: .color(Self.bodyC))
        c.fill(armPath(v, x: 13, y: 9, w: 2, h: 2, pivotX: 13, pivotY: 10, angle: armR, dy: jumpY), with: .color(Self.bodyC))

        if bangOpacity > 0.01 {
            let bw: CGFloat = 2 * bangScale
            let bx: CGFloat = 13
            let by: CGFloat = 4.5 + jumpY * 0.15
            c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)), with: .color(TerminalColors.amber.opacity(bangOpacity)))
            c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)), with: .color(TerminalColors.amber.opacity(bangOpacity)))
        }
    }

    // MARK: - Happy: the original pre-rewrite crab, walking-leg cycle from
    // the old `ClaudeCrabIcon` (used there while a session was processing).

    private static let legacyCrabColor = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let legacyLegOffsets: [[CGFloat]] = [
        [3, -3, 3, -3],
        [0, 0, 0, 0],
        [-3, 3, -3, 3],
        [0, 0, 0, 0],
    ]

    private func drawHappy(_ c: inout GraphicsContext, _ sz: CGSize, _ t: Double) {
        // Extra padding around the 66x52 art so it renders at roughly the
        // same on-screen size as the other poses instead of filling the frame.
        let v = V(sz, boardW: 86, boardH: 68, x0: 10, y0: -8)
        let offsets = Self.legacyLegOffsets[Int(t / 0.15) % 4]

        c.fill(Path(v.r(0, 13, 6, 13)), with: .color(Self.legacyCrabColor))
        c.fill(Path(v.r(60, 13, 6, 13)), with: .color(Self.legacyCrabColor))

        for (index, x) in [CGFloat(6), 18, 42, 54].enumerated() {
            c.fill(Path(v.r(x, 39, 6, 13 + offsets[index])), with: .color(Self.legacyCrabColor))
        }

        c.fill(Path(v.r(6, 0, 54, 39)), with: .color(Self.legacyCrabColor))

        c.fill(Path(v.r(12, 13, 6, 6.5)), with: .color(.black))
        c.fill(Path(v.r(48, 13, 6, 6.5)), with: .color(.black))
    }
}
