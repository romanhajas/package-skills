// Skills.swift - compare your skills with your Claude account and build upload ZIPs.
//
// Claude Code keeps a copy of the skills in your Claude account under
// ~/.claude/skills/synced/<id>/ (with a manifest.json). Every skill of yours that
// also lives in ~/.claude/skills/<name> is staged the way the Claude app expects
// it, compared with that copy, and zipped into ~/Desktop/claude-skills-upload only
// when the two differ. So that folder always holds exactly what needs uploading.

import Foundation

struct Problem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SkillRow: Identifiable, Sendable {
    enum State: Sendable {
        case upload(new: Bool)   // newer here than in Claude, or not in Claude yet
        case upToDate
        case onlyInClaude        // in your Claude account, not on this Mac
        case onlyOnMac           // on this Mac, not in your Claude account
        case hidden              // only in Claude, and you chose not to set it up here
        case failed(String)
    }
    let name: String
    let state: State
    var notes: [String] = []
    var id: String { name }
}

struct Report: Sendable {
    var rows: [SkillRow] = []
    var syncedAt: Date? = nil
    var noSync = false
}

enum Skills {
    static let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    static let skillsDir = home.appendingPathComponent(".claude/skills")
    static let syncedRoot = skillsDir.appendingPathComponent("synced")
    static let outDir = home.appendingPathComponent("Desktop/claude-skills-upload")
    static let configDir: URL = {
        let dir = home.appendingPathComponent(".config/skill-bridge")
        // Settings from before the rename (Package Skills) move over once.
        let old = home.appendingPathComponent(".config/package-skills")
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        return dir
    }()
    static let configFile = configDir.appendingPathComponent("config.json")
    static let hiddenFile = configDir.appendingPathComponent("hidden.json")

    /// Frontmatter keys the Claude app's uploader accepts; anything else moves under metadata.
    static let allowedKeys: Set<String> = ["name", "description", "license", "allowed-tools", "metadata", "compatibility"]
    static let ignoredNames: Set<String> = [".DS_Store", "__pycache__", ".git"]
    static let blockScalars: Set<String> = ["|", ">", "|-", ">-", "|+", ">+"]

    private static let fm = FileManager.default

    static func zip(for name: String) -> URL { outDir.appendingPathComponent("\(name).zip") }

    // MARK: - Check

    /// Compares every skill and rebuilds the ZIPs. `adding` are skills on this Mac to
    /// send to Claude for the first time; a ZIP already waiting for one counts too.
    static func check(adding: [String] = []) -> Report {
        guard let claude = claudeCopy() else { return Report(noSync: true) }
        let yours = Set(claude.yours)
        let local = localSkills()
        let hidden = loadHidden()
        let config = Config.load()
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: outDir.appendingPathComponent(".hashes.json"))  // left by version 1

        let tmp = fm.temporaryDirectory.appendingPathComponent("skill-bridge-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        let pendingNew = local.filter { !yours.contains($0) && (adding.contains($0) || fm.fileExists(atPath: zip(for: $0).path)) }
        var rows: [SkillRow] = []
        for name in local.filter(yours.contains) + pendingNew {
            do {
                let (staged, notes) = try stage(name, in: tmp, config: config)
                let isYours = yours.contains(name)
                if isYours, try sameSkill(staged, claude.folder.appendingPathComponent(name)) {
                    try? fm.removeItem(at: zip(for: name))
                    rows.append(SkillRow(name: name, state: .upToDate, notes: notes))
                } else {
                    try writeZip(staged, to: zip(for: name))
                    rows.append(SkillRow(name: name, state: .upload(new: !isYours), notes: notes))
                }
            } catch {
                rows.append(SkillRow(name: name, state: .failed(error.localizedDescription)))
            }
        }
        for name in claude.yours.sorted() where !local.contains(name) {
            rows.append(SkillRow(name: name, state: hidden.contains(name) ? .hidden : .onlyInClaude))
        }
        for name in local where !yours.contains(name) && !pendingNew.contains(name) {
            rows.append(SkillRow(name: name, state: .onlyOnMac))
        }
        return Report(rows: rows, syncedAt: claude.syncedAt)
    }

