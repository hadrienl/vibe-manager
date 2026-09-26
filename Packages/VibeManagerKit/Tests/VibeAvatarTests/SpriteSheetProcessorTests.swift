import CoreGraphics
import Foundation
import Testing
import VibeApplication

@testable import VibeAvatar

/// A fixture of this target: the sheet and the expression Codex drew in the spike of #41.
func fixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  return try Data(contentsOf: url)
}

/// An image drawn for a test: `cells` characters side by side on `background`, each a filled
/// ellipse of `size` in a square cell of `cell` pixels.
func drawnSheet(
  columns: Int, rows: Int, cell: Int = 300, background: (UInt8, UInt8, UInt8) = (255, 0, 255),
  transparent: Bool = false, ink: (UInt8, UInt8, UInt8) = (40, 120, 220),
  size: (Int) -> Int = { _ in 180 }, offset: (Int) -> (Int, Int) = { _ in (0, 0) }
) throws -> Data {
  var image = RGBAImage(width: columns * cell, height: rows * cell)
  for index in stride(from: 0, to: image.pixels.count, by: 4) {
    image.pixels[index] = background.0
    image.pixels[index + 1] = background.1
    image.pixels[index + 2] = background.2
    image.pixels[index + 3] = transparent ? 0 : 255
  }
  for index in 0..<(columns * rows) {
    let side = size(index)
    let (dx, dy) = offset(index)
    let centreX = (index % columns) * cell + cell / 2 + dx
    let centreY = (index / columns) * cell + cell / 2 + dy
    guard side > 0 else { continue }
    for y in (centreY - side / 2)..<(centreY + side / 2) {
      for x in (centreX - side / 3)..<(centreX + side / 3) {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
        let nx = Double(x - centreX) / Double(side / 3)
        let ny = Double(y - centreY) / Double(side / 2)
        guard nx * nx + ny * ny <= 1 else { continue }
        let offset = image.offset(x, y)
        image.pixels[offset] = ink.0
        image.pixels[offset + 1] = ink.1
        image.pixels[offset + 2] = ink.2
        image.pixels[offset + 3] = 255
      }
    }
  }
  return try ImageCodec.png(image)
}

@Suite("Cutting a sheet into sprites")
struct SpriteSheetProcessorTests {
  @Test("The sheet Codex drew in the spike becomes ten framed sprites, without a magenta fringe")
  func spikeSheet() throws {
    let sprites = try SpriteSheetProcessor.sprites(
      fromSheet: try fixture("codex-sheet.jpg"), expressions: AvatarExpression.allCases)

    #expect(Set(sprites.keys) == Set(AvatarExpression.allCases))
    for (expression, data) in sprites {
      let image = try ImageCodec.decode(data)
      #expect(image.width == 512 && image.height == 512, "\(expression)")
      #expect(BackgroundRemoval.transparentShare(ofBorderOf: image) > 0.99, "\(expression)")
      // No pixel that shows is the background's magenta: the edge was cleaned of it.
      var fringe = 0
      for index in stride(from: 0, to: image.pixels.count, by: 4) where image.pixels[index + 3] > 64 {
        let r = Int(image.pixels[index])
        let g = Int(image.pixels[index + 1])
        let b = Int(image.pixels[index + 2])
        if r > 180, b > 180, g < 90 { fringe += 1 }
      }
      #expect(fringe < 50, "\(expression): \(fringe) magenta pixels")
    }
  }

  @Test("Every sprite of a sheet has the same framing: the character does not jump")
  func sameFraming() throws {
    let sprites = try SpriteSheetProcessor.sprites(
      fromSheet: try drawnSheet(columns: 5, rows: 2), expressions: AvatarExpression.allCases)
    let boxes = try AvatarExpression.allCases.map { expression in
      let sprite = try #require(sprites[expression])
      return try #require(SpriteSheetProcessor.measure(ImageCodec.decode(sprite)).content)
    }
    for box in boxes.dropFirst() {
      #expect(abs(box.x - boxes[0].x) <= 2 && abs(box.y - boxes[0].y) <= 2)
      #expect(abs(box.height - boxes[0].height) <= 2)
    }
  }

