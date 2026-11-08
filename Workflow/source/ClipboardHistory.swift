// Clipboard History: a Raycast-style window for Alfred's clipboard history.
//
// Alfred keeps recording the clipboard as usual; this only reads its database.
// The window is drawn to look like Alfred with the Raycast themes: a list grouped
// by day on the left, and a preview with an Information panel on the right.
// ↩ pastes into the app you were in, ⌘↩ copies, and rows drag out as text or files.
// ⌘⇧P pins an item above the history and ⌘K lists the actions, adding to pinboards among them (see Saved).
//
// It's an app bundle (ClipHistory.app, LSUIElement) that starts at login (it keeps its own
// LaunchAgent, see installLoginAgent) and stays running, so it opens instantly. Like Alfred, it
// becomes the active app while its window is open; macOS allows that only when the app receives
// the key press itself (it registers its hotkey, ⌃⌘V unless set in Configure Workflow, see
// handleHotKey) or is opened through LaunchServices (the workflow's keyword runs `open`).
// Closing hands focus back to the app you were in.
// The app has no Accessibility permission, so to paste it asks Alfred to press ⌘V (askAlfredToPaste).
//
// Build: source/build.sh (add --package for a .alfredworkflow)
import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import SQLite3

// MARK: - Alfred's clipboard history

let alfredDatabases = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Alfred/Databases")
let historyPath = alfredDatabases.appendingPathComponent("clipboard.alfdb").path
let alfredData = alfredDatabases.appendingPathComponent("clipboard.alfdb.data")  // its images and file lists
let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/com.andreisuslov.alfred-clipboard-history")
/// Pins and pinboards, in the folder Alfred gives each workflow for data it keeps.
let savedDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Alfred/Workflow Data/com.andreisuslov.alfred-clipboard-history")

/// Lowercased and without accents, so typing "cafe" finds "Café".
func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

// Compiled once: the history is classified thousands of clippings at a time.
let colorFunction = try! NSRegularExpression(
    pattern: #"^(rgba?|hsla?)\(\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*[,\s]\s*([\d.]+%?)\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$"#)
/// A command with a flag within its first few words: "xattr -d …", "git log --oneline".
let commandWithFlag = try! NSRegularExpression(pattern: #"^[a-z][\w.-]*( +[^\s-]\S*){0,3} +-{1,2}[A-Za-z]"#)

/// The color a clipping names when it is only a color value: #RGB(A), #RRGGBB(AA), rgb()/rgba(), hsl()/hsla().
func parseColor(_ item: String) -> NSColor? {
    guard item.utf8.count <= 64 else { return nil }
    let text = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
    // Without "#", only six or eight hex digits mixing letters and numbers: "facade" is a word, "531348" a code.
    if !text.hasPrefix("#"), !([6, 8].contains(hex.count) && hex.contains(where: \.isNumber) && hex.contains(where: \.isLetter)) {
        hex = ""
    }
    // "#123" is more often an issue number than a color; "#000" and "#fff" are colors.
    if hex.count <= 4, hex.allSatisfy(\.isNumber), Set(hex).count > 1 { hex = "" }
    if [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) {
        if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6 { hex += "ff" }
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(value >> 24 & 0xFF) / 255, green: CGFloat(value >> 16 & 0xFF) / 255,
                       blue: CGFloat(value >> 8 & 0xFF) / 255, alpha: CGFloat(value & 0xFF) / 255)
    }
    guard let match = colorFunction.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func part(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
    /// A component as 0...1: "50%" is a percentage, a bare number is out of `scale`.
    func unit(_ value: String, scale: Double) -> CGFloat {
        let number = value.hasSuffix("%") ? (Double(value.dropLast()) ?? 0) / 100 : (Double(value) ?? 0) / scale
        return CGFloat(min(max(number, 0), 1))
    }
    guard let function = part(1), let a = part(2), let b = part(3), let c = part(4) else { return nil }
    let alpha = part(5).map { unit($0, scale: 1) } ?? 1
    if function.hasPrefix("rgb") {
        return NSColor(srgbRed: unit(a, scale: 255), green: unit(b, scale: 255), blue: unit(c, scale: 255), alpha: alpha)
    }
    // HSL to the HSB that NSColor takes.
    let hue = CGFloat((Double(a.replacingOccurrences(of: "%", with: "")) ?? 0).truncatingRemainder(dividingBy: 360) / 360)
    let saturation = unit(b, scale: 100), lightness = unit(c, scale: 100)
    let brightness = lightness + saturation * min(lightness, 1 - lightness)
    let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
    return NSColor(colorSpace: .sRGB, hue: hue, saturation: hsbSaturation, brightness: brightness, alpha: alpha)
}

/// A color as "#RRGGBB" (plus alpha when not opaque) and as "rgb(r, g, b)".
func colorValues(_ color: NSColor) -> (hex: String, rgb: String) {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    let r = Int((srgb.redComponent * 255).rounded()), g = Int((srgb.greenComponent * 255).rounded())
    let b = Int((srgb.blueComponent * 255).rounded()), alpha = srgb.alphaComponent
    if alpha < 1 {
        return (String(format: "#%02X%02X%02X%02X", r, g, b, Int((alpha * 255).rounded())),
                "rgba(\(r), \(g), \(b), \(String(format: "%.2f", alpha)))")
    }
    return (String(format: "#%02X%02X%02X", r, g, b), "rgb(\(r), \(g), \(b))")
}

/// A rounded square of a color, outlined so white and near-background colors still show.
func swatch(_ color: NSColor, side: CGFloat, radius: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        path.stroke()
        return true
    }
}

let codeStarts = ["import ", "def ", "class ", "func ", "function ", "fn ", "const ", "let ", "var ",
                  "return ", "if (", "for (", "while (", "} else", "public ", "private ", "static ", "struct ",
                  "enum ", "#include", "#!/", "package ", "select ", "insert into ", "create table", "$ ",
                  "sudo ", "git ", "brew ", "npm ", "npx ", "yarn ", "pip ", "cd ", "curl ", "docker ",
                  "kubectl ", "ssh ", "export ", "echo ", "python", "node ", "</", "<div", "<?xml"]

/// A guess at whether a clipping is code or a shell command rather than prose: code keywords,
/// lines ending in ; { or }, commands with flags, indentation and a high density of symbols.
func looksLikeCode(_ item: String) -> Bool {
    let rawLines = item.prefix(4000).split(whereSeparator: \.isNewline)
    let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    var score = 0
    for line in lines {
        let lower = line.lowercased()
        if codeStarts.contains(where: { lower.hasPrefix($0) }) { score += 2 }
        if lower.hasPrefix("from "), lower.contains(" import ") { score += 2 }  // Python, not "from - …"
        if let last = line.last, ";{}".contains(last) { score += 2 }
        if line.count < 300, commandWithFlag.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            score += 2
        }
        // Markdown tables start with "|", so their pipes don't count as shell pipes.
        if !line.hasPrefix("|"), [" && ", " | ", "=>", "->", "::", "==", "!="].contains(where: { line.contains($0) }) {
            score += 1
        }
    }
    score += rawLines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
    // Only for a few lines or more: "$3,485.74" or a list of email addresses is dense with symbols too.
    let sample = item.prefix(2000)
    let symbols = sample.unicodeScalars.filter { "{}[]();=<>$|&\\_".unicodeScalars.contains($0) }.count
    if lines.count >= 3, Double(symbols) / Double(sample.count) > 0.06 { score += 2 }
    return score >= (lines.count == 1 ? 2 : max(3, lines.count / 2))
}

struct Clip {
    enum Kind: String, Codable { case text, image, files }  // how Alfred stored it
    enum Category { case text, link, code, color, media }  // what the type menu filters by

    let kind: Kind
    let item: String  // the text itself, or Alfred's label for an image or a file list
    let date: Date
    let app: String
    let appPath: String
    let dataHash: String
    let folder: URL  // where its image or file list is: Alfred's, or the copy a pin or pinboard keeps
    // Worked out once when the history loads (off the main thread), so rows and filtering stay fast.
    let title: String
    let category: Category
    let color: NSColor?  // the color a color value names, for its swatch
    let searchKey: [UInt8]  // fold(text + app), searched as raw bytes
    let characters: Int  // for the Information panel; counting a long clipping on every selection was slow
    let words: Int

