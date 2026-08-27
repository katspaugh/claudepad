// claudepad — Novation Launchpad Mini MK3 as a physical control panel for
// Claude Code sessions.
//
// Only the 8x8 grid is used (no top-row or scene buttons). Columns = sessions:
//   row 8    session pad, colored by status (orange pulse working / yellow flash
//            waiting / cyan pulse monitoring / green idle) — press to focus
//   rows 7-3 running subagents (pulse cyan), compacted — press to attach
//   row 2    effort pad (effort color) — press cycles effort, applied after a debounce
//   row 1    preset pad (preset color) — press toggles model+effort presets
//            (default fable/high ↔ opus/medium), applied after a debounce
// Pressing a pad in an empty column scrolls the 5h/7d usage summary.
//
// Zero dependencies: CoreMIDI + osascript. Build with build.sh.

import Foundation
import CoreMIDI

// MARK: - Configuration

struct ModelChoice: Codable {
    var label: String      // shown in logs
    var match: String      // lowercase substring matched against model display name/id
    var command: String    // typed into the session's composer
    var color: UInt8       // launchpad palette index (bright variant)
}

struct EffortChoice: Codable {
    var label: String
    var match: String
    var command: String
    var color: UInt8
}

/// A model+effort pair toggled by the row-1 pad. `model`/`effort` reference
/// ModelChoice/EffortChoice labels.
struct Preset: Codable {
    var label: String
    var model: String
    var effort: String
    var color: UInt8
}

struct Config: Codable {
    var models: [ModelChoice]
    var efforts: [EffortChoice]
    var presets: [Preset]? = [
        Preset(label: "fable/high",  model: "fable", effort: "high",   color: 3),
        Preset(label: "opus/medium", model: "opus",  effort: "medium", color: 49),
    ]
    /// Hide sessions hosted by the Claude Code background daemon (no terminal
    /// window to focus). Default true.
    var hideHeadless: Bool? = true

    static let defaultConfig = Config(
        models: [
            ModelChoice(label: "fable",  match: "fable",  command: "/model claude-fable-5[1m]", color: 3),
            ModelChoice(label: "opus",   match: "opus",   command: "/model opus",   color: 49),
            ModelChoice(label: "sonnet", match: "sonnet", command: "/model sonnet", color: 45),
            ModelChoice(label: "haiku",  match: "haiku",  command: "/model haiku",  color: 21),
        ],
        efforts: [
            EffortChoice(label: "max",    match: "max",    command: "/effort max",    color: 5),
            EffortChoice(label: "xhigh",  match: "xhigh",  command: "/effort xhigh",  color: 9),
            EffortChoice(label: "high",   match: "high",   command: "/effort high",   color: 13),
            EffortChoice(label: "medium", match: "medium", command: "/effort medium", color: 21),
            EffortChoice(label: "low",    match: "low",    command: "/effort low",    color: 45),
        ]
    )
}

// MARK: - Session state (written by hooks/statusline wrapper)

struct AgentInfo: Codable {
    var id: String?
    var desc: String?
    var status: String
    var t: Double?
}

struct SessionState: Codable {
    var session_id: String
    var cwd: String?
    var transcript_path: String?
    var pid: Int?
    var status: String?
    var message: String?
    var model: String?
    var model_id: String?
    var effort: String?
    var ctx_pct: Double?
    var usage_5h: Double?
    var usage_7d: Double?
    var last_seen: Double?
    var sl_seen: Double?
    var started_at: Double?
    var agents: [AgentInfo]?
    var headless: Bool?
    var waiting_since: Double?
}

// MARK: - LED model

enum Light: Equatable {
    case off
    case solid(UInt8)
    case flash(UInt8, UInt8)
    case pulse(UInt8)
}

// Palette helpers: standard Launchpad palette groups colors in fours,
// bright at n, dimmer at n+2. White bright = 3, dim = 1.
func dim(_ c: UInt8) -> UInt8 { c <= 3 ? 1 : c &+ 2 }

