// idl-actool <catalog.xcassets> <output-dir> <deployment-target>
//
// Writes <output-dir>/Assets.car, any loose app-icon PNGs, and
// <output-dir>/assetcatalog_generated_info.json holding the Info.plist keys
// to merge (empty object when the catalog has no app icon). Exit status is
// non-zero with a message on stderr on failure.
import AssetKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("idl-actool: \(message)\n".utf8))
    exit(1)
}

/// JSON for the plist-shaped values AssetKit produces.
func json(_ value: Any) -> String {
    switch value {
    case let s as String:
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    case let b as Bool: return b ? "true" : "false"
    case let i as Int: return String(i)
    case let d as Double: return String(d)
    case let a as [any Sendable]: return "[" + a.map { json($0) }.joined(separator: ",") + "]"
    case let a as [Any]: return "[" + a.map { json($0) }.joined(separator: ",") + "]"
    case let d as [String: any Sendable]:
        return "{" + d.keys.sorted().map { json($0) + ":" + json(d[$0]!) }.joined(separator: ",") + "}"
    case let d as [String: Any]:
        return "{" + d.keys.sorted().map { json($0) + ":" + json(d[$0]!) }.joined(separator: ",") + "}"
    default:
        fail("unsupported Info.plist value type \(type(of: value))")
    }
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fail("usage: idl-actool <catalog.xcassets> <output-dir> <deployment-target>")
}
let catalog = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let result = try await XCAssetCompiler(deploymentTarget: args[3]).compile(catalog: catalog)
    try result.carData.write(to: outDir.appendingPathComponent("Assets.car"))
    var additions: [String: any Sendable] = [:]
    if let icon = result.appIconBundle {
        additions = icon.infoPlistAdditions
        for file in icon.looseFiles {
            try file.data.write(to: outDir.appendingPathComponent(file.name))
        }
    }
    try Data(json(additions).utf8).write(to: outDir.appendingPathComponent("assetcatalog_generated_info.json"))
} catch {
    fail("\(catalog.lastPathComponent): \(error)")
}
