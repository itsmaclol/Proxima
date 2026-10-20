import AppKit
// Reports SF Symbol names used in Proxima's sources that this macOS doesn't have (they'd draw nothing).
// Usage: grep -rhoE '(systemImage|systemName|symbol): ?"[a-z0-9.]+"' Proxima | grep -oE '"[a-z0-9.]+"' | tr -d '"' | sort -u > /tmp/symbols.txt
//        swift Tools/symbolcheck.swift /tmp/symbols.txt
let names = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
var missing = 0
for name in names where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
    print("MISSING", name)
    missing += 1
}
print("checked \(names.count), missing \(missing)")
