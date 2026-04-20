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

        let children = view.subviews.map {
            buildNode(
                from: $0,
                window: window,
                windowCapture: windowCapture,
                captureScreenshots: captureScreenshots
            )
        }

        let accID = view.accessibilityIdentifier?.isEmpty == false ? view.accessibilityIdentifier : nil
        let accLabel: String? = {
            let label = view.accessibilityLabel
            return (label?.isEmpty == false) ? label : nil
        }()

        let borderColor = view.layer.borderColor.flatMap { UIColor(cgColor: $0) }.flatMap(RGBAColor.init(uiColor:))

        let isEnabled: Bool? = (view as? UIControl)?.isEnabled

        let properties = Self.extractProperties(from: view)

        let nodeIdent = UUID()
        ViewIdentRegistry.shared.register(view: view, ident: nodeIdent)

        return ViewNode(
            ident: nodeIdent,
            className: String(describing: type(of: view)),
            frame: view.frame,
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
            screenshot: groupScreenshot,
            soloScreenshot: soloScreenshot,
            children: children
        )
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
