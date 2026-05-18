import Foundation
import Testing

@Suite("Public API Collapse")
struct PublicAPICollapseTests {
    @Test("Package exposes only the Conduit library product")
    func packageExposesOnlyConduitLibraryProduct() throws {
        let package = try String(contentsOfFile: "Package.swift", encoding: .utf8)
        let legacyModuleName = ["Conduit", "Advanced"].joined()

        #expect(package.contains(#"name: "Conduit""#))
        #expect(!package.contains(#"name: "\#(legacyModuleName)""#))
        #expect(!package.contains(#""\#(legacyModuleName)""#))
    }

    @Test("Public docs do not teach legacy advanced imports")
    func publicDocsDoNotTeachLegacyAdvancedImports() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let legacyModuleName = ["Conduit", "Advanced"].joined()
        let publicDocRoots = [
            root.appendingPathComponent("README.md"),
            root.appendingPathComponent("Sources/Conduit/Documentation.docc")
        ]

        for file in try markdownFiles(in: publicDocRoots) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            #expect(!contents.contains(legacyModuleName), "Unexpected legacy advanced module mention in \(file.path)")
        }
    }

    private func markdownFiles(in roots: [URL]) throws -> [URL] {
        var files: [URL] = []
        let manager = FileManager.default

        for root in roots {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                guard let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for case let url as URL in enumerator where url.pathExtension == "md" {
                    files.append(url)
                }
            } else if root.pathExtension == "md" {
                files.append(root)
            }
        }

        return files
    }
}
