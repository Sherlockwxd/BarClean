import Foundation

@objc private protocol MenuBarAssertion: AnyObject {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

@MainActor
final class VisibilityBridge {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configurationSelector = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")

    private let classes: (assertion: NSObject.Type, configuration: NSObject.Type)?
    private var current: MenuBarAssertion?
    private var pending: MenuBarAssertion?

    init() {
        // 私有接口可能随系统更新消失，先检查类和方法，避免向不存在的方法发送消息。
        guard dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let assertion = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let configuration = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              assertion.instancesRespond(to: #selector(MenuBarAssertion.activate(with:completionHandler:))),
              assertion.instancesRespond(to: #selector(MenuBarAssertion.invalidate)),
              configuration.instancesRespond(to: Self.configurationSelector) else {
            classes = nil
            return
        }
        classes = (assertion, configuration)
    }

    var isAvailable: Bool { classes != nil }

    func apply(allowedBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        guard let classes else {
            completion(BridgeError.unavailable)
            return
        }

        // 保留系统菜单项编号的宽松范围，避免时钟、电池等系统图标被意外收起。
        let systemItems = (0..<64).map(NSNumber.init(value:)) as NSArray
        let allocated = (classes.configuration as AnyObject)
            .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        guard let configuration = allocated?
            .perform(Self.configurationSelector, with: systemItems, with: allowedBundleIDs as NSArray)?
            .takeRetainedValue() else {
            completion(BridgeError.configuration)
            return
        }

        pending?.invalidate()
        let next = unsafeBitCast(classes.assertion.init(), to: MenuBarAssertion.self)
        pending = next
        next.activate(with: configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pending === next else { return }
                self.pending = nil
                if let error {
                    next.invalidate()
                    completion(error)
                } else {
                    self.current?.invalidate()
                    self.current = next
                    completion(nil)
                }
            }
        }
    }

    func release() {
        pending?.invalidate()
        pending = nil
        current?.invalidate()
        current = nil
    }
}

private enum BridgeError: LocalizedError {
    case unavailable
    case configuration

    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前系统未提供可用的菜单栏限制接口"
        case .configuration: return "无法创建菜单栏限制配置"
        }
    }
}
