// Entry point.
//
//   --version                              print the version and exit
//   --tap-probe [seconds] [--out file]     capture the system output, write a JSON report, exit
//   --meter-probe [seconds] [--out file] [--instance name]
//                                          run the meter on the system output (or the plugin
//                                          instance of that name), report, exit
//   --feed <file.wav>                      play the file in a loop instead of the system output
//                                          (reproducible input; with --meter-probe too)
//
// Without options the app shows the meter window.
import AppKit
import NMRCoreC

let arguments = Arguments(CommandLine.arguments)

/// The seconds given after `option`, or exits with status 64 and a message when they are invalid.
func probeSeconds(_ option: String, default fallback: Double) -> Double {
  switch arguments.seconds(after: option, default: fallback) {
  case .success(let seconds):
    return seconds
  case .failure(.invalid(let text)):
    let range = Arguments.probeSeconds
    let message = "\(option): '\(text)' is not a number of seconds from "
      + "\(Int(range.lowerBound)) to \(Int(range.upperBound))\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(64)
  }
}

/// The value given with `option` (nil when it is absent), or exits with status 64 when it is
/// there without one.
func optionValue(_ option: String) -> String? {
  switch arguments.option(option) {
  case .success(let value):
    return value
  case .failure(.missingValue(let name)):
    FileHandle.standardError.write(Data("\(name) needs a value\n".utf8))
    exit(64)
  }
}

if arguments.contains("--version") {
  print(String(cString: nmr_version()))
  exit(0)
}

if arguments.contains("--tap-probe") {
  let seconds = probeSeconds("--tap-probe", default: TapProbe.defaultSeconds)
  exit(TapProbe.run(seconds: seconds, outputPath: optionValue("--out")))
}

/// `--feed <file.wav>`, relative to the working directory.
let feed = optionValue("--feed").map { path in
  URL(filePath: path, relativeTo: URL(filePath: FileManager.default.currentDirectoryPath + "/"))
    .absoluteURL.standardized
}
let instance = optionValue("--instance")
let probe = arguments.contains("--meter-probe")
  ? MeterProbe(
    seconds: probeSeconds("--meter-probe", default: MeterProbe.defaultSeconds),
    outputPath: optionValue("--out"),
    source: instance.map(MeterProbe.Source.instance) ?? (feed != nil ? .file : nil))
  : nil
let delegate = AppDelegate(probe: probe, feed: feed)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
