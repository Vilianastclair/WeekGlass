import AppKit
import FlutterMacOS
import ImageIO
import Vision

enum TimetableOCR {
  private static let maxBytes = 25 * 1024 * 1024
  private enum Failure: String, Error {
    case size = "image_size", dimensions = "image_dimensions", decode = "decode_failed"
    case language = "chinese_unavailable"
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "weekglass/timetable_ocr", binaryMessenger: messenger)
    var recognizing = false
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "clipboardImage":
        let board = NSPasteboard.general
        guard let type = board.availableType(from: [.png, .tiff]),
              let bytes = board.data(forType: type) else { return result(nil) }
        guard bytes.count <= maxBytes else {
          return result(FlutterError(code: Failure.size.rawValue, message: nil, details: nil))
        }
        result(FlutterStandardTypedData(bytes: bytes))
      case "recognize":
        guard let data = (call.arguments as? FlutterStandardTypedData)?.data,
              !data.isEmpty, data.count <= maxBytes else {
          return result(FlutterError(code: Failure.size.rawValue, message: nil, details: nil))
        }
        guard !recognizing else { return result(FlutterError(code: "busy", message: nil, details: nil)) }
        recognizing = true
        DispatchQueue.global(qos: .userInitiated).async {
          let reply: Any = autoreleasepool {
            do { return try recognize(data) as Any }
            catch { return FlutterError(code: (error as? Failure)?.rawValue ?? "ocr_failed",
                                        message: nil, details: nil) as Any }
          }
          DispatchQueue.main.async { recognizing = false; result(reply) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func recognize(_ data: Data) throws -> [String: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = info[kCGImagePropertyPixelWidth] as? Int,
          let h = info[kCGImagePropertyPixelHeight] as? Int else { throw Failure.decode }
    guard w > 0, h > 0, w <= 80_000_000 / h else { throw Failure.dimensions }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), 2600)
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw Failure.decode
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let available = try request.supportedRecognitionLanguages()
    guard let chinese = available.first(where: { $0.hasPrefix("zh-Hans") }) else { throw Failure.language }
    request.recognitionLanguages = [chinese] + available.filter { $0 == "en-US" }
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let width = CGFloat(image.width), height = CGFloat(image.height)
    func word(_ text: String, _ box: CGRect) -> [String: Any] {
      return ["text": text, "x": box.minX * width, "y": (1 - box.maxY) * height,
              "width": box.width * width, "height": box.height * height]
    }
    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string
      var words: [[String: Any]] = []
      // Vision can put several columns on one line. Preserve each token's
      // position; the shared parser locates the day and period from the grid.
      for token in text.split(whereSeparator: { $0.isWhitespace }) {
        if let rect = try candidate.boundingBox(for: token.startIndex..<token.endIndex) {
          words.append(word(String(token), rect.boundingBox))
        }
      }
      if words.isEmpty { words.append(word(text, observation.boundingBox)) }
      lines.append(["text": text, "words": words])
    }
    return ["language": chinese, "width": image.width, "height": image.height, "lines": lines]
  }
}
