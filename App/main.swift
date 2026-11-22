// Entry point.
//
//   --version                              print the version and exit
//   --tap-probe [seconds] [--out file]     capture the system output, write a JSON report, exit
//   --meter-probe [seconds] [--out file]   run the meter on the system output, report, exit
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

if arguments.contains("--version") {
  print(String(cString: nmr_version()))
  exit(0)
}

if arguments.contains("--tap-probe") {
  let seconds = probeSeconds("--tap-probe", default: TapProbe.defaultSeconds)
  exit(TapProbe.run(seconds: seconds, outputPath: arguments.value(after: "--out")))
}

let probe = arguments.contains("--meter-probe")
  ? MeterProbe(
    seconds: probeSeconds("--meter-probe", default: MeterProbe.defaultSeconds),
    outputPath: arguments.value(after: "--out"))
  : nil
let delegate = AppDelegate(probe: probe)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
