//
//  SemanticVersion.swift
//  ClaudeIsland
//
//  Shared major.minor.patch version parsing/detection, used to gate
//  feature availability against an installed CLI's --version output.
//

import Foundation

struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// Extracts the first `X.Y.Z` token from arbitrary version output.
    /// Accepts any prefix/suffix — works for "2.1.88", "v2.1.88", "claude 2.1.88 (...)" etc.
    static func parse(from text: String) -> SemanticVersion? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges == 4,
              let majorRange = Range(match.range(at: 1), in: text),
              let minorRange = Range(match.range(at: 2), in: text),
              let patchRange = Range(match.range(at: 3), in: text),
              let major = Int(text[majorRange]),
              let minor = Int(text[minorRange]),
              let patch = Int(text[patchRange])
        else { return nil }
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    /// Runs `<binary> --version` on the first candidate path that exists and
    /// parses the result. Returns nil on any failure (binary not found,
    /// non-zero exit, unparseable output).
    static func detect(candidates: [String], arguments: [String] = ["--version"]) -> SemanticVersion? {
        let fm = FileManager.default
        guard let path = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parse(from: output)
        } catch {
            return nil
        }
    }
}