    init(kind: Kind, item: String, date: Date, app: String, appPath: String, dataHash: String, folder: URL = alfredData) {
        self.kind = kind
        self.item = item
        self.date = date
        self.app = app
        self.appPath = appPath
        self.dataHash = dataHash
        self.folder = folder
        color = kind == .text ? parseColor(item) : nil
        switch kind {
        case .image, .files: category = .media
        case .text where color != nil: category = .color
        case .text where Clip.isLink(item): category = .link
        case .text where looksLikeCode(item): category = .code
        case .text: category = .text
        }
        searchKey = Array(fold(item + "\n" + app).utf8)
        characters = kind == .text ? item.count : 0
        words = kind == .text ? item.split(whereSeparator: \.isWhitespace).count : 0
        switch kind {
        case .text:
            // Only the first lines are split, so a long clipping doesn't cost a full pass.
            let lines = item.split(maxSplits: 20, omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            let line = lines.first { !$0.allSatisfy(\.isWhitespace) } ?? ""
            title = String(line.trimmingCharacters(in: .whitespaces).prefix(300))
        case .image:
            title = "Image (\(Clip.imageInfo(item).dimensions))"
        case .files:
            let files = Clip.files(listedIn: folder.appendingPathComponent(dataHash))
            let first = files.first?.lastPathComponent ?? item
            title = files.count > 1 ? "\(first) and \(files.count - 1) more" : first
        }
    }

    static func files(listedIn plist: URL) -> [URL] {
        guard let data = try? Data(contentsOf: plist),
              let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    static func isLink(_ item: String) -> Bool {
        guard item.utf8.count < 4096 else { return false }
        let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    /// Alfred labels images "Image: 608x917 (2.1 MB)".
    static func imageInfo(_ label: String) -> (dimensions: String, size: String) {
        let parts = label.replacingOccurrences(of: "Image: ", with: "").components(separatedBy: " (")
        let size = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ")")) : ""
        return (parts[0].replacingOccurrences(of: "x", with: "×"), size)
    }

    /// The same thing copied again: Alfred keeps one entry per text, image or file list.
    func isSameItem(as other: Clip) -> Bool {
        kind == other.kind && (kind == .text ? item == other.item : dataHash == other.dataHash)
    }

    /// What isSameItem compares, as one value for looking clips up in a set.
    var key: String { kind == .text ? "text:" + item : "\(kind.rawValue):\(dataHash)" }

    var dataURL: URL { folder.appendingPathComponent(dataHash) }
    var files: [URL] { kind == .files ? Clip.files(listedIn: dataURL) : [] }
    var imageInfo: (dimensions: String, size: String) { Clip.imageInfo(item) }

    /// The image under a readable name for dragging, "Clipboard image 2026-10-26 at 05.39.08.tiff":
    /// a hard link to the file Alfred stored, so it takes no space.
    var namedImageFile: URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = cacheDir.appendingPathComponent("Clipboard image \(stamp.string(from: date)).\(dataURL.pathExtension)")
        if !FileManager.default.fileExists(atPath: file.path),
           (try? FileManager.default.linkItem(at: dataURL, to: file)) == nil {
            try? FileManager.default.copyItem(at: dataURL, to: file)
        }
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Puts the clip back on a pasteboard. Images go back as the exact bytes Alfred stored,
    /// so Alfred sees the same item again instead of recording a near-duplicate.
    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch kind {
        case .text:
            pasteboard.setString(item, forType: .string)
        case .image:
            guard let data = try? Data(contentsOf: dataURL) else { return }
            pasteboard.setData(data, forType: dataURL.pathExtension.lowercased() == "png" ? .png : .tiff)
        case .files:
            pasteboard.writeObjects(files as [NSURL])
        }
    }

    /// Puts several clips on a pasteboard at once. Texts go as one text, a line each, since a text field
    /// pastes only the first of several items; anything else goes as an item each, so Finder pastes them all.
    static func write(_ clips: [Clip], to pasteboard: NSPasteboard) {
        guard clips.count > 1 else {
            clips.first?.write(to: pasteboard)
            return
        }
        pasteboard.clearContents()
        if clips.allSatisfy({ $0.kind == .text }) {
            pasteboard.setString(clips.map(\.item).joined(separator: "\n"), forType: .string)
            return
        }
        pasteboard.writeObjects(clips.flatMap { clip -> [NSPasteboardWriting] in
            switch clip.kind {
            case .text: return [clip.item as NSString]
            case .image: return clip.namedImageFile.map { [$0 as NSURL] } ?? []
            case .files: return clip.files as [NSURL]
            }
        })
    }

    /// What a dragged row carries: text as text, an image or a file as the file itself.
    var dragWriter: NSPasteboardWriting? {
        switch kind {
        case .text: return item as NSString
        case .image: return namedImageFile as NSURL?
        case .files: return files.first as NSURL?
        }
    }
}

/// Pins and pinboards keep what Alfred recorded; the rest is worked out again as they load.
extension Clip: Codable {
    enum CodingKeys: CodingKey { case kind, item, date, app, appPath, dataHash }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind), item: try values.decode(String.self, forKey: .item),
                  date: try values.decode(Date.self, forKey: .date), app: try values.decode(String.self, forKey: .app),
                  appPath: try values.decode(String.self, forKey: .appPath),
                  dataHash: try values.decode(String.self, forKey: .dataHash), folder: Saved.data)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(item, forKey: .item)
        try values.encode(date, forKey: .date)
        try values.encode(app, forKey: .app)
        try values.encode(appPath, forKey: .appPath)
        try values.encode(dataHash, forKey: .dataHash)
    }
}

// MARK: - Pins and pinboards

/// Pins, as in Raycast, show above the history; pinboards, as in Paste, are lists you name and fill.
/// Both hold copies, images and file lists included, so they stay after Alfred deletes the originals.
struct Saved: Codable {
    struct Board: Codable {
        var name: String
        var items: [Clip]  // newest first
    }

    var pinned: [Clip] = []  // newest first
    var boards: [Board] = []

    static let file = savedDir.appendingPathComponent("saved.json")
    static let data = savedDir.appendingPathComponent("data")
    static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink]

    static func load() -> Saved {
        guard let json = try? Data(contentsOf: file) else { return Saved() }
        if let saved = try? JSONDecoder().decode(Saved.self, from: json) { return saved }
        // Not written over: the folder is set aside with its copies, rather than emptied by the next save.
        try? FileManager.default.moveItem(at: savedDir, to: savedDir.appendingPathExtension("unreadable"))
        return Saved()
    }

    /// Writes the list, and drops the copies of images and file lists that nothing holds any more.
    func save() {
        try? FileManager.default.createDirectory(at: Saved.data, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Saved.file, options: .atomic)
        let held = Set((pinned + boards.flatMap(\.items)).map(\.dataHash))
        for file in (try? FileManager.default.contentsOfDirectory(at: Saved.data, includingPropertiesForKeys: nil)) ?? []
        where !held.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The clip with its own copy of its image or file list, which Alfred's cleanup doesn't touch.
    static func keep(_ clip: Clip) -> Clip {
        guard clip.folder != data else { return clip }
        if clip.kind != .text {
            try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: clip.dataURL, to: data.appendingPathComponent(clip.dataHash))
        }
        return Clip(kind: clip.kind, item: clip.item, date: clip.date, app: clip.app, appPath: clip.appPath,
                    dataHash: clip.dataHash, folder: data)
    }

    func isPinned(_ clip: Clip) -> Bool { pinned.contains { $0.isSameItem(as: clip) } }

    /// A pinboard's dot, in the filter menu and the actions.
    func dot(_ name: String) -> NSImage? {
        boards.firstIndex { $0.name == name }.map { swatch(Saved.colors[$0 % Saved.colors.count], side: 10, radius: 5) }
    }
}

/// A menu item that runs a closure, for menus built on the spot.
final class ActionItem: NSMenuItem {
    let run: () -> Void

    init(_ title: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = [], image: NSImage? = nil,
         run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(chosen), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        self.image = image
        target = self
    }
    required init(coder: NSCoder) { fatalError() }

    @objc func chosen() { run() }
}

func withHistory<T>(_ sql: String, _ body: (OpaquePointer?) -> T) -> T? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(historyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    return body(stmt)
}

/// How many items Alfred has and when the newest was copied; any change means something to reload.
struct HistoryStamp: Equatable {
    var count = 0
    var newest = 0.0
}

func historyStamp() -> HistoryStamp {
    withHistory("select count(*), max(ts) from clipboard") { stmt in
        sqlite3_step(stmt) == SQLITE_ROW
            ? HistoryStamp(count: Int(sqlite3_column_int(stmt, 0)), newest: sqlite3_column_double(stmt, 1)) : HistoryStamp()
    } ?? HistoryStamp()
}

/// The whole history, newest first; or, with `newerThan`, just what Alfred recorded after that time.
func loadClips(newerThan: Double = -.infinity) -> [Clip] {
    let since = newerThan.isFinite ? "where ts > \(newerThan) " : ""
    return withHistory("select item, ts, app, apppath, dataType, dataHash from clipboard \(since)order by ts desc") { stmt in
        func text(_ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
        var clips: [Clip] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind: Clip.Kind
            switch sqlite3_column_int(stmt, 4) {
            case 1: kind = .image
            case 2: kind = .files
            default: kind = .text
            }
            // Alfred stores seconds since 2001-01-01, which is Foundation's reference date.
            clips.append(Clip(kind: kind, item: text(0),
                              date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)),
                              app: text(2), appPath: text(3), dataHash: text(5)))
        }
        return clips
    } ?? []
}

/// Drops image links whose original Alfred has deleted (a link count of 1 means ours is the last).
func pruneImageLinks() {
    let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.lastPathComponent.hasPrefix("Clipboard image ") {
        let links = (try? FileManager.default.attributesOfItem(atPath: file.path)[.referenceCount] as? Int) ?? 0
        if links <= 1 { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Formatting

func copiedLabel(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) { return "Today at \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday at \(time)" }
    return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
}

func dayTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
        return date.formatted(.dateTime.month(.wide).day())
    }
    return date.formatted(.dateTime.month(.wide).day().year())
}

func abbreviatingHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Theme

func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func make(_ rgba: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? make(dark) : make(light) }
}

/// The Raycast Light and Raycast Dark themes set up in Alfred.
enum Theme {
    static let window = color(0xF7F7_F8EB, 0x1C1C_1EEB)
    static let border = color(0x0000_001F, 0xFFFF_FF1F)
    static let selection = color(0x0000_001A, 0xFFFF_FF1A)
    static let text = color(0x0000_00E6, 0xFFFF_FFE6)
    static let secondary = color(0x0000_0073, 0xFFFF_FF73)
    static let separator = color(0x0000_0017, 0xFFFF_FF17)
    static let card = color(0xFFFF_FFFF, 0x2C2C_2EFF)
}

// MARK: - Views

class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded rectangle in a theme color; redrawn by AppKit when light/dark mode changes.
final class Fill: Flipped {
    let color: NSColor
    let radius: CGFloat
    let stroke: NSColor?

    init(_ color: NSColor, radius: CGFloat = 0, stroke: NSColor? = nil, frame: NSRect = .zero) {
        self.color = color
        self.radius = radius
        self.stroke = stroke
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Inset only when stroking, so the stroke stays inside; a 1pt hairline would vanish otherwise.
        let rect = stroke == nil ? bounds : bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.stroke()
        }
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    return field
}

