import AppKit
import Carbon

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
    static let edgeSnapDistance: CGFloat = 8
    static let handleHitSize: CGFloat = 18
    static let keyboardNudgeStep: CGFloat = 1
    static let keyboardLargeNudgeStep: CGFloat = 8
    static let magnifierSize = CGSize(width: 128, height: 96)
    static let magnifierContentInset: CGFloat = 8
    static let magnifierSourcePointSize = CGSize(width: 42, height: 30)
    static let lowOCRHeightWarningPixels: CGFloat = 28
    static let narrowOCRWidthWarningPixels: CGFloat = 90
    static let tallNarrowSelectionMinHeightPixels: CGFloat = 240
    static let tallNarrowSelectionAspectRatio: CGFloat = 4
    static let longSingleLineAspectRatio: CGFloat = 12
    static let largeSelectionWarningPixels: CGFloat = 2_800_000
}

private struct ScreenSelectionMetrics {
    let displayID: CGDirectDisplayID
    let displayName: String
    let isMain: Bool
    let placementDescription: String
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
        displayName = screen.localizedName.isEmpty ? "显示器 \(displayID)" : screen.localizedName
        isMain = screen == NSScreen.main
        placementDescription = Self.placementDescription(for: screen)
        self.pointSize = pointSize
        self.pixelSize = pixelSize
        scaleX = pixelSize.width / pointSize.width
        scaleY = pixelSize.height / pointSize.height
    }

    private static func placementDescription(for screen: NSScreen) -> String {
        guard screen != NSScreen.main,
              let mainFrame = NSScreen.main?.frame else {
            return "主屏"
        }

        let frame = screen.frame
        let horizontalDelta = frame.midX - mainFrame.midX
        let verticalDelta = frame.midY - mainFrame.midY
        let horizontalThreshold = max(CGFloat(80), min(frame.width, mainFrame.width) * 0.18)
        let verticalThreshold = max(CGFloat(80), min(frame.height, mainFrame.height) * 0.18)
        let horizontal = abs(horizontalDelta) > horizontalThreshold
            ? (horizontalDelta < 0 ? "左" : "右")
            : ""
        let vertical = abs(verticalDelta) > verticalThreshold
            ? (verticalDelta < 0 ? "下" : "上")
            : ""

        if horizontal.isEmpty, vertical.isEmpty {
            return "主屏附近"
        }
        return "主屏\(horizontal)\(vertical)方"
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

    func pixelPoint(for point: CGPoint) -> CGPoint? {
        guard
            point.x >= pointBounds.minX,
            point.x <= pointBounds.maxX,
            point.y >= pointBounds.minY,
            point.y <= pointBounds.maxY
        else {
            return nil
        }

        return CGPoint(
            x: min(max(point.x * scaleX, pixelBounds.minX), pixelBounds.maxX),
            y: min(max((pointSize.height - point.y) * scaleY, pixelBounds.minY), pixelBounds.maxY)
        )
    }

    func pixelRect(centeredAt point: CGPoint, pointSize: CGSize) -> CGRect? {
        let sourceRect = CGRect(
            x: point.x - pointSize.width / 2,
            y: point.y - pointSize.height / 2,
            width: pointSize.width,
            height: pointSize.height
        )
        return pixelRect(for: sourceRect)
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
            defer: false
        )
        // Avoid NSWindow's screen-specific initializer here: on newer macOS builds
        // it can re-enter the subclass's synthesized contentRect initializer and trap.
        setFrame(screen.frame, display: false)
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
        selectionView.backgroundImage = CGDisplayCreateImage(metrics.displayID)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class ScreenSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var metrics: ScreenSelectionMetrics?
    var backgroundImage: CGImage? {
        didSet {
            needsDisplay = true
        }
    }

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var hoverPoint: CGPoint?
    private var lastSelectionRect: CGRect?
    private var isDragging = false
    private var isCompleting = false
    private var wasSelectionReady = false
    private var dragMode: SelectionDragMode = .create
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var lastKeyboardAdjustmentHint: String?
    private var trackingArea: NSTrackingArea?
    private let accentColor = NSColor.systemTeal

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        focusForKeyboard()
        refreshCursor()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBaseOverlay()

        guard let selectionRect else {
            drawCrosshair(at: hoverPoint)
            drawEdgeSnapCue(for: nil, at: hoverPoint, state: .ready)
            drawIdleHint(at: hoverPoint)
            return
        }

        let state = visualState(for: selectionRect)
        drawSelectionHole(selectionRect, state: state)
        drawCrosshair(at: interactionPoint)
        drawEdgeSnapCue(for: selectionRect, at: interactionPoint, state: state)
        drawSelectionBorder(selectionRect, state: state)
        drawCornerGuides(in: selectionRect, state: state)
        drawHandles(in: selectionRect, state: state, hoverMode: hoverAdjustmentMode(for: selectionRect))
        drawAdjustmentCue(in: selectionRect, state: state)
        drawMagnifier(selectionRect, state: state)
        drawSelectionHUD(selectionRect, state: state)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCompleting else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        let rawPoint = rawPoint(for: event)
        let point = rawPoint.snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
        activeModifierFlags = normalizedModifierFlags(for: event)
        lastKeyboardAdjustmentHint = nil

        if let selectionRect,
           !isTooSmall(selectionRect),
           let adjustmentMode = adjustmentMode(at: rawPoint, in: selectionRect) {
            dragMode = adjustmentMode
            switch adjustmentMode {
            case .create:
                break
            case .move:
                hoverPoint = rawPoint
            case .resize(let handle):
                startPoint = handle.anchorPoint(in: selectionRect)
                currentPoint = handle.dragPoint(for: point, in: selectionRect)
                hoverPoint = point
            }
            isDragging = true
            wasSelectionReady = true
            refreshCursor()
            needsDisplay = true
            return
        }

        dragMode = .create
        startPoint = point
        currentPoint = startPoint
        hoverPoint = point
        isDragging = true
        wasSelectionReady = false
        refreshCursor()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCompleting else { return }
        activeModifierFlags = normalizedModifierFlags(for: event)
        lastKeyboardAdjustmentHint = nil
        switch dragMode {
        case .create:
            currentPoint = adjustedDragPoint(for: event)
            hoverPoint = currentPoint
        case .resize(let handle):
            currentPoint = adjustedResizePoint(for: event, handle: handle)
            hoverPoint = rawPoint(for: event)
        case .move(let originRect, let originPoint):
            let rect = movedSelectionRect(from: originRect, originPoint: originPoint, event: event)
            setSelectionRect(rect)
            hoverPoint = rawPoint(for: event)
        }
        lastSelectionRect = selectionRect
        updateReadinessFeedback()
        refreshCursor()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCompleting else { return }
        activeModifierFlags = normalizedModifierFlags(for: event)
        let wasAdjustingSelection = dragMode.isAdjustment
        switch dragMode {
        case .create:
            currentPoint = adjustedDragPoint(for: event)
            hoverPoint = currentPoint
        case .resize(let handle):
            currentPoint = adjustedResizePoint(for: event, handle: handle)
            hoverPoint = rawPoint(for: event)
        case .move(let originRect, let originPoint):
            let rect = movedSelectionRect(from: originRect, originPoint: originPoint, event: event)
            setSelectionRect(rect)
            hoverPoint = rawPoint(for: event)
        }
        isDragging = false
        dragMode = .create
        if let selectionRect {
            lastSelectionRect = selectionRect
            if isTooSmall(selectionRect) {
                flashTooSmallFeedback()
            } else if wasAdjustingSelection || shouldHoldSelectionForAdjustment(event) {
                holdSelectionForAdjustment()
            } else {
                completeAfterFeedback(selectionRect)
            }
        } else {
            resetSelection()
            flashTooSmallFeedback()
        }
        refreshCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        focusForKeyboard()
        activeModifierFlags = normalizedModifierFlags(for: event)
        lastKeyboardAdjustmentHint = nil
        hoverPoint = clampedPoint(for: event)
        refreshCursor()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        focusForKeyboard()
        activeModifierFlags = normalizedModifierFlags(for: event)
        lastKeyboardAdjustmentHint = nil
        hoverPoint = clampedPoint(for: event)
        refreshCursor()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else if shouldResetSelection(event) {
            resetSelection()
            return
        } else if handleNudge(event) {
            return
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

    private func completeAfterFeedback(_ rect: CGRect) {
        isCompleting = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ScreenSelectionConstants.completionFeedbackDelay) { [weak self] in
            guard let self, self.isCompleting else { return }
            self.onComplete?(rect)
        }
    }

    private func handleNudge(_ event: NSEvent) -> Bool {
        guard let currentPoint else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        activeModifierFlags = flags
        let step = flags.contains(.option)
            ? ScreenSelectionConstants.keyboardLargeNudgeStep
            : ScreenSelectionConstants.keyboardNudgeStep

        let delta: CGPoint
        switch event.keyCode {
        case UInt16(kVK_LeftArrow):
            delta = CGPoint(x: -step, y: 0)
        case UInt16(kVK_RightArrow):
            delta = CGPoint(x: step, y: 0)
        case UInt16(kVK_UpArrow):
            delta = CGPoint(x: 0, y: step)
        case UInt16(kVK_DownArrow):
            delta = CGPoint(x: 0, y: -step)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            if let selectionRect {
                if isTooSmall(selectionRect) {
                    flashTooSmallFeedback()
                } else {
                    completeAfterFeedback(selectionRect)
                }
                return true
            }
            return false
        default:
            return false
        }

        if !isDragging, let selectionRect {
            let adjustedRect: CGRect
            if flags.contains(.shift) {
                adjustedRect = keyboardResizedSelectionRect(
                    selectionRect,
                    delta: delta,
                    adjustsLeadingOrBottomEdge: flags.contains(.command)
                )
                lastKeyboardAdjustmentHint = keyboardResizeHint(
                    before: selectionRect,
                    after: adjustedRect,
                    requestedDelta: delta,
                    adjustsLeadingOrBottomEdge: flags.contains(.command)
                )
            } else {
                adjustedRect = selectionRect
                    .offsetBy(dx: delta.x, dy: delta.y)
                    .clamped(to: bounds)
                    .snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
                lastKeyboardAdjustmentHint = keyboardMoveHint(
                    before: selectionRect,
                    after: adjustedRect,
                    requestedDelta: delta
                )
            }
            setSelectionRect(adjustedRect)
            hoverPoint = CGPoint(x: adjustedRect.midX, y: adjustedRect.midY)
        } else {
            let previousPoint = currentPoint
            self.currentPoint = currentPoint
                .offsetBy(dx: delta.x, dy: delta.y)
                .clamped(to: bounds)
                .snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
            hoverPoint = self.currentPoint
            if let nextPoint = self.currentPoint {
                lastKeyboardAdjustmentHint = keyboardPointHint(
                    before: previousPoint,
                    after: nextPoint,
                    requestedDelta: delta
                )
            }
        }
        lastSelectionRect = selectionRect
        updateReadinessFeedback()
        needsDisplay = true
        return true
    }

    private func keyboardResizedSelectionRect(
        _ rect: CGRect,
        delta: CGPoint,
        adjustsLeadingOrBottomEdge: Bool
    ) -> CGRect {
        var resized = rect.standardized

        if adjustsLeadingOrBottomEdge {
            if delta.x != 0 {
                let proposedMinX = resized.minX + delta.x
                let maxMinX = resized.maxX - ScreenSelectionConstants.minimumSelectionSize.width
                resized.origin.x = min(max(proposedMinX, bounds.minX), maxMinX)
                resized.size.width = rect.maxX - resized.minX
            }
            if delta.y != 0 {
                let proposedMinY = resized.minY + delta.y
                let maxMinY = resized.maxY - ScreenSelectionConstants.minimumSelectionSize.height
                resized.origin.y = min(max(proposedMinY, bounds.minY), maxMinY)
                resized.size.height = rect.maxY - resized.minY
            }
        } else {
            if delta.x != 0 {
                let proposedMaxX = resized.maxX + delta.x
                let maxX = min(max(proposedMaxX, resized.minX + ScreenSelectionConstants.minimumSelectionSize.width), bounds.maxX)
                resized.size.width = maxX - resized.minX
            }
            if delta.y != 0 {
                let proposedMaxY = resized.maxY + delta.y
                let maxY = min(max(proposedMaxY, resized.minY + ScreenSelectionConstants.minimumSelectionSize.height), bounds.maxY)
                resized.size.height = maxY - resized.minY
            }
        }

        return keyboardSnappedResizedSelectionRect(
            resized,
            adjustsLeadingOrBottomEdge: adjustsLeadingOrBottomEdge
        )
    }

    private func keyboardSnappedResizedSelectionRect(
        _ rect: CGRect,
        adjustsLeadingOrBottomEdge: Bool
    ) -> CGRect {
        let distance = ScreenSelectionConstants.edgeSnapDistance
        var snapped = rect.standardized

        if adjustsLeadingOrBottomEdge {
            let fixedMaxX = snapped.maxX
            let fixedMaxY = snapped.maxY
            if abs(snapped.minX - bounds.minX) <= distance {
                snapped.origin.x = bounds.minX
                snapped.size.width = fixedMaxX - snapped.minX
            }
            if abs(snapped.minY - bounds.minY) <= distance {
                snapped.origin.y = bounds.minY
                snapped.size.height = fixedMaxY - snapped.minY
            }
        } else {
            if abs(snapped.maxX - bounds.maxX) <= distance {
                snapped.size.width = bounds.maxX - snapped.minX
            }
            if abs(snapped.maxY - bounds.maxY) <= distance {
                snapped.size.height = bounds.maxY - snapped.minY
            }
        }

        return snapped.clamped(to: bounds)
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
        let selectionDescription = selectionDescription(for: rect)

        switch state {
        case .ready:
            if isDragging, dragMode.isAdjustment {
                title = "正在微调选区"
            } else if let hoverMode = hoverAdjustmentMode(for: rect) {
                title = hoverTitle(for: hoverMode)
            } else {
                title = isDragging
                    ? (activeModifierFlags.contains(.option) ? "松开后微调" : "松开开始 OCR")
                    : "OCR 选区"
            }
            subtitle = subtitleWithReadabilityHint(
                selectionDescription,
                hint: readabilityHint(for: rect),
                fallback: interactionHint(for: rect)
            )
        case .tooSmall:
            title = "再拖大一点"
            subtitle = "\(selectionDescription) · 至少 \(minimumPixelDescription()) · 直接重拖或 R/⌘R 清空"
        case .completing:
            title = "正在截图"
            subtitle = subtitleWithReadabilityHint(
                selectionDescription,
                hint: readabilityHint(for: rect),
                fallback: "准备 OCR"
            )
        }
        drawPill(title: title, subtitle: subtitle, near: rect)
    }

    private func drawIdleHint(at point: CGPoint?) {
        let anchor = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let title = "框选文字区域"
        let screenDetail = screenDescription()
        let shortcutHint = "拖拽框选 · Enter 截图 · R/⌘R 重选 · Esc 取消"
        let width = pillWidth(title: title, subtitle: screenDetail, detail: shortcutHint)
        let height: CGFloat = 72
        let hintRect = CGRect(x: anchor.x - width / 2, y: anchor.y + 18, width: width, height: height)
            .clamped(to: bounds.insetBy(dx: 16, dy: 16))
        drawPill(
            title: title,
            subtitle: screenDetail,
            detail: shortcutHint,
            in: hintRect
        )
    }

    private func interactionHint(for rect: CGRect) -> String {
        let point = interactionPoint
        if isDragging {
            if dragMode.isAdjustment {
                return adjustmentHint(for: dragMode)
            }
            if activeModifierFlags.contains(.option) {
                if let point, let edge = edgeSnapDescription(for: point) {
                    return "\(edge) · 松开后可微调"
                }
                return "松开后可微调 · Shift 锁轴"
            }
            if let point, let edge = edgeSnapDescription(for: point) {
                return "\(edge) · Shift 锁轴"
            }
            return "Shift 锁轴 · R/⌘R 重选 · Esc 取消"
        }

        if isTooSmall(rect) {
            return "重新拖选 · R/⌘R 清空 · Esc 取消"
        }
        if let lastKeyboardAdjustmentHint {
            return lastKeyboardAdjustmentHint
        }
        if let hoverMode = hoverAdjustmentMode(for: rect) {
            return hoverHint(for: hoverMode)
        }
        if let point, let edge = edgeSnapDescription(for: point) {
            return "\(edge) · Enter 截图 · Shift+方向键改大小"
        }
        if lastSelectionRect != nil {
            return "方向键移动 · Shift+方向键改右/上边 · ⌘Shift 改左/下边"
        }
        return "拖拽框选 · Option 松手微调"
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

    private func drawEdgeSnapCue(for rect: CGRect?, at point: CGPoint?, state: SelectionVisualState) {
        var edges = Set(point.map(snappedEdges) ?? [])
        if let rect {
            edges.formUnion(snappedEdges(for: rect))
        }
        guard !edges.isEmpty else { return }

        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        for edge in edges {
            edge.addLine(to: path, in: bounds, inset: 2)
        }

        NSColor.white.withAlphaComponent(0.32).setStroke()
        let glow = path.copy() as? NSBezierPath
        glow?.lineWidth = 7
        glow?.stroke()

        color(for: state).withAlphaComponent(state == .tooSmall ? 0.68 : 0.9).setStroke()
        path.stroke()
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

    private func drawHandles(in rect: CGRect, state: SelectionVisualState, hoverMode: SelectionDragMode?) {
        guard rect.width >= 48, rect.height >= 36 else { return }
        for handle in SelectionHandle.allCases {
            let isHovered = hoverMode?.resizeHandle == handle
            let point = handle.point(in: rect)
            let handleSize: CGFloat = isHovered ? 9 : 5
            let handleRect = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            (isHovered ? NSColor.systemYellow : color(for: state)).setFill()
            NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
            if isHovered {
                NSColor.white.withAlphaComponent(0.86).setStroke()
                let outline = NSBezierPath(roundedRect: handleRect.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
                outline.lineWidth = 1.5
                outline.stroke()
            }
        }
    }

    private func drawAdjustmentCue(in rect: CGRect, state: SelectionVisualState) {
        guard state == .ready,
              !isDragging,
              case .move? = hoverAdjustmentMode(for: rect) else {
            return
        }

        let cueRect = CGRect(x: rect.midX - 46, y: rect.midY - 13, width: 92, height: 26)
            .clamped(to: bounds.insetBy(dx: 12, dy: 12))
        let path = NSBezierPath(roundedRect: cueRect, xRadius: 13, yRadius: 13)
        NSColor.black.withAlphaComponent(0.58).setFill()
        path.fill()
        accentColor.withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        NSAttributedString(string: "拖动移动", attributes: attributes)
            .draw(in: CGRect(x: cueRect.minX + 18, y: cueRect.minY + 6, width: cueRect.width - 28, height: 14))
    }

    private func drawMagnifier(_ rect: CGRect, state: SelectionVisualState) {
        guard let point = interactionPoint else { return }
        let size = ScreenSelectionConstants.magnifierSize
        let magnifierRect = magnifierFrame(near: point, avoiding: rect, size: size)
        let path = NSBezierPath(roundedRect: magnifierRect, xRadius: 14, yRadius: 14)
        let contentRect = magnifierRect.insetBy(
            dx: ScreenSelectionConstants.magnifierContentInset,
            dy: ScreenSelectionConstants.magnifierContentInset
        )

        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        color(for: state).withAlphaComponent(0.80).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let focusPoint = drawMagnifierImage(around: point, in: contentRect)
            ?? CGPoint(x: contentRect.midX, y: contentRect.midY)
        drawMagnifierGrid(in: contentRect, state: state)
        drawMagnifierCrosshair(at: focusPoint, in: contentRect, state: state)
        drawMagnifierTextScrims(in: magnifierRect)
        drawMagnifierText(in: magnifierRect, point: point, selection: rect)
    }

    private func drawMagnifierImage(around point: CGPoint, in rect: CGRect) -> CGPoint? {
        let contentPath = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        guard
            let source = magnifierSource(around: point),
            rect.width > 0,
            rect.height > 0
        else {
            drawMagnifierFallback(in: rect)
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        contentPath.addClip()
        let graphicsContext = NSGraphicsContext.current
        let previousInterpolation = graphicsContext?.imageInterpolation
        graphicsContext?.imageInterpolation = .none

        let image = NSImage(
            cgImage: source.image,
            size: CGSize(width: source.image.width, height: source.image.height)
        )
        image.draw(
            in: rect,
            from: CGRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )

        if let previousInterpolation {
            graphicsContext?.imageInterpolation = previousInterpolation
        }
        NSGraphicsContext.restoreGraphicsState()

        return CGPoint(
            x: rect.minX + source.focusUnitPoint.x * rect.width,
            y: rect.maxY - source.focusUnitPoint.y * rect.height
        )
    }

    private func drawMagnifierFallback(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.34).setFill()
        path.fill()
    }

    private func magnifierSource(around point: CGPoint) -> MagnifierSource? {
        guard
            let metrics,
            let backgroundImage,
            let sourcePixelRect = metrics.pixelRect(
                centeredAt: point,
                pointSize: ScreenSelectionConstants.magnifierSourcePointSize
            ),
            let focusPixelPoint = metrics.pixelPoint(for: point)
        else {
            return nil
        }

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: backgroundImage.width,
            height: backgroundImage.height
        )
        let cropRect = sourcePixelRect.intersection(imageBounds).integral
        guard
            !cropRect.isNull,
            !cropRect.isEmpty,
            cropRect.width >= 1,
            cropRect.height >= 1,
            let image = backgroundImage.cropping(to: cropRect)
        else {
            return nil
        }

        let focusUnitPoint = CGPoint(
            x: min(max((focusPixelPoint.x - cropRect.minX) / cropRect.width, 0), 1),
            y: min(max((focusPixelPoint.y - cropRect.minY) / cropRect.height, 0), 1)
        )
        return MagnifierSource(image: image, focusUnitPoint: focusUnitPoint)
    }

    private func drawMagnifierGrid(in rect: CGRect, state: SelectionVisualState) {
        let path = NSBezierPath()
        path.lineWidth = 0.75

        for index in 1..<4 {
            let x = rect.minX + rect.width * CGFloat(index) / 4
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.line(to: CGPoint(x: x, y: rect.maxY))
        }

        for index in 1..<3 {
            let y = rect.minY + rect.height * CGFloat(index) / 3
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
        }

        NSColor.white.withAlphaComponent(state == .tooSmall ? 0.14 : 0.20).setStroke()
        path.stroke()
    }

    private func drawMagnifierCrosshair(at center: CGPoint, in rect: CGRect, state: SelectionVisualState) {
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.move(to: CGPoint(x: max(rect.minX, center.x - 20), y: center.y))
        path.line(to: CGPoint(x: min(rect.maxX, center.x + 20), y: center.y))
        path.move(to: CGPoint(x: center.x, y: max(rect.minY, center.y - 20)))
        path.line(to: CGPoint(x: center.x, y: min(rect.maxY, center.y + 20)))
        color(for: state).withAlphaComponent(0.92).setStroke()
        path.stroke()

        color(for: state).withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }

    private func drawMagnifierTextScrims(in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.46).setFill()
        CGRect(x: rect.minX + 8, y: rect.minY + 7, width: rect.width - 16, height: 20).fill()
        CGRect(x: rect.minX + 8, y: rect.maxY - 27, width: rect.width - 16, height: 20).fill()
    }

    private func drawMagnifierText(in rect: CGRect, point: CGPoint, selection: CGRect) {
        let snapText = edgeSnapDescription(for: point)
        let coordinateText = "\(Int(point.x)), \(Int(point.y)) pt"
        let text = snapText.map { "\($0) · \(coordinateText)" } ?? coordinateText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82)
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(in: CGRect(x: rect.minX + 10, y: rect.minY + 8, width: rect.width - 20, height: 14))

        let sizeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ]
        NSAttributedString(string: pixelDescription(for: selection), attributes: sizeAttributes)
            .draw(in: CGRect(x: rect.minX + 10, y: rect.maxY - 22, width: rect.width - 20, height: 14))
    }

    private func magnifierFrame(near point: CGPoint, avoiding selection: CGRect, size: CGSize) -> CGRect {
        let margin: CGFloat = 14
        var candidates = [
            CGPoint(x: point.x + 18, y: point.y + 18),
            CGPoint(x: point.x + 18, y: point.y - size.height - 18),
            CGPoint(x: point.x - size.width - 18, y: point.y + 18),
            CGPoint(x: point.x - size.width - 18, y: point.y - size.height - 18)
        ].map { origin in
            CGRect(origin: origin, size: size).clamped(to: bounds.insetBy(dx: margin, dy: margin))
        }

        candidates.sort { left, right in
            let leftOverlap = left.intersection(selection).area
            let rightOverlap = right.intersection(selection).area
            if leftOverlap != rightOverlap {
                return leftOverlap < rightOverlap
            }
            return distance(from: left.origin, to: point) < distance(from: right.origin, to: point)
        }

        return candidates.first ?? CGRect(origin: CGPoint(x: margin, y: margin), size: size)
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

    private func drawPill(title: String, subtitle: String, detail: String, in rect: CGRect) {
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
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.76)
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ]
        NSAttributedString(string: title, attributes: titleAttributes)
            .draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 46, width: rect.width - 28, height: 18))
        NSAttributedString(string: subtitle, attributes: subtitleAttributes)
            .draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 29, width: rect.width - 28, height: 15))
        NSAttributedString(string: detail, attributes: detailAttributes)
            .draw(in: CGRect(x: rect.minX + 14, y: rect.minY + 12, width: rect.width - 28, height: 15))
    }

    private func clampedPoint(for event: NSEvent) -> CGPoint {
        rawPoint(for: event)
            .snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
    }

    private func rawPoint(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
            .clamped(to: bounds)
    }

    private func adjustedDragPoint(for event: NSEvent) -> CGPoint {
        let point = clampedPoint(for: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              let previousPoint = currentPoint,
              let selectionRect,
              !isTooSmall(selectionRect) else {
            return point
        }

        let xDelta = abs(point.x - previousPoint.x)
        let yDelta = abs(point.y - previousPoint.y)
        let lockedPoint = xDelta >= yDelta
            ? CGPoint(x: point.x, y: previousPoint.y)
            : CGPoint(x: previousPoint.x, y: point.y)
        return lockedPoint.clamped(to: bounds).snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
    }

    private func adjustedResizePoint(for event: NSEvent, handle: SelectionHandle) -> CGPoint {
        guard let selectionRect else { return clampedPoint(for: event) }
        let point = clampedPoint(for: event)
        let constrainedPoint = handle.dragPoint(for: point, in: selectionRect)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              let previousPoint = currentPoint,
              !isTooSmall(selectionRect) else {
            return constrainedPoint
        }

        let xDelta = abs(constrainedPoint.x - previousPoint.x)
        let yDelta = abs(constrainedPoint.y - previousPoint.y)
        let lockedPoint = xDelta >= yDelta
            ? CGPoint(x: constrainedPoint.x, y: previousPoint.y)
            : CGPoint(x: previousPoint.x, y: constrainedPoint.y)
        return handle.dragPoint(for: lockedPoint, in: selectionRect)
            .clamped(to: bounds)
            .snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
    }

    private func adjustmentMode(at point: CGPoint, in rect: CGRect) -> SelectionDragMode? {
        if let handle = hitTestHandle(at: point, in: rect) {
            return .resize(handle)
        }
        if rect.contains(point) {
            return .move(originRect: rect, originPoint: point)
        }
        return nil
    }

    private func refreshCursor() {
        cursorForCurrentInteraction().set()
    }

    private func focusForKeyboard() {
        guard window?.firstResponder !== self else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    private func cursorForCurrentInteraction() -> NSCursor {
        if isCompleting {
            return .arrow
        }

        if isDragging {
            return cursor(for: dragMode, isDragging: true)
        }

        guard
            let selectionRect,
            !isTooSmall(selectionRect),
            let hoverPoint,
            let mode = adjustmentMode(at: hoverPoint, in: selectionRect)
        else {
            return .crosshair
        }
        return cursor(for: mode, isDragging: false)
    }

    private func cursor(for mode: SelectionDragMode, isDragging: Bool) -> NSCursor {
        switch mode {
        case .create:
            return .crosshair
        case .move:
            return isDragging ? .closedHand : .openHand
        case .resize(let handle):
            return handle.cursor
        }
    }

    private func hoverAdjustmentMode(for rect: CGRect) -> SelectionDragMode? {
        guard !isDragging, !isCompleting, !isTooSmall(rect), let hoverPoint else {
            return nil
        }
        return adjustmentMode(at: hoverPoint, in: rect)
    }

    private func hoverTitle(for mode: SelectionDragMode) -> String {
        switch mode {
        case .create:
            return "OCR 选区"
        case .move:
            return "可拖动移动"
        case .resize:
            return "可拖边/角调整"
        }
    }

    private func hoverHint(for mode: SelectionDragMode) -> String {
        switch mode {
        case .create:
            return "拖拽框选 · Option 松手微调"
        case .move:
            return "拖动内部移动 · 方向键移动 · Enter 截图"
        case .resize:
            return "拖动边/角改大小 · Shift+方向键微调尺寸 · Enter 截图"
        }
    }

    private func hitTestHandle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        SelectionHandle.allCases.first { handle in
            let cornerPoint = handle.point(in: rect)
            let hitSize = ScreenSelectionConstants.handleHitSize
            let hitRect = CGRect(
                x: cornerPoint.x - hitSize / 2,
                y: cornerPoint.y - hitSize / 2,
                width: hitSize,
                height: hitSize
            )
            return hitRect.contains(point)
        }
    }

    private func movedSelectionRect(from originRect: CGRect, originPoint: CGPoint, event: NSEvent) -> CGRect {
        let point = rawPoint(for: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var delta = CGPoint(x: point.x - originPoint.x, y: point.y - originPoint.y)
        if flags.contains(.shift) {
            if abs(delta.x) >= abs(delta.y) {
                delta.y = 0
            } else {
                delta.x = 0
            }
        }
        return originRect
            .offsetBy(dx: delta.x, dy: delta.y)
            .clamped(to: bounds)
            .snapped(to: bounds, distance: ScreenSelectionConstants.edgeSnapDistance)
    }

    private func setSelectionRect(_ rect: CGRect) {
        let clampedRect = rect.standardized.clamped(to: bounds)
        startPoint = CGPoint(x: clampedRect.minX, y: clampedRect.minY)
        currentPoint = CGPoint(x: clampedRect.maxX, y: clampedRect.maxY)
    }

    private var interactionPoint: CGPoint? {
        switch dragMode {
        case .move:
            return hoverPoint ?? currentPoint
        case .create, .resize:
            return currentPoint ?? hoverPoint
        }
    }

    private func adjustmentHint(for mode: SelectionDragMode) -> String {
        switch mode {
        case .create:
            return "Shift 锁轴 · R/⌘R 重选 · Esc 取消"
        case .move:
            return "正在移动选区 · Shift 锁轴 · 松开后 Enter 截图"
        case .resize:
            return "正在调整边/角 · Shift 锁轴 · 松开后 Enter 截图"
        }
    }

    private func keyboardMoveHint(before: CGRect, after: CGRect, requestedDelta: CGPoint) -> String {
        ScreenSelectionGuidance.keyboardMoveHint(before: before, after: after, requestedDelta: requestedDelta)
    }

    private func keyboardResizeHint(
        before: CGRect,
        after: CGRect,
        requestedDelta: CGPoint,
        adjustsLeadingOrBottomEdge: Bool
    ) -> String {
        ScreenSelectionGuidance.keyboardResizeHint(
            before: before,
            after: after,
            requestedDelta: requestedDelta,
            adjustsLeadingOrBottomEdge: adjustsLeadingOrBottomEdge
        )
    }

    private func keyboardPointHint(before: CGPoint, after: CGPoint, requestedDelta: CGPoint) -> String {
        ScreenSelectionGuidance.keyboardPointHint(before: before, after: after, requestedDelta: requestedDelta)
    }

    private func keyboardMovementDescription(actualDelta: CGPoint, requestedDelta: CGPoint) -> String? {
        ScreenSelectionGuidance.keyboardMovementDescription(actualDelta: actualDelta, requestedDelta: requestedDelta)
    }

    private func edgeDirectionDescription(delta: CGFloat, isHorizontal: Bool) -> String {
        ScreenSelectionGuidance.edgeDirectionDescription(delta: delta, isHorizontal: isHorizontal)
    }

    private func shouldResetSelection(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == UInt16(kVK_ANSI_R) && (flags.isEmpty || flags == [.command])
    }

    private func shouldHoldSelectionForAdjustment(_ event: NSEvent) -> Bool {
        normalizedModifierFlags(for: event).contains(.option)
    }

    private func normalizedModifierFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    private func resetSelection() {
        startPoint = nil
        currentPoint = nil
        lastSelectionRect = nil
        lastKeyboardAdjustmentHint = nil
        isDragging = false
        isCompleting = false
        wasSelectionReady = false
        dragMode = .create
        refreshCursor()
        needsDisplay = true
    }

    private func flashTooSmallFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        wasSelectionReady = false
        needsDisplay = true
    }

    private func holdSelectionForAdjustment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        wasSelectionReady = true
        needsDisplay = true
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

    private func selectionDescription(for rect: CGRect) -> String {
        let pointText = "\(Int(rect.width.rounded())) x \(Int(rect.height.rounded())) pt"
        let pixelText = pixelDescription(for: rect)
        guard let metrics else {
            return "\(pixelText) / \(pointText)"
        }

        let scale = String(format: "%.1fx", (metrics.scaleX + metrics.scaleY) / 2)
        let screenRole = metrics.isMain ? "主屏" : "副屏"
        let placementText = metrics.isMain ? "" : " · \(metrics.placementDescription)"
        let screenText = "\(screenRole)\(placementText) · \(shortDisplayName(metrics.displayName))"
        let edgeText = snappedEdgeDescription(for: rect).map { " · \($0)" } ?? ""
        return "\(pixelText) / \(pointText) · \(screenText) \(scale)\(edgeText)"
    }

    private func subtitleWithReadabilityHint(_ selectionDescription: String, hint: String?, fallback: String) -> String {
        guard let hint else {
            return "\(selectionDescription) · \(fallback)"
        }
        return "\(selectionDescription) · \(hint) · \(fallback)"
    }

    private func readabilityHint(for rect: CGRect) -> String? {
        let size = metrics?.pixelSize(for: rect) ?? CGSize(
            width: rect.width * (window?.screen?.backingScaleFactor ?? 1),
            height: rect.height * (window?.screen?.backingScaleFactor ?? 1)
        )
        return ScreenSelectionGuidance.readabilityHint(forPixelSize: size)
    }

    private func minimumPixelDescription() -> String {
        let size = metrics?.pixelSize(forPointSize: ScreenSelectionConstants.minimumSelectionSize)
            ?? ScreenSelectionConstants.minimumSelectionSize
        return "\(Int(size.width)) x \(Int(size.height)) px"
    }

    private func screenDescription() -> String {
        guard let metrics else {
            return "拖拽选择"
        }
        let scale = String(format: "%.1fx", (metrics.scaleX + metrics.scaleY) / 2)
        let screenRole = metrics.isMain ? "主屏" : "副屏 · \(metrics.placementDescription)"
        return "\(screenRole) · \(shortDisplayName(metrics.displayName)) · \(scale) · \(Int(metrics.pointSize.width)) x \(Int(metrics.pointSize.height)) pt · \(Int(metrics.pixelSize.width)) x \(Int(metrics.pixelSize.height)) px"
    }

    private func shortDisplayName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 16 else { return clean }
        return "\(clean.prefix(15))..."
    }

    private func edgeSnapDescription(for point: CGPoint) -> String? {
        ScreenSelectionGuidance.edgeSnapDescription(for: point, bounds: bounds)
    }

    private func snappedEdgeDescription(for rect: CGRect) -> String? {
        ScreenSelectionGuidance.snappedEdgeDescription(for: rect, bounds: bounds)
    }

    private func snappedEdges(for point: CGPoint) -> [SelectionSnapEdge] {
        ScreenSelectionGuidance.snappedEdges(for: point, bounds: bounds)
    }

    private func snappedEdges(for rect: CGRect) -> [SelectionSnapEdge] {
        ScreenSelectionGuidance.snappedEdges(for: rect, bounds: bounds)
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

    private func pillWidth(title: String, subtitle: String, detail: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
        ]).width
        let subtitleWidth = (subtitle as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]).width
        let detailWidth = (detail as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular)
        ]).width
        let preferred = max(CGFloat(284), max(titleWidth, subtitleWidth, detailWidth) + 28)
        return min(preferred, max(CGFloat(220), bounds.width - 32))
    }

    private func distance(from origin: CGPoint, to point: CGPoint) -> CGFloat {
        hypot(origin.x - point.x, origin.y - point.y)
    }
}

