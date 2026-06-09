import AppKit

final class ScreenSelectionController {
    private var windows: [ScreenSelectionWindow] = []
    private var escapeMonitor: Any?
    private var didPushCursor = false
    private var didComplete = false
    private let onImage: (CGImage) -> Void
    private let onCancel: (ScreenSelectionCancelReason) -> Void

    init(onImage: @escaping (CGImage) -> Void, onCancel: @escaping (ScreenSelectionCancelReason) -> Void) {
        self.onImage = onImage
        self.onCancel = onCancel
    }

    deinit {
        releaseWindows()
    }

    func begin() {
        didComplete = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        pushCursor()
        installEscapeMonitor()

        windows = NSScreen.screens.compactMap { screen in
            guard let window = ScreenSelectionWindow(screen: screen) else { return nil }
            window.selectionView.onComplete = { [weak self, weak window] rect in
                guard let self, let window else { return }
                self.finish(window: window, selection: rect)
            }
            window.selectionView.onCancel = { [weak self] in
                self?.cancel()
            }
            window.orderFrontRegardless()
            return window
        }

        guard !windows.isEmpty else {
            cancel(reason: .captureFailed)
            return
        }

        if let targetWindow = windowUnderMouse() ?? windows.first {
            focus(targetWindow)
        }
    }

    private func finish(window: ScreenSelectionWindow, selection: CGRect) {
        guard !didComplete else { return }
        didComplete = true

        let standardizedSelection = selection.standardized
        let minimumSize = ScreenSelectionConstants.minimumSelectionSize
        guard standardizedSelection.width >= minimumSize.width, standardizedSelection.height >= minimumSize.height else {
            releaseWindows()
            onCancel(.tooSmall)
            return
        }

        hideWindows()
        guard let image = capture(metrics: window.metrics, selection: standardizedSelection) else {
            releaseWindows()
            onCancel(.captureFailed)
            return
        }
        releaseWindows()
        onImage(image)
    }

    private func cancel() {
        cancel(reason: .userCancelled)
    }

    private func cancel(reason: ScreenSelectionCancelReason) {
        guard !didComplete else { return }
        didComplete = true
        releaseWindows()
        onCancel(reason)
    }

    private func hideWindows() {
        windows.forEach { window in
            window.selectionView.onComplete = nil
            window.selectionView.onCancel = nil
            window.orderOut(nil)
        }
    }

    private func releaseWindows() {
        hideWindows()
        windows.removeAll()
        removeEscapeMonitor()
        popCursor()
    }

    private func capture(metrics: ScreenSelectionMetrics, selection: CGRect) -> CGImage? {
        guard let pixelRect = metrics.pixelRect(for: selection) else { return nil }
        DiagnosticLogger.log(
            "ocr.selection.capture display=\(metrics.displayID) scale=\(format(metrics.scaleX))x\(format(metrics.scaleY)) points=\(format(selection)) pixels=\(format(pixelRect))"
        )
        return CGDisplayCreateImage(metrics.displayID, rect: pixelRect)
    }

    private func windowUnderMouse() -> ScreenSelectionWindow? {
        let mouseLocation = NSEvent.mouseLocation
        return windows.first { window in
            window.targetScreen.frame.contains(mouseLocation)
        }
    }

    private func focus(_ window: ScreenSelectionWindow) {
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.selectionView)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func pushCursor() {
        guard !didPushCursor else { return }
        NSCursor.crosshair.push()
        didPushCursor = true
    }

    private func popCursor() {
        guard didPushCursor else { return }
        NSCursor.pop()
        didPushCursor = false
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func format(_ rect: CGRect) -> String {
        "\(format(rect.minX)),\(format(rect.minY)),\(format(rect.width))x\(format(rect.height))"
    }
}

enum ScreenSelectionCancelReason {
    case userCancelled
    case tooSmall
    case captureFailed
}

private enum ScreenSelectionConstants {
    static let minimumSelectionSize = CGSize(width: 20, height: 12)
    static let completionFeedbackDelay: TimeInterval = 0.08
}

private struct ScreenSelectionMetrics {
    let displayID: CGDirectDisplayID
    let pointSize: CGSize
    let pixelSize: CGSize
    let scaleX: CGFloat
    let scaleY: CGFloat

