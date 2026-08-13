import Carbon
import Foundation

func sourceID(_ source: TISInputSource) -> String? {
  guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
  return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
}

if CommandLine.arguments.count == 1 {
  guard let identifier = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) else {
    fputs("could not read the current input source\n", stderr)
    exit(1)
  }
  print(identifier)
  exit(0)
}

guard CommandLine.arguments.count == 2 else {
  fputs("usage: input_source.swift [INPUT_SOURCE_ID]\n", stderr)
  exit(2)
}

let wanted = CommandLine.arguments[1]
let matches = TISCreateInputSourceList(
  [kTISPropertyInputSourceID: wanted] as CFDictionary,
  false
).takeRetainedValue() as? [TISInputSource]

guard let source = matches?.first, TISSelectInputSource(source) == noErr else {
  fputs("could not select input source: \(wanted)\n", stderr)
  exit(1)
}
