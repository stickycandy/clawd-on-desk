import CoreGraphics
import Foundation

public enum UpdateBubbleLayout {
  public static let defaultWidth: CGFloat = 340
  public static let defaultEdgeMargin: CGFloat = 8
  public static let defaultGap: CGFloat = 6

  public static func computeBounds(
    bubbleFollowPet: Bool,
    bubbleSize: CGSize,
    workArea: CGRect,
    petFrame: CGRect?,
    edgeMargin: CGFloat = defaultEdgeMargin,
    gap: CGFloat = defaultGap
  ) -> CGRect {
    computeBounds(
      bubbleFollowPet: bubbleFollowPet,
      bubbleSize: bubbleSize,
      workArea: workArea,
      petFrame: petFrame,
      reservedHeight: 0,
      hudReservedOffset: 0,
      edgeMargin: edgeMargin,
      gap: gap
    )
  }

  public static func computeBounds(
    bubbleFollowPet: Bool,
    bubbleSize: CGSize,
    workArea: CGRect,
    petFrame: CGRect?,
    reservedHeight: CGFloat,
    hudReservedOffset: CGFloat = 0,
    edgeMargin: CGFloat = defaultEdgeMargin,
    gap: CGFloat = defaultGap
  ) -> CGRect {
    let width = min(max(bubbleSize.width, 1), max(workArea.width, 1))
    let height = min(max(bubbleSize.height, 1), max(workArea.height, 1))
    let stackOffset = max(0, reservedHeight)
    let hudOffset = max(0, hudReservedOffset)
    let maxX = workArea.maxX - width
    let maxY = workArea.maxY - edgeMargin - height

    guard bubbleFollowPet, let petFrame else {
      return CGRect(
        x: max(workArea.minX, maxX - edgeMargin),
        y: max(workArea.minY + edgeMargin, maxY - stackOffset),
        width: width,
        height: height
      )
    }

    let belowY = petFrame.minY - gap - hudOffset - stackOffset - height
    let aboveY = petFrame.maxY + gap
    let centeredX = petFrame.midX - width / 2
    if belowY >= workArea.minY + edgeMargin {
      return CGRect(
        x: clamp(centeredX, workArea.minX, maxX),
        y: belowY,
        width: width,
        height: height
      )
    }
    if aboveY + height <= workArea.maxY - edgeMargin {
      return CGRect(
        x: clamp(centeredX, workArea.minX, maxX),
        y: aboveY,
        width: width,
        height: height
      )
    }

    let rightX = petFrame.maxX + gap
    let leftX = petFrame.minX - gap - width
    let sideX = rightX + width <= workArea.maxX
      ? rightX
      : max(workArea.minX, leftX)
    return CGRect(
      x: clamp(sideX, workArea.minX, maxX),
      y: clamp(petFrame.midY - height / 2, workArea.minY + edgeMargin, maxY),
      width: width,
      height: height
    )
  }

  private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
    min(max(value, minValue), maxValue)
  }
}