    init?(screen: NSScreen) {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let pointSize = screen.frame.size
        let pixelSize = CGSize(
            width: CGFloat(CGDisplayPixelsWide(displayID)),
            height: CGFloat(CGDisplayPixelsHigh(displayID))
        )

        guard pointSize.width > 0, pointSize.height > 0, pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }

        self.displayID = displayID
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        scaleX = pixelSize.width / pointSize.width
        scaleY = pixelSize.height / pointSize.height
    }

    var pointBounds: CGRect {
        CGRect(origin: .zero, size: pointSize)
    }

    var pixelBounds: CGRect {
        CGRect(origin: .zero, size: pixelSize)
    }

    func pixelRect(for selection: CGRect) -> CGRect? {
        let clampedSelection = selection.standardized.intersection(pointBounds)
        guard !clampedSelection.isNull, !clampedSelection.isEmpty else { return nil }

        let minX = floor(clampedSelection.minX * scaleX)
        let maxX = ceil(clampedSelection.maxX * scaleX)
        let minY = floor((pointSize.height - clampedSelection.maxY) * scaleY)
        let maxY = ceil((pointSize.height - clampedSelection.minY) * scaleY)
        let rect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ).intersection(pixelBounds).integral

        guard !rect.isNull, !rect.isEmpty, rect.width >= 1, rect.height >= 1 else {
            return nil
        }
        return rect
    }

    func pixelSize(for selection: CGRect) -> CGSize? {
        pixelRect(for: selection)?.size
    }

    func pixelSize(forPointSize pointSize: CGSize) -> CGSize {
        CGSize(
            width: ceil(pointSize.width * scaleX),
            height: ceil(pointSize.height * scaleY)
        )
    }
}

private final class ScreenSelectionWindow: NSWindow {
    let targetScreen: NSScreen
    let metrics: ScreenSelectionMetrics
    let selectionView = ScreenSelectionView()