private enum ScreenSelectionGuidance {
    static func readabilityHint(forPixelSize size: CGSize) -> String? {
        guard size.width > 0, size.height > 0 else { return nil }

        if size.width < ScreenSelectionConstants.narrowOCRWidthWarningPixels,
           size.height < ScreenSelectionConstants.lowOCRHeightWarningPixels {
            return "选区偏小，可能只截到局部文字；向外多框一点"
        }
        if size.height < ScreenSelectionConstants.lowOCRHeightWarningPixels {
            return "高度偏低，可能只截到半行文字"
        }
        if size.width < ScreenSelectionConstants.narrowOCRWidthWarningPixels,
           size.height >= ScreenSelectionConstants.tallNarrowSelectionMinHeightPixels,
           size.height / max(size.width, 1) >= ScreenSelectionConstants.tallNarrowSelectionAspectRatio {
            return "选区窄而高，可能截到列边缘或跨行碎片；建议横向扩到完整一列"
        }
        if size.width < ScreenSelectionConstants.narrowOCRWidthWarningPixels {
            return "宽度偏窄，尽量覆盖完整单词或一整列"
        }
        if size.width / max(size.height, 1) >= ScreenSelectionConstants.longSingleLineAspectRatio {
            return "像超长单行，确认左右边缘是否完整"
        }
        if size.width * size.height >= ScreenSelectionConstants.largeSelectionWarningPixels {
            return "区域较大，OCR 可能稍慢；可只框文字区域"
        }
        return nil
    }