/// Finder-style thumbnail (an image's content, a PDF's first page), or the file's icon when there is none.
func thumbnail(of file: URL, side: CGFloat, completion: @escaping (NSImage) -> Void) {
    let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: side, height: side),
                                               scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        DispatchQueue.main.async {
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: side, height: side)
            completion(representation?.nsImage ?? icon)
        }
    }
}

func symbol(_ name: String, size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}

/// A small key cap, like the ↩ and ⌘ hints in Raycast's action bar.
func keyCap(_ key: String) -> NSView {
    let text = label(key, size: 11, weight: .medium, color: Theme.secondary)
    text.alignment = .center
    let width = max(20, text.intrinsicContentSize.width + 8)
    let cap = Fill(Theme.selection, radius: 4, frame: NSRect(x: 0, y: 0, width: width, height: 20))
    text.frame = NSRect(x: 0, y: 3, width: width, height: 14)
    cap.addSubview(text)
    return cap
}

final class RowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

final class ClipCell: NSTableCellView {
    let icon = NSImageView()
    let title = label("", size: 14)
    let number = label("", size: 12, color: Theme.secondary)  // ⌘1 to ⌘9 while in view
    var file: URL?  // whose thumbnail this cell is waiting for

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = Theme.secondary
        icon.frame = NSRect(x: 18, y: 8, width: 20, height: 20)
        title.frame = NSRect(x: 48, y: 9, width: 300 - 48 - 18 - 30, height: 18)
        number.frame = NSRect(x: 300 - 18 - 26, y: 10, width: 26, height: 16)
        number.alignment = .right
        addSubview(icon)
        addSubview(title)
        addSubview(number)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class HeaderCell: NSTableCellView {
    let title = label("", size: 11, weight: .semibold, color: Theme.secondary)

    init() {
        super.init(frame: .zero)
        title.frame = NSRect(x: 18, y: 4, width: 300 - 36, height: 14)
        addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Preview of the selected clip on top, Raycast's "Information" list below it.
final class DetailView: Flipped {
    let textScroll = NSScrollView()
    let textView = NSTextView()
    let imageView = NSImageView()
    let fileIcon = NSImageView()
    let fileName = label("", size: 13, weight: .medium)
    let info = Flipped()
    var shownFile: URL?
    var appIcons: [String: NSImage] = [:]

    /// Loading an app's icon from disk is slow, and the same few apps come up again and again.
    func appIcon(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let icon = appIcons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIcons[path] = icon
        return icon
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Theme.text
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        imageView.imageScaling = .scaleProportionallyDown
        fileIcon.imageScaling = .scaleProportionallyDown
        fileName.alignment = .center
        fileName.lineBreakMode = .byTruncatingMiddle
        [textScroll, imageView, fileIcon, fileName, info].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ clip: Clip?) {
        [textScroll, imageView, fileIcon, fileName].forEach { $0.isHidden = true }
        info.subviews.forEach { $0.removeFromSuperview() }
        shownFile = nil
        guard let clip else { return }

        var rows: [(String, String, NSImage?)] = [
            ("Application", clip.app.isEmpty ? "Unknown" : clip.app,
             appIcon(clip.appPath)),
        ]
        switch clip.kind {
        case .text:
            if let color = clip.color {
                let values = colorValues(color)
                rows.append(("Content type", "Color", nil))
                rows.append(("Hex", values.hex, nil))
                rows.append(("RGB", values.rgb, nil))
            } else {
                rows.append(("Content type", clip.category == .link ? "Link" : clip.category == .code ? "Code" : "Text", nil))
                rows.append(("Characters", clip.characters.formatted(), nil))
                rows.append(("Words", clip.words.formatted(), nil))
            }
        case .image:
            let info = clip.imageInfo
            rows.append(("Content type", "Image", nil))
            rows.append(("Dimensions", info.dimensions, nil))
            rows.append(("Image size", info.size, nil))
        case .files:
            let files = clip.files
            let isFolder = (try? files.first?.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            rows.append(("Content type", files.count > 1 ? "\(files.count) files" : isFolder ? "Folder" : "File", nil))
            if let first = files.first {
                rows.append(("Path", abbreviatingHome(first.deletingLastPathComponent().path), nil))
                if let size = try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    rows.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), nil))
                }
            }
        }
        rows.append(("Copied", copiedLabel(clip.date), nil))

        let rowHeight: CGFloat = 30
        let infoHeight = 36 + CGFloat(rows.count) * rowHeight + 8
        info.frame = NSRect(x: 0, y: bounds.height - infoHeight, width: bounds.width, height: infoHeight)
        info.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: 0, width: bounds.width, height: 1)))
        let header = label("Information", size: 12, weight: .semibold, color: Theme.secondary)
        header.frame = NSRect(x: 18, y: 14, width: 200, height: 16)
        info.addSubview(header)
        for (index, (name, value, image)) in rows.enumerated() {
            let y = 36 + CGFloat(index) * rowHeight
            if index > 0 {
                info.addSubview(Fill(Theme.separator, frame: NSRect(x: 18, y: y, width: bounds.width - 36, height: 1)))
            }
            let nameLabel = label(name, size: 12, color: Theme.secondary)
            nameLabel.frame = NSRect(x: 18, y: y + 7, width: 130, height: 16)
            let valueLabel = label(value, size: 12)
            valueLabel.alignment = .right
            valueLabel.lineBreakMode = .byTruncatingMiddle
            valueLabel.sizeToFit()
            let valueWidth = min(valueLabel.frame.width, bounds.width - 36 - 150)
            valueLabel.frame = NSRect(x: bounds.width - 18 - valueWidth, y: y + 7, width: valueWidth, height: 16)
            info.addSubview(nameLabel)
            info.addSubview(valueLabel)
            if let image {
                let icon = NSImageView(image: image)
                icon.frame = NSRect(x: valueLabel.frame.minX - 20, y: y + 7, width: 16, height: 16)
                info.addSubview(icon)
            }
        }

        let preview = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - infoHeight)
        switch clip.kind {
        case .text where clip.color != nil:
            // A large swatch with the value under it, as Raycast shows colors.
            fileIcon.isHidden = false
            fileName.isHidden = false
            let side = min(preview.width - 36, preview.height - 16 - 42, 160)
            fileIcon.frame = NSRect(x: (preview.width - side) / 2, y: 16 + (preview.height - 58 - side) / 2, width: side, height: side)
            fileIcon.image = swatch(clip.color!, side: side, radius: 12)
            fileName.frame = NSRect(x: 18, y: preview.height - 34, width: preview.width - 36, height: 18)
            fileName.stringValue = clip.title
        case .text:
            textScroll.isHidden = false
            textScroll.frame = preview.insetBy(dx: 6, dy: 4)
            textView.frame = NSRect(origin: .zero, size: textScroll.contentSize)
            // Laying out a long clipping takes a while; the pane shows the first couple of thousand characters.
            textView.string = String(clip.item.prefix(2_500))
            textView.font = clip.category == .code ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
            textView.textColor = Theme.text
            textView.scroll(.zero)
        case .image:
            imageView.isHidden = false
            imageView.frame = preview.insetBy(dx: 18, dy: 16)
            imageView.image = NSImage(contentsOf: clip.dataURL)
        case .files:
            fileIcon.isHidden = false
            fileName.isHidden = false
            fileIcon.frame = NSRect(x: 18, y: 16, width: preview.width - 36, height: preview.height - 16 - 42)
            fileName.frame = NSRect(x: 18, y: preview.height - 34, width: preview.width - 36, height: 18)
            fileName.stringValue = clip.title
            fileIcon.image = nil
            guard let file = clip.files.first else { return }
            shownFile = file
            thumbnail(of: file, side: max(fileIcon.frame.width, fileIcon.frame.height)) { [weak self] image in
                if self?.shownFile == file { self?.fileIcon.image = image }
            }
        }
    }
}

// MARK: - Bottom bar

/// Set in Configure Workflow.
enum Layout: String {
    case window  // Raycast's: a list and a preview in a window in the middle of the screen
    case bar  // Paste's: a row of cards along the bottom of the screen
}

func isLight(_ color: NSColor) -> Bool {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent > 0.6
}

/// The most colorful tone of an app icon, for the header of its cards as in Paste. Pixels count by their
/// saturation, so Safari is blue rather than the gray of its white background, and they're grouped by hue,
/// so an icon of many colors such as Chrome's gets the strongest of them rather than a mix of them all.
func colorfulTone(of icon: NSImage) -> NSColor {
    let side = 16
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return .systemGray }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    // Twelve hues, and grays on their own.
    var groups = [(red: CGFloat, green: CGFloat, blue: CGFloat, weight: CGFloat)](repeating: (0, 0, 0, 0), count: 13)
    for x in 0..<side {
        for y in 0..<side {
            guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
            let saturation = pixel.saturationComponent
            let group = saturation < 0.15 ? 12 : min(Int(pixel.hueComponent * 12), 11)
            let weight = saturation * saturation + 0.02
            groups[group].red += pixel.redComponent * weight
            groups[group].green += pixel.greenComponent * weight
            groups[group].blue += pixel.blueComponent * weight
            groups[group].weight += weight
        }
    }
    guard let best = groups.max(by: { $0.weight < $1.weight }), best.weight > 0 else { return .systemGray }
    return NSColor(deviceRed: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight, alpha: 1)
}

/// A clipping in the bottom bar, drawn like Paste's cards: a header in the color of the app it came from,
/// with its type and when it was copied, then the content as large as the card allows and a line about it.
final class Card: Flipped {
    static let size = NSSize(width: 232, height: 252)
    static let inset: CGFloat = 4  // room for the selection ring
    static let shape = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
    static let header = NSRect(x: inset, y: inset, width: shape.width, height: 54)
    static let body = NSRect(x: inset, y: header.maxY, width: shape.width, height: shape.height - header.height - 26)

