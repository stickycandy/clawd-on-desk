import CoreGraphics
import Foundation

public enum BubbleStackLayout {
  public static let defaultWidth: CGFloat = 340
  public static let defaultMargin: CGFloat = 8
  public static let defaultGap: CGFloat = 6

  public static func computeBounds(
    followPet: Bool,
    bubbleHeights: [CGFloat],
    bubbleWidth: CGFloat = defaultWidth,
    margin: CGFloat = defaultMargin,
    gap: CGFloat = defaultGap,
    workArea: CGRect,
    petFrame: CGRect?
  ) -> [CGRect] {
    guard !bubbleHeights.isEmpty else { return [] }
    let width = min(max(bubbleWidth, 1), max(workArea.width, 1))
    let heights = bubbleHeights.map { min(max($0, 1), max(workArea.height, 1)) }
    let totalHeight = heights.reduce(CGFloat(0), +) + gap * CGFloat(max(heights.count - 1, 0))

    if followPet, let petFrame {
      let centeredX = clamp(petFrame.midX - width / 2, workArea.minX, workArea.maxX - width)
      let belowTop = petFrame.minY - gap
      if belowTop - totalHeight >= workArea.minY + margin {
        return stackDown(fromTop: belowTop, x: centeredX, width: width, heights: heights, gap: gap)
      }

      let aboveBottom = petFrame.maxY + gap
      if aboveBottom + totalHeight <= workArea.maxY - margin {
        return stackUp(fromBottom: aboveBottom, x: centeredX, width: width, heights: heights, gap: gap)
      }

      let rightX = petFrame.maxX + gap
      let leftX = petFrame.minX - gap - width
      if rightX + width <= workArea.maxX || leftX >= workArea.minX {
        let x = rightX + width <= workArea.maxX ? rightX : leftX
        let top = clamp(
          petFrame.midY + totalHeight / 2,
          workArea.minY + margin + totalHeight,
          workArea.maxY - margin
        )
        return stackDown(fromTop: top, x: x, width: width, heights: heights, gap: gap)
      }
    }

    let x = workArea.maxX - width - margin
    let top = workArea.maxY - margin
    return stackDown(fromTop: top, x: max(workArea.minX, x), width: width, heights: heights, gap: gap)
  }

  private static func stackDown(fromTop top: CGFloat, x: CGFloat, width: CGFloat, heights: [CGFloat], gap: CGFloat) -> [CGRect] {
    var yTop = top
    return heights.map { height in
      let frame = CGRect(x: x, y: yTop - height, width: width, height: height)
      yTop -= height + gap
      return frame
    }
  }

  private static func stackUp(fromBottom bottom: CGFloat, x: CGFloat, width: CGFloat, heights: [CGFloat], gap: CGFloat) -> [CGRect] {
    var y = bottom
    return heights.map { height in
      let frame = CGRect(x: x, y: y, width: width, height: height)
      y += height + gap
      return frame
    }
  }

  private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
    if minValue > maxValue { return maxValue }
    return min(max(value, minValue), maxValue)
  }
}