    static func edgeSnapDescription(for point: CGPoint, bounds: CGRect) -> String? {
        let edges = snappedEdges(for: point, bounds: bounds).map(\.title)
        guard !edges.isEmpty else { return nil }
        return "已吸附" + edges.joined(separator: "/")
    }

    static func snappedEdgeDescription(for rect: CGRect, bounds: CGRect) -> String? {
        let edges = snappedEdges(for: rect, bounds: bounds).map(\.shortTitle)
        guard !edges.isEmpty else { return nil }
        return "贴齐" + edges.joined(separator: "/")
    }

    static func snappedEdges(for point: CGPoint, bounds: CGRect) -> [SelectionSnapEdge] {
        let distance = ScreenSelectionConstants.edgeSnapDistance
        var edges: [SelectionSnapEdge] = []
        if abs(point.x - bounds.minX) <= distance {
            edges.append(.left)
        } else if abs(point.x - bounds.maxX) <= distance {
            edges.append(.right)
        }
        if abs(point.y - bounds.minY) <= distance {
            edges.append(.bottom)
        } else if abs(point.y - bounds.maxY) <= distance {
            edges.append(.top)
        }
        return edges
    }

    static func snappedEdges(for rect: CGRect, bounds: CGRect) -> [SelectionSnapEdge] {
        let tolerance: CGFloat = 0.5
        var edges: [SelectionSnapEdge] = []
        if abs(rect.minX - bounds.minX) <= tolerance {
            edges.append(.left)
        }
        if abs(rect.maxX - bounds.maxX) <= tolerance {
            edges.append(.right)
        }
        if abs(rect.minY - bounds.minY) <= tolerance {
            edges.append(.bottom)
        }
        if abs(rect.maxY - bounds.maxY) <= tolerance {
            edges.append(.top)
        }
        return edges
    }

