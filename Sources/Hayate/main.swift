import Cocoa
import InputMethodKit
import HayateCore
import os

/// Diagnostics only — never log typed text or key codes.  `log stream --predicate 'subsystem == "dev.hayate.inputmethod.Hayate"'`
let log = Logger(subsystem: "dev.hayate.inputmethod.Hayate", category: "ime")
log.notice("started")
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
