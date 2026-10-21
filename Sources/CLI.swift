// CLI.swift - the same checks from Terminal. The app's binary runs this when it is
// started as `package-skills` (a symlink the app keeps in ~/.local/bin) or with --cli.

import AppKit

enum CLI {
    static let usage = """
    Package your skills as ZIPs for upload to the Claude app.

    Compares each of your skills on this Mac with the copy your Claude account has
    (Claude Code keeps it in ~/.claude/skills/synced) and builds a ZIP only for the
    skills that differ. Upload those in the Claude app: Settings -> Capabilities -> Skills.

    Usage:
      package-skills                  check all your skills, build what changed
      package-skills NAME ...         also send these skills on this Mac to Claude
      package-skills --setup NAME     copy a skill from your Claude account onto this Mac
      package-skills --hide NAME      stop offering to set it up on this Mac (--unhide to undo)
      package-skills --discard NAME   drop a waiting ZIP for a skill not in Claude yet
      package-skills --no-open        don't open the folder in Finder

    Personal packaging rules: ~/.config/package-skills/config.json (see README).
    """

    static func run(_ args: [String]) -> Int32 {
        let flags = Set(args.filter { $0.hasPrefix("-") })
        let names = args.filter { !$0.hasPrefix("-") }
        let known: Set<String> = ["--no-open", "--setup", "--hide", "--unhide", "--discard", "-h", "--help"]
        if !flags.subtracting(known).isEmpty {
            print("unknown option: \(flags.subtracting(known).sorted().joined(separator: " "))\n\n\(usage)")
            return 2
        }
        if flags.contains("-h") || flags.contains("--help") { print(usage); return 0 }

        do {
            if flags.contains("--setup") {
                for name in names { try Skills.setUp(name); print("  set up     \(name) in \(Skills.skillsDir.appendingPathComponent(name).path)") }
                return 0
            }
            if flags.contains("--hide") || flags.contains("--unhide") {
                for name in names { try Skills.setHidden(name, flags.contains("--hide")) }
                return 0
            }
            if flags.contains("--discard") {
                names.forEach(Skills.discard)
                return 0
            }
        } catch {
            print("  FAILED     \(error.localizedDescription)")
            return 1
        }

        let unknown = names.filter { !Skills.localSkills().contains($0) }
        if !unknown.isEmpty { print("not in ~/.claude/skills: \(unknown.joined(separator: ", "))"); return 1 }

        let report = Skills.check(adding: names)
        if report.noSync {
            print("Can't find your Claude account's skills on this Mac (~/.claude/skills/synced).\nOpen Claude Code once and sign in, then try again.")
            return 2
        }

        var uploads = 0, failed = false
        var onlyInClaude: [String] = [], onlyOnMac: [String] = []
        for row in report.rows {
            let status: String
            switch row.state {
            case .upload(let new): status = new ? "UPLOAD new " : "UPLOAD     "; uploads += 1
            case .upToDate: status = "in sync    "
            case .failed(let why): status = "FAILED     "; failed = true; print("  \(status)\(row.name): \(why)"); continue
            case .onlyInClaude: onlyInClaude.append(row.name); continue
            case .onlyOnMac: onlyOnMac.append(row.name); continue
            case .hidden: continue
            }
            print("  \(status)\(row.name)" + row.notes.map { "\n               \($0)" }.joined())
        }

        let checked = report.syncedAt.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "unknown"
        print("\nCompared with your Claude account as of \(checked).")
        if !onlyInClaude.isEmpty { print("In Claude but not on this Mac: \(onlyInClaude.joined(separator: ", "))  (--setup NAME)") }
        if !onlyOnMac.isEmpty { print("On this Mac but not in Claude: \(onlyOnMac.joined(separator: ", "))  (package-skills NAME to add)") }
        print()
        if uploads > 0 {
            print("Upload \(uploads) ZIP(s) from \(Skills.outDir.path)")
            print("  Claude app -> Settings -> Capabilities -> Skills (replace the old version)")
            if !flags.contains("--no-open") { NSWorkspace.shared.open(Skills.outDir) }
        } else {
            print("Everything matches your Claude account. No upload needed.")
        }
        return failed ? 1 : 0
    }
}