    static func keyboardMoveHint(before: CGRect, after: CGRect, requestedDelta: CGPoint) -> String {
        let actualDelta = CGPoint(x: after.minX - before.minX, y: after.minY - before.minY)
        guard let movement = keyboardMovementDescription(actualDelta: actualDelta, requestedDelta: requestedDelta) else {
            return "已到屏幕边缘 · 反方向移动或拖动内部调整 · Enter 截图"
        }
        return "已移动：\(movement) · Shift+方向键改大小 · Enter 截图"
    }

    static func keyboardResizeHint(
        before: CGRect,
        after: CGRect,
        requestedDelta: CGPoint,
        adjustsLeadingOrBottomEdge: Bool
    ) -> String {
        let edgeName: String
        let actualDelta: CGFloat
        if requestedDelta.x != 0 {
            edgeName = adjustsLeadingOrBottomEdge ? "左边缘" : "右边缘"
            actualDelta = adjustsLeadingOrBottomEdge
                ? after.minX - before.minX
                : after.maxX - before.maxX
        } else {
            edgeName = adjustsLeadingOrBottomEdge ? "下边缘" : "上边缘"
            actualDelta = adjustsLeadingOrBottomEdge
                ? after.minY - before.minY
                : after.maxY - before.maxY
        }

        guard abs(actualDelta) >= 0.5 else {
            return "已到最小尺寸或屏幕边缘 · 反向调整或拖边放大 · Enter 截图"
        }

        let direction = edgeDirectionDescription(delta: actualDelta, isHorizontal: requestedDelta.x != 0)
        return "已调整\(edgeName)：\(direction) \(Int(abs(actualDelta).rounded()))pt · Enter 截图"
    }

