import CoreGraphics
import Foundation
import VibeApplication

/// Turns what a generator drew into sprites (#41): a sheet cut along its grid, or one image drawn
/// again, each with its background removed, checked, framed and written again as a PNG.
enum SpriteSheetProcessor {
  /// How far a sheet's proportions may stray from its grid's.
  static let gridTolerance = 0.1
  /// The smallest cell a sheet may have, in pixels.
  static let minimumCell = 256
  /// Space left around the characters in their sprites, as a share of the framing's side.
  static let margin = 0.06
  /// An opaque pixel, for the measures.
  static let opaque: UInt8 = 128

  /// The sprites of a sheet drawn on the grid of `expressions`.
  static func sprites(fromSheet data: Data, expressions: [AvatarExpression]) throws
    -> [AvatarExpression: Data]
  {
    let sheet = try ImageCodec.decode(data)
    let grid = SpriteSheetGrid.forExpressions(expressions.count)
    let expected = Double(grid.columns) / Double(grid.rows)
    let found = Double(sheet.width) / Double(sheet.height)
    guard abs(found - expected) <= expected * gridTolerance else {
      throw AvatarProblem.wrongGrid(
        expectedColumns: grid.columns, expectedRows: grid.rows, width: sheet.width,
        height: sheet.height)
    }
    let cellWidth = sheet.width / grid.columns
    let cellHeight = sheet.height / grid.rows
    guard cellWidth >= minimumCell, cellHeight >= minimumCell else {
      throw AvatarProblem.cellTooSmall
    }
    // Already transparent — a generator may remove the background itself — it is kept as it is.
    // Otherwise keyed as a whole when its border is flat: every cell loses the same colour.
    let keyedSheet: RGBAImage?
    if BackgroundRemoval.transparentShare(ofBorderOf: sheet)
      >= BackgroundRemoval.transparentBorderShare
    {
      keyedSheet = sheet
    } else {
      keyedSheet = BackgroundRemoval.flatBorderColour(of: sheet).map {
        BackgroundRemoval.keyed(sheet, background: $0)
      }
    }
    var cells: [(AvatarExpression, RGBAImage, SpriteCellMeasurement)] = []
    for (index, expression) in expressions.enumerated() {
      let x = (index % grid.columns) * cellWidth
      let y = (index / grid.columns) * cellHeight
      let cell: RGBAImage
      if let keyedSheet {
        cell = keyedSheet.cropped(x: x, y: y, width: cellWidth, height: cellHeight)
      } else {
        cell = try removingBackground(
          sheet.cropped(x: x, y: y, width: cellWidth, height: cellHeight), as: expression)
      }
      cells.append((expression, cell, measure(cell)))
    }
    try SpriteSetValidation.validate(cells.map { ($0.0, $0.2) })
    // One framing for all: the character does not jump from one sprite to the next.
    let boxes = cells.compactMap(\.2.content)
    let union = boxes.dropFirst().reduce(boxes[0]) { unite($0, $1) }
    let frame = squareFrame(around: union)
    var result: [AvatarExpression: Data] = [:]
    for (expression, cell, _) in cells {
      result[expression] = try ImageCodec.png(
        ImageCodec.render(cell, from: frame, into: AvatarSpriteSet.spriteSide))
    }
    return result
  }

  /// One expression drawn again, framed like `reference` — the set's neutral sprite — when there
  /// is one: same height, standing on the same line, centred the same way.
  static func sprite(
    fromImage data: Data, as expression: AvatarExpression, matching reference: Data?
  ) throws -> Data {
    let image = try removingBackground(ImageCodec.decode(data), as: expression)
    let measurement = measure(image)
    try SpriteSetValidation.validate(measurement, as: expression)
    guard let box = measurement.content else { throw AvatarProblem.emptyCell(expression) }
    let side = AvatarSpriteSet.spriteSide
    guard let reference,
      let target = try? measure(ImageCodec.decode(reference)).content
    else {
      return try ImageCodec.png(
        ImageCodec.render(image, from: squareFrame(around: box), into: side))
    }
    // The source rectangle that, rendered into the sprite, puts `box` where `target` is.
    let scale = Double(target.height) / Double(box.height)
    let sourceSide = Double(side) / scale
    let boxCentreX = Double(box.x) + Double(box.width) / 2
    let targetCentreX = Double(target.x) + Double(target.width) / 2
    let originX = boxCentreX - targetCentreX / scale
    let originY = Double(box.y + box.height) - Double(target.y + target.height) / scale
    return try ImageCodec.png(
      ImageCodec.render(
        image, from: CGRect(x: originX, y: originY, width: sourceSide, height: sourceSide),
        into: side))
  }

  /// An image of an archive: square, background removed if it has one, checked alone, and scaled
  /// whole to the sprite's side — its author framed it.
  static func sprite(fromDrawing image: RGBAImage, as expression: AvatarExpression) throws -> Data
  {
    let cleared = try removingBackground(image, as: expression)
    try SpriteSetValidation.validate(measure(cleared), as: expression)
    return try ImageCodec.png(
      ImageCodec.render(
        cleared, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
        into: AvatarSpriteSet.spriteSide))
  }

  // MARK: - Measures

  static func measure(_ image: RGBAImage) -> SpriteCellMeasurement {
    var minX = Int.max
    var minY = Int.max
    var maxX = -1
    var maxY = -1
    var count = 0
    for y in 0..<image.height {
      for x in 0..<image.width where image.alpha(x, y) >= opaque {
        count += 1
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    let content =
      count == 0
      ? nil
      : SpriteCellMeasurement.Box(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return SpriteCellMeasurement(
      cellWidth: image.width, cellHeight: image.height, content: content,
      coverage: Double(count) / Double(max(1, image.width * image.height)),
      transparentBorder: BackgroundRemoval.transparentShare(ofBorderOf: image))
  }

  static func removingBackground(_ image: RGBAImage, as expression: AvatarExpression) throws
    -> RGBAImage
  {
    do {
      return try BackgroundRemoval.removed(from: image)
    } catch AvatarProblem.backgroundNotRemoved {
      throw AvatarProblem.backgroundNotRemoved(expression)
    }
  }

  static func unite(_ a: SpriteCellMeasurement.Box, _ b: SpriteCellMeasurement.Box)
    -> SpriteCellMeasurement.Box
  {
    let minX = min(a.x, b.x)
    let minY = min(a.y, b.y)
    let maxX = max(a.x + a.width, b.x + b.width)
    let maxY = max(a.y + a.height, b.y + b.height)
    return SpriteCellMeasurement.Box(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  /// The square, centred on `box`, that holds it with a margin.
  static func squareFrame(around box: SpriteCellMeasurement.Box) -> CGRect {
    let side = Double(max(box.width, box.height)) * (1 + 2 * margin)
    let centreX = Double(box.x) + Double(box.width) / 2
    let centreY = Double(box.y) + Double(box.height) / 2
    return CGRect(x: centreX - side / 2, y: centreY - side / 2, width: side, height: side)
  }
}
