import Foundation
import NaturalLanguage

private enum TokenUnit: String, Hashable {
  case word
  case sentence
}

private struct TokenizationRequest: Decodable {
  let requestID: Int
  let sourceText: String
  let tokenUnit: String
  let languageCode: String

  private enum CodingKeys: String, CodingKey {
    case requestID = "id"
    case sourceText = "text"
    case tokenUnit = "unit"
    case languageCode = "language"
  }
}

private struct TokenSpan {
  let startByte: Int
  let endByte: Int
  let tokenizerAttributes: NLTokenizer.Attributes
}

private struct EncodedToken: Encodable {
  let startByte: Int
  let endByte: Int
  let rawAttributes: Int
  let isNumeric: Bool
  let isSymbolic: Bool
  let isEmoji: Bool

  init(span: TokenSpan) {
    startByte = span.startByte
    endByte = span.endByte
    rawAttributes = Int(span.tokenizerAttributes.rawValue)
    isNumeric = span.tokenizerAttributes.contains(.numeric)
    isSymbolic = span.tokenizerAttributes.contains(.symbolic)
    isEmoji = span.tokenizerAttributes.contains(.emoji)
  }

  private enum CodingKeys: String, CodingKey {
    case startByte = "start"
    case endByte = "end"
    case rawAttributes = "attributes"
    case isNumeric = "numeric"
    case isSymbolic = "symbolic"
    case isEmoji = "emoji"
  }
}

private struct TokenizationResponse: Encodable {
  let requestID: Int
  let encodedTokens: [EncodedToken]
  let errorMessage: String?

  private enum CodingKeys: String, CodingKey {
    case requestID = "id"
    case encodedTokens = "tokens"
    case errorMessage = "error"
  }
}

@MainActor
private enum HelperState {
  static var tokenizers: [TokenUnit: (languageCode: String, tokenizer: NLTokenizer)] = [:]
}

private func utf8Offset(of index: String.Index, in text: String) -> Int? {
  guard let utf8Index = index.samePosition(in: text.utf8) else {
    return nil
  }
  return text.utf8.distance(from: text.utf8.startIndex, to: utf8Index)
}

private func utf8Segment(in text: String, startByte: Int, endByte: Int) -> String? {
  guard startByte >= 0, startByte <= endByte, endByte <= text.utf8.count else {
    return nil
  }
  let utf8View = text.utf8
  let startIndex = utf8View.index(utf8View.startIndex, offsetBy: startByte)
  let endIndex = utf8View.index(utf8View.startIndex, offsetBy: endByte)
  return String(bytes: utf8View[startIndex..<endIndex], encoding: .utf8)
}

@MainActor
private func tokenizer(for unit: TokenUnit, languageCode: String) -> NLTokenizer {
  if let cached = HelperState.tokenizers[unit], cached.languageCode == languageCode {
    return cached.tokenizer
  }

  let tokenizer = NLTokenizer(unit: unit == .word ? .word : .sentence)
  if languageCode != "auto" {
    tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
  }
  HelperState.tokenizers[unit] = (languageCode: languageCode, tokenizer: tokenizer)
  return tokenizer
}

private func fallbackAttributes(for character: Character) -> NLTokenizer.Attributes {
  var attributes: NLTokenizer.Attributes = []
  let unicodeScalars = character.unicodeScalars
  if unicodeScalars.contains(where: { $0.properties.numericType != nil }) {
    attributes.insert(.numeric)
  }
  if unicodeScalars.contains(where: {
    CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
  }) {
    attributes.insert(.symbolic)
  }
  if unicodeScalars.contains(where: { $0.properties.isEmoji }) {
    attributes.insert(.emoji)
  }
  return attributes
}

private func fallbackTokens(in text: String, startByte: Int, endByte: Int) -> [TokenSpan] {
  guard startByte < endByte,
    let segment = utf8Segment(in: text, startByte: startByte, endByte: endByte)
  else {
    return []
  }

  var fallbackSpans: [TokenSpan] = []
  var runStartByte: Int?
  var currentByte = startByte

  func flushWordRun() {
    if let runStartByte, runStartByte < currentByte {
      fallbackSpans.append(
        TokenSpan(startByte: runStartByte, endByte: currentByte, tokenizerAttributes: [])
      )
    }
  }

  for character in segment {
    let characterLength = character.utf8.count
    let isWhitespace = character.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    let attributes = fallbackAttributes(for: character)
    if isWhitespace {
      flushWordRun()
      runStartByte = nil
    } else if !attributes.isEmpty {
      flushWordRun()
      runStartByte = nil
      fallbackSpans.append(
        TokenSpan(
          startByte: currentByte,
          endByte: currentByte + characterLength,
          tokenizerAttributes: attributes
        )
      )
    } else if runStartByte == nil {
      runStartByte = currentByte
    }
    currentByte += characterLength
  }

  flushWordRun()
  return fallbackSpans
}

private func trimmedRange(
  in text: String,
  startByte: Int,
  endByte: Int
) -> (startByte: Int, endByte: Int)? {
  guard startByte < endByte,
    let segment = utf8Segment(in: text, startByte: startByte, endByte: endByte)
  else {
    return nil
  }
  var leadingByteCount = 0
  for scalar in segment.unicodeScalars {
    guard scalar.properties.isWhitespace else { break }
    leadingByteCount += scalar.utf8.count
  }
  var trailingByteCount = 0
  for scalar in segment.unicodeScalars.reversed() {
    guard scalar.properties.isWhitespace else { break }
    trailingByteCount += scalar.utf8.count
  }
  let trimmedStartByte = startByte + leadingByteCount
  let trimmedEndByte = endByte - trailingByteCount
  return trimmedStartByte < trimmedEndByte
    ? (trimmedStartByte, trimmedEndByte)
    : nil
}