    static func keyboardPointHint(before: CGPoint, after: CGPoint, requestedDelta: CGPoint) -> String {
        let actualDelta = CGPoint(x: after.x - before.x, y: after.y - before.y)
        guard let movement = keyboardMovementDescription(actualDelta: actualDelta, requestedDelta: requestedDelta) else {
            return "端点已到屏幕边缘 · 继续拖拽或重新框选"
        }
        return "已移动端点：\(movement) · 继续拖拽或 Enter 截图"
    }

    static func keyboardMovementDescription(actualDelta: CGPoint, requestedDelta: CGPoint) -> String? {
        let horizontalMove = requestedDelta.x != 0 || abs(actualDelta.x) >= abs(actualDelta.y)
        let value = horizontalMove ? actualDelta.x : actualDelta.y
        if abs(value) < 0.5 {
            return nil
        }

        let direction: String
        if horizontalMove {
            direction = value > 0 ? "右" : "左"
        } else {
            direction = value > 0 ? "上" : "下"
        }
        return "\(direction) \(Int(abs(value).rounded()))pt"
    }

    static func edgeDirectionDescription(delta: CGFloat, isHorizontal: Bool) -> String {
        if isHorizontal {
            return delta > 0 ? "向右" : "向左"
        }
        return delta > 0 ? "向上" : "向下"
    }
}

