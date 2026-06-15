import Foundation
import JavaScriptCore

public enum ThemeWebDocumentChannel: String, Equatable, Sendable {
  case inlineSVG = "inline-svg"
  case objectSVG = "object-svg"
  case image
}

public struct ThemeWebDocument: Equatable, Sendable {
  public var channel: ThemeWebDocumentChannel
  public var html: String
  public var baseURL: URL
  public var usesDOMEyeTracking: Bool
  public var usesLayeredTracking: Bool
  public var fallbackSVG: String?

  public init(
    channel: ThemeWebDocumentChannel,
    html: String,
    baseURL: URL,
    usesDOMEyeTracking: Bool,
    usesLayeredTracking: Bool,
    fallbackSVG: String? = nil
  ) {
    self.channel = channel
    self.html = html
    self.baseURL = baseURL
    self.usesDOMEyeTracking = usesDOMEyeTracking
    self.usesLayeredTracking = usesLayeredTracking
    self.fallbackSVG = fallbackSVG
  }
}

public enum ThemeWebDocumentBuilder {
  public static func document(for asset: ThemeAsset, cacheBust: String) -> ThemeWebDocument {
    let file = baseName(asset.fileName)
    let svg = file.lowercased().hasSuffix(".svg")
    let domTracking = usesDOMEyeTracking(asset)
    let trustedScripted = isTrustedScriptedSVG(asset)
    let needsObjectSVG = svg && !domTracking && !trustedScripted && forcesObjectChannel(asset)
    if needsObjectSVG {
      let url = escapedCacheBustedURL(asset.url.absoluteString, cacheBust: cacheBust)
      return ThemeWebDocument(
        channel: .objectSVG,
        html: html(for: asset, media: objectSVGMedia(url), inlineSVG: false),
        baseURL: asset.readAccessURL,
        usesDOMEyeTracking: false,
        usesLayeredTracking: false
      )
    }

    let needsInlineSVG = svg
    if needsInlineSVG,
       let svgText = try? String(contentsOf: asset.url, encoding: .utf8) {
      let preparedSVG = prepareInlineSVG(svgText)
      return ThemeWebDocument(
        channel: .inlineSVG,
        html: html(for: asset, media: inlineSVGMedia(preparedSVG, executeScripts: trustedScripted), inlineSVG: true),
        baseURL: asset.readAccessURL,
        usesDOMEyeTracking: domTracking,
        usesLayeredTracking: usesLayeredTracking(asset),
        fallbackSVG: trustedScripted ? scriptedSVGSnapshot(from: preparedSVG) : nil
      )
    }

    let url = escapedCacheBustedURL(asset.url.absoluteString, cacheBust: cacheBust)
    let media = #"<img id="asset" class="clawd-img" src="\#(url)" alt="" />"#
    return ThemeWebDocument(
      channel: .image,
      html: html(for: asset, media: media, inlineSVG: false),
      baseURL: asset.readAccessURL,
      usesDOMEyeTracking: false,
      usesLayeredTracking: false
    )
  }

  public static func usesDOMEyeTracking(_ asset: ThemeAsset) -> Bool {
    guard asset.fileName.lowercased().hasSuffix(".svg"),
          asset.manifest.eyeTracking?.enabled == true
    else { return false }
    let states = Set(asset.manifest.eyeTracking?.states ?? [])
    return states.isEmpty || states.contains(asset.state.rawValue)
  }

  public static func isTrustedScriptedSVG(_ asset: ThemeAsset) -> Bool {
    guard asset.fileName.lowercased().hasSuffix(".svg") else { return false }
    let file = baseName(asset.fileName)
    return Set(asset.manifest.trustedRuntime?.scriptedSvgFiles ?? []).contains(file)
  }

  public static func forcesObjectChannel(_ asset: ThemeAsset) -> Bool {
    asset.fileName.lowercased().hasSuffix(".svg") && asset.manifest.rendering?.svgChannel == "object"
  }

  public static func usesLayeredTracking(_ asset: ThemeAsset) -> Bool {
    usesDOMEyeTracking(asset) && asset.manifest.eyeTracking?.trackingLayers?.isEmpty == false
  }

