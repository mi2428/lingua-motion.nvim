import ApplicationServices
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 7,
  let pid = Int32(CommandLine.arguments[1]),
  let x = Double(CommandLine.arguments[3]),
  let y = Double(CommandLine.arguments[4]),
  let width = Double(CommandLine.arguments[5]),
  let height = Double(CommandLine.arguments[6])
else {
  fputs("usage: place_window.swift PID TITLE X Y WIDTH HEIGHT\n", stderr)
  exit(2)
}

let title = CommandLine.arguments[2]

let application = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
guard
  AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
  let windows = value as? [AXUIElement],
  let window = windows.first(where: { window in
    var titleValue: CFTypeRef?
    return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success
      && titleValue as? String == title
  })
else {
  fputs("could not find the titled Ghostty window\n", stderr)
  exit(1)
}

var position = CGPoint(x: x, y: y)
var size = CGSize(width: width, height: height)
guard let positionValue = AXValueCreate(.cgPoint, &position),
  let sizeValue = AXValueCreate(.cgSize, &size),
  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
else {
  fputs("could not position the Ghostty window\n", stderr)
  exit(1)
}

AXUIElementPerformAction(window, kAXRaiseAction as CFString)