private enum SelectionVisualState {
    case ready
    case tooSmall
    case completing
}

private enum SelectionSnapEdge: Hashable {
    case left
    case right
    case top
    case bottom

    var title: String {
        switch self {
        case .left:
            return "左边缘"
        case .right:
            return "右边缘"
        case .top:
            return "上边缘"
        case .bottom:
            return "下边缘"
        }
    }

    var shortTitle: String {
        switch self {
        case .left:
            return "左"
        case .right:
            return "右"
        case .top:
            return "上"
        case .bottom:
            return "下"
        }
    }

    func addLine(to path: NSBezierPath, in bounds: CGRect, inset: CGFloat) {
        switch self {
        case .left:
            path.move(to: CGPoint(x: bounds.minX + inset, y: bounds.minY + inset))
            path.line(to: CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset))
        case .right:
            path.move(to: CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset))
            path.line(to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        case .top:
            path.move(to: CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset))
            path.line(to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        case .bottom:
            path.move(to: CGPoint(x: bounds.minX + inset, y: bounds.minY + inset))
            path.line(to: CGPoint(x: bounds.maxX - inset, y: bounds.minY + inset))
        }
    }
}

private enum SelectionDragMode {
    case create
    case move(originRect: CGRect, originPoint: CGPoint)
    case resize(SelectionHandle)