  private static func html(for asset: ThemeAsset, media: String, inlineSVG: Bool) -> String {
    let mediaStyle = objectScaleCSS(for: asset)
    let eyeConfig = eyeTrackingConfigJSON(asset)
    let assetSelector = "#asset"
    return """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        html, body {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          background: transparent;
        }
        \(assetSelector) {
          display: block;
          position: absolute;
          border: 0;
          object-fit: contain;
          image-rendering: auto;
          transform-origin: center center;
          \(mediaStyle)
        }
        #asset > svg {
          display: block;
          width: 100%;
          height: 100%;
          overflow: visible;
        }
      </style>
      <script>
        window.__clawdNativeReady = false;
        window.__clawdNativeScriptErrors = [];
        window.addEventListener('error', function(event) {
          window.__clawdNativeScriptErrors.push(String(event.message || 'script error'));
        });
        window.addEventListener('unhandledrejection', function(event) {
          window.__clawdNativeScriptErrors.push(String((event.reason && event.reason.message) || event.reason || 'unhandled rejection'));
        });
        window.__clawdNativeEyeConfig = \(eyeConfig);
        \(eyeTrackingScript)
      </script>
    </head>
    <body>
      \(media)
      <script>
        (function() {
          function markReadyAfterPaint() {
            requestAnimationFrame(() => {
              requestAnimationFrame(() => { window.__clawdNativeReady = true; });
            });
          }
          const img = document.querySelector('img#asset');
          if (img) {
            if (img.complete) {
              if (img.naturalWidth > 0) {
                markReadyAfterPaint();
              } else {
                window.__clawdNativeReady = false;
              }
              return;
            }
            img.addEventListener('load', () => {
              if (img.naturalWidth > 0) markReadyAfterPaint();
            }, { once: true });
            img.addEventListener('error', () => { window.__clawdNativeReady = false; }, { once: true });
            return;
          }
          const object = document.querySelector('object#asset');
          if (object) {
            let ready = false;
            try {
              ready = object.contentDocument && object.contentDocument.readyState === 'complete';
            } catch (_) {}
            if (ready) {
              markReadyAfterPaint();
              return;
            }
            object.addEventListener('load', markReadyAfterPaint, { once: true });
            object.addEventListener('error', () => { window.__clawdNativeReady = false; }, { once: true });
            return;
          }
          let attempts = 0;
          function waitForInlineSVG() {
            const frame = document.getElementById('asset');
            const svg = frame && frame.querySelector ? frame.querySelector('svg') : null;
            if (svg || attempts >= 20) {
              markReadyAfterPaint();
              return;
            }
            attempts += 1;
            requestAnimationFrame(waitForInlineSVG);
          }
          waitForInlineSVG();
        })();
      </script>
    </body>
    </html>
    """
  }

  private static func inlineSVGMedia(_ svg: String, executeScripts: Bool = false) -> String {
    let extracted = extractScripts(from: svg)
    if executeScripts {
      let scripts = extracted.scripts
        .map { "<script data-clawd-native-scripted-svg=\"true\">\(scriptForHTML(rewriteSVGInnerHTMLAssignments($0)))</script>" }
        .joined(separator: "\n")
      return #"<div id="asset" data-channel="inline-svg">\#(extracted.markup)</div><script>\#(svgInnerHTMLShim)</script>\#(scripts)"#
    }
    return #"<div id="asset" data-channel="inline-svg">\#(extracted.markup)</div>"#
  }

  private static func objectSVGMedia(_ url: String) -> String {
    #"<object id="asset" class="clawd-img" data-channel="object-svg" data="\#(url)" type="image/svg+xml"></object>"#
  }

