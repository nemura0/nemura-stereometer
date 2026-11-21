// Entry point.
//
//   --version                              print the version and exit
//   --tap-probe [seconds] [--out file]     capture the system output, write a JSON report, exit
//
// Without options the app shows the meter window.
import AppKit
import NMRCoreC

let arguments = Arguments(CommandLine.arguments)

if arguments.contains("--version") {
  print(String(cString: nmr_version()))
  exit(0)
}

if arguments.contains("--tap-probe") {
  let seconds = arguments.double(after: "--tap-probe") ?? TapProbe.defaultSeconds
  exit(TapProbe.run(seconds: seconds, outputPath: arguments.value(after: "--out")))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