    var isAdjustment: Bool {
        switch self {
        case .create:
            return false
        case .move, .resize:
            return true
        }
    }

    var resizeHandle: SelectionHandle? {
        switch self {
        case .resize(let handle):
            return handle
        case .create, .move:
            return nil
        }
    }
}

private enum SelectionHandle: CaseIterable {
    case bottomLeft
    case bottom
    case bottomRight
    case right
    case topRight
    case top
    case topLeft
    case left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func anchorPoint(in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .right:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .topLeft:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    func dragPoint(for point: CGPoint, in rect: CGRect) -> CGPoint {
        switch self {
        case .bottomLeft, .bottomRight, .topRight, .topLeft:
            return point
        case .bottom:
            return CGPoint(x: rect.minX, y: point.y)
        case .right:
            return CGPoint(x: point.x, y: rect.maxY)
        case .top:
            return CGPoint(x: rect.maxX, y: point.y)
        case .left:
            return CGPoint(x: point.x, y: rect.minY)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right, .bottomLeft, .bottomRight, .topLeft, .topRight:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        }
    }
}

private struct MagnifierSource {
    let image: CGImage
    let focusUnitPoint: CGPoint
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

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

    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGRect {
        CGRect(x: minX + dx, y: minY + dy, width: width, height: height)
    }

