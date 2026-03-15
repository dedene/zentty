import CoreGraphics

enum ShellMetrics {
    static let outerInset: CGFloat = 6
    static let shellGap: CGFloat = 10

    static let outerWindowRadius: CGFloat = 28
    static let contentShellRadius: CGFloat = outerWindowRadius - outerInset
    static let sidebarRadius: CGFloat = contentShellRadius
    static let paneRadius: CGFloat = contentShellRadius - outerInset
    static let rowRadius: CGFloat = paneRadius
    static let pillRadius: CGFloat = rowRadius - 2

    static let headerHeight: CGFloat = 48
    static let headerHorizontalInset: CGFloat = 14
    static let contentPadding: CGFloat = 0

    static let sidebarContentInset: CGFloat = 10
    static let sidebarTopInset: CGFloat = 58
    static let sidebarBottomInset: CGFloat = 10
    static let sidebarRowHeight: CGFloat = 54
    static let footerHeight: CGFloat = 36

    static let trafficLightLeadingInset: CGFloat = 14
    static let trafficLightTopInset: CGFloat = 14
    static let trafficLightSpacing: CGFloat = 6
}
