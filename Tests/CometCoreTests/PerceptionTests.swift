import CometCore
import CometSession
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class PerceptionTests: XCTestCase {
  private func frame(marker: UInt8 = 0, pixels: Data? = nil, width: Int = 320, height: Int = 200)
    throws -> PerceptionFrame
  {
    try PerceptionFrame(
      width: width, height: height, timestamp: 100, image: Data([marker]),
      pixels: pixels ?? Data(repeating: 0, count: width * height * 4))
  }
  private func normalize(_ detections: [ParserDetection], width: Int = 320, height: Int = 200)
    throws -> ParsedScreen
  {
    let frame = try frame(width: width, height: height)
    var normalizer = UIElementNormalizer()
    return try normalizer.normalize(
      ParserResponse(frame: frame, detections: detections), frame: frame, minimumConfidence: 0)
  }
  func testCoordinatesClickPointsAndUnknownTypes() throws {
    let parsed = try normalize([
      ParserDetection(
        type: "future_control", bbox: [0.1, 0.2, 0.4, 0.6], description: "settings gear",
        interactive: true)
    ])
    let element = try XCTUnwrap(parsed.elements.first)
    XCTAssertEqual(element.bboxPx, [32, 40, 128, 120])
    XCTAssertEqual(element.clickPoint, [80, 80])
    XCTAssertEqual(element.description, "settings gear")
    XCTAssertEqual(element.type.rawValue, "unknown")
    XCTAssertTrue(element.interactive)
    let decoded = try JSONDecoder().decode(ParsedScreen.self, from: JSONEncoder().encode(parsed))
    XCTAssertEqual(parsed, decoded)
  }
  func testDuplicateMergingPreservesOCRAndCaption() throws {
    let parsed = try normalize([
      ParserDetection(
        type: "text", bbox: [0.1, 0.2, 0.4, 0.4], text: "Save", interactive: false, confidence: 0.9),
      ParserDetection(
        type: "icon", bbox: [0.1, 0.2, 0.4, 0.4], description: "Save button", interactive: true,
        confidence: 0.8),
      ParserDetection(
        type: "text", bbox: [0.1, 0.2, 0.4, 0.4], text: "Different", interactive: false),
    ])
    XCTAssertEqual(parsed.elements.count, 2)
    XCTAssertEqual(parsed.elements[0].text, "Save")
    XCTAssertEqual(parsed.elements[0].description, "Save button")
    XCTAssertEqual(parsed.elements[0].type.rawValue, "button")
  }
  func testStableTrackingRejectsChangedSemanticsAndAmbiguousMatches() throws {
    let a = try frame()
    let b = try frame(marker: 1)
    var normalizer = UIElementNormalizer()
    let base = ParserDetection(
      type: "button", bbox: [0.1, 0.2, 0.4, 0.4], text: "Save", interactive: true)
    let first = try normalizer.normalize(
      ParserResponse(frame: a, detections: [base]), frame: a, minimumConfidence: 0)
    var moved = base
    moved.bbox = [0.105, 0.2, 0.405, 0.4]
    let second = try normalizer.normalize(
      ParserResponse(frame: b, detections: [moved]), frame: b, minimumConfidence: 0)
    XCTAssertEqual(first.elements[0].id, second.elements[0].id)
    moved.text = "Delete"
    let changed = try normalizer.normalize(
      ParserResponse(frame: b, detections: [moved]), frame: b, minimumConfidence: 0)
    XCTAssertNotEqual(second.elements[0].id, changed.elements[0].id)
    moved.bbox = [0.12, 0.2, 0.42, 0.4]
    var neighbor = moved
    neighbor.bbox = [0.08, 0.2, 0.38, 0.4]
    let ambiguous = try normalizer.normalize(
      ParserResponse(frame: b, detections: [moved, neighbor]), frame: b, minimumConfidence: 0)
    XCTAssertTrue(ambiguous.elements.allSatisfy { $0.id != changed.elements[0].id })
  }
  func testLabelAssociationAndParentsAreConservative() throws {
    let parsed = try normalize([
      ParserDetection(type: "dialog", bbox: [0, 0, 1, 1], interactive: false),
      ParserDetection(
        type: "text", bbox: [0.1, 0.1, 0.3, 0.2], text: "Username", interactive: false),
      ParserDetection(type: "textfield", bbox: [0.1, 0.25, 0.8, 0.4], interactive: true),
      ParserDetection(
        type: "text", bbox: [0.1, 0.6, 0.3, 0.7], text: "Unrelated", interactive: false),
    ])
    XCTAssertEqual(parsed.elements[2].label, "Username")
    XCTAssertEqual(parsed.elements[1].labelFor, parsed.elements[2].id)
    XCTAssertNil(parsed.elements[3].labelFor)
    XCTAssertEqual(parsed.elements[2].parentID, parsed.elements[0].id)
    XCTAssertTrue(parsed.elements[0].children!.contains(parsed.elements[2].id))
  }
  func testInvalidResponsesFailClosed() throws {
    let frame = try frame()
    for box in [[0.8, 0.1, 0.2, 0.3], [-1, 0, 1, 1], [0, 0, 1], [0, 0, Double.nan, 1]] {
      XCTAssertThrowsError(
        try ParserResponse(
          frame: frame, detections: [ParserDetection(type: "button", bbox: box, interactive: true)]
        ).validate(for: frame))
    }
    let valid = ParserResponse(frame: frame, detections: [])
    XCTAssertThrowsError(try valid.validate(for: self.frame(marker: 1)))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        ParserResponse.self, from: Data(#"{"schema_version":1,"detections":"wrong"}"#.utf8)))
    var settings = PerceptionSettings()
    settings.host = "example.com"
    XCTAssertThrowsError(try settings.validatedURL(path: "parse"))
  }
  func testCacheUsesPixelsAndRejectsSmallLocalChanges() async throws {
    let parser = FixtureUIParser()
    let store = UIPerceptionStore(parser: parser, settings: PerceptionSettings())
    let a = try frame()
    let noise = try frame(marker: 1, pixels: Data(repeating: 2, count: 320 * 200 * 4))
    let first = try await store.elements(frame: a)
    let cached = try await store.elements(frame: noise)
    XCTAssertEqual(
      first.frameID, cached.frameID, "Cached IDs still refer to the original parsed bytes")
    let hits = await parser.calls
    XCTAssertEqual(hits, 1)
    var pixels = a.pixels
    for y in 35..<45 { for x in 40..<50 { pixels[(y * 320 + x) * 4] = 255 } }
    let changed = try frame(marker: 2, pixels: pixels)
    XCTAssertFalse(FrameComparison.equivalent(a, changed, threshold: 0.01))
    do {
      _ = try await store.validate(
        frameID: first.frameID, elementID: first.elements[0].id, current: changed)
      XCTFail("Changed screen accepted")
    } catch let error as PerceptionError {
      XCTAssertEqual(error.code, "STALE_FRAME")
      XCTAssertEqual(error.currentFrameID, changed.id)
    }
    let next = try await store.elements(frame: changed)
    let misses = await parser.calls
    XCTAssertEqual(misses, 2)
    XCTAssertNotEqual(first.frameID, next.frameID)
    XCTAssertEqual(first.elements[0].id, next.elements[0].id)
    let freshStore = UIPerceptionStore(parser: parser, settings: PerceptionSettings())
    let other = try await freshStore.elements(frame: a)
    XCTAssertNotEqual(
      first.frameID, other.frameID,
      "Different parser configurations must not alias an old element namespace")
  }
  func testUnavailableParserDoesNotBecomeEmptySuccess() async throws {
    let parser = FixtureUIParser(unavailable: true)
    let store = UIPerceptionStore(parser: parser, settings: PerceptionSettings())
    do {
      _ = try await store.elements(frame: frame())
      XCTFail("Unavailable parser reported success")
    } catch let error as PerceptionError { XCTAssertEqual(error.code, "PARSER_UNAVAILABLE") }
  }
  func testServiceJSONDecodingAndMalformedBody() async throws {
    let frame = try frame()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ParserURLProtocol.self]
    let client = OmniParserClient(
      settings: PerceptionSettings(), token: "test",
      session: URLSession(configuration: configuration))
    ParserURLProtocol.payload = try JSONEncoder().encode(
      ParserResponse(frame: frame, detections: []))
    let parsed = try await client.parse(frame: frame)
    XCTAssertEqual(parsed.frameID, frame.id)
    ParserURLProtocol.payload = Data("not JSON".utf8)
    do {
      _ = try await client.parse(frame: frame)
      XCTFail("Malformed response accepted")
    } catch let error as PerceptionError { XCTAssertEqual(error.code, "INVALID_RESPONSE") }
  }
  func testInstalledLocalParserWithStaticScreenshot() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["COMET_OMNIPARSER_E2E"] == "1", let tokenPath = env["COMET_OMNIPARSER_TOKEN_FILE"]
    else {
      throw XCTSkip(
        "Set COMET_OMNIPARSER_E2E=1 and COMET_OMNIPARSER_TOKEN_FILE to test installed local models."
      )
    }
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/Perception/browser.png")
    let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(contentsOf: path) as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let jpeg = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    var pixels = Data(count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      let context = CGContext(
        data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let frame = try PerceptionFrame(
      width: image.width, height: image.height, timestamp: Date().timeIntervalSince1970,
      image: jpeg as Data, pixels: pixels)
    var settings = PerceptionSettings()
    settings.enabled = true
    settings.port = Int(env["COMET_OMNIPARSER_PORT"] ?? "9120") ?? 9120
    let client = OmniParserClient(
      settings: settings,
      token: try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines))
    let store = UIPerceptionStore(parser: client, settings: settings)
    let result = try await store.elements(frame: frame)
    XCTAssertTrue(result.elements.contains { $0.text?.isEmpty == false })
    XCTAssertTrue(result.elements.contains { $0.description?.isEmpty == false })
    let interactive = try XCTUnwrap(result.elements.first(where: \.interactive))
    _ = try await store.validate(frameID: result.frameID, elementID: interactive.id, current: frame)
    XCTAssertEqual(result.width, 960)
  }

  func testStaticScreenshotContractFixtures() async throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/Perception")
    for name in ["browser", "macos", "windows_dialog", "bios_console"] {
      let data = try Data(contentsOf: directory.appendingPathComponent(name + ".png"))
      let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      var pixels = Data(count: image.width * image.height * 4)
      pixels.withUnsafeMutableBytes { ptr in
        let context = CGContext(
          data: ptr.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      let frame = try PerceptionFrame(
        width: image.width, height: image.height, timestamp: 100, image: data, pixels: pixels)
      let detections = try JSONDecoder().decode(
        [ParserDetection].self,
        from: Data(contentsOf: directory.appendingPathComponent(name + ".json")))
      let parser = FixtureUIParser(detections: detections)
      let store = UIPerceptionStore(parser: parser, settings: PerceptionSettings())
      let parsed = try await store.elements(frame: frame)
      XCTAssertFalse(parsed.elements.isEmpty)
      XCTAssertEqual(parsed.width, image.width)
      for element in parsed.elements {
        XCTAssertTrue((0..<image.width).contains(element.clickPoint[0]))
        XCTAssertTrue((0..<image.height).contains(element.clickPoint[1]))
        _ = try await store.validate(frameID: parsed.frameID, elementID: element.id, current: frame)
      }
    }
  }
}

actor FixtureUIParser: UIParser {
  var calls = 0
  let unavailable: Bool
  let detections: [ParserDetection]
  init(
    unavailable: Bool = false,
    detections: [ParserDetection] = [
      ParserDetection(type: "button", bbox: [0.1, 0.2, 0.4, 0.4], text: "Save", interactive: true)
    ]
  ) {
    self.unavailable = unavailable
    self.detections = detections
  }
  func parse(frame: PerceptionFrame) async throws -> ParserResponse {
    calls += 1
    if unavailable { throw PerceptionError("PARSER_UNAVAILABLE", "Fixture unavailable") }
    return ParserResponse(frame: frame, detections: detections)
  }
}

private final class ParserURLProtocol: URLProtocol {
  static var payload = Data()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.payload)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