    /// Each app's icon and tone, worked out once.
    static var looks: [String: (icon: NSImage?, tone: NSColor)] = [:]
    static let thumbnails = NSCache<NSURL, NSImage>()
    static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named  // "now" rather than "in 0 seconds"
        return formatter
    }()

    let kind = label("", size: 13, weight: .semibold)
    let time = label("", size: 11)
    let appIcon = NSImageView()
    let text = NSTextField(wrappingLabelWithString: "")
    let picture = NSView()  // an image, filling the body
    let fileIcon = NSImageView()  // a file's thumbnail or icon, whole
    let footer = label("", size: 11, color: Theme.secondary)
    let number = label("", size: 11, weight: .medium, color: Theme.secondary)  // ⌘1 to ⌘9 while in view
    var tone = NSColor.systemGray
    var swatch: NSColor?  // a color clipping's color, filling the body
    var file: URL?  // whose thumbnail the card is waiting for
    var isSelected = false { didSet { needsDisplay = true } }

    static func look(_ appPath: String) -> (icon: NSImage?, tone: NSColor) {
        if let look = looks[appPath] { return look }
        guard !appPath.isEmpty else { return (nil, .systemGray) }
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        looks[appPath] = (icon, colorfulTone(of: icon))
        return looks[appPath]!
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        kind.frame = NSRect(x: 18, y: 14, width: 150, height: 17)
        time.frame = NSRect(x: 18, y: 33, width: 150, height: 14)
        appIcon.frame = NSRect(x: Card.header.maxX - 14 - 34, y: Card.header.midY - 17, width: 34, height: 34)
        text.frame = Card.body.insetBy(dx: 14, dy: 10)
        text.cell?.truncatesLastVisibleLine = true
        picture.frame = Card.body
        picture.wantsLayer = true
        picture.layer?.contentsGravity = .resizeAspectFill
        picture.layer?.masksToBounds = true
        fileIcon.frame = Card.body.insetBy(dx: 18, dy: 12)
        fileIcon.imageScaling = .scaleProportionallyUpOrDown
        footer.frame = NSRect(x: 18, y: Card.body.maxY + 6, width: Card.shape.width - 28 - 32, height: 14)
        number.frame = NSRect(x: Card.shape.maxX - 14 - 30, y: Card.body.maxY + 6, width: 30, height: 14)
        number.alignment = .right
        [kind, time, appIcon, text, picture, fileIcon, footer, number].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks and drags go to the collection view, whatever part of the card they start on.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: Card.shape, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        Theme.card.setFill()
        Card.shape.fill()
        tone.setFill()
        Card.header.fill()
        if let swatch {
            swatch.setFill()
            Card.body.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.border.setStroke()
        shape.stroke()
        if isSelected {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12.5, yRadius: 12.5)
            ring.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }

    func show(_ clip: Clip, pinned: Bool) {
        let look = Card.look(clip.appPath)
        tone = look.tone
        let onTone = isLight(tone) ? NSColor(white: 0, alpha: 0.85) : .white
        kind.textColor = onTone
        time.textColor = onTone.withAlphaComponent(0.75)
        time.stringValue = pinned ? "Pinned" : Card.ago.localizedString(for: clip.date, relativeTo: Date())
        appIcon.image = look.icon
        [text, picture, fileIcon].forEach { $0.isHidden = true }
        picture.layer?.contents = nil
        swatch = nil
        file = nil
        needsDisplay = true
        switch clip.kind {
        case .text where clip.color != nil:
            kind.stringValue = "Color"
            swatch = clip.color
            footer.stringValue = colorValues(clip.color!).hex
        case .text:
            let trimmed = clip.item.prefix(600).trimmingCharacters(in: .whitespacesAndNewlines)
            kind.stringValue = clip.category == .link ? "Link" : clip.category == .code ? "Code" : "Text"
            text.isHidden = false
            text.stringValue = trimmed
            text.font = clip.category == .code ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
            text.textColor = clip.category == .link ? .linkColor : Theme.text
            footer.stringValue = clip.category == .link
                ? URL(string: trimmed)?.host ?? "" : "\(clip.characters.formatted()) characters"
        case .image:
            let info = clip.imageInfo
            kind.stringValue = "Image"
            footer.stringValue = "\(info.dimensions)   \(info.size)"
            picture.isHidden = false
            load(clip.dataURL, side: 360) { [weak self] in self?.picture.layer?.contents = $0 }
        case .files:
            let files = clip.files
            kind.stringValue = files.count > 1 ? "\(files.count) Files" : "File"
            footer.stringValue = clip.title
            fileIcon.isHidden = false
            fileIcon.image = nil
            guard let first = files.first else { return }
            load(first, side: 200) { [weak self] in self?.fileIcon.image = $0 }
        }
    }

    /// Shows a thumbnail now if it's been made before, or once it's ready if the card still shows that file.
    func load(_ file: URL, side: CGFloat, into show: @escaping (NSImage) -> Void) {
        if let image = Card.thumbnails.object(forKey: file as NSURL) { return show(image) }
        self.file = file
        thumbnail(of: file, side: side) { [weak self] image in
            Card.thumbnails.setObject(image, forKey: file as NSURL)
            if self?.file == file { show(image) }
        }
    }
}

final class CardItem: NSCollectionViewItem {
    override func loadView() { view = Card(frame: NSRect(origin: .zero, size: Card.size)) }
    override var isSelected: Bool { didSet { (view as? Card)?.isSelected = isSelected } }
}

final class CardStrip: NSCollectionView {
    var onDoubleClick: (() -> Void)?
    var onMenu: ((Int?) -> NSMenu?)?  // given the card right-clicked

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            onDoubleClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?(indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item)
    }
}

/// Scrolls sideways with a mouse wheel too, which only scrolls up and down.
final class SidewaysScroll: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let content = documentView else {
            return super.scrollWheel(with: event)
        }
        var origin = contentView.bounds.origin
        origin.x -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        origin.x = max(0, min(origin.x, content.frame.width - contentView.bounds.width))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

// MARK: - Window

final class Panel: NSPanel {
    var onShortcut: ((NSEvent) -> Bool)?  // ⌘↩, ⌘K and the like; true when it was one
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    // Esc when something other than the search field has focus (the search field handles its own).
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onShortcut?(event) == true || super.performKeyEquivalent(with: event)
    }
}

func roundedMask(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}

/// Has Alfred run the workflow's "paste" trigger, which presses ⌘V with Alfred's Accessibility
/// permission. Opened without activating Alfred, so the app you were in stays in front and gets it.
func askAlfredToPaste() {
    guard let url = URL(string: "alfred://runtrigger/com.andreisuslov.alfred-clipboard-history/paste/") else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open(url, configuration: configuration)
}

/// Presses ⌘V in whatever app is in front.
func pressCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: keyDown)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
}

final class Controller: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate, NSMenuDelegate {
    enum Row {
        case header(String)
        case clip(Clip)
    }

    /// What the menu next to the search field shows: the history of one type (an index into `types`,
    /// pins first), or a pinboard.
    enum Filter: Equatable {
        case type(Int)
        case board(String)
    }

    static let size = NSSize(width: 768, height: 480)
    static let listWidth: CGFloat = 300
    static let searchHeight: CGFloat = 56
    static let footerHeight: CGFloat = 40
    static let barHeight = searchHeight + Card.size.height + 14

    let layout: Layout
    let panel: Panel
    let root: Fill
    let search = NSTextField()
    let typeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let table = NSTableView()
    let detail: DetailView
    let cards = CardStrip()
    let emptyHint = label("", size: 13, color: Theme.secondary)
    var footerView: NSView?
    var clips: [Clip] = []
    var saved = Saved.load()
    var filter = Filter.type(0)
    var asking: ((String) -> Void)?  // while the search field takes a pinboard's name, what to do with it
    var numbered: [Int] = []  // the rows ⌘1 to ⌘9 paste: the items wholly in view, in order
    var loadedStamp = HistoryStamp()
    var loading = false
    var selectingFromCode = false
    var rows: [Row] = []
    var thumbnails: [String: NSImage] = [:]
    var target: NSRunningApplication?  // the app ↩ pastes into and Esc returns to: the last one you were in
    var dragWatch: Timer?
    var refreshTimer: Timer?

    init(layout: Layout) {
        self.layout = layout
        // The bar takes the width of the screen it opens on; this is only a start.
        let size = layout == .bar ? NSSize(width: 1440, height: Controller.barHeight) : Controller.size
        let bodyTop = Controller.searchHeight + 1
        let bodyHeight = size.height - bodyTop - Controller.footerHeight - 1
        detail = DetailView(frame: NSRect(x: Controller.listWidth + 1, y: bodyTop,
                                          width: size.width - Controller.listWidth - 1, height: bodyHeight))
        panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root = Fill(Theme.window, radius: layout == .bar ? 0 : 12, stroke: Theme.border, frame: blur.bounds)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Alfred's own level: above status-bar-level windows such as the GlobalProtect login, below menus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Drag the window by the search bar, footer or preview background; the bar stays at the bottom.
        panel.isMovableByWindowBackground = layout == .window
        panel.delegate = self
        panel.onShortcut = { [weak self] in self?.shortcut($0) ?? false }
        panel.onEscape = { [weak self] in self?.hide() }

        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        if layout == .window { blur.maskImage = roundedMask(radius: 12) }
        panel.contentView = blur
        root.autoresizingMask = [.width, .height]
        blur.addSubview(root)

        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 18)
        search.textColor = Theme.text
        search.placeholderAttributedString = placeholder("Type to filter entries…")
        search.delegate = self
        search.frame = NSRect(x: 20, y: 16, width: size.width - 40 - 140, height: 24)
        search.autoresizingMask = [.width]
        root.addSubview(search)