let COLOR_OFF: UInt8 = 0
let COLOR_WHITE: UInt8 = 3
let COLOR_RED: UInt8 = 5
let COLOR_ORANGE: UInt8 = 9
let COLOR_YELLOW: UInt8 = 13
let COLOR_GREEN: UInt8 = 21
let COLOR_CYAN: UInt8 = 37
let COLOR_BLUE: UInt8 = 45

// MARK: - Launchpad Mini MK3 MIDI

final class Launchpad {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var dest: MIDIEndpointRef = 0
    private var source: MIDIEndpointRef = 0
    private(set) var connected = false

    var onPress: ((Int) -> Void)?          // pad index in programmer layout
    var onConnect: (() -> Void)?

    private let sysexHeader: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0D]

    init() {
        MIDIClientCreateWithBlock("claudepad" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.reconnect() }
        }
        MIDIOutputPortCreate(client, "claudepad-out" as CFString, &outPort)
        MIDIInputPortCreateWithBlock(client, "claudepad-in" as CFString, &inPort) { [weak self] pktList, _ in
            self?.handlePackets(pktList)
        }
        reconnect()
    }

    private func displayName(_ obj: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(obj, kMIDIPropertyDisplayName, &name)
        return name?.takeRetainedValue() as String? ?? ""
    }

    func reconnect() {
        var newDest: MIDIEndpointRef = 0
        var newSource: MIDIEndpointRef = 0
        for i in 0..<MIDIGetNumberOfDestinations() {
            let d = MIDIGetDestination(i)
            if displayName(d).contains("LPMiniMK3 MIDI") { newDest = d }
        }
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            if displayName(s).contains("LPMiniMK3 MIDI") { newSource = s }
        }
        let wasConnected = connected
        if newDest != 0 && newSource != 0 {
            if newSource != source {
                if source != 0 { MIDIPortDisconnectSource(inPort, source) }
                MIDIPortConnectSource(inPort, newSource, nil)
            }
            dest = newDest
            source = newSource
            connected = true
            if !wasConnected {
                log("launchpad connected")
                enterProgrammerMode()
                onConnect?()
            }
        } else {
            connected = false
            dest = 0
            if wasConnected { log("launchpad disconnected") }
        }
    }

    private func handlePackets(_ pktList: UnsafePointer<MIDIPacketList>) {
        var presses: [Int] = []
        for packet in pktList.unsafeSequence() {
            let len = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) { raw -> [UInt8] in
                Array(raw.prefix(len))
            }
            var i = 0
            while i + 2 < bytes.count {
                let status = bytes[i] & 0xF0
                if status == 0x90 || status == 0xB0 {
                    let num = Int(bytes[i + 1])
                    let val = Int(bytes[i + 2])
                    if val > 0 { presses.append(num) }
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        if !presses.isEmpty {
            DispatchQueue.main.async { [weak self] in
                presses.forEach { self?.onPress?($0) }
            }
        }
    }

    func send(_ data: [UInt8]) {
        guard dest != 0 else { return }
        let bufLen = data.count + 512
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufLen, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { buf.deallocate() }
        let pl = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var pkt = MIDIPacketListInit(pl)
        pkt = MIDIPacketListAdd(pl, bufLen, pkt, 0, data.count, data)
        MIDISend(outPort, dest, pl)
    }

    func enterProgrammerMode() { send(sysexHeader + [0x0E, 0x01, 0xF7]) }
    func exitProgrammerMode() { send(sysexHeader + [0x0E, 0x00, 0xF7]) }

    /// Batch LED update via SysEx.
    func setLights(_ lights: [(Int, Light)]) {
        guard !lights.isEmpty else { return }
        var specs: [UInt8] = []
        for (idx, light) in lights {
            let i = UInt8(clamping: idx)
            switch light {
            case .off:              specs += [0, i, 0]
            case .solid(let c):     specs += [0, i, c]
            case .flash(let a, let b): specs += [1, i, a, b]
            case .pulse(let c):     specs += [2, i, c]
            }
            if specs.count > 240 {
                send(sysexHeader + [0x03] + specs + [0xF7])
                specs = []
            }
        }
        if !specs.isEmpty { send(sysexHeader + [0x03] + specs + [0xF7]) }
    }

    /// Clear every LED, including top row/scene buttons we don't use.
    func clearAll() {
        var lights: [(Int, Light)] = []
        for row in 1...9 {
            for col in 1...9 {
                lights.append((row * 10 + col, .off))
            }
        }
        setLights(lights)
    }

    /// Scroll text once across the pads.
    func scrollText(_ text: String, color: UInt8 = COLOR_WHITE, speed: UInt8 = 12) {
        let ascii = Array(text.utf8).filter { $0 >= 0x20 && $0 < 0x7F }
        send(sysexHeader + [0x07, 0x00, speed, 0x00, color] + ascii + [0xF7])
    }
}

// MARK: - Ghostty control (native scripting API via osascript)

// Ghostty ships an AppleScript dictionary: terminals expose `working
// directory` and support `focus` (raises the window), `input text` (paste
// without focusing), and `send key`. We match a session's terminal by exact
// cwd, falling back to a title-substring match.
final class Ghostty {
    private let scriptPath: String
    private let queue = DispatchQueue(label: "claudepad.ghostty")

    init(supportDir: String) {
        scriptPath = supportDir + "/ghostty.applescript"
        let script = """
        on run argv
          set targetCwd to item 1 of argv
          set needle to item 2 of argv
          set verb to item 3 of argv
          set cmdText to ""
          if (count of argv) > 3 then set cmdText to item 4 of argv
          tell application "Ghostty"
            set target to missing value
            repeat with t in terminals
              if (working directory of t) is targetCwd then
                set target to t
                exit repeat
              end if
            end repeat
            if target is missing value and needle is not "" then
              repeat with t in terminals
                if (name of t) contains needle then
                  set target to t
                  exit repeat
                end if
              end repeat
            end if
            if target is missing value then return "notfound"
            if verb is "focus" then
              focus target
              activate
            else if verb is "key" then
              repeat with k in (words of cmdText)
                send key (k as text) to target
                delay 0.15
              end repeat
            else
              input text cmdText to target
              delay 0.1
              send key "enter" to target
              -- /model and /effort may open a picker preselecting the requested
              -- value; a second Enter confirms it (harmless on an empty composer).
              delay 0.6
              send key "enter" to target
            end if
            return "ok"
          end tell
        end run
        """
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    }

    /// Ghostty reports fully resolved paths (e.g. /private/tmp, not /tmp).
    private func resolved(_ cwd: String) -> String {
        URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    }

    private func run(_ args: [String], label: String) {
        queue.async { [scriptPath] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [scriptPath] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log("\(label) -> \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Raise the window of the terminal at `cwd` (or whose title contains `needle`).
    func focus(cwd: String, needle: String) {
        run([resolved(cwd), needle, "focus"], label: "focus '\(needle)'")
    }

    /// Paste `command` + Enter into the terminal at `cwd` without focusing it.
    func type(cwd: String, needle: String, command: String) {
        run([resolved(cwd), needle, "type", command], label: "type '\(command)' into '\(needle)'")
    }

    /// Send a sequence of named keys (e.g. ["left", "down", "enter"]) to the
    /// terminal at `cwd`, 0.15s apart.
    func keys(cwd: String, needle: String, sequence: [String]) {
        let joined = sequence.joined(separator: " ")
        run([resolved(cwd), needle, "key", joined], label: "keys '\(joined)' to '\(needle)'")
    }
}

// MARK: - App

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

final class App {
    let pad = Launchpad()
    let ghostty: Ghostty
    let stateDir: String
    let configPath: String
    var config = Config.defaultConfig
    var configMtime: Date?

    var sessions: [SessionState] = []          // live, sorted by started_at
    var columns: [String: Int] = [:]           // session_id -> column 1...8
    var lastFrame: [Int: Light] = [:]
    var scrollUntil: Date = .distantPast

    // Debounced cycling: a press advances a pending selection (shown pulsing);
    // it is applied (focus + type command) once no press lands for `settle`.
    struct Pending { var idx: Int; var deadline: Date }
    let settle: TimeInterval = 1.2
    var pendingModel: [Int: Pending] = [:]     // column -> selection
    var pendingPreset: [Int: Pending] = [:]    // column -> preset selection
    var pendingEffort: [Int: Pending] = [:]

    // After applying, show the new value until the statusline reports fresh
    // truth (a rejected change then snaps the pad back to the actual value).
    // The expiry is a backstop for sessions whose statusline never ticks.
    let optimisticBackstop: TimeInterval = 8
    struct Optimistic { var idx: Int; var appliedAt: Date; var expires: Date }
    var optimisticModel: [String: Optimistic] = [:]   // session_id -> value
    /// Waiting pads acknowledged by a press: session_id -> the waiting event's
    /// waiting_since. Stops the flash until a newer waiting event arrives.
    var acknowledgedWaiting: [String: Double] = [:]
    var optimisticEffort: [String: Optimistic] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let baseDir = home + "/.claude/claudepad"
        stateDir = baseDir + "/state"
        configPath = baseDir + "/config.json"
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        ghostty = Ghostty(supportDir: baseDir)

        loadConfig()
        writeDefaultConfigIfMissing()

        pad.onConnect = { [weak self] in
            guard let self else { return }
            self.pad.clearAll()
            self.lastFrame = [:]
            self.render(force: true)
        }
        pad.onPress = { [weak self] idx in self?.handlePress(idx) }
    }

    func writeDefaultConfigIfMissing() {
        guard !FileManager.default.fileExists(atPath: configPath) else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Config.defaultConfig) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    func loadConfig() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: configPath),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if mtime == configMtime { return }
        configMtime = mtime
        if let data = FileManager.default.contents(atPath: configPath),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            config = c
            log("config reloaded")
        }
    }

    // MARK: State scanning

    func scanSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else { return }
        var result: [SessionState] = []
        for file in files where file.hasSuffix(".json") {
            let path = stateDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let s = try? JSONDecoder().decode(SessionState.self, from: data) else { continue }
            // Liveness. Two prune paths:
            // - recorded pid is dead (EPERM still counts as alive) and the file
            //   is >20s old, or
            // - the statusline heartbeat (refreshInterval) stopped >90s ago.
            //   The recorded pid can be wrong (e.g. a long-lived "claude
            //   bg-spare" worker), so a live pid alone doesn't keep a session.
            let age = Date().timeIntervalSince1970 - (s.last_seen ?? 0)
            let pidDead = s.pid.map { kill(pid_t($0), 0) != 0 && errno == ESRCH } ?? true
            if pidDead && age > 20 {
                try? fm.removeItem(atPath: path)
                continue
            }
            // Quiet for 90s with a live pid: hide the column but keep the file,
            // so the session reappears if its heartbeat resumes.
            if age > 90 { continue }
            // Daemon-hosted sessions have no terminal to focus; hide unless configured otherwise.
            if (config.hideHeadless ?? true) && (s.headless ?? false) { continue }
            result.append(s)
        }
        result.sort { ($0.started_at ?? $0.last_seen ?? 0) < ($1.started_at ?? $1.last_seen ?? 0) }
        sessions = result
        acknowledgedWaiting = acknowledgedWaiting.filter { id, seen in
            result.contains { $0.session_id == id && $0.status == "waiting" && ($0.waiting_since ?? 0) == seen }
        }

        // Stable column assignment: keep existing, new sessions take lowest free column.
        let liveIds = Set(sessions.map { $0.session_id })
        columns = columns.filter { liveIds.contains($0.key) }
        let used = Set(columns.values)
        var free = (1...8).filter { !used.contains($0) }
        for s in sessions where columns[s.session_id] == nil {
            guard !free.isEmpty else { break }
            columns[s.session_id] = free.removeFirst()
        }
    }

    // MARK: Rendering

    func modelIndex(for s: SessionState) -> Int? {
        let name = (s.model ?? s.model_id ?? "").lowercased()
        guard !name.isEmpty else { return nil }
        return config.models.firstIndex { name.contains($0.match) }
    }

    func effortIndex(for s: SessionState) -> Int? {
        let name = (s.effort ?? "").lowercased()
        guard !name.isEmpty else { return nil }
        return config.efforts.firstIndex { name == $0.match || name.contains($0.match) }
    }

    var presets: [Preset] { config.presets ?? Config.defaultConfig.presets ?? [] }

    /// Model/effort choice indices a preset refers to (nil if a label is unknown).
    func choices(for p: Preset) -> (model: Int, effort: Int)? {
        guard let m = config.models.firstIndex(where: { $0.label == p.model }),
              let e = config.efforts.firstIndex(where: { $0.label == p.effort }) else { return nil }
        return (m, e)
    }

    /// The preset matching the session's displayed model+effort, if any.
    func displayedPresetIndex(_ s: SessionState) -> Int? {
        guard let m = displayedModelIndex(s), let e = displayedEffortIndex(s) else { return nil }
        return presets.firstIndex { choices(for: $0).map { $0.model == m && $0.effort == e } ?? false }
    }

    func displayedModelIndex(_ s: SessionState) -> Int? {
        if let o = optimisticModel[s.session_id], o.expires > Date() { return o.idx }
        return modelIndex(for: s)
    }

    func displayedEffortIndex(_ s: SessionState) -> Int? {
        if let o = optimisticEffort[s.session_id], o.expires > Date() { return o.idx }
        return effortIndex(for: s)
    }

    func statusLight(_ s: SessionState) -> Light {
        let running = (s.agents ?? []).contains { $0.status == "running" }
        switch s.status ?? "idle" {
        case "working":  return .pulse(COLOR_ORANGE)
        case "waiting":
            if let ack = acknowledgedWaiting[s.session_id], ack == (s.waiting_since ?? 0) { return .solid(COLOR_YELLOW) }
            return .flash(COLOR_YELLOW, 0)
        default:         return running ? .pulse(COLOR_CYAN) : .solid(COLOR_GREEN)
        }
    }

    func buildFrame() -> [Int: Light] {
        var f: [Int: Light] = [:]
        // 8x8 grid only; everything defaults to off.
        for row in 1...8 { for col in 1...8 { f[row * 10 + col] = .off } }

        for s in sessions {
            guard let col = columns[s.session_id] else { continue }

            // Row 8: session pad, colored by status (pulse orange = working,
            // flash yellow = waiting, pulse cyan = monitoring, green = idle).
            f[80 + col] = statusLight(s)

            // Rows 7..3: running subagents, newest at the top, compacted —
            // a finished agent frees its slot and the rest shift immediately.
            let running = (s.agents ?? []).filter { $0.status == "running" }
            var row = 7
            for _ in running.suffix(5) {
                guard row >= 3 else { break }
                f[row * 10 + col] = .pulse(COLOR_CYAN)
                row -= 1
            }

            // Row 2: effort. Pending selection pulses; settled value sits dim.
            if let p = pendingEffort[col], p.idx < config.efforts.count {
                f[20 + col] = .pulse(config.efforts[p.idx].color)
            } else if let i = displayedEffortIndex(s) {
                f[20 + col] = .solid(dim(config.efforts[i].color))
            } else {
                f[20 + col] = .solid(dim(COLOR_WHITE))
            }

            // Row 1: preset. Pending pulses; matched preset sits dim; no match = dim white.
            if let p = pendingPreset[col], p.idx < presets.count {
                f[10 + col] = .pulse(presets[p.idx].color)
            } else if let i = displayedPresetIndex(s) {
                f[10 + col] = .solid(dim(presets[i].color))
            } else {
                f[10 + col] = .solid(dim(COLOR_WHITE))
            }
        }
        return f
    }

    private var lastFullRender = Date.distantPast

    func render(force: Bool = false) {
        guard pad.connected, Date() > scrollUntil else { return }
        // Periodic full refresh: a dropped MIDI message would otherwise leave
        // a stale LED forever, since diffing assumes the device has lastFrame.
        let full = force || Date().timeIntervalSince(lastFullRender) > 5
        if full { lastFullRender = Date() }
        let frame = buildFrame()
        var changes: [(Int, Light)] = []
        for (idx, light) in frame where full || lastFrame[idx] != light {
            changes.append((idx, light))
        }
        lastFrame = frame
        pad.setLights(changes)
    }

    // MARK: Input

    func sessionAt(column: Int) -> SessionState? {
        guard let id = columns.first(where: { $0.value == column })?.key else { return nil }
        return sessions.first { $0.session_id == id }
    }

    func transcriptPath(for s: SessionState) -> String? {
        if let t = s.transcript_path, !t.isEmpty { return t }
        guard let cwd = s.cwd else { return nil }
        // Claude Code sanitizes the cwd into a project dir name: non-alphanumerics -> '-'.
        let sanitized = String(cwd.map { c in c.isLetter || c.isNumber ? c : "-" })
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.claude/projects/" + sanitized + "/" + s.session_id + ".jsonl"
    }

    /// Title fallback for terminal matching: the latest ai-title record in the
    /// transcript (this is what Claude Code sets the tab title to).
    func sessionTitle(_ s: SessionState) -> String? {
        guard let path = transcriptPath(for: s),
              let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail = min(size, 262_144)
        try? fh.seek(toOffset: size - tail)
        guard let data = try? fh.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var title: String?
        for line in text.split(separator: "\n") where line.contains("\"type\":\"ai-title\"") {
            if let d = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                title = t
            }
        }
        return title
    }

    func needle(for s: SessionState) -> String {
        sessionTitle(s) ?? (s.cwd as NSString?)?.lastPathComponent ?? s.session_id
    }

    func scrollUsage() {
        let u5 = sessions.compactMap { $0.usage_5h }.max()
        let u7 = sessions.compactMap { $0.usage_7d }.max()
        var parts: [String] = []
        if let u5 { parts.append("5h \(Int(u5))%") }
        if let u7 { parts.append("7d \(Int(u7))%") }
        let text = parts.isEmpty ? "no data" : parts.joined(separator: "  ")
        scrollUntil = Date().addingTimeInterval(Double(text.count) * 0.45 + 1)
        pad.scrollText(text, color: COLOR_WHITE)
        lastFrame = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(text.count) * 0.45 + 1.2) { [weak self] in
            self?.render(force: true)
        }
    }

    func handlePress(_ idx: Int) {
        let row = idx / 10
        let col = idx % 10
        // 8x8 grid only — ignore top-row CCs, scene buttons, logo.
        guard (1...8).contains(row), (1...8).contains(col) else { return }

        guard let s = sessionAt(column: col) else {
            scrollUsage()
            return
        }

        switch row {
        case 1:
            guard !presets.isEmpty else { return }
            let cur = pendingPreset[col]?.idx ?? displayedPresetIndex(s) ?? -1
            pendingPreset[col] = Pending(idx: (cur + 1) % presets.count,
                                         deadline: Date().addingTimeInterval(settle))
            render()
        case 2:
            guard !config.efforts.isEmpty else { return }
            // Efforts are listed max→low; step toward max (wrap low after max).
            let n = config.efforts.count
            let cur = pendingEffort[col]?.idx ?? displayedEffortIndex(s) ?? 0
            pendingEffort[col] = Pending(idx: (cur - 1 + n) % n,
                                         deadline: Date().addingTimeInterval(settle))
            render()
        case 3...7:
            guard let cwd = s.cwd else { return }
            let nd = needle(for: s)
            ghostty.focus(cwd: cwd, needle: nd)
            // Occupied slot: open the agent view and attach to that agent —
            // what clicking its row in the strip does. "left" is sent twice:
            // on an empty composer the second press is a no-op; with text in
            // the composer the first press only shows a confirmation hint and
            // the second opens the view (documented behavior).
            // Agent view rows: main first, then agents in spawn order.
            let running = (s.agents ?? []).filter { $0.status == "running" }
            let shown = min(running.count, 5)
            let slot = 7 - row
            guard slot < shown else { return }  // empty pad: focus only
            let chrono = running.count - 1 - slot  // newest renders at row 7
            let seq = ["left", "left"] + Array(repeating: "down", count: 1 + chrono) + ["enter"]
            ghostty.keys(cwd: cwd, needle: nd, sequence: seq)
        default:
            if s.status == "waiting" {
                acknowledgedWaiting[s.session_id] = s.waiting_since ?? 0
                render()
            }
            guard let cwd = s.cwd else { return }
            ghostty.focus(cwd: cwd, needle: needle(for: s))
        }
    }

    /// Apply pending model/effort selections whose debounce has settled.
    func applyPending() {
        let now = Date()
        for (col, p) in pendingModel where p.deadline <= now {
            pendingModel.removeValue(forKey: col)
            guard let s = sessionAt(column: col), let cwd = s.cwd,
                  p.idx < config.models.count else { continue }
            optimisticModel[s.session_id] = Optimistic(idx: p.idx, appliedAt: now, expires: now.addingTimeInterval(optimisticBackstop))
            ghostty.type(cwd: cwd, needle: needle(for: s), command: config.models[p.idx].command)
        }
        for (col, p) in pendingPreset where p.deadline <= now {
            pendingPreset.removeValue(forKey: col)
            guard let s = sessionAt(column: col), let cwd = s.cwd,
                  p.idx < presets.count, let c = choices(for: presets[p.idx]) else { continue }
            let exp = now.addingTimeInterval(optimisticBackstop)
            optimisticModel[s.session_id] = Optimistic(idx: c.model, appliedAt: now, expires: exp)
            optimisticEffort[s.session_id] = Optimistic(idx: c.effort, appliedAt: now, expires: exp)
            // Serial queue: model lands first, then effort.
            ghostty.type(cwd: cwd, needle: needle(for: s), command: config.models[c.model].command)
            ghostty.type(cwd: cwd, needle: needle(for: s), command: config.efforts[c.effort].command)
        }
        for (col, p) in pendingEffort where p.deadline <= now {
            pendingEffort.removeValue(forKey: col)
            guard let s = sessionAt(column: col), let cwd = s.cwd,
                  p.idx < config.efforts.count else { continue }
            optimisticEffort[s.session_id] = Optimistic(idx: p.idx, appliedAt: now, expires: now.addingTimeInterval(optimisticBackstop))
            ghostty.type(cwd: cwd, needle: needle(for: s), command: config.efforts[p.idx].command)
        }
    }

    /// Drop optimistic values once the statusline has reported truth from
    /// after the command landed (>=3s grace for the paste to execute), or
    /// after the 20s backstop. A rejected change then reverts the pad.
    func pruneOptimistic() {
        let now = Date()
        func confirmed(_ o: Optimistic, _ sid: String) -> Bool {
            guard let slSeen = sessions.first(where: { $0.session_id == sid })?.sl_seen else { return false }
            return slSeen >= o.appliedAt.timeIntervalSince1970 + 3
        }
        for (sid, o) in optimisticModel where o.expires <= now || confirmed(o, sid) {
            optimisticModel.removeValue(forKey: sid)
        }
        for (sid, o) in optimisticEffort where o.expires <= now || confirmed(o, sid) {
            optimisticEffort.removeValue(forKey: sid)
        }
    }

    // MARK: Run loop

    func run() {
        log("claudepad starting; state dir: \(stateDir)")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.loadConfig()
            if !self.pad.connected { self.pad.reconnect() }
            self.scanSessions()
            self.applyPending()
            self.pruneOptimistic()
            self.render()
        }
        timer.resume()

        // Clean shutdown: clear pads and return to Live mode.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                log("shutting down")
                self?.pad.clearAll()
                self?.pad.exitProgrammerMode()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        RunLoop.main.run()
    }

    private var signalSources: [DispatchSourceSignal] = []
}

let app = App()
app.run()