  @Test("A sheet already transparent keeps its dark lines: nothing is keyed out of it")
  func alreadyTransparent() throws {
    let sprites = try SpriteSheetProcessor.sprites(
      fromSheet: try drawnSheet(columns: 5, rows: 2, transparent: true, ink: (0, 0, 0)),
      expressions: AvatarExpression.allCases)
    let neutral = try ImageCodec.decode(try #require(sprites[.neutral]))
    let centre = neutral.offset(neutral.width / 2, neutral.height / 2)
    #expect(neutral.pixels[centre + 3] == 255)
    #expect(neutral.pixels[centre] < 10)
  }

  @Test("A sheet of the wrong proportions is refused, saying what was found")
  func wrongGrid() throws {
    #expect(
      throws: AvatarProblem.wrongGrid(expectedColumns: 5, expectedRows: 2, width: 1200, height: 1200)
    ) {
      try SpriteSheetProcessor.sprites(
        fromSheet: try drawnSheet(columns: 4, rows: 4), expressions: AvatarExpression.allCases)
    }
  }

  @Test("A sheet whose cells are too small is refused")
  func cellTooSmall() throws {
    #expect(throws: AvatarProblem.cellTooSmall) {
      try SpriteSheetProcessor.sprites(
        fromSheet: try drawnSheet(columns: 5, rows: 2, cell: 120, size: { _ in 60 }),
        expressions: AvatarExpression.allCases)
    }
  }

  @Test("An empty cell names its expression")
  func emptyCell() throws {
    #expect(throws: AvatarProblem.emptyCell(.eyesClosed)) {
      try SpriteSheetProcessor.sprites(
        fromSheet: try drawnSheet(columns: 5, rows: 2, size: { $0 == 5 ? 0 : 180 }),
        expressions: AvatarExpression.allCases)
    }
  }

  @Test("A character cut by the edge of its cell names its expression")
  func cutCell() throws {
    #expect(throws: AvatarProblem.cutCell(.mouthOpen)) {
      try SpriteSheetProcessor.sprites(
        fromSheet: try drawnSheet(columns: 5, rows: 2, offset: { $0 == 2 ? (0, 120) : (0, 0) }),
        expressions: AvatarExpression.allCases)
    }
  }

  @Test("A character much bigger than the others names its expression")
  func inconsistentSize() throws {
    #expect(throws: AvatarProblem.inconsistentSize(.worried)) {
      try SpriteSheetProcessor.sprites(
        fromSheet: try drawnSheet(columns: 5, rows: 2, size: { $0 == 9 ? 270 : 150 }),
        expressions: AvatarExpression.allCases)
    }
  }

  @Test("An image too large is refused before it is decoded")
  func tooLarge() throws {
    #expect(throws: AvatarProblem.imageTooLarge) {
      try ImageCodec.decode(Data(count: ImageCodec.maximumBytes + 1))
    }
  }

  @Test("Something that is not an image is refused")
  func notAnImage() {
    #expect(throws: AvatarProblem.unreadableImage) {
      try ImageCodec.decode(Data("not an image".utf8))
    }
  }

  @Test("An expression drawn again is framed like the neutral sprite: same height, same line")
  func expressionMatchesReference() throws {
    let sprites = try SpriteSheetProcessor.sprites(
      fromSheet: try fixture("codex-sheet.jpg"), expressions: AvatarExpression.allCases)
    let neutral = try #require(sprites[.neutral])
    let redrawn = try SpriteSheetProcessor.sprite(
      fromImage: try fixture("codex-expression.png"), as: .eyesClosed, matching: neutral)

    let target = try #require(SpriteSheetProcessor.measure(ImageCodec.decode(neutral)).content)
    let box = try #require(SpriteSheetProcessor.measure(ImageCodec.decode(redrawn)).content)
    #expect(abs(box.height - target.height) <= target.height / 20)
    #expect(abs((box.y + box.height) - (target.y + target.height)) <= 8)
  }
}
