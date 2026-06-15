import CoreGraphics
import Foundation

public enum MiniModeLayout {
  public enum Edge: String, Sendable {
    case left
    case right
  }

  public struct SnapResult: Equatable, Sendable {
    public var edge: Edge
    public var miniFrame: CGRect
    public var preMiniOrigin: CGPoint
  }

  public struct DisplayGeometry: Equatable, Sendable {
    public var bounds: CGRect
    public var workArea: CGRect

    public init(bounds: CGRect, workArea: CGRect) {
      self.bounds = bounds
      self.workArea = workArea
    }
  }

  public struct Clip: Equatable, Sendable {
    public var edge: Edge
    public var fraction: CGFloat

    public init(edge: Edge, fraction: CGFloat) {
      self.edge = edge
      self.fraction = fraction
    }
  }

  public static let defaultSnapTolerance: CGFloat = 30
  public static let defaultPeekOffset: CGFloat = 25
  public static let defaultVerticalMargin: CGFloat = 20
  public static let defaultSeamTolerance: CGFloat = 4
  public static let defaultCrabwalkSpeed: CGFloat = 0.12
  public static let defaultJumpDurationMs = 350
  public static let defaultJumpPeakHeight: CGFloat = 40

  public static func snapResult(
    windowFrame: CGRect,
    workAreas: [CGRect],
    miniSize: CGSize,
    offsetRatio rawOffsetRatio: CGFloat,
    snapTolerance: CGFloat = defaultSnapTolerance,
    verticalMargin: CGFloat = defaultVerticalMargin
  ) -> SnapResult? {
    guard windowFrame.width > 0,
          windowFrame.height > 0,
          miniSize.width > 0,
          miniSize.height > 0
    else { return nil }

    let offsetRatio = min(max(rawOffsetRatio.isFinite ? rawOffsetRatio : 0.486, 0), 1)
    let snapEdgeWidth = windowFrame.width * 0.25
    let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)

    for workArea in workAreas where workArea.width > 0 && workArea.height > 0 {
      guard center.x >= workArea.minX,
            center.x <= workArea.maxX,
            center.y >= workArea.minY,
            center.y <= workArea.maxY
      else { continue }

      let rightLimit = workArea.maxX - windowFrame.width + snapEdgeWidth
      if windowFrame.minX >= rightLimit - snapTolerance {
        return SnapResult(
          edge: .right,
          miniFrame: miniFrame(edge: .right, workArea: workArea, sourceFrame: windowFrame, miniSize: miniSize, offsetRatio: offsetRatio, verticalMargin: verticalMargin),
          preMiniOrigin: windowFrame.origin
        )
      }

      let leftLimit = workArea.minX - snapEdgeWidth
      if windowFrame.minX <= leftLimit + snapTolerance {
        return SnapResult(
          edge: .left,
          miniFrame: miniFrame(edge: .left, workArea: workArea, sourceFrame: windowFrame, miniSize: miniSize, offsetRatio: offsetRatio, verticalMargin: verticalMargin),
          preMiniOrigin: windowFrame.origin
        )
      }
    }

