#if DEBUG && canImport(UIKit)
import UIKit
import InspectCore

@MainActor
public enum HierarchyScanner {
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
                captureScreenshots: captureScreenshots
            )
        }
    }

    static func buildNode(
        from view: UIView,
        window: UIWindow,
        windowCapture: (CGImage, CGFloat)?,
        captureScreenshots: Bool
    ) -> ViewNode {
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

        // UIView children
        var children = view.subviews.map {
            buildNode(
                from: $0,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots
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
                captureScreenshots: captureScreenshots
            ))
        }

        let accID = view.accessibilityIdentifier?.isEmpty == false ? view.accessibilityIdentifier : nil
        let accLabel: String? = {
            let label = view.accessibilityLabel
            return (label?.isEmpty == false) ? label : nil
        }()

        let borderColor = view.layer.borderColor.flatMap { UIColor(cgColor: $0) }.flatMap(RGBAColor.init(uiColor:))

        let isEnabled: Bool? = (view as? UIControl)?.isEnabled

        let properties = Self.extractProperties(from: view)

        let constraints = Self.extractConstraints(from: view)

        // Absolute AABB in window coordinates — used for culling and as a
        // fallback for clients that don't do the recursive origin walk.
        let windowFrame = view.convert(view.bounds, to: window)

        // Four corners of bounds in window space — preserves enough 2D
        // affine information for a future renderer to rotate/skew planes.
        let b = view.bounds
        let cornersInWindow: [CGPoint] = [
            view.convert(CGPoint(x: b.minX, y: b.minY), to: window),
            view.convert(CGPoint(x: b.maxX, y: b.minY), to: window),
            view.convert(CGPoint(x: b.minX, y: b.maxY), to: window),
            view.convert(CGPoint(x: b.maxX, y: b.maxY), to: window),
        ]

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
        captureScreenshots: Bool
    ) -> ViewNode {
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

        // Recurse into sublayers
        let children = (layer.sublayers ?? []).map {
            buildNode(
                fromLayer: $0,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots
            )
        }

        let backgroundColor = layer.backgroundColor
            .flatMap { UIColor(cgColor: $0) }
            .flatMap(RGBAColor.init(uiColor:))
        let borderColor = layer.borderColor
            .flatMap { UIColor(cgColor: $0) }
            .flatMap(RGBAColor.init(uiColor:))

        let properties = Self.extractLayerProperties(from: layer)

        let nodeIdent = UUID()

        // Absolute AABB in window coordinates (for culling / fallback).
        let windowFrame = layer.convert(layer.bounds, to: window.layer)

        let b = layer.bounds
        let cornersInWindow: [CGPoint] = [
            layer.convert(CGPoint(x: b.minX, y: b.minY), to: window.layer),
            layer.convert(CGPoint(x: b.maxX, y: b.minY), to: window.layer),
            layer.convert(CGPoint(x: b.minX, y: b.maxY), to: window.layer),
            layer.convert(CGPoint(x: b.maxX, y: b.maxY), to: window.layer),
        ]

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
            props["fontSize"] = String(format: "%g", textLayer.fontSize)
            if let fg = textLayer.foregroundColor {
                props["foregroundColor"] = describeColor(UIColor(cgColor: fg))
            }
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
        if let id = guide.identifier, !id.isEmpty { return id }
        return "layoutGuide"
    }

    // MARK: - Type-specific property extraction

    private static func extractProperties(from view: UIView) -> [String: String] {
        var props: [String: String] = [:]

        if let label = view as? UILabel {
            if let text = label.text { props["text"] = text }
            props["font"] = "\(label.font.fontName) \(label.font.pointSize)"
            if let textColor = label.textColor { props["textColor"] = describeColor(textColor) }
            props["numberOfLines"] = "\(label.numberOfLines)"
            props["textAlignment"] = describeTextAlignment(label.textAlignment)
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
            props["titleColor"] = describeColor(button.currentTitleColor)
            if let titleFont = button.titleLabel?.font {
                props["titleFont"] = "\(titleFont.fontName) \(titleFont.pointSize)"
            }
            props["isSelected"] = "\(button.isSelected)"
        }

        if let textField = view as? UITextField {
            if let text = textField.text, !text.isEmpty { props["text"] = text }
            if let placeholder = textField.placeholder { props["placeholder"] = placeholder }
            if let font = textField.font { props["font"] = "\(font.fontName) \(font.pointSize)" }
            if let textColor = textField.textColor { props["textColor"] = describeColor(textColor) }
            props["textAlignment"] = describeTextAlignment(textField.textAlignment)
        }

        if let textView = view as? UITextView {
            if let text = textView.text, !text.isEmpty { props["text"] = text }
            if let font = textView.font { props["font"] = "\(font.fontName) \(font.pointSize)" }
            if let textColor = textView.textColor { props["textColor"] = describeColor(textColor) }
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
}
#endif
