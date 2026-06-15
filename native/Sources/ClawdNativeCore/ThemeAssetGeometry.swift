import CoreGraphics
import Foundation

public enum ThemeAssetGeometry {
  public struct EyeOffset: Equatable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat

    public init(dx: CGFloat, dy: CGFloat) {
      self.dx = dx
      self.dy = dy
    }
  }

  public struct PointerPayload: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var inside: Bool

    public init(x: CGFloat, y: CGFloat, inside: Bool) {
      self.x = x
      self.y = y
      self.inside = inside
    }
  }

  public static func mediaFrame(
    for asset: ThemeAsset,
    in bounds: CGRect,
    imageSize: CGSize? = nil
  ) -> CGRect {
    if let normalized = normalizedLayoutFrame(for: asset, in: bounds) {
      return normalized
    }

    let scale = asset.manifest.objectScale
    let file = baseName(asset.fileName)
    let fileOffset = scale?.fileOffsets?[file]
    let fileOffsetX = CGFloat(fileOffset?.x ?? 0)
    let fileOffsetY = CGFloat(fileOffset?.y ?? 0)
    let fileScale = CGFloat(scale?.fileScales?[file] ?? 1)

    if asset.fileName.lowercased().hasSuffix(".svg") {
      let widthRatio = CGFloat(scale?.widthRatio ?? 1.9)
      let heightRatio = CGFloat(scale?.heightRatio ?? 1.3)
      let offsetX = CGFloat(scale?.offsetX ?? -0.45)
      let offsetY = CGFloat(scale?.offsetY ?? -0.25)
      let bottom = CGFloat(scale?.objBottom ?? (1 - Double(offsetY) - Double(heightRatio)))
      return finiteFrame(
        x: bounds.width * offsetX + fileOffsetX,
        y: bounds.height * bottom + fileOffsetY,
        width: bounds.width * widthRatio,
        height: bounds.height * heightRatio,
        fallback: bounds
      )
    }

    let widthRatio = CGFloat(scale?.imgWidthRatio ?? scale?.widthRatio ?? 1.9) * fileScale
    let offsetX = CGFloat(scale?.imgOffsetX ?? scale?.offsetX ?? -0.45)
    let bottom = CGFloat(scale?.imgBottom ?? 0.05)
    let width = bounds.width * widthRatio
    return finiteFrame(
      x: bounds.width * offsetX + fileOffsetX,
      y: bounds.height * bottom + fileOffsetY,
      width: width,
      height: width / imageAspectRatio(imageSize),
      fallback: bounds
    )
  }

  public static func hitRect(
    for asset: ThemeAsset,
    hitBox: ThemeManifest.HitBox,
    in bounds: CGRect,
    imageSize: CGSize? = nil,
    padding: CGFloat = 6
  ) -> CGRect? {
    guard let viewBox = resolvedViewBox(for: asset) else { return nil }
    let media = mediaFrame(for: asset, in: bounds, imageSize: imageSize)
    let viewWidth = max(CGFloat(viewBox.width), 1)
    let viewHeight = max(CGFloat(viewBox.height), 1)
    let scaleX = media.width / viewWidth
    let scaleY = media.height / viewHeight
    let x = media.minX + CGFloat(hitBox.x - viewBox.x) * scaleX
    let yFromTop = CGFloat(hitBox.y - viewBox.y + hitBox.h) * scaleY
    let y = media.maxY - yFromTop
    return CGRect(
      x: x,
      y: y,
      width: CGFloat(hitBox.w) * scaleX,
      height: CGFloat(hitBox.h) * scaleY
    ).insetBy(dx: -padding, dy: -padding)
  }

  public static func renderedArtFrame(
    for asset: ThemeAsset,
    in bounds: CGRect,
    imageSize: CGSize? = nil
  ) -> CGRect? {
    guard let viewBox = resolvedViewBox(for: asset) else { return nil }
    let media = mediaFrame(for: asset, in: bounds, imageSize: imageSize)
    if usesDocumentChannel(asset), !usesNormalizedLayout(asset) {
      return fitViewBox(media, viewBox: viewBox)
    }
    return media
  }

  public static func eyeOffset(
    for asset: ThemeAsset,
    windowFrame: CGRect,
    viewBounds: CGRect,
    cursorScreenPoint: CGPoint,
    imageSize: CGSize? = nil
  ) -> EyeOffset? {
    guard asset.manifest.eyeTracking?.enabled == true else { return nil }
    let states = Set(asset.manifest.eyeTracking?.states ?? [])
    if !states.isEmpty, !states.contains(asset.state.rawValue) { return nil }
    guard let art = renderedArtFrame(for: asset, in: viewBounds, imageSize: imageSize) else { return nil }

    let ratioX = CGFloat(asset.manifest.eyeTracking?.eyeRatioX ?? 0.5)
    let ratioY = CGFloat(asset.manifest.eyeTracking?.eyeRatioY ?? 0.5)
    let eyeX = windowFrame.minX + art.minX + art.width * ratioX
    // Electron screen coordinates are y-down and use art.y + art.h * ratioY.
    // AppKit screen coordinates are y-up, so mirror around art.maxY.
    let eyeY = windowFrame.minY + art.maxY - art.height * ratioY
    let relX = cursorScreenPoint.x - eyeX
    let relY = eyeY - cursorScreenPoint.y
    let maxOffset = CGFloat(asset.manifest.eyeTracking?.maxOffset ?? 3)
    let dist = hypot(relX, relY)
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    if dist > 1, maxOffset > 0 {
      let scale = min(1, dist / 300)
      dx = (relX / dist) * maxOffset * scale
      dy = (relY / dist) * maxOffset * scale
    }
    dx = quantize(dx, unit: 2)
    dy = quantize(dy, unit: 2)
    let xClamp = maxOffset * 0.85
    let yClamp = maxOffset * 0.5
    return EyeOffset(
      dx: min(max(dx, -xClamp), xClamp),
      dy: min(max(dy, -yClamp), yClamp)
    )
  }

  public static func pointerPayload(
    for asset: ThemeAsset,
    windowFrame: CGRect,
    viewBounds: CGRect,
    cursorScreenPoint: CGPoint,
    imageSize: CGSize? = nil
  ) -> PointerPayload? {
    guard let viewBox = resolvedViewBox(for: asset),
          let art = renderedArtFrame(for: asset, in: viewBounds, imageSize: imageSize),
          art.width > 0,
          art.height > 0
    else { return nil }
    let localX = cursorScreenPoint.x - windowFrame.minX
    let localY = cursorScreenPoint.y - windowFrame.minY
    return PointerPayload(
      x: CGFloat(viewBox.x) + ((localX - art.minX) / art.width) * CGFloat(viewBox.width),
      y: CGFloat(viewBox.y) + ((art.maxY - localY) / art.height) * CGFloat(viewBox.height),
      inside: localX >= art.minX && localX <= art.maxX && localY >= art.minY && localY <= art.maxY
    )
  }

  public static func appKitFallbackEyeOffset(
    dx: CGFloat,
    dy: CGFloat,
    scale: CGFloat = 0.25
  ) -> CGSize {
    let safeScale = scale.isFinite ? scale : 0.25
    let x = dx.isFinite ? dx * safeScale : 0
    // CSS fallback translates positive y downward. AppKit frame coordinates
    // are y-up, so mirror the sign to keep mouse-follow direction consistent.
    let y = dy.isFinite ? -dy * safeScale : 0
    return CGSize(width: x, height: y)
  }

  private static func resolvedViewBox(for asset: ThemeAsset) -> ThemeManifest.ViewBox? {
    let file = baseName(asset.fileName)
    if let fileViewBox = asset.manifest.fileViewBoxes?[file] {
      return fileViewBox
    }
    if asset.state.rawValue.hasPrefix("mini-") {
      return asset.manifest.miniMode?.viewBox ?? asset.manifest.viewBox
    }
    return asset.manifest.viewBox
  }

  private static func usesDocumentChannel(_ asset: ThemeAsset) -> Bool {
    ThemeWebDocumentBuilder.usesDOMEyeTracking(asset)
      || ThemeWebDocumentBuilder.isTrustedScriptedSVG(asset)
      || ThemeWebDocumentBuilder.forcesObjectChannel(asset)
  }

  private static func usesNormalizedLayout(_ asset: ThemeAsset) -> Bool {
    let file = baseName(asset.fileName)
    guard asset.manifest.layout?.contentBox != nil else { return false }
    if let fileViewBox = asset.manifest.fileViewBoxes?[file],
       let rootViewBox = asset.manifest.viewBox,
       viewBoxEquals(fileViewBox, rootViewBox) {
      return true
    }
    if asset.state.rawValue.hasPrefix("mini-") || file.hasPrefix("mini-") {
      return false
    }
    return true
  }

  private static func normalizedLayoutFrame(for asset: ThemeAsset, in bounds: CGRect) -> CGRect? {
    let file = baseName(asset.fileName)
    guard usesNormalizedLayout(asset),
          let layout = asset.manifest.layout,
          let contentBox = layout.contentBox,
          let viewBox = resolvedViewBox(for: asset)
    else { return nil }

    let scale = asset.manifest.objectScale
    let fileOffset = scale?.fileOffsets?[file]
    let fileOffsetX = CGFloat(fileOffset?.x ?? 0)
    let fileOffsetY = CGFloat(fileOffset?.y ?? 0)
    let fileScale = CGFloat(scale?.fileScales?[file] ?? 1)
    let centerX = CGFloat(layout.centerX ?? (contentBox.x + contentBox.width / 2))
    let baselineY = CGFloat(layout.baselineY ?? (contentBox.y + contentBox.height))
    let centerXRatio = CGFloat(layout.centerXRatio ?? 0.5)
    let baselineBottomRatio = CGFloat(layout.baselineBottomRatio ?? 0.05)
    let visibleHeightRatio = CGFloat(layout.visibleHeightRatio ?? 0.58)
    let unitRatio = (visibleHeightRatio * fileScale) / max(CGFloat(contentBox.height), 0.0001)
    let widthRatio = CGFloat(viewBox.width) * unitRatio
    let heightRatio = CGFloat(viewBox.height) * unitRatio
    let leftRatio = centerXRatio - ((centerX - CGFloat(viewBox.x)) * unitRatio)
    let bottomRatio = baselineBottomRatio - ((CGFloat(viewBox.y + viewBox.height) - baselineY) * unitRatio)
    return finiteFrame(
      x: bounds.width * leftRatio + fileOffsetX,
      y: bounds.height * bottomRatio + fileOffsetY,
      width: bounds.width * widthRatio,
      height: bounds.height * heightRatio,
      fallback: bounds
    )
  }

  private static func fitViewBox(_ outer: CGRect, viewBox: ThemeManifest.ViewBox) -> CGRect {
    let viewWidth = max(CGFloat(viewBox.width), 1)
    let viewHeight = max(CGFloat(viewBox.height), 1)
    let scale = min(outer.width / viewWidth, outer.height / viewHeight)
    let width = viewWidth * scale
    let height = viewHeight * scale
    return CGRect(
      x: outer.minX + (outer.width - width) / 2,
      y: outer.minY + (outer.height - height) / 2,
      width: width,
      height: height
    )
  }

  private static func viewBoxEquals(_ lhs: ThemeManifest.ViewBox, _ rhs: ThemeManifest.ViewBox) -> Bool {
    abs(lhs.x - rhs.x) < 0.0001
      && abs(lhs.y - rhs.y) < 0.0001
      && abs(lhs.width - rhs.width) < 0.0001
      && abs(lhs.height - rhs.height) < 0.0001
  }

  private static func quantize(_ value: CGFloat, unit: CGFloat) -> CGFloat {
    guard value.isFinite, unit > 0 else { return 0 }
    return (value * unit).rounded() / unit
  }

  private static func baseName(_ value: String) -> String {
    (value as NSString).lastPathComponent
  }

  private static func imageAspectRatio(_ size: CGSize?) -> CGFloat {
    guard let size, size.width > 0, size.height > 0 else { return 1 }
    return size.width / size.height
  }

  private static func finiteFrame(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, fallback: CGRect) -> CGRect {
    guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
      return fallback
    }
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