    return nil
  }

  public static func miniFrame(
    edge: Edge,
    workArea: CGRect,
    sourceFrame: CGRect,
    miniSize: CGSize,
    offsetRatio rawOffsetRatio: CGFloat,
    verticalMargin: CGFloat = defaultVerticalMargin
  ) -> CGRect {
    let offsetRatio = min(max(rawOffsetRatio.isFinite ? rawOffsetRatio : 0.486, 0), 1)
    let minY = workArea.minY + verticalMargin
    let maxY = workArea.maxY - miniSize.height - verticalMargin
    let y = clamp(sourceFrame.midY - miniSize.height / 2, minY, maxY)
    let x: CGFloat
    switch edge {
    case .left:
      x = workArea.minX - miniSize.width * offsetRatio
    case .right:
      x = workArea.maxX - miniSize.width * (1 - offsetRatio)
    }
    return CGRect(origin: CGPoint(x: x, y: y), size: miniSize)
  }

  public static func menuEntryEdge(windowFrame: CGRect, workArea: CGRect) -> Edge {
    windowFrame.midX <= workArea.midX ? .left : .right
  }

  public static func crabwalkFrame(
    windowFrame: CGRect,
    workArea: CGRect,
    edge: Edge,
    adjacentSeam: Bool
  ) -> CGRect {
    guard windowFrame.width > 0 else { return windowFrame }
    let quarterWidth = (windowFrame.width * 0.25).rounded()
    let x: CGFloat
    switch edge {
    case .left:
      x = adjacentSeam ? workArea.minX : workArea.minX - quarterWidth
    case .right:
      x = adjacentSeam ? workArea.maxX - windowFrame.width : workArea.maxX - windowFrame.width + quarterWidth
    }
    return CGRect(origin: CGPoint(x: x, y: windowFrame.minY), size: windowFrame.size)
  }

  public static func crabwalkDurationMs(
    from startFrame: CGRect,
    to targetFrame: CGRect,
    speed: CGFloat = defaultCrabwalkSpeed
  ) -> Int {
    guard speed > 0, speed.isFinite else { return 0 }
    let distance = abs(targetFrame.minX - startFrame.minX)
    return max(0, Int((distance / speed).rounded()))
  }

  public static func menuJumpFrame(
    crabwalkFrame: CGRect,
    miniFrame: CGRect,
    edge: Edge,
    displays: [DisplayGeometry],
    adjacentSeam: Bool
  ) -> CGRect {
    guard crabwalkFrame.width > 0 else { return crabwalkFrame }
    if adjacentSeam {
      return CGRect(origin: CGPoint(x: miniFrame.minX, y: crabwalkFrame.minY), size: crabwalkFrame.size)
    }
    let displayBounds = displays.map(\.bounds).filter { $0.width > 0 && $0.height > 0 }
    let x: CGFloat
    switch edge {
    case .left:
      let minLeft = displayBounds.map(\.minX).min() ?? crabwalkFrame.minX
      x = minLeft - crabwalkFrame.width
    case .right:
      x = displayBounds.map(\.maxX).max() ?? crabwalkFrame.maxX
    }
    return CGRect(origin: CGPoint(x: x, y: crabwalkFrame.minY), size: crabwalkFrame.size)
  }

  public static func exitFrame(
    preMiniOrigin: CGPoint,
    workArea: CGRect,
    normalSize: CGSize,
    snapTolerance: CGFloat = defaultSnapTolerance
  ) -> CGRect {
    guard normalSize.width > 0,
          normalSize.height > 0
    else { return CGRect(origin: preMiniOrigin, size: normalSize) }
    var x = preMiniOrigin.x
    let y = clamp(preMiniOrigin.y, workArea.minY + 8, workArea.maxY - normalSize.height - 8)
    let snapEdgeWidth = (normalSize.width * 0.25).rounded()
    if x >= workArea.maxX - normalSize.width + snapEdgeWidth - snapTolerance {
      x = workArea.maxX - normalSize.width + snapEdgeWidth - 100
    }
    if x <= workArea.minX - snapEdgeWidth + snapTolerance {
      x = workArea.minX - snapEdgeWidth + snapTolerance + 100
    }
    x = clamp(x, workArea.minX + 8, workArea.maxX - normalSize.width - 8)
    return CGRect(origin: CGPoint(x: x, y: y), size: normalSize)
  }

  public static func peekFrame(
    miniFrame: CGRect,
    edge: Edge,
    peeking: Bool,
    peekOffset: CGFloat = defaultPeekOffset
  ) -> CGRect {
    let offset = peeking ? peekOffset : -peekOffset
    let dx = edge == .left ? offset : -offset
    return miniFrame.offsetBy(dx: dx, dy: 0)
  }

  public static func seamBoundary(
    workArea: CGRect,
    yMid: CGFloat,
    edge: Edge,
    displays: [DisplayGeometry],
    tolerance: CGFloat = defaultSeamTolerance
  ) -> CGFloat? {
    guard workArea.width > 0,
          workArea.height > 0,
          yMid.isFinite
    else { return nil }

    let center = CGPoint(x: workArea.midX, y: workArea.midY)
    let localIndex = displays.firstIndex { display in
      display.workArea.containsInclusive(center)
    }
    let localBounds = localIndex.map { displays[$0].bounds } ?? workArea
    let seam = edge == .right ? localBounds.maxX : localBounds.minX

    let hasNeighbour = displays.enumerated().contains { index, display in
      if let localIndex, index == localIndex { return false }
      guard yMid >= display.bounds.minY,
            yMid <= display.bounds.maxY
      else { return false }
      let neighbourEdge = edge == .right ? display.bounds.minX : display.bounds.maxX
      return abs(neighbourEdge - seam) <= tolerance
    }
    return hasNeighbour ? seam : nil
  }

  public static func clip(
    miniFrame: CGRect,
    edge: Edge,
    seamBoundary: CGFloat
  ) -> Clip? {
    guard miniFrame.width > 0,
          miniFrame.height > 0,
          seamBoundary.isFinite
    else { return nil }
    let fraction = clamp((seamBoundary - miniFrame.minX) / miniFrame.width, 0, 1)
    return Clip(edge: edge, fraction: fraction)
  }

  private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
    if minValue > maxValue { return (minValue + maxValue) / 2 }
    return min(max(value, minValue), maxValue)
  }
}

private extension CGRect {
  func containsInclusive(_ point: CGPoint) -> Bool {
    point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
  }
}
