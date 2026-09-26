/// Why an image, a sheet or an archive cannot become an avatar (#41). Each names what is wrong, and
/// which expression when it is one, so that the message can say it.
public enum AvatarProblem: Error, Hashable, Sendable {
  // The image.
  case unreadableImage
  case imageTooLarge
  /// The sheet is not the grid asked for: its proportions do not fit.
  case wrongGrid(expectedColumns: Int, expectedRows: Int, width: Int, height: Int)
  case cellTooSmall
  case emptyCell(AvatarExpression)
  /// The character touches the edge of its cell: it is cut.
  case cutCell(AvatarExpression)
  /// The character is much bigger or smaller here than in the other cells.
  case inconsistentSize(AvatarExpression)
  case backgroundNotRemoved(AvatarExpression)
  // An archive.
  case archiveUnreadable
  case archiveTooLarge
  /// An entry that could land outside the folder, is a link, or is not a plain file.
  case archiveUnsafeEntry(String)
  case archiveEncrypted
  case archiveFromNewerVersion
  case archiveHasNoImage
  case imageNotSquare(AvatarExpression)
  case imageTooSmall(AvatarExpression)
  /// Two images of the archive have different sizes.
  case imagesOfDifferentSizes(AvatarExpression)
}

/// What was measured of one cell, once its background was removed.
public struct SpriteCellMeasurement: Hashable, Sendable {
  public struct Box: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }
  }

  public let cellWidth: Int
  public let cellHeight: Int
  /// The smallest box holding every opaque pixel. `nil`: none is.
  public let content: Box?
  /// The share of opaque pixels, from 0 to 1.
  public let coverage: Double
  /// The share of the cell's outermost pixels that are transparent, from 0 to 1.
  public let transparentBorder: Double

  public init(
    cellWidth: Int, cellHeight: Int, content: Box?, coverage: Double, transparentBorder: Double
  ) {
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.content = content
    self.coverage = coverage
    self.transparentBorder = transparentBorder
  }
}

/// The rules a set of cells must follow to become an avatar. Pure: the measures come from the
/// image processing, the verdict from here, so that each rule is tested without an image.
public enum SpriteSetValidation {
  /// Less than this share of opaque pixels is an empty cell.
  public static let minimumCoverage = 0.03
  /// Closer than this to the edge of its cell, the character is cut.
  public static let edgeMargin = 2
  /// How far a character's width or height may stray from the median of the set.
  public static let sizeTolerance = 0.2
  /// The share of a cell's border that must be transparent once the background is removed.
  public static let minimumTransparentBorder = 0.95

  /// Throws the first problem found, in the animation's order.
  public static func validate(_ cells: [(AvatarExpression, SpriteCellMeasurement)]) throws {
    for (expression, cell) in cells {
      try validate(cell, as: expression)
    }
    guard cells.count > 1 else { return }
    let boxes = cells.compactMap { expression, cell in cell.content.map { (expression, $0) } }
    let medianWidth = median(boxes.map { Double($0.1.width) })
    let medianHeight = median(boxes.map { Double($0.1.height) })
    for (expression, box) in boxes {
      if abs(Double(box.width) - medianWidth) > medianWidth * sizeTolerance
        || abs(Double(box.height) - medianHeight) > medianHeight * sizeTolerance
      {
        throw AvatarProblem.inconsistentSize(expression)
      }
    }
  }

  /// One cell alone: an expression drawn again.
  public static func validate(_ cell: SpriteCellMeasurement, as expression: AvatarExpression)
    throws
  {
    guard let box = cell.content, cell.coverage >= minimumCoverage else {
      throw AvatarProblem.emptyCell(expression)
    }
    // A background left whole covers most of the border; a character cut by the edge covers only
    // where it crosses it.
    guard cell.transparentBorder >= 0.5 else {
      throw AvatarProblem.backgroundNotRemoved(expression)
    }
    if box.x < edgeMargin || box.y < edgeMargin
      || box.x + box.width > cell.cellWidth - edgeMargin
      || box.y + box.height > cell.cellHeight - edgeMargin
    {
      throw AvatarProblem.cutCell(expression)
    }
    guard cell.transparentBorder >= minimumTransparentBorder else {
      throw AvatarProblem.backgroundNotRemoved(expression)
    }
  }

  static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}