    // MARK: - Actions

    /// Copies a skill from your Claude account's copy into ~/.claude/skills.
    static func setUp(_ name: String) throws {
        guard let claude = claudeCopy() else { throw Problem("Can't find your Claude account's skills on this Mac.") }
        let src = claude.folder.appendingPathComponent(name), dst = skillsDir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.appendingPathComponent("SKILL.md").path) else { throw Problem("\(name) is not in your Claude account.") }
        guard !fm.fileExists(atPath: dst.path) else { throw Problem("\(name) is already on this Mac at \(dst.path).") }
        try copyTree(src, to: dst)
    }

    /// Stops (or resumes) offering to set up a Claude-only skill on this Mac.
    static func setHidden(_ name: String, _ hide: Bool) throws {
        var hidden = loadHidden()
        if hide { hidden.insert(name) } else { hidden.remove(name) }
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: hidden.sorted(), options: [.prettyPrinted]).write(to: hiddenFile)
    }

    /// Drops a waiting ZIP for a skill you no longer want to send to Claude.
    static func discard(_ name: String) { try? fm.removeItem(at: zip(for: name)) }

    // MARK: - Claude's copy and this Mac's skills

    struct ClaudeCopy { let folder: URL; let yours: [String]; let syncedAt: Date }

    /// The newest synced copy of the Claude account's skills. Anthropic's own
    /// skills are left out; the rest are the ones you uploaded.
    static func claudeCopy() -> ClaudeCopy? {
        let dirs = (try? fm.contentsOfDirectory(at: syncedRoot, includingPropertiesForKeys: nil)) ?? []
        var best: (manifest: [String: Any], path: URL)?
        for dir in dirs {
            let path = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: path),
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if best == nil || lastUpdated(manifest) > lastUpdated(best!.manifest) { best = (manifest, path) }
        }
        guard let best else { return nil }
        let (manifest, path) = best
        let skills = manifest["skills"] as? [[String: Any]] ?? []
        let yours = skills.filter { !(($0["source"] as? String) ?? "").hasPrefix("anthropic") }.compactMap { $0["name"] as? String }
        let modified = (try? fm.attributesOfItem(atPath: path.path)[.modificationDate] as? Date) ?? .distantPast
        let syncedAt = max(Date(timeIntervalSince1970: lastUpdated(manifest) / 1000), modified)
        return ClaudeCopy(folder: path.deletingLastPathComponent(), yours: yours, syncedAt: syncedAt)
    }

    private static func lastUpdated(_ manifest: [String: Any]) -> Double { (manifest["lastUpdated"] as? NSNumber)?.doubleValue ?? 0 }

    static func localSkills() -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: skillsDir.path)) ?? []
        return names.filter { $0 != "synced" && !$0.hasPrefix(".")
            && fm.fileExists(atPath: skillsDir.appendingPathComponent($0).appendingPathComponent("SKILL.md").path) }.sorted()
    }

    static func loadHidden() -> Set<String> {
        guard let data = try? Data(contentsOf: hiddenFile), let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return Set(names)
    }

    // MARK: - Staging

    /// Personal packaging rules, from ~/.config/skill-bridge/config.json.
    struct Config {
        /// skill -> (path inside the skill -> file elsewhere on disk to ship there)
        var extraFiles: [String: [String: String]] = [:]
        /// skill -> [[find, replace]] applied to SKILL.md after extraFiles are copied in
        var textFixes: [String: [[String]]] = [:]

        static func load() -> Config {
            guard let data = try? Data(contentsOf: configFile),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Config() }
            return Config(extraFiles: o["extraFiles"] as? [String: [String: String]] ?? [:],
                          textFixes: o["textFixes"] as? [String: [[String]]] ?? [:])
        }
    }

    /// Copies a skill into `tmp` the way the Claude app wants it: extra files in,
    /// text fixes applied, unknown frontmatter keys moved under metadata.
    static func stage(_ name: String, in tmp: URL, config: Config) throws -> (URL, [String]) {
        let src = skillsDir.appendingPathComponent(name).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: src.appendingPathComponent("SKILL.md").path) else { throw Problem("no SKILL.md in \(src.path)") }
        let dst = tmp.appendingPathComponent(name)
        try copyTree(src, to: dst)
        for (rel, extra) in config.extraFiles[name] ?? [:] {
            let from = URL(fileURLWithPath: extra.hasPrefix("~/") ? home.path + extra.dropFirst() : extra)
            guard fm.fileExists(atPath: from.path) else { continue }  // e.g. a Mac set up from the Claude copy, which has it already
            let to = dst.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }

        let skillMD = dst.appendingPathComponent("SKILL.md")
        var text = try String(contentsOf: skillMD, encoding: .utf8)
        for fix in config.textFixes[name] ?? [] where fix.count == 2 {
            text = text.replacingOccurrences(of: fix[0], with: fix[1])
        }
        let (fixed, moved) = try fixFrontmatter(text)
        try fixed.write(to: skillMD, atomically: true, encoding: .utf8)

        var notes = moved.isEmpty ? [] : ["moved \(moved.joined(separator: ", ")) under metadata"]
        let lines = try splitFrontmatter(fixed).lines
        let declared = field(lines, "name")
        if declared != name { notes.append("WARNING: frontmatter name is \(declared.map { "'\($0)'" } ?? "missing"), folder is '\(name)'") }
        let desc = field(lines, "description") ?? ""
        if desc.isEmpty { notes.append("WARNING: no description") }
        else if desc.count > 1024 { notes.append("WARNING: description is \(desc.count) chars (limit 1024)") }
        return (dst, notes)
    }

    static func writeZip(_ src: URL, to zipURL: URL) throws {
        let work = fm.temporaryDirectory.appendingPathComponent("skill-bridge-zip-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let built = work.appendingPathComponent(zipURL.lastPathComponent)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qrX", built.path, src.lastPathComponent]
        zip.currentDirectoryURL = src.deletingLastPathComponent()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw Problem("zip failed for \(src.lastPathComponent)") }
        try? fm.removeItem(at: zipURL)
        try fm.moveItem(at: built, to: zipURL)
    }

    /// Copies a folder, skipping .DS_Store, .git, __pycache__ and *.pyc, and
    /// following symlinks so the copy holds real files.
    static func copyTree(_ src: URL, to dst: URL) throws {
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let walk = fm.enumerator(atPath: src.path) else { throw Problem("can't read \(src.path)") }
        while let rel = walk.nextObject() as? String {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.contains(where: ignoredNames.contains) || rel.hasSuffix(".pyc") {
                walk.skipDescendants()
                continue
            }
            let from = src.appendingPathComponent(rel), to = dst.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &isDir)
            if isDir.boolValue {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
            } else {
                try Data(contentsOf: from).write(to: to)
            }
        }
    }

    // MARK: - Comparing with the Claude copy

    /// True when the staged build says the same as the copy in the Claude account.
    /// SKILL.md is compared by meaning, since the Claude app rewrites its frontmatter.
    static func sameSkill(_ staged: URL, _ remote: URL) throws -> Bool {
        let a = files(staged), b = files(remote)
        guard Set(a) == Set(b) else { return false }
        for rel in a {
            let x = staged.appendingPathComponent(rel), y = remote.appendingPathComponent(rel)
            if rel == "SKILL.md" {
                let fa = try splitFrontmatter(String(contentsOf: x, encoding: .utf8))
                let fb = try splitFrontmatter(String(contentsOf: y, encoding: .utf8))
                if frontmatterMeaning(fa.lines) != frontmatterMeaning(fb.lines) || trimmed(fa.body) != trimmed(fb.body) { return false }
            } else if try Data(contentsOf: x) != Data(contentsOf: y) {
                return false
            }
        }
        return true
    }

    static func files(_ root: URL) -> [String] {
        var out: [String] = []
        guard let walk = fm.enumerator(atPath: root.path) else { return out }
        while let rel = walk.nextObject() as? String {
            if rel.split(separator: "/").contains(where: { ignoredNames.contains(String($0)) }) || rel.hasSuffix(".pyc") { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue { out.append(rel) }
        }
        return out
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: - Frontmatter

    static func splitFrontmatter(_ text: String) throws -> (lines: [String], body: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard t.hasPrefix("---\n"),
              let end = t.range(of: "\n---\n", range: t.index(t.startIndex, offsetBy: 3)..<t.endIndex) else {
            throw Problem("SKILL.md has no --- frontmatter block")
        }
        let start = t.index(t.startIndex, offsetBy: 4)
        let header = start <= end.lowerBound ? String(t[start..<end.lowerBound]) : ""
        return (header.components(separatedBy: "\n"), String(t[end.upperBound...]))
    }

    /// `key:` at the start of a line, as YAML writes a mapping key.
    static func leadingKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return String(key)
    }

    /// Frontmatter lines grouped into top-level entries.
    static func entries(_ lines: [String]) -> [(key: String, block: [String])] {
        var out: [(key: String, block: [String])] = []
        for line in lines {
            if let first = line.first, !first.isWhitespace, let key = leadingKey(line) {
                out.append((key, [line]))
            } else if !out.isEmpty {
                out[out.count - 1].block.append(line)
            }
        }
        return out
    }

    static func fixFrontmatter(_ text: String) throws -> (String, [String]) {
        let (lines, body) = try splitFrontmatter(text)
        var kept: [(key: String, block: [String])] = [], moved: [(key: String, block: [String])] = []
        for entry in entries(lines) {
            if allowedKeys.contains(entry.key) { kept.append(entry) } else { moved.append(entry) }
        }
        if !moved.isEmpty {
            let indented = moved.flatMap(\.block).map { trimmed($0).isEmpty ? $0 : "  " + $0 }
            if let i = kept.firstIndex(where: { $0.key == "metadata" }) { kept[i].block += indented }
            else { kept.append(("metadata", ["metadata:"] + indented)) }
        }
        return ("---\n\(kept.flatMap(\.block).joined(separator: "\n"))\n---\n\(body)", moved.map(\.key))
    }

    private static func firstValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// Value of a top-level field, block scalars flattened.
    static func field(_ lines: [String], _ name: String) -> String? {
        guard let block = entries(lines).first(where: { $0.key == name })?.block else { return nil }
        let first = firstValue(block[0])
        if blockScalars.contains(first) {
            return block.dropFirst().map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// Strips YAML quotes from a scalar, keeping a leading "- " or "key: ".
    static func unquote(_ part: String) -> String {
        var prefix = "", rest = Substring(part)
        if rest.hasPrefix("- ") {
            prefix = "- "; rest = rest.dropFirst(2)
        } else if let key = leadingKey(part) {
            prefix = key + ":"; rest = rest.dropFirst(key.count + 1)
            if rest.hasPrefix(" ") { prefix += " "; rest = rest.dropFirst() }
        }
        var v = rest.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.first == "\"", v.last == "\"" {
            if let data = v.data(using: .utf8), let s = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String {
                v = s
            } else {
                v = String(v.dropFirst().dropLast())
            }
        } else if v.count >= 2, v.first == "'", v.last == "'" {
            v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return prefix + v
    }

    /// Each top-level key with its value reduced to plain words, so the same
    /// frontmatter written in a different YAML style compares equal.
    static func frontmatterMeaning(_ lines: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, block) in entries(lines) {
            let first = firstValue(block[0])
            let rest = block.dropFirst().map(trimmed).filter { !$0.isEmpty }
            let parts = blockScalars.contains(first) ? rest : (first.isEmpty ? [] : [first]) + rest
            out[key] = parts.map(unquote).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return out
    }
}
