import Foundation
import NMRCoreC
import Testing

@testable import App

/// Built-in and imported colormaps, through the C API and Colormaps.
@Suite("Colormaps")
struct ColormapsTests {
  @Test("Six originals, Iris first and the colormap setting's default")
  func builtins() throws {
    #expect(
      Colormaps.builtins.map(\.key) == [
        "iris", "chrome", "bloodmoon", "phosphor", "aurora", "glacier",
      ])
    #expect(
      Colormaps.builtins.map(\.label) == [
        "Iris", "Chrome", "Bloodmoon", "Phosphor", "Aurora", "Glacier",
      ])
    let colormap = try #require(Schema.spec(.colormap))
    #expect(Colormaps.builtins.first?.key == colormap.defaultText)
  }

  @Test("A built-in key gives its table; anything else gives Iris and says so")
  func tables() {
    let iris = Colormaps.table(for: "iris", userFolder: nil)
    #expect(iris.found)
    #expect(iris.rgba.count == Colormaps.tableSize * 4)
    #expect(Array(iris.rgba.prefix(4)) == [78, 70, 190, 255])
    #expect(Array(iris.rgba.suffix(4)) == [244, 246, 255, 255])
    let chrome = Colormaps.table(for: "chrome", userFolder: nil)
    #expect(chrome.found)
    #expect(Array(chrome.rgba.suffix(4)) == [255, 255, 255, 255])
    for key in ["", "Chrome", "user:Missing", "nope"] {
      let other = Colormaps.table(for: key, userFolder: nil)
      #expect(!other.found, "\(key)")
      #expect(other.rgba == iris.rgba, "\(key)")
    }
  }

  @Test("An imported .map is listed, found by its user key and removed")
  func importListResolveRemove() throws {
    let temporary = try TemporaryFolder()
    let folder = temporary.url.appending(path: "Colormaps")
    let source = temporary.url.appending(path: "Sunset Glow.map")
    try "[rgb(0, 0, 255); 0.5] // blue\n[rgb(300, 0, 0); 1]"
      .write(to: source, atomically: true, encoding: .utf8)

    let (file, report) = try Colormaps.importMap(source, into: folder)
    #expect(file.lastPathComponent == "Sunset Glow.map")
    #expect(report == ColormapReport(status: .ok, skipped: 0, adjusted: 1))
    #expect(Colormaps.list(in: folder).map(\.name) == ["Sunset Glow"])

    let key = Colormaps.key(forUserColormap: "Sunset Glow")
    #expect(key == "user:Sunset Glow")
    #expect(Colormaps.key(forUserColormap: "Sunset\0 Glow") == "")  // no listed name has a NUL
    let table = Colormaps.table(for: key, userFolder: folder)
    #expect(table.found)
    #expect(Array(table.rgba.prefix(4)) == [0, 0, 255, 255])  // the first stop's color before it
    #expect(Array(table.rgba.suffix(4)) == [255, 0, 0, 255])
    #expect(!Colormaps.table(for: key, userFolder: nil).found)

    try Colormaps.remove(file)
    #expect(Colormaps.list(in: folder).isEmpty)
    #expect(!Colormaps.table(for: key, userFolder: folder).found)
    #expect(throws: POSIXError(.ENOENT)) { try Colormaps.remove(file) }
  }

  @Test("Unreadable files, files without stops and unwritable folders import nothing")
  func importFailures() throws {
    let temporary = try TemporaryFolder()
    let folder = temporary.url.appending(path: "Colormaps")
    let fine = temporary.url.appending(path: "Fine.map")
    try "[rgb(1, 2, 3); 0.5]".write(to: fine, atomically: true, encoding: .utf8)
    let empty = temporary.url.appending(path: "Empty.map")
    try "nothing here [rgb(1, 2); 0.5]".write(to: empty, atomically: true, encoding: .utf8)
    #expect(
      throws: ColormapImportError.notAColormap(
        ColormapReport(status: .noStops, skipped: 1, adjusted: 0))
    ) { try Colormaps.importMap(empty, into: folder) }
    #expect(throws: ColormapImportError.unreadable) {
      try Colormaps.importMap(temporary.url.appending(path: "Missing.map"), into: folder)
    }
    let web = try #require(URL(string: "https://example.com\(fine.path())"))
    #expect(throws: ColormapImportError.unreadable) {  // not a file URL
      try Colormaps.importMap(web, into: folder)
    }
    #expect(!FileManager.default.fileExists(atPath: folder.cPath))

    let file = temporary.url.appending(path: "file")
    try "".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: ColormapImportError.notWritten(POSIXError(.ENOTDIR))) {
      try Colormaps.importMap(fine, into: file.appending(path: "Colormaps"))
    }
  }

  @Test("The colormap C calls refuse missing arguments and relative paths")
  func cEdges() throws {
    let count = nmr_colormaps_builtin_count()
    #expect(nmr_colormaps_builtin_key(count) == nil)
    #expect(nmr_colormaps_builtin_label(count) == nil)
    #expect(!nmr_colormaps_table("iris", nil, nil))
    var rgba = [UInt8](repeating: 0, count: Colormaps.tableSize * 4)
    let found = rgba.withUnsafeMutableBufferPointer { table in
      nmr_colormaps_table(nil, nil, table.baseAddress)
    }
    #expect(!found)
    #expect(rgba == Colormaps.table(for: "iris", userFolder: nil).rgba)
    #expect(nmr_colormaps_user_key(nil) == nil)
    #expect(UserFile.adopt(nmr_colormaps_list("relative")).isEmpty)

    var report = nmr_colormap_report()
    var error: Int32 = 0
    #expect(nmr_colormaps_import("relative", "/nonexistent-nmr.map", &report, &error) == nil)
    #expect(error == EINVAL)
    #expect(report.status == NMR_COLORMAP_OK)
    #expect(nmr_colormaps_import("/nonexistent-nmr", "relative.map", &report, &error) == nil)
    #expect(error == EINVAL)
    #expect(nmr_colormaps_import(nil, nil, nil, nil) == nil)
    #expect(!nmr_colormaps_remove("relative.map", &error))
    #expect(error == EINVAL)
    #expect(Colormaps.directory?.cPath.hasSuffix("/Colormaps/") == true)
  }

  @Test("The C calls say why through the report and errno, and give errno 0 on success")
  func cErrors() throws {
    let temporary = try TemporaryFolder()
    let folder = temporary.url.appending(path: "Colormaps").cPath
    let fine = temporary.url.appending(path: "Fine.map")
    try "[rgb(1, 2, 3); 0.5]".write(to: fine, atomically: true, encoding: .utf8)
    let empty = temporary.url.appending(path: "Empty.map")
    try "no stops".write(to: empty, atomically: true, encoding: .utf8)
    let file = temporary.url.appending(path: "file")
    try "".write(to: file, atomically: true, encoding: .utf8)
    var report = nmr_colormap_report()
    var error: Int32 = -1

    #expect(nmr_colormaps_import(folder, empty.cPath, &report, &error) == nil)
    #expect(report.status == NMR_COLORMAP_NO_STOPS)
    #expect(error == EFTYPE)
    let large = temporary.url.appending(path: "Large.map")
    try String(repeating: " ", count: 64 * 1024 + 1).write(
      to: large, atomically: true, encoding: .utf8)
    #expect(nmr_colormaps_import(folder, large.cPath, &report, &error) == nil)
    #expect(report.status == NMR_COLORMAP_TOO_LARGE)
    #expect(error == EFBIG)
    let missing = temporary.url.appending(path: "Missing.map").cPath
    #expect(nmr_colormaps_import(folder, missing, nil, &error) == nil)  // no report: errno says why
    #expect(error == EIO)
    let below = file.appending(path: "Colormaps").cPath
    #expect(nmr_colormaps_import(below, fine.cPath, &report, &error) == nil)
    #expect(report.status == NMR_COLORMAP_OK)
    #expect(error == ENOTDIR)

    error = -1
    let imported = try #require(
      takenString(nmr_colormaps_import(folder, fine.cPath, &report, &error)))
    #expect(error == 0)
    error = -1
    #expect(nmr_colormaps_remove(imported, &error))
    #expect(error == 0)
    #expect(!nmr_colormaps_remove(imported, &error))
    #expect(error == ENOENT)
    #expect(!nmr_colormaps_remove(file.cPath, &error))  // not a colormap file: left alone
    #expect(error == EINVAL)
    #expect(FileManager.default.fileExists(atPath: file.cPath))
  }
}