        typeMenu.isBordered = false
        typeMenu.font = .systemFont(ofSize: 13)
        typeMenu.contentTintColor = Theme.secondary
        typeMenu.target = self
        typeMenu.action = #selector(filterChosen)
        typeMenu.autoresizingMask = [.minXMargin]
        root.addSubview(typeMenu)
        buildFilterMenu()

        // Pick up new copies while hidden, so the window opens with them already listed.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.refreshIfChanged()
        }

        // The app you were in is the last one to come to the front, kept as it happens: opened through
        // Alfred (the keyword, or a list of apps to open), this app is already in front by the time the window shows.
        if let front = NSWorkspace.shared.frontmostApplication { noteFront(front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // An empty pinboard says how to fill it: in the middle of the bar, or of the window's preview.
        emptyHint.frame = layout == .bar
            ? NSRect(x: 0, y: Controller.searchHeight + Card.size.height / 2 - 9, width: size.width, height: 18)
            : NSRect(x: detail.frame.minX, y: detail.frame.midY - 9, width: detail.frame.width, height: 18)
        emptyHint.alignment = .center
        emptyHint.autoresizingMask = [.width]
        emptyHint.isHidden = true

        guard layout == .window else {
            addCards(width: size.width)
            root.addSubview(emptyHint)
            return
        }
        root.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: Controller.searchHeight, width: size.width, height: 1)))

        let column = NSTableColumn(identifier: .init("clip"))
        column.width = Controller.listWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.allowsMultipleSelection = true
        table.menu = NSMenu()  // filled with the actions as it opens, see menuNeedsUpdate
        table.menu?.delegate = self
        // No .move: dropping a file in Finder must copy it, never take it out of the history.
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: bodyTop, width: Controller.listWidth, height: bodyHeight))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        root.addSubview(scroll)
        renumberWhenScrolled(scroll)

        root.addSubview(Fill(Theme.separator, frame: NSRect(x: Controller.listWidth, y: bodyTop, width: 1, height: bodyHeight)))
        root.addSubview(detail)
        root.addSubview(Fill(Theme.separator, frame: NSRect(x: 0, y: size.height - Controller.footerHeight - 1,
                                                             width: size.width, height: 1)))
        root.addSubview(emptyHint)
    }

    /// Replaced when the layout changes in Configure Workflow.
    deinit {
        refreshTimer?.invalidate()
        panel.delegate = nil
    }

    /// The bottom bar's row of cards under the search field, newest on the left.
    func addCards(width: CGFloat) {
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = Card.size
        flow.minimumLineSpacing = 8  // between columns, when scrolling sideways
        flow.sectionInset = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        cards.collectionViewLayout = flow
        cards.backgroundColors = [.clear]
        cards.isSelectable = true
        cards.allowsEmptySelection = false
        cards.allowsMultipleSelection = true
        cards.register(CardItem.self, forItemWithIdentifier: .init("card"))
        cards.dataSource = self
        cards.delegate = self
        cards.onDoubleClick = { [weak self] in self?.use(paste: true) }
        cards.onMenu = { [weak self] in self?.menu(forCard: $0) }
        cards.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        let scroll = SidewaysScroll(frame: NSRect(x: 0, y: Controller.searchHeight - 4, width: width,
                                                  height: Card.size.height + 10))
        scroll.documentView = cards
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width]
        root.addSubview(scroll)
        renumberWhenScrolled(scroll)
    }

    /// Raycast's action bar: where you are on the left, the keys for the selection on the right.
    func footer(width: CGFloat, y: CGFloat) -> NSView {
        let bar = Flipped(frame: NSRect(x: 0, y: y, width: width, height: Controller.footerHeight))
        var board: String?
        if case .board(let name) = filter { board = name }
        let icon = NSImageView(image: symbol(board == nil ? "doc.on.clipboard" : "pin", size: 13) ?? NSImage())
        icon.contentTintColor = Theme.secondary
        icon.frame = NSRect(x: 18, y: 11, width: 18, height: 18)
        let keys = keyHints()
        keys.frame.origin = NSPoint(x: width - 18 - keys.frame.width, y: 0)
        let title = label(board ?? "Clipboard History", size: 12, weight: .medium, color: Theme.secondary)
        title.frame = NSRect(x: 42, y: 12, width: max(0, min(200, keys.frame.minX - 12 - 42)), height: 16)
        bar.addSubview(icon)
        bar.addSubview(title)
        bar.addSubview(keys)
        return bar
    }

    /// Paste, then pinning (taking off a pinboard, on one), then the rest under ⌘K: the keys are on show,
    /// so how to unpin or tidy a pinboard is there to see.
    func keyHints() -> NSView {
        let keys = Flipped()
        var x: CGFloat = 0
        func place(_ view: NSView, gap: CGFloat = 4) {
            x -= view.frame.width
            view.frame.origin = NSPoint(x: x, y: (Controller.footerHeight - view.frame.height) / 2)
            keys.addSubview(view)
            x -= gap
        }
        func text(_ string: String) -> NSTextField {
            let field = label(string, size: 12, weight: .medium)
            field.sizeToFit()
            return field
        }
        func separator() { place(Fill(Theme.separator, frame: NSRect(x: 0, y: 0, width: 1, height: 16)), gap: 12) }
        place(keyCap("K"))
        place(keyCap("⌘"))
        place(text("Actions"), gap: 12)
        let chosen = selectedClips
        if !chosen.isEmpty {
            separator()
            if case .board = filter {
                place(keyCap("⌫"))
                place(keyCap("⌘"))
                place(text("Remove"), gap: 12)
            } else {
                place(keyCap("P"))
                place(keyCap("⇧"))
                place(keyCap("⌘"))
                place(text(chosen.allSatisfy(saved.isPinned) ? "Unpin" : "Pin"), gap: 12)
            }
            separator()
            place(keyCap("↩"))
            place(text(pasteTitle))
        }
        // Placed leftwards from 0; moved into a view as wide as they are.
        keys.subviews.forEach { $0.frame.origin.x -= x }
        keys.frame.size = NSSize(width: -x, height: Controller.footerHeight)
        return keys
    }

    /// "Paste to Safari", "Paste 3 Items to Safari": for the footer and the actions.
    var pasteTitle: String {
        "Paste\(itemCount)" + (target?.localizedName.map { " to \($0)" } ?? "")
    }

    var itemCount: String {
        let count = selectedClips.count
        return count > 1 ? " \(count) Items" : ""
    }

    /// Rebuilt for the app you were in and for what's selected. The bar has no footer: its keys go between
    /// the search field and the menu.
    func showFooter() {
        footerView?.removeFromSuperview()
        if layout == .bar {
            let keys = keyHints()
            keys.frame.origin = NSPoint(x: typeMenu.frame.minX - 16 - keys.frame.width, y: 8)
            keys.autoresizingMask = [.minXMargin]
            search.frame.size.width = keys.frame.minX - 12 - search.frame.minX
            footerView = keys
        } else {
            footerView = footer(width: Controller.size.width, y: Controller.size.height - Controller.footerHeight)
        }
        root.addSubview(footerView!)
    }

    // MARK: Showing and hiding

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    @objc func appActivated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { noteFront(app) }
    }

    /// Only ordinary apps count: Alfred and Spotlight close their windows as this one opens.
    func noteFront(_ app: NSRunningApplication) {
        if app.processIdentifier != getpid(), app.activationPolicy == .regular { target = app }
    }

    /// The list is kept ready while the window is hidden, so showing it only has to put it on screen.
    func show() {
        refreshIfChanged()
        let screen = screenWithPointer()
        // The bar spans the bottom of the screen and rises from its edge, as Paste's does.
        let bar = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: Controller.barHeight)
        if layout == .bar {
            panel.setFrame(bar.offsetBy(dx: 0, dy: -bar.height), display: false)
        } else {
            panel.setFrameOrigin(origin(on: screen))
        }
        showFooter()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        if layout == .bar {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(bar, display: true)
            }
        }
        // Become the active app, as Raycast does. A window of an inactive app keeps the keyboard only
        // until the active app (a browser updating its page, say) takes it back, which lost keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(search)
        panel.invalidateShadow()
        numberVisible()
    }

    /// Closes the window and, unless you clicked into another app (which then has the keyboard
    /// already), hands focus back to the app you were in.
    func hide(returnFocus: Bool = true) {
        dragWatch?.invalidate()
        dragWatch = nil
        panel.orderOut(nil)
        if returnFocus, NSApp.isActive, let target {
            // macOS 14 only lets the target activate if we yield first; 13 has no such handshake.
            if #available(macOS 14, *) { NSApp.yieldActivation(to: target) }
            target.activate()
        }
        // Like Raycast, the next opening starts from an empty search at the newest item.
        DispatchQueue.main.async { [weak self] in self?.resetView() }
    }

    func resetView() {
        stopAsking()
        search.stringValue = ""
        filter = .type(0)
        buildFilterMenu()
        reload()
    }

    /// Reloads only when Alfred has recorded or removed something since the last load. Loading and
    /// indexing thousands of clippings happens off the main thread, so the window never waits for it.
    func refreshIfChanged() {
        guard !loading else { return }
        let stamp = historyStamp()
        guard stamp != loadedStamp else { return }
        // Usually Alfred has only added a copy or two: load just those, right away (about a millisecond).
        if !clips.isEmpty, stamp.newest > loadedStamp.newest {
            let added = loadClips(newerThan: loadedStamp.newest)
            // Copying something again moves Alfred's item to the top, so its older entry goes.
            let kept = clips.filter { old in !added.contains { $0.isSameItem(as: old) } }
            if kept.count + added.count == stamp.count {
                clips = added + kept
                loadedStamp = stamp
                reload()
                return
            }
        }
        // Anything else (the first load, Alfred deleting items) reloads everything in the background.
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fresh = loadClips()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clips = fresh
                self.loadedStamp = stamp
                self.loading = false
                self.reload()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if dragWatch == nil { hide(returnFocus: false) }
    }

    // MARK: Position

    func screenWithPointer() -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
    }

    /// Where the window goes: where you last dragged it, or where Alfred's window appears
    /// (centered, its top about 36% down the screen). Remembered relative to the screen's top center.
    func origin(on screen: NSScreen) -> NSPoint {
        let frame = screen.frame
        let size = Controller.size
        let defaults = UserDefaults.standard
        let fromCenter = defaults.object(forKey: "offsetFromCenter") as? Double ?? -Double(size.width / 2)
        let fromTop = defaults.object(forKey: "offsetFromTop") as? Double ?? Double(frame.height * 0.36)
        let point = NSPoint(x: frame.midX + fromCenter, y: frame.maxY - fromTop - size.height)
        // A position saved on a bigger screen could leave it partly off this one.
        return screen.visibleFrame.contains(NSRect(origin: point, size: size))
            ? point : NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.36 - size.height)
    }

    func windowDidMove(_ notification: Notification) {
        guard layout == .window, panel.isVisible, let frame = panel.screen?.frame else { return }
        UserDefaults.standard.set(Double(panel.frame.minX - frame.midX), forKey: "offsetFromCenter")
        UserDefaults.standard.set(Double(frame.maxY - panel.frame.maxY), forKey: "offsetFromTop")
    }

    // MARK: Paste and copy

    func use(paste: Bool) {
        let chosen = selectedClips
        guard !chosen.isEmpty else { return NSSound.beep() }
        Clip.write(chosen, to: .general)
        hide()
        guard paste, let target else { return }
        whenFrontmost(target, then: askAlfredToPaste)
    }

    /// ⌘V has to reach the app you were in, so wait until it is back in front (a few milliseconds),
    /// giving up after half a second.
    func whenFrontmost(_ app: NSRunningApplication, then action: @escaping () -> Void, until deadline: Date = Date() + 0.5) {
        if NSWorkspace.shared.frontmostApplication == app || Date() > deadline { return action() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { self.whenFrontmost(app, then: action, until: deadline) }
    }

    @objc func doubleClicked() {
        if table.clickedRow >= 0 { use(paste: true) }
    }

    // MARK: Filtering

    /// The type menu, in order; Media is images and copied files.
    static let types: [(title: String, category: Clip.Category?)] = [
        ("All Types", nil), ("Text", .text), ("Links", .link), ("Code", .code), ("Media", .media), ("Colors", .color),
    ]

    func matches(_ clip: Clip, _ query: [UInt8], category: Clip.Category?) -> Bool {
        if let category, clip.category != category { return false }
        guard !query.isEmpty else { return true }
        // A plain byte search over the pre-folded text: a few milliseconds for the whole history.
        return clip.searchKey.withUnsafeBytes { key in
            query.withUnsafeBytes { needle in
                memmem(key.baseAddress, key.count, needle.baseAddress, needle.count) != nil
            }
        }
    }

    /// Lists what the filter and the search pick, and selects the newest copy (or the first match when
    /// searching), or else the item that was selected, when it's still listed.
    func reload(keeping kept: [Clip] = []) {
        let query = asking == nil ? Array(fold(search.stringValue.trimmingCharacters(in: .whitespaces)).utf8) : []
        rows = []
        var newest: Int?
        switch filter {
        case .board(let name):
            let items = saved.boards.first { $0.name == name }?.items ?? []
            rows = items.filter { matches($0, query, category: nil) }.map { .clip($0) }
        case .type(let type):
            let category = Controller.types[type].category
            let pins = saved.pinned.filter { matches($0, query, category: category) }
            if layout == .window, !pins.isEmpty { rows.append(.header("Pinned")) }
            rows += pins.map { .clip($0) }
            // A pinned item shows only among the pins.
            let pinned = Set(saved.pinned.map(\.key))
            // Clips are newest first, so a new day starts only when a clip is older than the current day's start;
            // titles are formatted once per day rather than once per clip. The bar has no titles: each card
            // says when it was copied.
            var dayStart = Date.distantFuture
            for clip in clips where matches(clip, query, category: category) && !pinned.contains(clip.key) {
                if layout == .window, clip.date < dayStart {
                    dayStart = Calendar.current.startOfDay(for: clip.date)
                    rows.append(.header(dayTitle(clip.date)))
                }
                if query.isEmpty, newest == nil { newest = rows.count }
                rows.append(.clip(clip))
            }
        }
        if layout == .bar { cards.reloadData() } else { table.reloadData() }
        let keptRow = kept.first.flatMap { kept in
            rows.firstIndex { if case .clip(let clip) = $0 { return clip.isSameItem(as: kept) } else { return false } }
        }
        select(keptRow ?? newest ?? rows.firstIndex { if case .clip = $0 { return true } else { return false } })
        numberVisible()
        if case .board(let name) = filter, rows.isEmpty, query.isEmpty {
            emptyHint.stringValue = "Nothing on “\(name)” yet. Add items with ⌘K or a right-click."
            emptyHint.isHidden = false
        } else {
            emptyHint.isHidden = true
        }
    }

    /// The types, then the pinboards with their dots, then what can be done with pinboards.
    func buildFilterMenu() {
        let menu = NSMenu()
        func add(_ title: String, tag: Int, image: NSImage? = nil) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            item.image = image
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        for (index, type) in Controller.types.enumerated() { add(type.title, tag: index) }
        menu.addItem(.separator())
        add("Pinboards", tag: -100)
        menu.items.last?.isEnabled = false  // a heading
        for (index, board) in saved.boards.enumerated() { add(board.name, tag: 100 + index, image: saved.dot(board.name)) }
        add("New Pinboard…", tag: -1)
        if case .board(let name) = filter {
            menu.addItem(.separator())
            add("Rename “\(name)”…", tag: -2)
            add("Delete “\(name)”…", tag: -3)
        }
        typeMenu.menu = menu
        switch filter {
        case .type(let index): typeMenu.selectItem(withTag: index)
        case .board(let name): typeMenu.selectItem(withTag: 100 + (saved.boards.firstIndex { $0.name == name } ?? 0))
        }
        typeMenu.sizeToFit()
        typeMenu.frame = NSRect(x: root.bounds.width - 20 - typeMenu.frame.width, y: 16,
                                width: typeMenu.frame.width, height: 24)
        search.frame.size.width = typeMenu.frame.minX - 12 - search.frame.minX
        showFooter()
    }

    @objc func filterChosen() {
        stopAsking()
        let tag = typeMenu.selectedTag()
        switch tag {
        case -1: return newBoard()
        case -2: return renameBoard()
        case -3: return deleteBoard()
        case 100...: filter = .board(saved.boards[tag - 100].name)
        default: filter = .type(tag)
        }
        buildFilterMenu()
        reload()
        panel.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) {
        if asking == nil { reload() }
    }

    // MARK: Pins and pinboards

    func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: Theme.secondary])
    }

    /// Has the search field take a pinboard's name, as Raycast does, rather than a dialog, which would take
    /// the keyboard from the window and so close it. ↩ answers and Esc cancels.
    func ask(_ prompt: String, text: String = "", then answer: @escaping (String) -> Void) {
        asking = answer
        search.stringValue = text
        search.placeholderAttributedString = placeholder(prompt)
        panel.makeFirstResponder(search)
        search.currentEditor()?.selectAll(nil)
    }

    func stopAsking() {
        guard asking != nil else { return }
        asking = nil
        search.stringValue = ""
        search.placeholderAttributedString = placeholder("Type to filter entries…")
    }

    /// The menu back on what's shown, after choosing one of its pinboard actions.
    func cancelAsking() {
        stopAsking()
        buildFilterMenu()
        reload()
    }

    func newBoard(adding chosen: [Clip] = []) {
        ask("Name the new pinboard and press ↩") { [weak self] name in
            guard let self else { return }
            guard !name.isEmpty else { return self.cancelAsking() }
            if !self.saved.boards.contains(where: { $0.name == name }) {
                self.saved.boards.append(Saved.Board(name: name, items: []))
                self.saved.save()
            }
            if chosen.isEmpty {
                self.filter = .board(name)
                self.buildFilterMenu()
                self.reload()
            } else {
                self.buildFilterMenu()
                self.add(chosen, to: name)
            }
        }
    }

    func renameBoard() {
        guard case .board(let name) = filter else { return }
        ask("Rename “\(name)” and press ↩", text: name) { [weak self] newName in
            guard let self else { return }
            if !newName.isEmpty, !self.saved.boards.contains(where: { $0.name == newName }),
               let index = self.saved.boards.firstIndex(where: { $0.name == name }) {
                self.saved.boards[index].name = newName
                self.saved.save()
                self.filter = .board(newName)
            }
            self.cancelAsking()
        }
    }

    func deleteBoard() {
        guard case .board(let name) = filter, let board = saved.boards.first(where: { $0.name == name }) else { return }
        let items = board.items.count == 1 ? "its 1 item" : "its \(board.items.count) items"
        ask("Press ↩ to delete “\(name)” and \(items), or Esc to keep it") { [weak self] _ in
            guard let self else { return }
            self.saved.boards.removeAll { $0.name == name }
            self.saved.save()
            self.filter = .type(0)
            self.cancelAsking()
        }
    }

    /// Pins what's selected, or unpins it when it's all pinned already.
    func togglePin() {
        let chosen = selectedClips
        guard !chosen.isEmpty else { return NSSound.beep() }
        if chosen.allSatisfy(saved.isPinned) {
            saved.pinned.removeAll { pin in chosen.contains { $0.isSameItem(as: pin) } }
        } else {
            saved.pinned.insert(contentsOf: chosen.filter { !saved.isPinned($0) }.map(Saved.keep), at: 0)
        }
        saved.save()
        reload(keeping: chosen)
    }

    func add(_ chosen: [Clip], to name: String) {
        guard let index = saved.boards.firstIndex(where: { $0.name == name }) else { return }
        let new = chosen.filter { clip in !saved.boards[index].items.contains { $0.isSameItem(as: clip) } }
        saved.boards[index].items.insert(contentsOf: new.map(Saved.keep), at: 0)
        saved.save()
        reload(keeping: chosen)
    }

    func remove(_ chosen: [Clip], from name: String) {
        guard let index = saved.boards.firstIndex(where: { $0.name == name }) else { return }
        saved.boards[index].items.removeAll { item in chosen.contains { $0.isSameItem(as: item) } }
        saved.save()
        reload()
    }

    /// Raycast's action panel, for ⌘K and a right-click: what can be done with the selected items.
    func actions() -> [NSMenuItem] {
        let chosen = selectedClips
        guard !chosen.isEmpty else { return [] }
        var items: [NSMenuItem] = [
            // No ↩ shown for Paste: in an open menu ↩ has to choose the highlighted item.
            ActionItem(pasteTitle) { [weak self] in self?.use(paste: true) },
            ActionItem("Copy\(itemCount)", key: "\r", .command) { [weak self] in self?.use(paste: false) },
            .separator(),
            ActionItem(chosen.allSatisfy(saved.isPinned) ? "Unpin" : "Pin", key: "p", [.command, .shift]) { [weak self] in
                self?.togglePin()
            },
        ]
        let boards = NSMenu()
        for board in saved.boards {
            boards.addItem(ActionItem(board.name, image: saved.dot(board.name)) { [weak self] in self?.add(chosen, to: board.name) })
        }
        if !saved.boards.isEmpty { boards.addItem(.separator()) }
        boards.addItem(ActionItem("New Pinboard…") { [weak self] in self?.newBoard(adding: chosen) })
        let addTo = NSMenuItem(title: "Add to Pinboard", action: nil, keyEquivalent: "")
        addTo.submenu = boards
        items.append(addTo)
        if case .board(let name) = filter {
            items.append(ActionItem("Remove from “\(name)”", key: "\u{8}", .command) { [weak self] in
                self?.remove(chosen, from: name)
            })
            items.append(.separator())
            items.append(ActionItem("Rename “\(name)”…") { [weak self] in self?.renameBoard() })
            items.append(ActionItem("Delete “\(name)”…") { [weak self] in self?.deleteBoard() })
        }
        return items
    }

    /// ⌘K: the actions, under the selected row or card.
    func showActions() {
        let items = actions()
        guard !items.isEmpty else { return NSSound.beep() }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        if layout == .bar {
            let card = cards.frameForItem(at: selectedRow)
            menu.popUp(positioning: nil, at: NSPoint(x: card.minX + 14, y: card.minY + Card.header.maxY), in: cards)
        } else {
            let row = table.rect(ofRow: selectedRow)
            menu.popUp(positioning: nil, at: NSPoint(x: row.minX + 40, y: row.maxY), in: table)
        }
    }

    /// A right-click on a row that isn't selected selects it, as in Finder, so the actions are for it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard rows.indices.contains(row), case .clip = rows[row] else { return }  // a day title: no menu
        if !table.selectedRowIndexes.contains(row) { select(row) }
        actions().forEach(menu.addItem)
    }

    func menu(forCard item: Int?) -> NSMenu? {
        guard let item else { return nil }
        if !selectedRows.contains(item) { select(item) }
        let menu = NSMenu()
        actions().forEach(menu.addItem)
        return menu
    }

    static let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
                             kVK_ANSI_8, kVK_ANSI_9]

    /// ⌘↩ copies, ⌘⇧P pins as in Raycast, ⌘K shows the actions, ⌘1 to ⌘9 paste the items in view as in
    /// Alfred, and on a pinboard ⌘⌫ takes the selection off it, as Finder's key for Move to Trash.
    func shortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        switch (flags, key) {
        case (.command, kVK_Return), (.command, kVK_ANSI_KeypadEnter): use(paste: false)
        case ([.command, .shift], kVK_ANSI_P): togglePin()
        case (.command, kVK_ANSI_K): showActions()
        case (.command, _) where Controller.numberKeys.contains(key):
            let index = Controller.numberKeys.firstIndex(of: key)!
            guard numbered.indices.contains(index) else { NSSound.beep(); return true }
            select(numbered[index])
            use(paste: true)
        case (.command, kVK_Delete):
            guard case .board(let name) = filter else { return false }  // elsewhere it deletes search text
            remove(selectedClips, from: name)
        default: return false
        }
        return true
    }

    func renumberWhenScrolled(_ scroll: NSScrollView) {
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(numberVisible),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    /// Numbers the items wholly in view ⌘1 to ⌘9, as Alfred numbers its results; scrolling renumbers them.
    @objc func numberVisible(_ notification: Notification? = nil) {
        if layout == .bar {
            cards.layoutSubtreeIfNeeded()
            let visible = cards.visibleRect.insetBy(dx: -1, dy: -1)
            numbered = (cards.collectionViewLayout?.layoutAttributesForElements(in: visible) ?? [])
                .filter { visible.contains($0.frame) }.compactMap { $0.indexPath?.item }.sorted()
        } else {
            let visible = table.visibleRect
            let range = table.rows(in: visible)
            numbered = (range.lowerBound..<range.upperBound).filter { row in
                guard rows.indices.contains(row), case .clip = rows[row] else { return false }
                let rect = table.rect(ofRow: row)
                return rect.minY >= visible.minY - 1 && rect.maxY <= visible.maxY + 1
            }
        }
        numbered = Array(numbered.prefix(9))
        if layout == .bar {
            for path in cards.indexPathsForVisibleItems() {
                (cards.item(at: path)?.view as? Card)?.number.stringValue = number(for: path.item)
            }
        } else {
            let range = table.rows(in: table.visibleRect)
            for row in range.lowerBound..<range.upperBound {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCell)?.number.stringValue = number(for: row)
            }
        }
    }

    func number(for row: Int) -> String {
        numbered.firstIndex(of: row).map { "⌘\($0 + 1)" } ?? ""
    }

    // MARK: Selection

    /// ⌘-click and ⇧-click select more than one; they're pasted in the order shown.
    var selectedRows: [Int] {
        layout == .bar ? cards.selectionIndexPaths.map(\.item).sorted() : Array(table.selectedRowIndexes)
    }

    /// The row the keyboard moves from and the preview shows: in the list the one clicked last, in the bar
    /// the rightmost.
    var selectedRow: Int {
        layout == .bar ? selectedRows.last ?? -1 : table.selectedRow
    }

    var selectedClip: Clip? {
        guard rows.indices.contains(selectedRow), case .clip(let clip) = rows[selectedRow] else { return nil }
        return clip
    }

    var selectedClips: [Clip] {
        selectedRows.compactMap { row in
            guard rows.indices.contains(row), case .clip(let clip) = rows[row] else { return nil }
            return clip
        }
    }

    /// Selects a row from the keyboard or after filtering, and shows its preview once.
    func select(_ row: Int?) {
        if layout == .bar {
            cards.selectionIndexPaths = row.map { [IndexPath(item: $0, section: 0)] } ?? []
            // With the same margin as the first card has.
            if let row { cards.scrollToVisible(cards.frameForItem(at: row).insetBy(dx: -14, dy: 0)) }
            showFooter()
            return
        }
        selectingFromCode = true
        if let row {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            if case .header = rows[max(row - 1, 0)] { table.scrollRowToVisible(row - 1) }  // keep the day's title in view
        } else {
            table.deselectAll(nil)
        }
        selectingFromCode = false
        detail.show(selectedClip)
        showFooter()
    }

    /// Moves the selection by `count` items, skipping day titles and stopping at either end.
    func move(by count: Int) {
        let step = count < 0 ? -1 : 1
        var row = selectedRow
        var moved = 0
        var candidate = row + step
        while rows.indices.contains(candidate), moved < abs(count) {
            if case .clip = rows[candidate] {
                row = candidate
                moved += 1
            }
            candidate += step
        }
        if row != selectedRow { select(row) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        // In the bar ← and → go through the cards, as in Paste, rather than through the search text.
        case #selector(NSResponder.moveRight(_:)) where layout == .bar: move(by: 1)
        case #selector(NSResponder.moveLeft(_:)) where layout == .bar: move(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(by: 8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(by: -8)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): move(by: -rows.count)
        case #selector(NSResponder.moveToEndOfDocument(_:)): move(by: rows.count)
        // A text field sends Esc as complete: (autocompletion), not cancelOperation:.
        // While the field takes a pinboard's name, Esc cancels that and ↩ gives the name.
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            asking == nil ? hide() : cancelAsking()
        case #selector(NSResponder.insertNewline(_:)):
            guard let answer = asking else {
                use(paste: true)
                return true
            }
            let name = search.stringValue.trimmingCharacters(in: .whitespaces)
            stopAsking()
            answer(name)
        default: return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 36
    }

    /// Day titles never get selected, by a ⇧-click across days either.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { row in
            guard rows.indices.contains(row), case .clip = rows[row] else { return false }
            return true
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingFromCode else { return }  // select(_:) shows the preview itself
        detail.show(selectedClip)
        showFooter()
        if panel.firstResponder === table { keepTyping() }
    }

    /// After a click, keep typing going to the search field, as in Raycast.
    func keepTyping() {
        panel.makeFirstResponder(search)
        search.currentEditor()?.selectedRange = NSRange(location: search.stringValue.utf16.count, length: 0)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: .init("header"), owner: nil) as? HeaderCell ?? HeaderCell()
            cell.identifier = .init("header")
            cell.title.stringValue = title
            return cell
        case .clip(let clip):
            let cell = tableView.makeView(withIdentifier: .init("clip"), owner: nil) as? ClipCell ?? ClipCell()
            cell.identifier = .init("clip")
            cell.title.stringValue = clip.title
            cell.number.stringValue = number(for: row)
            cell.file = nil
            switch clip.kind {
            case .text:
                switch clip.category {
                case .color: cell.icon.image = swatch(clip.color!, side: 18, radius: 4)
                case .link: cell.icon.image = symbol("link", size: 14)
                case .code: cell.icon.image = symbol("chevron.left.forwardslash.chevron.right", size: 13)
                default: cell.icon.image = symbol("text.alignleft", size: 14)
                }
            case .image, .files:
                let file = clip.kind == .image ? clip.dataURL : clip.files.first
                cell.icon.image = file.flatMap { thumbnails[$0.path] }
                if let file, cell.icon.image == nil {
                    cell.file = file
                    thumbnail(of: file, side: 40) { [weak self, weak cell] image in
                        self?.thumbnails[file.path] = image
                        if cell?.file == file { cell?.icon.image = image }
                    }
                }
            }
            return cell
        }
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .clip(let clip) = rows[row] else { return nil }
        return clip.dragWriter
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragStarted(session)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(operation)
    }

    func dragStarted(_ session: NSDraggingSession) {
        session.animatesToStartingPositionsOnCancelOrFail = false
        // Once the drag leaves the window, fade it out so whatever is underneath (a Finder window,
        // Dropover's shelf) can take the drop. The timer runs in .common so it ticks while dragging.
        let watch = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let outside = !NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false)
            self.panel.alphaValue = outside ? 0 : 1
            self.panel.ignoresMouseEvents = outside
        }
        RunLoop.main.add(watch, forMode: .common)
        dragWatch = watch
    }

    func dragEnded(_ operation: NSDragOperation) {
        dragWatch?.invalidate()
        dragWatch = nil
        if operation.isEmpty && panel.isKeyWindow {
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        } else {
            hide()
        }
    }

    // MARK: Cards

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("card"), for: indexPath)
        if case .clip(let clip) = rows[indexPath.item] {
            // Pins come first in the history, with no day titles in the bar to set them apart.
            var pinned = false
            if case .type = filter { pinned = saved.isPinned(clip) }
            (item.view as? Card)?.show(clip, pinned: pinned)
            (item.view as? Card)?.number.stringValue = number(for: indexPath.item)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        showFooter()
        keepTyping()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        showFooter()
        keepTyping()  // a ⌘-click that takes a card out of the selection
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard case .clip(let clip) = rows[indexPath.item] else { return nil }
        return clip.dragWriter
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        dragStarted(session)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        dragEnded(operation)
    }
}