    func snapped(to bounds: CGRect, distance: CGFloat) -> CGRect {
        var rect = self
        if abs(rect.minX - bounds.minX) <= distance {
            rect.origin.x = bounds.minX
        } else if abs(rect.maxX - bounds.maxX) <= distance {
            rect.origin.x = bounds.maxX - rect.width
        }

        if abs(rect.minY - bounds.minY) <= distance {
            rect.origin.y = bounds.minY
        } else if abs(rect.maxY - bounds.maxY) <= distance {
            rect.origin.y = bounds.maxY - rect.height
        }

        return rect.clamped(to: bounds)
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }

    func clamped(to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(x, bounds.minX), bounds.maxX),
            y: min(max(y, bounds.minY), bounds.maxY)
        )
    }

    func snapped(to bounds: CGRect, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: snappedCoordinate(x, min: bounds.minX, max: bounds.maxX, distance: distance),
            y: snappedCoordinate(y, min: bounds.minY, max: bounds.maxY, distance: distance)
        )
    }

    private func snappedCoordinate(_ value: CGFloat, min: CGFloat, max: CGFloat, distance: CGFloat) -> CGFloat {
        if abs(value - min) <= distance {
            return min
        }
        if abs(value - max) <= distance {
            return max
        }
        return value
    }
}
