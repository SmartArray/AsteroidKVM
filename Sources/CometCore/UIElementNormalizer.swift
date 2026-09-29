import Foundation

// Conservative geometry and semantic matching. Raw detector metadata stays internal to the parser response.
public struct UIElementNormalizer: Sendable {
  private var previous: [UIElement] = []
  private var nextID = 1
  private var dimensions: [Int] = []
  public init() {}
  public mutating func reset() {
    previous = []
    dimensions = []
  }

  private func rect(_ box: [Int]) -> CGRect {
    CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
  }
  private func overlap(_ a: UIElement, _ b: UIElement) -> Double {
    let x = rect(a.bboxPx)
    let y = rect(b.bboxPx)
    let intersection = x.intersection(y)
    let area = intersection.isNull ? 0 : intersection.width * intersection.height
    return area / max(1, x.width * x.height + y.width * y.height - area)
  }
  private func semantics(_ item: UIElement) -> String {
    [item.text, item.description].compactMap {
      $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }.joined(separator: "|")
  }
  public mutating func normalize(
    _ response: ParserResponse, frame: PerceptionFrame, minimumConfidence: Double
  ) throws -> ParsedScreen {
    try response.validate(for: frame)
    if dimensions != [frame.width, frame.height] {
      reset()
      dimensions = [frame.width, frame.height]
    }
    var elements: [UIElement] = []
    for detection in response.detections {
      if let confidence = detection.confidence, confidence < minimumConfidence { continue }
      let bbox = [
        Int(floor(detection.bbox[0] * Double(frame.width))),
        Int(floor(detection.bbox[1] * Double(frame.height))),
        Int(ceil(detection.bbox[2] * Double(frame.width))),
        Int(ceil(detection.bbox[3] * Double(frame.height))),
      ]
      let type = UIElementType.supported.contains(detection.type) ? detection.type : "unknown"
      var item = UIElement(
        id: 0, type: UIElementType(rawValue: type), text: detection.text,
        description: detection.description,
        bboxPx: bbox, bboxNorm: detection.bbox,
        clickPoint: [
          min(frame.width - 1, (bbox[0] + bbox[2]) / 2),
          min(frame.height - 1, (bbox[1] + bbox[3]) / 2),
        ],
        interactive: detection.interactive, confidence: detection.confidence)
      // Captions are evidence, not a reason to infer all icons are buttons or all wide boxes are fields.
      if item.type.rawValue == "icon", item.interactive {
        let caption = (item.description ?? "").lowercased()
        if caption.contains("text field") || caption.contains("search field")
          || caption.contains("input field") || caption.contains("search bar")
          || caption.contains("text box") || caption.contains("input box")
        {
          item.type = UIElementType(rawValue: "textfield")
        } else if caption.contains("text area") {
          item.type = UIElementType(rawValue: "textarea")
        } else if caption.contains("radio button") {
          item.type = UIElementType(rawValue: "radio")
        } else if caption.contains("toggle switch") {
          item.type = UIElementType(rawValue: "toggle")
        } else if caption.contains("checkbox") || caption.contains("check box") {
          item.type = UIElementType(rawValue: "checkbox")
        } else if caption.contains("dropdown") || caption.contains("drop-down")
          || caption.contains("drop down")
        {
          item.type = UIElementType(rawValue: "dropdown")
        } else if caption.contains("scrollbar") {
          item.type = UIElementType(rawValue: "scrollbar")
        } else if caption.hasSuffix(" slider") {
          item.type = UIElementType(rawValue: "slider")
        } else if caption.hasSuffix(" link") {
          item.type = UIElementType(rawValue: "link")
        } else if caption.hasSuffix(" button") {
          item.type = UIElementType(rawValue: "button")
        }
      }
      // Merge near-identical detections only when their semantics agree or supply complementary OCR/caption data.
      if let index = elements.firstIndex(where: {
        overlap($0, item) >= 0.85
          && ($0.type == item.type || $0.type.rawValue == "text" || item.type.rawValue == "text")
          && ($0.text == nil || item.text == nil || $0.text == item.text)
          && ($0.description == nil || item.description == nil
            || $0.description == item.description)
      }) {
        elements[index].text = elements[index].text ?? item.text
        elements[index].description = elements[index].description ?? item.description
        if item.interactive {
          elements[index].type = item.type
          elements[index].interactive = true
        }
        elements[index].confidence = [elements[index].confidence, item.confidence].compactMap { $0 }
          .max()
      } else {
        elements.append(item)
      }
    }
    // Match uniquely in both directions. Ambiguous repeated icons get new IDs rather than unsafe continuity.
    let matches: [[Int]] = elements.map { item in
      previous.indices.filter { index in
        let old = previous[index]
        return item.type == old.type && item.interactive == old.interactive
          && semantics(item) == semantics(old)
          && overlap(item, old) >= (semantics(item).isEmpty ? 0.95 : 0.75)
      }
    }
    for index in elements.indices {
      if matches[index].count == 1, let match = matches[index].first,
        matches.filter({ $0.contains(match) }).count == 1
      {
        elements[index].id = previous[match].id
      } else {
        elements[index].id = nextID
        nextID += 1
      }
    }
    let controlTypes = Set([
      "textfield", "textarea", "checkbox", "radio", "toggle", "dropdown", "slider",
    ])
    for index in elements.indices
    where elements[index].interactive && controlTypes.contains(elements[index].type.rawValue) {
      let box = rect(elements[index].bboxPx)
      let candidates = elements.indices.filter { label in
        guard label != index, elements[label].type.rawValue == "text",
          let text = elements[label].text, !text.isEmpty
        else { return false }
        let other = rect(elements[label].bboxPx)
        let left =
          other.maxX <= box.minX && box.minX - other.maxX <= 32
          && abs(other.midY - box.midY) <= min(16, box.height / 2)
        let above =
          other.maxY <= box.minY && box.minY - other.maxY <= 24 && abs(other.minX - box.minX) <= 16
        let right =
          ["checkbox", "radio", "toggle"].contains(elements[index].type.rawValue)
          && other.minX >= box.maxX && other.minX - box.maxX <= 32
          && abs(other.midY - box.midY) <= 16
        return left || above || right
      }
      if candidates.count == 1, let label = candidates.first, elements[label].labelFor == nil {
        // A competing nearby control makes this label association ambiguous.
        let otherControls = elements.indices.filter { other in
          guard other != index, elements[other].interactive,
            controlTypes.contains(elements[other].type.rawValue)
          else { return false }
          let otherBox = rect(elements[other].bboxPx)
          let labelBox = rect(elements[label].bboxPx)
          return abs(otherBox.midX - labelBox.midX) < abs(box.midX - labelBox.midX) + 4
            && abs(otherBox.midY - labelBox.midY) < abs(box.midY - labelBox.midY) + 4
        }
        if otherControls.isEmpty {
          elements[index].label = elements[label].text
          elements[label].labelFor = elements[index].id
        }
      }
    }
    let containers = Set(["window", "dialog", "toolbar", "menu", "list", "card"])
    for index in elements.indices {
      let child = rect(elements[index].bboxPx)
      let parents = elements.indices.filter { parent in
        let box = rect(elements[parent].bboxPx)
        return parent != index && containers.contains(elements[parent].type.rawValue)
          && box.contains(child) && box.width * box.height > child.width * child.height * 1.2
      }.sorted {
        rect(elements[$0].bboxPx).width * rect(elements[$0].bboxPx).height < rect(
          elements[$1].bboxPx
        ).width * rect(elements[$1].bboxPx).height
      }
      if let parent = parents.first {
        elements[index].parentID = elements[parent].id
        elements[parent].children = (elements[parent].children ?? []) + [elements[index].id]
      }
    }
    previous = elements
    return ParsedScreen(frame: frame, elements: elements)
  }
}