// MARK: - Hotkey

/// What the hotkey does; a global so the Carbon callback (a C function) can reach it.
var hotKeyAction: () -> Void = {}
var registeredHotKey: EventHotKeyRef?

/// Has the hotkey run hotKeyAction. The app registers the hotkey itself rather than in Alfred: the key press
/// then reaches this process, which is what lets macOS make it the active app with the keyboard; a request
/// sent from a script is refused.
func handleHotKey() {
    var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        hotKeyAction()
        return noErr
    }, 1, &pressed, nil, nil)
}

/// Frees the hotkey, if one is registered.
func unregisterHotKey() {
    if let registeredHotKey { UnregisterEventHotKey(registeredHotKey) }
    registeredHotKey = nil
}

/// Makes `key` with `modifiers` the hotkey, in place of the one before.
func registerHotKey(key: Int, modifiers: Int) {
    unregisterHotKey()
    RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x434C_4950, id: 1),
                        GetApplicationEventTarget(), 0, &registeredHotKey)
}

/// The app in the workflow folder. Allowed with Open Anyway, a downloaded app runs from a random
/// read-only copy (App Translocation, .../AppTranslocation/<UUID>/d/ClipHistory.app), so ask macOS
/// where the original is, as Sparkle does.
let appURL: URL = {
    typealias Create = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL"),
          let original = unsafeBitCast(symbol, to: Create.self)(Bundle.main.bundleURL as CFURL, nil)
    else { return Bundle.main.bundleURL }
    return original.takeRetainedValue() as URL
}()