  private static func prepareInlineSVG(_ svg: String) -> String {
    var out = svg.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.hasPrefix("<?xml"), let end = out.range(of: "?>") {
      out.removeSubrange(out.startIndex..<end.upperBound)
      out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if out.uppercased().hasPrefix("<!DOCTYPE"), let end = out.range(of: ">") {
      out.removeSubrange(out.startIndex..<end.upperBound)
      out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return out
  }

  private static func extractScripts(from svg: String) -> (markup: String, scripts: [String]) {
    var markup = svg
    var scripts: [String] = []
    while let open = markup.range(of: "<script", options: [.caseInsensitive]),
          let openEnd = markup[open.upperBound...].range(of: ">"),
          let close = markup[openEnd.upperBound...].range(of: "</script>", options: [.caseInsensitive]) {
      let scriptBody = String(markup[openEnd.upperBound..<close.lowerBound])
      scripts.append(stripCDATA(scriptBody))
      markup.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
    }
    return (markup, scripts)
  }

  private static func stripCDATA(_ script: String) -> String {
    var out = script.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.hasPrefix("<![CDATA[") {
      out.removeFirst("<![CDATA[".count)
    }
    if out.hasSuffix("]]>") {
      out.removeLast("]]>".count)
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func scriptForHTML(_ script: String) -> String {
    script.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
  }

  private static func rewriteSVGInnerHTMLAssignments(_ script: String) -> String {
    let needle = "stage.innerHTML ="
    var out = ""
    var cursor = script.startIndex
    while let assignment = script[cursor...].range(of: needle) {
      out.append(contentsOf: script[cursor..<assignment.lowerBound])
      var templateStart = assignment.upperBound
      while templateStart < script.endIndex,
            script[templateStart].isWhitespace {
        templateStart = script.index(after: templateStart)
      }
      guard templateStart < script.endIndex,
            script[templateStart] == "`",
            let close = script[script.index(after: templateStart)...].range(of: "`;")
      else {
        out.append(contentsOf: script[assignment])
        cursor = assignment.upperBound
        continue
      }
      out.append("window.__clawdNativeSetSVGInnerHTML(stage, ")
      out.append(contentsOf: script[templateStart...close.lowerBound])
      out.append(");")
      cursor = close.upperBound
    }
    out.append(contentsOf: script[cursor...])
    return out
  }

  private static func scriptedSVGSnapshot(from svg: String) -> String? {
    let extracted = extractScripts(from: svg)
    guard !extracted.scripts.isEmpty else { return nil }
    guard let context = JSContext() else { return nil }
    var exceptionText: String?
    context.exceptionHandler = { _, exception in
      exceptionText = exception?.toString()
    }
    context.evaluateScript(scriptedSVGSnapshotDOMStub)
    for script in extracted.scripts {
      context.evaluateScript(stripCDATA(script))
      if exceptionText != nil { return nil }
    }
    guard exceptionText == nil,
          let innerHTML = context.evaluateScript("__clawdNativeElements.stage && __clawdNativeElements.stage.innerHTML || ''")?.toString(),
          !innerHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return replacingSVGContents(in: extracted.markup, with: innerHTML)
  }

  private static func replacingSVGContents(in svg: String, with innerHTML: String) -> String? {
    guard let openEnd = svg.range(of: ">"),
          let close = svg.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
          openEnd.upperBound <= close.lowerBound
    else { return nil }
    return String(svg[..<openEnd.upperBound])
      + "\n"
      + innerHTML
      + "\n"
      + String(svg[close.lowerBound...])
  }

  private static let scriptedSVGSnapshotDOMStub = """
    var __clawdNativeElements = {};
    function __clawdNativeElement(id) {
      if (!__clawdNativeElements[id]) {
        __clawdNativeElements[id] = {
          id: id,
          innerHTML: '',
          textContent: '',
          value: '',
          max: '',
          style: {},
          children: [],
          setAttribute: function(name, value) { this[name] = String(value); },
          getAttribute: function(name) { return this[name] || ''; },
          appendChild: function(child) { this.children.push(child); return child; },
          addEventListener: function() {},
          removeEventListener: function() {},
          querySelector: function(selector) { return __clawdNativeElement(id + ':' + selector); },
          querySelectorAll: function() { return []; }
        };
      }
      return __clawdNativeElements[id];
    }
    var document = {
      getElementById: function(id) { return __clawdNativeElement(id); },
      createElement: function(tag) { return __clawdNativeElement('created:' + tag + ':' + Object.keys(__clawdNativeElements).length); },
      createElementNS: function(ns, tag) { return __clawdNativeElement('createdNS:' + tag + ':' + Object.keys(__clawdNativeElements).length); },
      querySelector: function(selector) { return __clawdNativeElement('query:' + selector); },
      querySelectorAll: function() { return []; }
    };
    var window = this;
    window.addEventListener = function() {};
    window.removeEventListener = function() {};
    window.matchMedia = function() {
      return {
        matches: false,
        addEventListener: function() {},
        removeEventListener: function() {}
      };
    };
    var performance = { now: function() { return 0; } };
    function requestAnimationFrame() {}
    function cancelAnimationFrame() {}
  """

  private static let svgInnerHTMLShim = """
    (function() {
      function setSVGInnerHTML(target, markup) {
        if (!target) return;
        const parser = new DOMParser();
        const wrapped = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">' + markup + '</svg>';
        const doc = parser.parseFromString(wrapped, 'image/svg+xml');
        if (doc.querySelector && doc.querySelector('parsererror')) {
          target.textContent = '';
          return;
        }
        while (target.firstChild) target.removeChild(target.firstChild);
        const children = Array.prototype.slice.call(doc.documentElement.childNodes);
        for (const child of children) {
          target.appendChild(document.importNode(child, true));
        }
      }
      const asset = document.getElementById('asset');
      const root = asset && asset.querySelector ? asset.querySelector('svg') : null;
      if (!root) return;
      try {
        Object.defineProperty(root, 'innerHTML', {
          configurable: true,
          get: function() {
            return new XMLSerializer().serializeToString(root);
          },
          set: function(markup) {
            setSVGInnerHTML(root, markup);
          }
        });
      } catch (_) {}
      window.__clawdNativeSetSVGInnerHTML = setSVGInnerHTML;
    })();
  """

  private static func cacheBustedURL(_ url: String, cacheBust: String) -> String {
    "\(url)\(url.contains("?") ? "&" : "?")_t=\(cacheBust)"
  }

  private static func escapedCacheBustedURL(_ url: String, cacheBust: String) -> String {
    cacheBustedURL(url, cacheBust: cacheBust)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func eyeTrackingConfigJSON(_ asset: ThemeAsset) -> String {
    let eye = asset.manifest.eyeTracking
    let ids: [String: String] = [
      "eyes": eye?.ids?.eyes ?? "eyes-js",
      "body": eye?.ids?.body ?? "body-js",
      "shadow": eye?.ids?.shadow ?? "shadow-js",
      "dozeEyes": eye?.ids?.dozeEyes ?? "eyes-doze"
    ]
    let layers: [String: Any]? = eye?.trackingLayers?.reduce(into: [:]) { out, entry in
      var layer: [String: Any] = [:]
      if let ids = entry.value.ids { layer["ids"] = ids }
      if let classes = entry.value.classes { layer["classes"] = classes }
      layer["maxOffset"] = entry.value.maxOffset ?? 10
      layer["ease"] = entry.value.ease ?? 0.15
      out[entry.key] = layer
    }
    var config: [String: Any] = [
      "ids": ids,
      "bodyScale": eye?.bodyScale ?? 0.33,
      "shadowStretch": eye?.shadowStretch ?? 0.15,
      "shadowShift": eye?.shadowShift ?? 0.3,
      "themeMaxOffset": eye?.maxOffset ?? 20
    ]
    if let layers {
      config["trackingLayers"] = layers
    }
    guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  private static let eyeTrackingScript = """
    (function() {
      const cfg = window.__clawdNativeEyeConfig || {};
      let wrappersReady = false;
      let trackingWrappers = null;

      function svgRoot() {
        const frame = document.getElementById('asset');
        if (!frame) return null;
        if (frame.tagName && frame.tagName.toLowerCase() === 'svg') return frame;
        return frame.querySelector ? frame.querySelector('svg') : null;
      }

      function q(value, unit) {
        const factor = unit || 2;
        return Math.round(value * factor) / factor;
      }

      function setTranslate(el, x, y) {
        if (!el) return false;
        el.setAttribute('transform', 'translate(' + q(x, 2) + ',' + q(y, 2) + ')');
        return true;
      }

      function applySingle(dx, dy) {
        const root = svgRoot();
        if (!root) return false;
        const ids = cfg.ids || {};
        const eyes = root.getElementById ? root.getElementById(ids.eyes || 'eyes-js') : null;
        const dozeEyes = root.getElementById ? root.getElementById(ids.dozeEyes || 'eyes-doze') : null;
        const body = root.getElementById ? root.getElementById(ids.body || 'body-js') : null;
        const shadow = root.getElementById ? root.getElementById(ids.shadow || 'shadow-js') : null;
        let applied = false;
        applied = setTranslate(eyes || dozeEyes, dx, dy) || applied;
        const bdx = q(dx * (cfg.bodyScale == null ? 0.33 : cfg.bodyScale), 2);
        const bdy = q(dy * (cfg.bodyScale == null ? 0.33 : cfg.bodyScale), 2);
        applied = setTranslate(body, bdx, bdy) || applied;
        if (shadow) {
          const stretch = cfg.shadowStretch == null ? 0.15 : cfg.shadowStretch;
          const shift = cfg.shadowShift == null ? 0.3 : cfg.shadowShift;
          const scaleX = 1 + Math.abs(bdx) * stretch;
          const shiftX = q(bdx * shift, 2);
          shadow.setAttribute('transform', 'translate(' + shiftX + ',0) scale(' + scaleX + ',1)');
          applied = true;
        }
        return applied;
      }

      function wrapElement(root, el) {
        if (!el || !el.parentNode) return null;
        const parent = el.parentNode;
        if (parent.getAttribute && parent.getAttribute('data-clawd-native-tracking-wrapper') === '1') {
          return parent;
        }
        const wrapper = document.createElementNS('http://www.w3.org/2000/svg', 'g');
        wrapper.setAttribute('data-clawd-native-tracking-wrapper', '1');
        parent.insertBefore(wrapper, el);
        wrapper.appendChild(el);
        return wrapper;
      }

      function ensureLayerWrappers() {
        if (wrappersReady) return trackingWrappers;
        wrappersReady = true;
        const root = svgRoot();
        const layers = cfg.trackingLayers || null;
        if (!root || !layers) return null;
        trackingWrappers = {};
        for (const name of Object.keys(layers)) {
          const layer = layers[name] || {};
          const wrappers = [];
          for (const id of (layer.ids || [])) {
            const wrapper = wrapElement(root, root.getElementById ? root.getElementById(id) : null);
            if (wrapper) wrappers.push(wrapper);
          }
          for (const cls of (layer.classes || [])) {
            const matches = root.querySelectorAll ? root.querySelectorAll('.' + cls) : [];
            for (const el of matches) {
              const wrapper = wrapElement(root, el);
              if (wrapper) wrappers.push(wrapper);
            }
          }
          trackingWrappers[name] = {
            wrappers,
            maxOffset: layer.maxOffset || 10
          };
        }
        return trackingWrappers;
      }

      function applyLayered(dx, dy) {
        const layers = ensureLayerWrappers();
        if (!layers) return false;
        const themeMax = cfg.themeMaxOffset || 20;
        let applied = false;
        for (const layer of Object.values(layers)) {
          const scale = layer.maxOffset / themeMax;
          const x = q(dx * scale, 4);
          const y = q(dy * scale, 4);
          for (const wrapper of layer.wrappers) {
            wrapper.setAttribute('transform', 'translate(' + x + ',' + y + ')');
            applied = true;
          }
        }
        return applied;
      }

      window.clawdSetEye = function(dx, dy) {
        if (cfg.trackingLayers && applyLayered(dx, dy)) return true;
        if (applySingle(dx, dy)) return true;
        const asset = document.getElementById('asset');
        if (!asset) return false;
        asset.style.transform = 'translate(' + (dx * 0.25) + 'px,' + (dy * 0.25) + 'px)';
        return false;
      };

    })();
  """

  private static func objectScaleCSS(for asset: ThemeAsset) -> String {
    if let normalized = normalizedLayoutCSS(for: asset) {
      return normalized
    }

    let scale = asset.manifest.objectScale
    let widthRatio = scale?.widthRatio ?? 1.9
    let heightRatio = scale?.heightRatio ?? 1.3
    let offsetX = scale?.offsetX ?? -0.45
    let offsetY = scale?.offsetY ?? -0.25
    let safeFile = baseName(asset.fileName)
    let fileOffset = scale?.fileOffsets?[safeFile]
    let fileOffsetX = fileOffset?.x ?? 0
    let fileOffsetY = fileOffset?.y ?? 0
    if asset.fileName.lowercased().hasSuffix(".svg") {
      let bottom = scale?.objBottom ?? (1 - offsetY - heightRatio)
      return [
        "width: \(percent(widthRatio));",
        "height: \(percent(heightRatio));",
        "left: calc(\(percent(offsetX)) + \(px(fileOffsetX)));",
        "right: auto;",
        "top: auto;",
        "bottom: calc(\(percent(bottom)) + \(px(fileOffsetY)));"
      ].joined(separator: "\n          ")
    }
    let imgWidthRatio = scale?.imgWidthRatio ?? widthRatio
    let imgOffsetX = scale?.imgOffsetX ?? offsetX
    let imgBottom = scale?.imgBottom ?? 0.05
    let fileScale = scale?.fileScales?[safeFile] ?? 1
    return [
      "width: \(percent(imgWidthRatio * fileScale));",
      "height: auto;",
      "left: calc(\(percent(imgOffsetX)) + \(px(fileOffsetX)));",
      "right: auto;",
      "top: auto;",
      "bottom: calc(\(percent(imgBottom)) + \(px(fileOffsetY)));"
    ].joined(separator: "\n          ")
  }

  private static func normalizedLayoutCSS(for asset: ThemeAsset) -> String? {
    let file = baseName(asset.fileName)
    guard shouldUseNormalizedLayout(asset: asset, file: file),
          let layout = asset.manifest.layout,
          let contentBox = layout.contentBox,
          let viewBox = resolvedViewBox(for: asset, file: file)
    else { return nil }

    let scale = asset.manifest.objectScale
    let fileOffset = scale?.fileOffsets?[file]
    let fileOffsetX = fileOffset?.x ?? 0
    let fileOffsetY = fileOffset?.y ?? 0
    let fileScale = scale?.fileScales?[file] ?? 1
    let centerX = layout.centerX ?? (contentBox.x + contentBox.width / 2)
    let baselineY = layout.baselineY ?? (contentBox.y + contentBox.height)
    let unitRatio = ((layout.visibleHeightRatio ?? 0.58) * fileScale) / max(contentBox.height, 0.0001)
    let widthRatio = viewBox.width * unitRatio
    let heightRatio = viewBox.height * unitRatio
    let leftRatio = (layout.centerXRatio ?? 0.5) - ((centerX - viewBox.x) * unitRatio)
    let bottomRatio = (layout.baselineBottomRatio ?? 0.05) - ((viewBox.y + viewBox.height - baselineY) * unitRatio)

    if asset.fileName.lowercased().hasSuffix(".svg") {
      return [
        "width: \(percent(widthRatio));",
        "height: \(percent(heightRatio));",
        "left: calc(\(percent(leftRatio)) + \(px(fileOffsetX)));",
        "right: auto;",
        "top: auto;",
        "bottom: calc(\(percent(bottomRatio)) + \(px(fileOffsetY)));"
      ].joined(separator: "\n          ")
    }
    return [
      "width: \(percent(widthRatio));",
      "height: auto;",
      "left: calc(\(percent(leftRatio)) + \(px(fileOffsetX)));",
      "right: auto;",
      "top: auto;",
      "bottom: calc(\(percent(bottomRatio)) + \(px(fileOffsetY)));"
    ].joined(separator: "\n          ")
  }

  private static func shouldUseNormalizedLayout(asset: ThemeAsset, file: String) -> Bool {
    guard asset.manifest.layout?.contentBox != nil else { return false }
    if hasRootViewBoxFileOverride(manifest: asset.manifest, file: file) {
      return true
    }
    if asset.state.rawValue.hasPrefix("mini-") || file.hasPrefix("mini-") {
      return false
    }
    return true
  }

  private static func resolvedViewBox(for asset: ThemeAsset, file: String) -> ThemeManifest.ViewBox? {
    if let fileViewBox = asset.manifest.fileViewBoxes?[file] {
      return fileViewBox
    }
    if asset.state.rawValue.hasPrefix("mini-") {
      return asset.manifest.miniMode?.viewBox ?? asset.manifest.viewBox
    }
    return asset.manifest.viewBox
  }

  private static func hasRootViewBoxFileOverride(manifest: ThemeManifest, file: String) -> Bool {
    guard let fileViewBox = manifest.fileViewBoxes?[file],
          let rootViewBox = manifest.viewBox
    else { return false }
    return viewBoxEquals(fileViewBox, rootViewBox)
  }

  private static func viewBoxEquals(_ lhs: ThemeManifest.ViewBox, _ rhs: ThemeManifest.ViewBox) -> Bool {
    abs(lhs.x - rhs.x) < 0.0001
      && abs(lhs.y - rhs.y) < 0.0001
      && abs(lhs.width - rhs.width) < 0.0001
      && abs(lhs.height - rhs.height) < 0.0001
  }

  private static func percent(_ value: Double) -> String {
    "\(formatNumber(value * 100))%"
  }

  private static func px(_ value: Double) -> String {
    "\(formatNumber(value))px"
  }

  private static func formatNumber(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    let rounded = (value * 1000).rounded() / 1000
    if rounded.rounded() == rounded {
      return String(Int(rounded))
    }
    return String(rounded)
  }

  private static func baseName(_ value: String) -> String {
    (value as NSString).lastPathComponent
  }
}