    init?(screen: NSScreen) {
        guard let metrics = ScreenSelectionMetrics(screen: screen) else { return nil }
        targetScreen = screen
        self.metrics = metrics
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false
        level = .screenSaver
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
        selectionView.frame = NSRect(origin: .zero, size: metrics.pointSize)
        selectionView.autoresizingMask = [.width, .height]
        selectionView.metrics = metrics
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScreenSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var metrics: ScreenSelectionMetrics?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hoverPoint: CGPoint?
    private var isDragging = false
    private var isCompleting = false
    private var wasSelectionReady = false
    private let accentColor = NSColor.systemTeal

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBaseOverlay()

        guard let selectionRect else {
            drawCrosshair(at: hoverPoint)
            drawIdleHint(at: hoverPoint)
            return
        }

        let state = visualState(for: selectionRect)
        drawSelectionHole(selectionRect, state: state)
        drawCrosshair(at: currentPoint ?? hoverPoint)
        drawSelectionBorder(selectionRect, state: state)
        drawCornerGuides(in: selectionRect, state: state)
        drawHandles(in: selectionRect, state: state)
        drawSelectionHUD(selectionRect, state: state)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCompleting else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = clampedPoint(for: event)
        startPoint = point
        currentPoint = startPoint
        hoverPoint = point
        isDragging = true
        wasSelectionReady = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCompleting else { return }
        currentPoint = clampedPoint(for: event)
        hoverPoint = currentPoint
        updateReadinessFeedback()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCompleting else { return }
        currentPoint = clampedPoint(for: event)
        hoverPoint = currentPoint
        isDragging = false
        if let selectionRect {
            if isTooSmall(selectionRect) {
                onComplete?(selectionRect)
            } else {
                isCompleting = true
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + ScreenSelectionConstants.completionFeedbackDelay) { [weak self] in
                    guard let self, self.isCompleting else { return }
                    self.onComplete?(selectionRect)
                }
            }
        } else {
            onCancel?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = clampedPoint(for: event)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private var selectionRect: CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let x = min(startPoint.x, currentPoint.x)
        let y = min(startPoint.y, currentPoint.y)
        let width = abs(startPoint.x - currentPoint.x)
        let height = abs(startPoint.y - currentPoint.y)
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height).intersection(bounds)
    }

    private func drawBaseOverlay() {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
    }

    private func drawSelectionHole(_ rect: CGRect, state: SelectionVisualState) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        let overlay = NSBezierPath(rect: bounds)
        overlay.append(NSBezierPath(rect: rect))
        overlay.windingRule = .evenOdd
        overlay.fill()

        switch state {
        case .ready:
            NSColor.white.withAlphaComponent(0.04).setFill()
        case .tooSmall:
            NSColor.systemOrange.withAlphaComponent(0.08).setFill()
        case .completing:
            NSColor.systemGreen.withAlphaComponent(0.12).setFill()
        }
        rect.fill()
    }

    private func drawSelectionBorder(_ rect: CGRect, state: SelectionVisualState) {
        color(for: state).setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = state == .completing ? 3 : 2
        path.stroke()

        NSColor.white.withAlphaComponent(0.65).setStroke()
        let innerRect = rect.insetBy(dx: 1.5, dy: 1.5)
        guard innerRect.width > 0, innerRect.height > 0 else { return }
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: 3, yRadius: 3)
        innerPath.lineWidth = 1
        innerPath.stroke()
    }

    private func drawSelectionHUD(_ rect: CGRect, state: SelectionVisualState) {
        let title: String
        let subtitle: String
        let pixelDescription = pixelDescription(for: rect)

        switch state {
        case .ready:
            title = isDragging ? "松开开始 OCR" : "OCR 选区"
            subtitle = "\(pixelDescription) · Esc 取消"
        case .tooSmall:
            title = "再拖大一点"
            subtitle = "\(pixelDescription) · 至少 \(minimumPixelDescription())"
        case .completing:
            title = "正在截图"
            subtitle = "\(pixelDescription) · 准备 OCR"
        }
        drawPill(title: title, subtitle: subtitle, near: rect)
    }

    private func drawIdleHint(at point: CGPoint?) {
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let hintRect = CGRect(x: anchor.x - 132, y: anchor.y + 18, width: 264, height: 62)
            .clamped(to: bounds.insetBy(dx: 16, dy: 16))
        drawPill(
            title: "框选文字区域",
            subtitle: "拖拽选择 · Esc 取消",
            in: hintRect
        )
    }

    private func drawCrosshair(at point: CGPoint?) {
        guard let point else { return }
        NSColor.white.withAlphaComponent(0.36).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: bounds.minX, y: point.y))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y))
        path.move(to: NSPoint(x: point.x, y: bounds.minY))
        path.line(to: NSPoint(x: point.x, y: bounds.maxY))
        path.stroke()

        accentColor.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
    }

    private func drawCornerGuides(in rect: CGRect, state: SelectionVisualState) {
        guard rect.width >= 28, rect.height >= 28 else { return }
        color(for: state).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        let length = min(CGFloat(26), min(rect.width, rect.height) / 3)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.line(to: CGPoint(x: rect.minX, y: rect.minY))
        path.line(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.line(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.line(to: CGPoint(x: rect.minX, y: rect.maxY - length))

        path.stroke()
    }

    private func drawHandles(in rect: CGRect, state: SelectionVisualState) {
        guard rect.width >= 48, rect.height >= 36 else { return }
        color(for: state).setFill()
        let handleSize: CGFloat = 5
        let points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]

        for point in points {
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawPill(title: String, subtitle: String, near rect: CGRect) {
        let width = pillWidth(title: title, subtitle: subtitle)
        let height: CGFloat = 54
        var origin = CGPoint(x: rect.minX, y: rect.minY - height - 10)
        if origin.y < bounds.minY + 12 {
            origin.y = rect.maxY + 10
        }
        if origin.y + height > bounds.maxY - 12 {
            origin.y = bounds.maxY - height - 12
        }
        if origin.x + width > bounds.maxX - 12 {
            origin.x = bounds.maxX - width - 12
        }
        if origin.x < bounds.minX + 12 {
            origin.x = bounds.minX + 12
        }
        drawPill(title: title, subtitle: subtitle, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))
    }

    private func drawPill(title: String, subtitle: String, in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.74).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ]
        NSAttributedString(string: title, attributes: titleAttributes)
            .draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 28, width: rect.width - 28, height: 18))
        NSAttributedString(string: subtitle, attributes: subtitleAttributes)
            .draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 11, width: rect.width - 28, height: 15))
    }

    private func clampedPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).clamped(to: bounds)
    }

    private func updateReadinessFeedback() {
        let isReady = selectionRect.map { !isTooSmall($0) } ?? false
        if isReady, !wasSelectionReady {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        wasSelectionReady = isReady
    }

    private func isTooSmall(_ rect: CGRect) -> Bool {
        rect.width < ScreenSelectionConstants.minimumSelectionSize.width
            || rect.height < ScreenSelectionConstants.minimumSelectionSize.height
    }

    private func visualState(for rect: CGRect) -> SelectionVisualState {
        if isCompleting {
            return .completing
        }
        if isTooSmall(rect) {
            return .tooSmall
        }
        return .ready
    }

    private func color(for state: SelectionVisualState) -> NSColor {
        switch state {
        case .ready:
            return accentColor
        case .tooSmall:
            return .systemOrange
        case .completing:
            return .systemGreen
        }
    }

    private func pixelDescription(for rect: CGRect) -> String {
        let size = metrics?.pixelSize(for: rect) ?? CGSize(
            width: rect.width * (window?.screen?.backingScaleFactor ?? 1),
            height: rect.height * (window?.screen?.backingScaleFactor ?? 1)
        )
        return "\(Int(size.width)) x \(Int(size.height)) px"
    }

    private func minimumPixelDescription() -> String {
        let size = metrics?.pixelSize(forPointSize: ScreenSelectionConstants.minimumSelectionSize)
            ?? ScreenSelectionConstants.minimumSelectionSize
        return "\(Int(size.width)) x \(Int(size.height)) px"
    }

    private func pillWidth(title: String, subtitle: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ]).width
        let subtitleWidth = (subtitle as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular)
        ]).width
        let preferred = max(CGFloat(236), max(titleWidth, subtitleWidth) + 28)
        return min(preferred, max(CGFloat(180), bounds.width - 24))
    }
}

private enum SelectionVisualState {
    case ready
    case tooSmall
    case completing
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        var rect = self
        if rect.width > bounds.width {
            rect.size.width = bounds.width
            rect.origin.x = bounds.minX
        }
        if rect.height > bounds.height {
            rect.size.height = bounds.height
            rect.origin.y = bounds.minY
        }
        if rect.minX < bounds.minX {
            rect.origin.x = bounds.minX
        }
        if rect.minY < bounds.minY {
            rect.origin.y = bounds.minY
        }
        if rect.maxX > bounds.maxX {
            rect.origin.x = bounds.maxX - rect.width
        }
        if rect.maxY > bounds.maxY {
            rect.origin.y = bounds.maxY - rect.height
        }
        return rect
    }
}

private extension CGPoint {
    func clamped(to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(x, bounds.minX), bounds.maxX),
            y: min(max(y, bounds.minY), bounds.maxY)
        )
    }
}