/// A field of the workflow's Configure Workflow sheet. Alfred saves them to prefs.plist in the workflow
/// folder, next to the app; there's no file until one is changed.
func setting(_ variable: String) -> String {
    let prefs = appURL.deletingLastPathComponent().appendingPathComponent("prefs.plist")
    return NSDictionary(contentsOf: prefs)?[variable] as? String ?? ""
}

/// Whether the workflow is turned off in Alfred, which saves that as `disabled` in the workflow's info.plist.
func workflowDisabled() -> Bool {
    let info = appURL.deletingLastPathComponent().appendingPathComponent("info.plist")
    return NSDictionary(contentsOf: info)?["disabled"] as? Bool ?? false
}

let modifierNames = ["⌃": controlKey, "^": controlKey, "ctrl": controlKey, "control": controlKey,
                     "⌥": optionKey, "opt": optionKey, "option": optionKey, "alt": optionKey,
                     "⇧": shiftKey, "shift": shiftKey, "⌘": cmdKey, "cmd": cmdKey, "command": cmdKey]
let namedKeys = ["space": kVK_Space, "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
                 "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12]

/// A hotkey written with symbols or words: "⌥⌘V", "opt+cmd+v", "⌃⇧ Space". It needs a modifier, so that
/// typing the key on its own still types it.
func parseHotKey(_ text: String) -> (key: Int, modifiers: Int)? {
    var spaced = text.lowercased()
    for symbol in ["⌃", "^", "⌥", "⇧", "⌘"] { spaced = spaced.replacingOccurrences(of: symbol, with: " \(symbol) ") }
    var words = spaced.split { $0 == " " || $0 == "+" }.map(String.init)
    guard let last = words.popLast(), !words.isEmpty,
          let key = namedKeys[last] ?? (last.count == 1 ? keyCode(typing: last) : nil) else { return nil }
    var modifiers = 0
    for word in words {
        guard let modifier = modifierNames[word] else { return nil }
        modifiers |= modifier
    }
    return (key, modifiers)
}

/// The key that types `character` in the keyboard layout, so V is wherever the layout puts it (on Dvorak
/// too). It looks in the ASCII-capable layout, which finds V while a Russian or Greek layout is selected.
func keyCode(typing character: String) -> Int? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
    return layout.withUnsafeBytes { bytes -> Int? in
        guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
        // Key codes from 0, so the number row comes before the keypad.
        for code in 0..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var typed = [UniChar](repeating: 0, count: 4)
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, typed.count, &length, &typed)
            if String(utf16CodeUnits: typed, count: length).lowercased() == character { return code }
        }
        return nil
    }
}

