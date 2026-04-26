#if (DEBUG || SWIFT_INSPECTOR_ENABLED) && canImport(UIKit)
import UIKit
import InspectCore

@MainActor
public enum HierarchyScanner {
    /// Hard cap on recursion depth. Real UIKit hierarchies very rarely exceed
    /// ~50 levels; anything past this is almost certainly pathological (e.g.
    /// a custom container that re-parents itself), and recursing further
    /// risks a stack overflow inside `view.convert` / `layer.render`.
    /// When the cap is hit we return the current node with `children = []`
    /// and a `_truncated` marker in `properties` so the client can surface it.
    public static let maxDepth = 200

    public static func captureAllWindows(captureScreenshots: Bool = true) -> [ViewNode] {
        ViewIdentRegistry.shared.clear()

        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }

        return windows.map { window in
            let windowCapture: (CGImage, CGFloat)?
            if captureScreenshots {
                windowCapture = ScreenshotCapture.captureWindow(window)
            } else {
                windowCapture = nil
            }
            return buildNode(
                from: window,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots,
                depth: 0
            )
        }
    }

    /// Affine that maps a point in `layer`'s bounds coords to its parent's
    /// bounds coords. Mirrors CoreAnimation: `T(position) ∘ R(transform) ∘ T(-anchorInBounds)`.
    /// 3D transforms degrade to their affine projection (same as `view.convert` for
    /// non-perspective cases).
    private static func layerToParentTransform(_ layer: CALayer) -> CGAffineTransform {
        let bounds = layer.bounds
        let position = layer.position
        let anchor = layer.anchorPoint
        let xform = layer.affineTransform()
        let anchorX = bounds.origin.x + bounds.size.width * anchor.x
        let anchorY = bounds.origin.y + bounds.size.height * anchor.y
        return CGAffineTransform(translationX: -anchorX, y: -anchorY)
            .concatenating(xform)
            .concatenating(CGAffineTransform(translationX: position.x, y: position.y))
    }

    /// One-time seed used when `buildNode` is invoked on a non-window root
    /// (e.g. tests). Walks ancestors once; descendants then reuse the chain.
    private static func layerChainToWindow(_ layer: CALayer, window: UIWindow) -> CGAffineTransform {
        var matrix: CGAffineTransform = .identity
        var current: CALayer? = layer
        while let l = current, l !== window.layer {
            matrix = matrix.concatenating(layerToParentTransform(l))
            current = l.superlayer
        }
        return matrix
    }

    private static func aabb(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func buildNode(
        from view: UIView,
        window: UIWindow,
        windowCapture: (CGImage, CGFloat)?,
        captureScreenshots: Bool,
        depth: Int = 0,
        // Affine transform mapping the parent's bounds coords into window
        // coords. Composed once per recursion step so we never need to walk
        // the ancestor chain via `view.convert(_:to:)` per node.
        // `nil` means "this is a root call — seed by walking ancestors once."
        parentToWindow: CGAffineTransform? = nil
    ) -> ViewNode {
        let selfToWindow: CGAffineTransform
        if let pt = parentToWindow {
            selfToWindow = layerToParentTransform(view.layer).concatenating(pt)
        } else {
            selfToWindow = layerChainToWindow(view.layer, window: window)
        }

        let groupScreenshot: Data?
        let soloScreenshot: Data?

        if captureScreenshots {
            // Group screenshot: crop from window capture (includes subviews)
            if let (windowImage, scale) = windowCapture {
                groupScreenshot = ScreenshotCapture.crop(
                    from: windowImage,
                    scale: scale,
                    view: view,
                    window: window
                )
            } else {
                groupScreenshot = nil
            }

            // Solo screenshot: this layer only, sublayers hidden
            soloScreenshot = ScreenshotCapture.soloScreenshot(of: view)
        } else {
            groupScreenshot = nil
            soloScreenshot = nil
        }

        // Register this view's ident BEFORE recursing so constraint anchors
        // on descendants can resolve UUIDs of their ancestors.
        let nodeIdent = UUID()
        ViewIdentRegistry.shared.register(view: view, ident: nodeIdent)

        // Collect backing layers of subviews so we can skip them when scanning sublayers
        let subviewLayerIdentifiers = Set(view.subviews.map { ObjectIdentifier($0.layer) })

        var children: [ViewNode] = []
        var truncated = false

        if depth >= maxDepth {
            // Drop children entirely; mark via properties so the client can hint
            truncated = (view.subviews.isEmpty == false)
                || ((view.layer.sublayers ?? []).contains { !subviewLayerIdentifiers.contains(ObjectIdentifier($0)) })
        } else {
            // UIView children
            children = view.subviews.map {
                buildNode(
                    from: $0,
                    window: window,
                    windowCapture: windowCapture,
                    captureScreenshots: captureScreenshots,
                    depth: depth + 1,
                    parentToWindow: selfToWindow
                )
            }

            // CALayer children (sublayers not backed by any subview)
            for sublayer in view.layer.sublayers ?? [] {
                if subviewLayerIdentifiers.contains(ObjectIdentifier(sublayer)) {
                    continue
                }
                children.append(buildNode(
                    fromLayer: sublayer,
                    window: window,
                    windowCapture: windowCapture,
                    captureScreenshots: captureScreenshots,
                    depth: depth + 1,
                    parentToWindow: selfToWindow
                ))
            }
        }

        let accID = view.accessibilityIdentifier?.isEmpty == false ? view.accessibilityIdentifier : nil
        let accLabel: String? = {
            let label = view.accessibilityLabel
            return (label?.isEmpty == false) ? label : nil
        }()

        let borderColor = view.layer.borderColor.flatMap { UIColor(cgColor: $0) }.flatMap(RGBAColor.init(uiColor:))

        let isEnabled: Bool? = (view as? UIControl)?.isEnabled

        var properties = Self.extractProperties(from: view)
        if truncated {
            properties["_truncated"] = "depth>=\(maxDepth)"
        }

        let typography = Self.extractTypography(from: view)

        let constraints = Self.extractConstraints(from: view)

        // Four corners of bounds in window space — preserves enough 2D
        // affine information for a future renderer to rotate/skew planes.
        let b = view.bounds
        let cornersInWindow: [CGPoint] = [
            CGPoint(x: b.minX, y: b.minY).applying(selfToWindow),
            CGPoint(x: b.maxX, y: b.minY).applying(selfToWindow),
            CGPoint(x: b.minX, y: b.maxY).applying(selfToWindow),
            CGPoint(x: b.maxX, y: b.maxY).applying(selfToWindow),
        ]

        // Absolute AABB in window coordinates — derived from the corners
        // we just computed (matches what `view.convert(rect:to:)` returns).
        let windowFrame = aabb(of: cornersInWindow)

        return ViewNode(
            ident: nodeIdent,
            className: String(describing: type(of: view)),
            frame: view.frame,
            windowFrame: windowFrame,
            boundsOrigin: view.bounds.origin,
            boundsSize: view.bounds.size,
            cornersInWindow: cornersInWindow,
            isHidden: view.isHidden,
            alpha: Double(view.alpha),
            backgroundColor: view.backgroundColor.flatMap(RGBAColor.init(uiColor:)),
            accessibilityIdentifier: accID,
            accessibilityLabel: accLabel,
            clipsToBounds: view.clipsToBounds,
            cornerRadius: Double(view.layer.cornerRadius),
            borderWidth: Double(view.layer.borderWidth),
            borderColor: borderColor,
            contentMode: view.contentMode.rawValue,
            isUserInteractionEnabled: view.isUserInteractionEnabled,
            isEnabled: isEnabled,
            properties: properties,
            typography: typography,
            constraints: constraints,
            screenshot: groupScreenshot,
            soloScreenshot: soloScreenshot,
            children: children
        )
    }
    // MARK: - CALayer node building

    static func buildNode(
        fromLayer layer: CALayer,
        window: UIWindow,
        windowCapture: (CGImage, CGFloat)?,
        captureScreenshots: Bool,
        depth: Int = 0,
        parentToWindow: CGAffineTransform? = nil
    ) -> ViewNode {
        let selfToWindow: CGAffineTransform
        if let pt = parentToWindow {
            selfToWindow = layerToParentTransform(layer).concatenating(pt)
        } else {
            selfToWindow = layerChainToWindow(layer, window: window)
        }

        let groupScreenshot: Data?
        let soloScreenshot: Data?

        if captureScreenshots {
            if let (windowImage, scale) = windowCapture {
                groupScreenshot = ScreenshotCapture.cropLayer(
                    from: windowImage,
                    scale: scale,
                    layer: layer,
                    window: window
                )
            } else {
                groupScreenshot = nil
            }
            soloScreenshot = ScreenshotCapture.soloScreenshotOfLayer(layer)
        } else {
            groupScreenshot = nil
            soloScreenshot = nil
        }

        // Recurse into sublayers (respecting depth cap)
        let children: [ViewNode]
        let truncated: Bool
        if depth >= maxDepth {
            children = []
            truncated = (layer.sublayers ?? []).isEmpty == false
        } else {
            children = (layer.sublayers ?? []).map {
                buildNode(
                    fromLayer: $0,
                    window: window,
                    windowCapture: windowCapture,
                    captureScreenshots: captureScreenshots,
                    depth: depth + 1,
                    parentToWindow: selfToWindow
                )
            }
            truncated = false
        }

        let backgroundColor = layer.backgroundColor
            .flatMap { UIColor(cgColor: $0) }
            .flatMap(RGBAColor.init(uiColor:))
        let borderColor = layer.borderColor
            .flatMap { UIColor(cgColor: $0) }
            .flatMap(RGBAColor.init(uiColor:))

        var properties = Self.extractLayerProperties(from: layer)
        if truncated {
            properties["_truncated"] = "depth>=\(maxDepth)"
        }

        let typography = Self.extractTypography(fromLayer: layer)

        let nodeIdent = UUID()

        let b = layer.bounds
        let cornersInWindow: [CGPoint] = [
            CGPoint(x: b.minX, y: b.minY).applying(selfToWindow),
            CGPoint(x: b.maxX, y: b.minY).applying(selfToWindow),
            CGPoint(x: b.minX, y: b.maxY).applying(selfToWindow),
            CGPoint(x: b.maxX, y: b.maxY).applying(selfToWindow),
        ]
        let windowFrame = aabb(of: cornersInWindow)

        return ViewNode(
            ident: nodeIdent,
            className: String(describing: type(of: layer)),
            frame: layer.frame,
            windowFrame: windowFrame,
            boundsOrigin: layer.bounds.origin,
            boundsSize: layer.bounds.size,
            cornersInWindow: cornersInWindow,
            isHidden: layer.isHidden,
            alpha: Double(layer.opacity),
            backgroundColor: backgroundColor,
            accessibilityIdentifier: nil,
            accessibilityLabel: nil,
            clipsToBounds: layer.masksToBounds,
            cornerRadius: Double(layer.cornerRadius),
            borderWidth: Double(layer.borderWidth),
            borderColor: borderColor,
            contentMode: nil,
            isUserInteractionEnabled: false,
            isEnabled: nil,
            properties: properties,
            typography: typography,
            screenshot: groupScreenshot,
            soloScreenshot: soloScreenshot,
            children: children
        )
    }

    private static func extractLayerProperties(from layer: CALayer) -> [String: String] {
        var props: [String: String] = [:]
        props["_kind"] = "CALayer"

        if let textLayer = layer as? CATextLayer {
            if let str = textLayer.string as? String {
                props["text"] = str
            } else if let attr = textLayer.string as? NSAttributedString {
                props["text"] = attr.string
            }
            // font / color captured in the structured Typography field
        }

        if let shapeLayer = layer as? CAShapeLayer {
            if let fillColor = shapeLayer.fillColor {
                props["fillColor"] = describeColor(UIColor(cgColor: fillColor))
            }
            if let strokeColor = shapeLayer.strokeColor {
                props["strokeColor"] = describeColor(UIColor(cgColor: strokeColor))
            }
            props["lineWidth"] = String(format: "%g", shapeLayer.lineWidth)
        }

        if let gradientLayer = layer as? CAGradientLayer {
            props["type"] = gradientLayer.type.rawValue
            if let colors = gradientLayer.colors as? [CGColor] {
                props["colorCount"] = "\(colors.count)"
            }
        }

        if layer.contents != nil {
            props["hasContents"] = "true"
        }

        return props
    }

    // MARK: - Auto Layout constraint extraction

    /// Collects the Auto Layout constraints owned by `view`. Each constraint
    /// is owned by the closest common ancestor of its two items, so walking
    /// the tree from the root and recording each view's `.constraints` gives
    /// full coverage without duplicates. Private system-internal constraint
    /// subclasses are filtered out.
    private static func extractConstraints(from view: UIView) -> [LayoutConstraint] {
        view.constraints.compactMap { constraint in
            let constraintClass = String(describing: type(of: constraint))
            // Skip UIKit-generated constraint subclasses — they describe
            // system layout (safe area, keyboard, etc.) or the implicit
            // frame translation that UIKit adds for views with
            // `translatesAutoresizingMaskIntoConstraints = true`. These
            // would drown out the developer's own rules (four implicit
            // constraints per legacy view).
            if constraintClass.hasPrefix("_")
                || constraintClass.hasPrefix("NSIB")
                || constraintClass == "NSAutoresizingMaskLayoutConstraint" {
                return nil
            }

            guard let first = makeAnchor(
                item: constraint.firstItem,
                attribute: constraint.firstAttribute
            ) else {
                return nil
            }

            let second: LayoutConstraint.Anchor? = {
                // `.notAnAttribute` (rawValue == 0) means there is no second
                // item (e.g. width/height constants). UIKit also returns
                // `firstItem` with a non-nil secondItem == nil occasionally;
                // treat both as absent.
                guard constraint.secondAttribute != .notAnAttribute else { return nil }
                return makeAnchor(
                    item: constraint.secondItem,
                    attribute: constraint.secondAttribute
                )
            }()

            return LayoutConstraint(
                identifier: constraint.identifier,
                first: first,
                second: second,
                relation: constraint.relation.rawValue,
                multiplier: Double(constraint.multiplier),
                constant: Double(constraint.constant),
                priority: constraint.priority.rawValue,
                isActive: constraint.isActive
            )
        }
    }

    private static func makeAnchor(
        item: AnyObject?,
        attribute: NSLayoutConstraint.Attribute
    ) -> LayoutConstraint.Anchor? {
        if let view = item as? UIView {
            return LayoutConstraint.Anchor(
                ownerID: ViewIdentRegistry.shared.ident(for: view),
                description: String(describing: type(of: view)),
                isLayoutGuide: false,
                attribute: attribute.rawValue
            )
        }
        if let guide = item as? UILayoutGuide {
            let ownerClass = guide.owningView.map { String(describing: type(of: $0)) } ?? "?"
            let guideName = guideIdentifier(guide)
            return LayoutConstraint.Anchor(
                ownerID: guide.owningView.flatMap { ViewIdentRegistry.shared.ident(for: $0) },
                description: "\(ownerClass).\(guideName)",
                isLayoutGuide: true,
                attribute: attribute.rawValue
            )
        }
        if item == nil {
            return nil
        }
        // Unknown item type (should be rare) — keep the constraint with a
        // descriptive name so the user still sees it.
        return LayoutConstraint.Anchor(
            ownerID: nil,
            description: String(describing: type(of: item!)),
            isLayoutGuide: false,
            attribute: attribute.rawValue
        )
    }

    private static func guideIdentifier(_ guide: UILayoutGuide) -> String {
        if guide === guide.owningView?.safeAreaLayoutGuide { return "safeAreaLayoutGuide" }
        if guide === guide.owningView?.layoutMarginsGuide { return "layoutMarginsGuide" }
        if guide === guide.owningView?.readableContentGuide { return "readableContentGuide" }
        if guide === guide.owningView?.keyboardLayoutGuide { return "keyboardLayoutGuide" }
        if !guide.identifier.isEmpty { return guide.identifier }
        return "layoutGuide"
    }

    // MARK: - Type-specific property extraction
    //
    // Font / text color / alignment / numberOfLines are intentionally NOT
    // recorded here — they live on the structured `Typography` field instead
    // so the client can render them as a proper typography section rather
    // than a key/value string grid.

    private static func extractProperties(from view: UIView) -> [String: String] {
        var props: [String: String] = [:]

        if let label = view as? UILabel {
            if let text = label.text { props["text"] = text }
            props["lineBreakMode"] = describeLineBreakMode(label.lineBreakMode)
        }

        if let imageView = view as? UIImageView {
            if let image = imageView.image {
                props["imageSize"] = "\(Int(image.size.width))x\(Int(image.size.height))"
                props["imageScale"] = String(format: "%.0f", image.scale)
            }
            props["isHighlighted"] = "\(imageView.isHighlighted)"
        }

        if let button = view as? UIButton {
            if let title = button.currentTitle { props["title"] = title }
            props["isSelected"] = "\(button.isSelected)"
        }

        if let textField = view as? UITextField {
            if let text = textField.text, !text.isEmpty { props["text"] = text }
            if let placeholder = textField.placeholder { props["placeholder"] = placeholder }
        }

        if let textView = view as? UITextView {
            if let text = textView.text, !text.isEmpty { props["text"] = text }
            props["isEditable"] = "\(textView.isEditable)"
            props["isSelectable"] = "\(textView.isSelectable)"
        }

        if let scrollView = view as? UIScrollView {
            let cs = scrollView.contentSize
            props["contentSize"] = "\(String(format: "%g", cs.width))x\(String(format: "%g", cs.height))"
            let co = scrollView.contentOffset
            props["contentOffset"] = "(\(String(format: "%g", co.x)), \(String(format: "%g", co.y)))"
            let ci = scrollView.contentInset
            props["contentInset"] = "(\(String(format: "%g", ci.top)), \(String(format: "%g", ci.left)), \(String(format: "%g", ci.bottom)), \(String(format: "%g", ci.right)))"
            props["isScrollEnabled"] = "\(scrollView.isScrollEnabled)"
            props["isPagingEnabled"] = "\(scrollView.isPagingEnabled)"
            props["bounces"] = "\(scrollView.bounces)"
        }

        if let stackView = view as? UIStackView {
            props["axis"] = stackView.axis == .horizontal ? "horizontal" : "vertical"
            props["spacing"] = String(format: "%g", stackView.spacing)
            props["alignment"] = describeStackAlignment(stackView.alignment)
            props["distribution"] = describeStackDistribution(stackView.distribution)
        }

        return props
    }

    private static func describeColor(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%.2f, %.2f, %.2f, %.2f)", r, g, b, a)
    }

    private static func describeTextAlignment(_ alignment: NSTextAlignment) -> String {
        switch alignment {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case .justified: return "justified"
        case .natural: return "natural"
        @unknown default: return "unknown"
        }
    }

    private static func describeLineBreakMode(_ mode: NSLineBreakMode) -> String {
        switch mode {
        case .byWordWrapping: return "wordWrap"
        case .byCharWrapping: return "charWrap"
        case .byClipping: return "clipping"
        case .byTruncatingHead: return "truncHead"
        case .byTruncatingTail: return "truncTail"
        case .byTruncatingMiddle: return "truncMiddle"
        @unknown default: return "unknown"
        }
    }

    private static func describeStackAlignment(_ alignment: UIStackView.Alignment) -> String {
        switch alignment {
        case .fill: return "fill"
        case .leading: return "leading"
        case .top: return "top"
        case .firstBaseline: return "firstBaseline"
        case .center: return "center"
        case .trailing: return "trailing"
        case .bottom: return "bottom"
        case .lastBaseline: return "lastBaseline"
        @unknown default: return "unknown"
        }
    }

    private static func describeStackDistribution(_ distribution: UIStackView.Distribution) -> String {
        switch distribution {
        case .fill: return "fill"
        case .fillEqually: return "fillEqually"
        case .fillProportionally: return "fillProportionally"
        case .equalSpacing: return "equalSpacing"
        case .equalCentering: return "equalCentering"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Typography extraction

    /// Builds a `Typography` payload from the text-bearing view types we
    /// recognise. Returns nil for views that don't carry typography so the
    /// client's "Typography" section stays hidden on structural views.
    private static func extractTypography(from view: UIView) -> Typography? {
        if let label = view as? UILabel {
            return makeTypography(
                font: label.font,
                color: label.textColor,
                alignment: label.textAlignment,
                numberOfLines: label.numberOfLines
            )
        }
        if let button = view as? UIButton {
            guard let font = button.titleLabel?.font else { return nil }
            return makeTypography(
                font: font,
                color: button.currentTitleColor,
                alignment: button.titleLabel?.textAlignment,
                numberOfLines: button.titleLabel?.numberOfLines
            )
        }
        if let textField = view as? UITextField {
            guard let font = textField.font else { return nil }
            return makeTypography(
                font: font,
                color: textField.textColor,
                alignment: textField.textAlignment,
                numberOfLines: nil
            )
        }
        if let textView = view as? UITextView {
            guard let font = textView.font else { return nil }
            return makeTypography(
                font: font,
                color: textView.textColor,
                alignment: textView.textAlignment,
                numberOfLines: nil
            )
        }
        return nil
    }

    /// CATextLayer has its own font/size/color API that doesn't go through
    /// UIFont, so it needs a dedicated builder.
    private static func extractTypography(fromLayer layer: CALayer) -> Typography? {
        guard let textLayer = layer as? CATextLayer else { return nil }
        let pointSize = Double(textLayer.fontSize)
        let (name, family): (String, String?) = {
            if let font = textLayer.font as? UIFont {
                return (font.fontName, font.familyName)
            }
            if let ctFont = textLayer.font {
                // CFTypeRef branch — CATextLayer.font can also be
                // CTFontRef / CGFontRef / String depending on how it was set.
                let typeID = CFGetTypeID(ctFont as CFTypeRef)
                if typeID == CTFontGetTypeID() {
                    let ct = ctFont as! CTFont
                    return (CTFontCopyPostScriptName(ct) as String,
                            CTFontCopyFamilyName(ct) as String)
                }
                if typeID == CGFont.typeID {
                    let cg = ctFont as! CGFont
                    return ((cg.postScriptName as String?) ?? "CGFont", nil)
                }
                if let name = ctFont as? String {
                    return (name, nil)
                }
            }
            return ("Helvetica", nil)
        }()
        let color = textLayer.foregroundColor.flatMap { UIColor(cgColor: $0) }
        return Typography(
            fontName: name,
            familyName: family,
            pointSize: pointSize,
            weight: nil,
            weightName: nil,
            isBold: false,
            isItalic: false,
            textColor: color.flatMap(RGBAColor.init(uiColor:)),
            alignment: describeCATextAlignment(textLayer.alignmentMode),
            numberOfLines: nil,
            lineHeight: nil,
            ascender: nil,
            descender: nil
        )
    }

    private static func makeTypography(
        font: UIFont,
        color: UIColor?,
        alignment: NSTextAlignment?,
        numberOfLines: Int?
    ) -> Typography {
        let traits = font.fontDescriptor.symbolicTraits
        let weightValue = fontWeightValue(for: font)
        return Typography(
            fontName: font.fontName,
            familyName: font.familyName,
            pointSize: Double(font.pointSize),
            weight: weightValue,
            weightName: weightValue.flatMap(weightName(for:)),
            isBold: traits.contains(.traitBold),
            isItalic: traits.contains(.traitItalic),
            textColor: color.flatMap(RGBAColor.init(uiColor:)),
            alignment: alignment.map(describeTextAlignment),
            numberOfLines: numberOfLines,
            lineHeight: Double(font.lineHeight),
            ascender: Double(font.ascender),
            descender: Double(font.descender)
        )
    }

    /// Extracts the `UIFont.Weight` raw value from the font descriptor's
    /// traits dictionary. Returns nil for fonts without a standard weight
    /// trait (rare; happens for some custom fonts).
    private static func fontWeightValue(for font: UIFont) -> Double? {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        guard let number = traits?[.weight] as? NSNumber else { return nil }
        return number.doubleValue
    }

    private static let weightAnchors: [(Double, String)] = [
        (UIFont.Weight.ultraLight.rawValue, "ultraLight"),
        (UIFont.Weight.thin.rawValue, "thin"),
        (UIFont.Weight.light.rawValue, "light"),
        (UIFont.Weight.regular.rawValue, "regular"),
        (UIFont.Weight.medium.rawValue, "medium"),
        (UIFont.Weight.semibold.rawValue, "semibold"),
        (UIFont.Weight.bold.rawValue, "bold"),
        (UIFont.Weight.heavy.rawValue, "heavy"),
        (UIFont.Weight.black.rawValue, "black"),
    ]

    /// Maps a raw weight value to a human-readable name. Uses the standard
    /// UIFont.Weight anchor values with a tolerance so slight variations
    /// still snap to the nearest named weight.
    private static func weightName(for value: Double) -> String? {
        let closest = weightAnchors.min { abs($0.0 - value) < abs($1.0 - value) }
        if let closest, abs(closest.0 - value) < 0.05 {
            return closest.1
        }
        return nil
    }

    private static func describeCATextAlignment(_ mode: CATextLayerAlignmentMode) -> String {
        switch mode {
        case .left: return "left"
        case .right: return "right"
        case .center: return "center"
        case .justified: return "justified"
        case .natural: return "natural"
        default: return "natural"
        }
    }
}
#endif
