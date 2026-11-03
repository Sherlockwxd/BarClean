import AppKit

enum StatusIconStyle: String, CaseIterable {
    case standard
    case arrows
    case chevrons
    case dots

    var title: String {
        switch self {
        case .standard: return "标准"
        case .arrows: return "箭头"
        case .chevrons: return "尖括号"
        case .dots: return "省略号"
        }
    }

    func image(collapsed: Bool) -> NSImage? {
        let symbolName: String
        switch self {
        case .standard:
            symbolName = collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
        case .arrows:
            symbolName = collapsed ? "arrowshape.left.fill" : "arrowshape.right.fill"
        case .chevrons:
            symbolName = collapsed ? "chevron.left" : "chevron.right"
        case .dots:
            symbolName = collapsed ? "ellipsis" : "ellipsis.circle.fill"
        }
        let description = collapsed ? "展开隐藏图标" : "收起隐藏图标"
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) else {
            return nil
        }
        symbol.isTemplate = true
        return symbol
    }
}