/// An Edit menu, never shown (the app has no menu bar), so ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z work in the search
/// field: text fields get those shortcuts through the menu.
func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    item.submenu = edit
    let menu = NSMenu()
    menu.addItem(item)
    return menu
}

/// Keeps a LaunchAgent that starts the app in the background at login, pointing at wherever the
/// workflow is installed, so the hotkey works right after logging in. Rewritten only when it differs.
func installLoginAgent() {
    let label = Bundle.main.bundleIdentifier ?? "com.andreisuslov.alfred-clipboard-history"
    let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    let file = agents.appendingPathComponent("\(label).plist")
    let agent: NSDictionary = [
        "Label": label,
        "ProgramArguments": ["/usr/bin/open", "-g", "-a", appURL.path, "--args", "--login"],
        "RunAtLoad": true,
    ]
    if NSDictionary(contentsOf: file) == agent { return }
    try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    agent.write(to: file, atomically: true)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?
    var hotKeyText: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        installLoginAgent()
        pruneImageLinks()
        hotKeyAction = { [weak self] in self?.controller?.toggle() }
        handleHotKey()
        updateSettings()
        // What's saved in Configure Workflow applies within a couple of seconds, without a restart.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateSettings() }
        // At login (the LaunchAgent passes --login) it only starts, ready for the hotkey.
        if !CommandLine.arguments.contains("--login") { controller?.show() }
    }

    func updateSettings() {
        // The hotkey first: building the window can wait a second or two on the font server at login,
        // and a press in that time then opens it once it's built rather than going nowhere.
        updateHotKey()
        let layout = Layout(rawValue: setting("layout")) ?? .window
        if layout != controller?.layout {
            if controller?.panel.isVisible == true { controller?.hide() }
            controller = Controller(layout: layout)
            controller?.refreshIfChanged()
        }
    }

    /// Registers the hotkey from Configure Workflow when it has changed. An empty or unreadable one is ⌃⌘V.
    /// While the workflow is turned off in Alfred there's no hotkey and the window stays closed.
    func updateHotKey() {
        let text = workflowDisabled() ? nil : setting("hotkey")
        guard text != hotKeyText else { return }
        hotKeyText = text
        guard let text else {
            unregisterHotKey()
            if controller?.panel.isVisible == true { controller?.hide() }
            return
        }
        let hotKey = parseHotKey(text) ?? (kVK_ANSI_V, controlKey | cmdKey)
        registerHotKey(key: hotKey.key, modifiers: hotKey.modifiers)
    }

    /// The workflow's keyword and Home entry run `open ClipHistory.app`. For an app that is already
    /// running, macOS activates it and asks it to reopen, which is when the window shows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }
}

// `ClipHistory --paste` only presses ⌘V. The workflow's "paste" trigger runs it, so the key press
// comes from a process Alfred started and is covered by Alfred's Accessibility permission.
if CommandLine.arguments.contains("--paste") {
    pressCommandV()
    exit(0)
}

// Started through LaunchServices (`open`), so macOS keeps a single copy running.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