@MainActor
private func enumerateAppleSpans(in text: String, using tokenizer: NLTokenizer) -> [TokenSpan]? {
  tokenizer.string = text
  var appleSpans: [TokenSpan] = []
  var hasValidByteRanges = true
  tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, attributes in
    guard let startByte = utf8Offset(of: range.lowerBound, in: text),
      let endByte = utf8Offset(of: range.upperBound, in: text)
    else {
      hasValidByteRanges = false
      return false
    }
    if let trimmed = trimmedRange(in: text, startByte: startByte, endByte: endByte) {
      appleSpans.append(
        TokenSpan(
          startByte: trimmed.startByte,
          endByte: trimmed.endByte,
          tokenizerAttributes: attributes
        )
      )
    } else if startByte < endByte {
      appleSpans.append(
        TokenSpan(startByte: startByte, endByte: endByte, tokenizerAttributes: attributes)
      )
    }
    return true
  }
  guard hasValidByteRanges else { return nil }
  appleSpans.sort { $0.startByte < $1.startByte }
  return appleSpans
}

private func mergeTokenSpans(
  in text: String,
  unit: TokenUnit,
  appleSpans: [TokenSpan]
) -> [TokenSpan] {
  var tokenSpans: [TokenSpan] = []
  var cursorByte = 0

  for appleSpan in appleSpans {
    if appleSpan.startByte > cursorByte, unit == .word {
      tokenSpans.append(
        contentsOf: fallbackTokens(in: text, startByte: cursorByte, endByte: appleSpan.startByte))
    }
    let actualStartByte = max(appleSpan.startByte, cursorByte)
    if actualStartByte < appleSpan.endByte {
      tokenSpans.append(
        TokenSpan(
          startByte: actualStartByte,
          endByte: appleSpan.endByte,
          tokenizerAttributes: appleSpan.tokenizerAttributes
        )
      )
      cursorByte = appleSpan.endByte
    }
  }

  if cursorByte < text.utf8.count, unit == .word {
    tokenSpans.append(
      contentsOf: fallbackTokens(in: text, startByte: cursorByte, endByte: text.utf8.count))
  }
  if unit == .sentence, tokenSpans.isEmpty {
    let fallbackSpans = fallbackTokens(in: text, startByte: 0, endByte: text.utf8.count)
    if let firstSpan = fallbackSpans.first, let lastSpan = fallbackSpans.last {
      return [
        TokenSpan(
          startByte: firstSpan.startByte,
          endByte: lastSpan.endByte,
          tokenizerAttributes: []
        )
      ]
    }
  }
  return tokenSpans
}

@MainActor
private func tokenize(
  _ text: String,
  unit: TokenUnit,
  languageCode: String
) -> [TokenSpan]? {
  guard !text.isEmpty else { return [] }
  let tokenizer = tokenizer(for: unit, languageCode: languageCode)
  guard let appleSpans = enumerateAppleSpans(in: text, using: tokenizer) else {
    return nil
  }
  return mergeTokenSpans(in: text, unit: unit, appleSpans: appleSpans)
}

private func writeDiagnostic(_ message: String) {
  let data = Data((message + "\n").utf8)
  FileHandle.standardError.write(data)
}

private func writeResponse(
  requestID: Int,
  tokenSpans: [TokenSpan] = [],
  errorMessage: String? = nil
) {
  let response = TokenizationResponse(
    requestID: requestID,
    encodedTokens: tokenSpans.map(EncodedToken.init(span:)),
    errorMessage: errorMessage
  )
  do {
    let data = try JSONEncoder().encode(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  } catch {
    writeDiagnostic("failed to encode response: \(error)")
  }
}

@MainActor
private func processRequest(_ line: String, decoder: JSONDecoder) {
  autoreleasepool {
    guard let data = line.data(using: .utf8) else {
      writeDiagnostic("request is not UTF-8")
      return
    }

    do {
      let request = try decoder.decode(TokenizationRequest.self, from: data)
      guard let unit = TokenUnit(rawValue: request.tokenUnit) else {
        writeResponse(
          requestID: request.requestID,
          errorMessage: "unknown unit: \(request.tokenUnit)"
        )
        return
      }
      guard request.languageCode == "auto" || !request.languageCode.isEmpty else {
        writeResponse(requestID: request.requestID, errorMessage: "invalid language")
        return
      }
      guard
        let tokenSpans = tokenize(
          request.sourceText,
          unit: unit,
          languageCode: request.languageCode
        )
      else {
        writeResponse(requestID: request.requestID, errorMessage: "tokenization failed")
        return
      }
      writeResponse(requestID: request.requestID, tokenSpans: tokenSpans)
    } catch {
      writeDiagnostic("invalid request: \(error)")
    }
  }
}

@MainActor
private func runHelper() {
  let decoder = JSONDecoder()
  _ = tokenize("日本語のwarmup", unit: .word, languageCode: "auto")
  _ = tokenize("日本語のwarmup。", unit: .sentence, languageCode: "auto")
  while let line = readLine() {
    processRequest(line, decoder: decoder)
  }
}

runHelper()
