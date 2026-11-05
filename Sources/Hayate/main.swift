import Cocoa
import InputMethodKit
import HayateCore
import os

/// Diagnostics: events only — never typed text or key codes.
/// `log stream --predicate 'subsystem == "dev.hayate.inputmethod.Hayate"'`
let log = Logger(subsystem: "dev.hayate.inputmethod.Hayate", category: "ime")
log.notice("started")

/// Opt-in troubleshooting (input menu). When on, context and candidates are logged at *debug*
/// level, which macOS keeps in memory only (nothing to erase later); watch with
/// `log stream --level debug --predicate 'subsystem == "dev.hayate.inputmethod.Hayate"'`.
/// Not persisted: every restart turns it off, so it can't be forgotten on.
var debugMode = false
UserDefaults.standard.removeObject(forKey: "debugMode")  // drop the old persisted flag
let app = NSApplication.shared  // before any AppKit object
let res = Bundle.main.resourceURL!
let server = IMKServer(name: Bundle.main.infoDictionary!["InputMethodConnectionName"] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
let candidateWindow = CandidateWindow()
let engine = Engine(
    dictionaryURL: res.appendingPathComponent("Dictionary", isDirectory: true),
    zenzURL: res.appendingPathComponent("zenz.gguf"),
    memoryDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hayate"),
    emojiURL: res.appendingPathComponent("emoji.txt")
)
var warmup = ComposingText()  // load dictionary + model now, not on the first Space
warmup.insertAtCursorPosition("あ", inputStyle: .direct)
engine.prefetch(warmup, left: "")
engine.endComposition()
app.run()
