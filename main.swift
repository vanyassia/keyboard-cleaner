import Cocoa
import SwiftUI
import Combine

private let diagnosticLogLock = NSLock()
private let systemDefinedEventRawValue: UInt32 = 14
private let maxDiagnosticLogSize = 512 * 1024
private let unlockHoldDuration: TimeInterval = 3.0
private let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
private let diagnosticLogURL: URL = {
    let fileManager = FileManager.default
    let baseDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        ?? fileManager.temporaryDirectory
    let logDirectory = baseDirectory
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("KeyboardCleaner", isDirectory: true)

    try? fileManager.createDirectory(
        at: logDirectory,
        withIntermediateDirectories: true,
        attributes: nil
    )

    return logDirectory.appendingPathComponent("diagnostic.log")
}()

func logDiagnostic(_ message: String) {
    guard let data = "[\(Date())] \(message)\n".data(using: .utf8) else {
        return
    }

    diagnosticLogLock.lock()
    defer { diagnosticLogLock.unlock() }

    // Keep the log from growing without bound on long-lived installs.
    if let attributes = try? FileManager.default.attributesOfItem(atPath: diagnosticLogURL.path),
       let size = attributes[.size] as? NSNumber,
       size.intValue > maxDiagnosticLogSize {
        try? FileManager.default.removeItem(at: diagnosticLogURL)
    }

    if let fileHandle = try? FileHandle(forWritingTo: diagnosticLogURL) {
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        fileHandle.closeFile()
    } else {
        try? data.write(to: diagnosticLogURL, options: .atomic)
    }
}

// App Model to manage state
class AppModel: ObservableObject {
    static let shared = AppModel()
    
    @Published var isBlocked = false
    @Published var blockedCount = 0
    @Published var historyCount = UserDefaults.standard.integer(forKey: "clean_history_count")
    @Published var keyLogs: [KeyLogEntry] = []
    
    // Accessibility status
    @Published var isAccessibilityGranted = GlobalEventTap.shared.isAccessibilityGranted
    @Published var isFullyBlocked = false
    
    var onBlock: (() -> Void)?
    var onUnblock: (() -> Void)?
    
    func checkAccessibilityStatus() {
        isAccessibilityGranted = GlobalEventTap.shared.isAccessibilityGranted
    }
    
    func startBlocking() {
        guard !isBlocked else { return }

        isBlocked = true
        keyLogs.removeAll()
        blockedCount = 0
        onBlock?()
    }
    
    func stopBlocking() {
        guard isBlocked else { return }

        isBlocked = false
        historyCount += 1
        UserDefaults.standard.set(historyCount, forKey: "clean_history_count")
        onUnblock?()
    }
    
    func logEvent(_ text: String) {
        guard isBlocked else { return }

        blockedCount += 1
        let entry = KeyLogEntry(text: text)
        keyLogs.append(entry)
        if keyLogs.count > 8 {
            keyLogs.removeFirst()
        }
    }
}

struct KeyLogEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let timestamp = Date()
    
    static func == (lhs: KeyLogEntry, rhs: KeyLogEntry) -> Bool {
        return lhs.id == rhs.id
    }
}

// Global Event Tap Helper for low-level blocking (requires Accessibility permission)
class GlobalEventTap {
    static let shared = GlobalEventTap()
    
    private(set) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isRunning = false
    
    var isAccessibilityGranted: Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    
    func start() -> Bool {
        if eventTap != nil || runLoopSource != nil {
            stop()
        }

        logDiagnostic("Starting event tap...")
        let trusted = isAccessibilityGranted
        logDiagnostic("Accessibility granted status: \(trusted)")
        
        guard trusted else { 
            logDiagnostic("Start failed: Accessibility not granted")
            return false 
        }
        
        let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                        (CGEventMask(1) << CGEventType.keyUp.rawValue) |
                        (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
                        (CGEventMask(1) << systemDefinedEventRawValue)
        
        let callback: CGEventTapCallBack = { (_, type, event, _) -> Unmanaged<CGEvent>? in
            // Handle system timeout auto-disabling event tap
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if GlobalEventTap.shared.isRunning, let tap = GlobalEventTap.shared.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
            
            // Convert the event to a value type before returning from the callback.
            // Retaining CGEvent/NSEvent in an asynchronous closure can leave AppKit
            // objects alive past the event tap's lifetime and cause EXC_BAD_ACCESS.
            guard let cgCopy = event.copy() else {
                return nil
            }

            let eventName: String?
            if type.rawValue == systemDefinedEventRawValue {
                if let nsEvent = NSEvent(cgEvent: cgCopy), nsEvent.subtype.rawValue == 8 {
                    let keyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
                    eventName = getMediaKeyName(keyCode)
                } else {
                    eventName = nil
                }
            } else if type == .keyDown || type == .flagsChanged {
                eventName = NSEvent(cgEvent: cgCopy).map { displayName(for: $0) }
            } else {
                eventName = nil
            }

            if let eventName {
                DispatchQueue.main.async {
                    AppModel.shared.logEvent(eventName)
                }
            }
            
            return nil // Swallow event
        }
        
        // Try creating HID event tap first (low level)
        logDiagnostic("Attempting to create cghidEventTap...")
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: callback,
            userInfo: nil
        )
        
        // Fallback to Session event tap if HID fails
        if eventTap == nil {
            logDiagnostic("Failed to create cghidEventTap, attempting cgSessionEventTap...")
            eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: nil
            )
            if eventTap != nil {
                logDiagnostic("Successfully created cgSessionEventTap fallback")
            } else {
                logDiagnostic("Failed to create cgSessionEventTap fallback")
            }
        } else {
            logDiagnostic("Successfully created cghidEventTap")
        }
        
        guard let eventTap = eventTap else { 
            logDiagnostic("Start failed: Both event taps returned nil")
            return false 
        }
        
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            logDiagnostic("Start failed: Could not create run loop source")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            return false
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        isRunning = true
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logDiagnostic("Event tap enabled successfully")
        return true
    }
    
    func stop() {
        logDiagnostic("Stopping event tap...")

        // Detach the source before releasing the mach port. This keeps the
        // run-loop source from referring to a port that has already deallocated.
        isRunning = false
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
            logDiagnostic("Run loop source removed")
        }

        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
            logDiagnostic("Event tap disabled and invalidated")
        }
    }
}

// Visual Mini-Keyboard View for aesthetics
struct KeyboardGraphicView: View {
    var body: some View {
        VStack(spacing: 6) {
            // Row 1
            HStack(spacing: 6) {
                ForEach(0..<10) { _ in key(width: 24) }
            }
            // Row 2
            HStack(spacing: 6) {
                key(width: 32)
                ForEach(0..<8) { _ in key(width: 24) }
                key(width: 20)
            }
            // Row 3
            HStack(spacing: 6) {
                key(width: 40)
                ForEach(0..<7) { _ in key(width: 24) }
                key(width: 26)
            }
            // Row 4
            HStack(spacing: 6) {
                key(width: 50)
                key(width: 24)
                key(width: 110) // Spacebar
                key(width: 24)
                key(width: 50)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    func key(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 0.2))
            .frame(width: width, height: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
    }
}

// Main screen view (Ready State)
struct ReadyView: View {
    @ObservedObject var model = AppModel.shared
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 18) {
                // Header
                VStack(spacing: 6) {
                    Text("Keyboard Cleaner")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Полная блокировка клавиатуры для безопасной чистки")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 8)

                // Keyboard Graphic
                KeyboardGraphicView()
                    .frame(width: 320, height: 140)
                    .shadow(color: Color.blue.opacity(0.12), radius: 20)
                
                // Accessibility Status Info
                VStack(spacing: 8) {
                    if model.isAccessibilityGranted {
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Доступ к системе разрешен")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            Text("Блокируются все клавиши, включая F1–F12, яркость и громкость.")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)
                                Text("Частичная блокировка. Дайте доступ для блокировки всех клавиш.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                            
                            Button("Разрешить полную блокировку") {
                                GlobalEventTap.shared.requestAccessibilityPrompt()
                                if let url = accessibilitySettingsURL {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Color.white.opacity(0.03))
                .cornerRadius(10)
                
                // Stats Card
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Сеансов очистки")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        Text("\(model.historyCount)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.blue)
                    }
                    
                    Divider()
                        .frame(height: 40)
                        .background(Color.white.opacity(0.1))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Состояние")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Готов к работе")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                
                // Block Button
                Button(action: {
                    model.startBlocking()
                }) {
                    Text("Блокировать клавиатуру")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan, Color.green],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: isHovering ? Color.cyan.opacity(0.4) : Color.cyan.opacity(0.2), radius: 15, x: 0, y: 5)
                        )
                        .scaleEffect(isHovering ? 1.03 : 1.0)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isHovering = hovering
                    }
                }
                .padding(.bottom, 16)
            }
            .padding()
        }
        .frame(minWidth: 550)
        .onAppear {
            model.checkAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkAccessibilityStatus()
        }
    }
}

// Hold to Unlock Button with Circular Progress
struct HoldToUnlockButton: View {
    @Binding var progress: Double
    var onUnlock: () -> Void
    
    @State private var isPressing = false
    @State private var isUnlocked = false
    // Progress is derived from the press start time, so view re-renders
    // (every blocked key press) cannot stall or reset the countdown.
    @State private var pressStartDate: Date?
    private let progressTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                // Background Circle
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                    .frame(width: 80, height: 80)
                
                // Progress Circle
                Circle()
                    .trim(from: 0.0, to: CGFloat(min(progress, 1.0)))
                    .stroke(
                        LinearGradient(
                            colors: [isUnlocked ? Color.green : Color.orange, Color.blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(Angle(degrees: -90))
                
                // Icon
                Image(systemName: isUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isUnlocked ? .green : .white)
                    .scaleEffect(isPressing ? 1.15 : 1.0)
            }
            .background(
                Circle()
                    .fill(Color(white: 0.12))
                    .frame(width: 80, height: 80)
                    .shadow(color: isUnlocked ? Color.green.opacity(0.4) : (isPressing ? Color.orange.opacity(0.3) : Color.black.opacity(0.3)), radius: 10)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressing && !isUnlocked {
                            pressStartDate = Date()
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                                isPressing = true
                            }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                            isPressing = false
                        }
                        
                        if isUnlocked {
                            onUnlock()
                        } else {
                            resetProgress()
                        }
                    }
            )
            .onReceive(progressTimer) { _ in
                advanceProgress()
            }
            
            Text(isUnlocked ? "Отпустите кнопку мыши" : "Зажмите и удерживайте для разблокировки")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(isUnlocked ? .green : .white.opacity(0.7))
            
            if !isUnlocked {
                Text("Осталось: \(String(format: "%.1f", max(0.0, unlockHoldDuration * (1.0 - progress)))) сек")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text("Готово!")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green.opacity(0.8))
            }
        }
    }
    
    func advanceProgress() {
        guard isPressing, !isUnlocked, let pressStartDate else { return }

        let nextProgress = min(Date().timeIntervalSince(pressStartDate) / unlockHoldDuration, 1.0)
        if nextProgress >= 1.0 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                progress = 1.0
                isUnlocked = true
            }
        } else {
            withAnimation(.linear(duration: 0.05)) {
                progress = nextProgress
            }
        }
    }
    
    func resetProgress() {
        isUnlocked = false
        pressStartDate = nil
        if progress < 1.0 {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                progress = 0.0
            }
        }
    }
}

// Giant Keycap showing the last pressed key
struct GiantKeycapView: View {
    let key: String
    
    var body: some View {
        VStack(spacing: 8) {
            Text(key)
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundColor(.orange)
                .shadow(color: .orange.opacity(0.4), radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 20)
                .frame(minWidth: 140, maxWidth: 280, minHeight: 90, maxHeight: 90)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.14))
                        .shadow(color: Color.black.opacity(0.5), radius: 6, x: 0, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.4), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
            
            Text("ПОСЛЕДНЕЕ НАЖАТИЕ")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)
        }
    }
}

// Stable and glitch-free Key History Stream using a single Text view
struct KeyHistoryStreamView: View {
    let logs: [KeyLogEntry]
    
    var body: some View {
        VStack(spacing: 8) {
            Text("ИСТОРИЯ НАЖАТИЙ")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .tracking(1)
            
            HStack {
                if logs.isEmpty {
                    Text("Нажимайте любые клавиши...")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                } else {
                    Text(logs.map { $0.text }.joined(separator: "  ›  "))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minWidth: 320, maxWidth: 500)
            .background(Color.black.opacity(0.2))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
    }
}

// Fullscreen Blocked Overlay
struct BlockedView: View {
    @ObservedObject var model = AppModel.shared
    @State private var unlockProgress: Double = 0.0
    @State private var isPulsing = false
    @State private var contentOpacity: Double = 1.0

    // keyboard.badge.eye is only available starting with macOS 13.
    private var blockedSymbolName: String {
        if #available(macOS 13.0, *) {
            return "keyboard.badge.eye.fill"
        }
        return "keyboard"
    }

    var body: some View {
        ZStack {
            // Dark Overlay
            Color.black.ignoresSafeArea()
            
            // Neon radial glow
            RadialGradient(
                colors: [Color.orange.opacity(0.08), Color.clear],
                center: .center,
                startRadius: 10,
                endRadius: 600
            )
            .ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Warning icon & Status
                VStack(spacing: 12) {
                    Image(systemName: blockedSymbolName)
                        .font(.system(size: 56))
                        .foregroundColor(.orange)
                        .shadow(color: .orange.opacity(0.4), radius: 15)
                        .scaleEffect(isPulsing ? 1.04 : 0.96)
                        // Scope the endless animation to the scale only. A
                        // global withAnimation(.repeatForever) also captured the
                        // initial layout, so the icon kept drifting around.
                        .animation(
                            .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                            value: isPulsing
                        )
                        .onAppear {
                            DispatchQueue.main.async {
                                isPulsing = true
                            }
                        }
                    
                    Text("КЛАВИАТУРА ЗАБЛОКИРОВАНА")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(2)
                    
                    Text(model.isFullyBlocked
                         ? "Полная блокировка активна. Все клавиши (включая F1–F12 и громкость) заблокированы."
                         : "Внимание: активна частичная блокировка!\nСистемные клавиши (яркость, громкость, Siri) могут срабатывать.\n\nЧтобы блокировать все клавиши, разблокируйте клавиатуру и разрешите доступ:\nСистемные настройки → Конфиденциальность и безопасность → Универсальный доступ.")
                        .font(.system(size: 13, weight: model.isFullyBlocked ? .regular : .bold))
                        .foregroundColor(model.isFullyBlocked ? .white.opacity(0.6) : .yellow.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 30)
                
                // Giant keycap for last pressed key
                GiantKeycapView(key: model.keyLogs.last?.text ?? "⌨️")
                
                // Keyboard logs stream (Glitch-free horizontal joined string)
                KeyHistoryStreamView(logs: model.keyLogs)
                
                // Stats Card & Clear Button
                HStack(spacing: 20) {
                    Text("Заблокировано нажатий: \(model.blockedCount)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    
                    if !model.keyLogs.isEmpty {
                        Button(action: {
                            model.keyLogs.removeAll()
                            model.blockedCount = 0
                        }) {
                            Text("Очистить")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                
                Spacer()
                
                // Unlock Button
                HoldToUnlockButton(progress: $unlockProgress) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        contentOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        model.stopBlocking()
                    }
                }
                .padding(.bottom, 40)
            }
            .padding()
            .opacity(contentOpacity)
        }
    }
}

struct KeycapView: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(.title3, design: .monospaced))
            .bold()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.18))
                    .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .foregroundColor(.white)
    }
}

// Virtual key codes of F1–F20 (Carbon kVK_F* constants)
private let functionKeyNames: [UInt16: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
    97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
]

// Helper to translate key events to readable characters/strings
func displayName(for event: NSEvent) -> String {
    if event.type == .systemDefined {
        if event.subtype.rawValue == 8 {
            let keyCode = ((event.data1 & 0xFFFF0000) >> 16)
            return getMediaKeyName(keyCode)
        }
        return "Media"
    }
    
    if event.type == .flagsChanged {
        let keyCode = event.keyCode
        switch keyCode {
        case 54: return "R ⌘"
        case 55: return "L ⌘"
        case 56: return "L ⇧"
        case 57: return "⇪ Caps"
        case 58: return "L ⌥"
        case 59: return "L ⌃"
        case 60: return "R ⇧"
        case 61: return "R ⌥"
        case 62: return "R ⌃"
        case 63: return "fn"
        default: return "Mod"
        }
    }
    
    if let functionKeyName = functionKeyNames[event.keyCode] {
        return functionKeyName
    }

    switch event.keyCode {
    case 36: return "⏎ Enter"
    case 71: return "⌧ Clear"
    case 76: return "⌤ Enter"
    case 114: return "Help"
    case 48: return "⇥ Tab"
    case 49: return "␣ Space"
    case 51: return "⌫ Del"
    case 53: return "⎋ Esc"
    case 115: return "↖ Home"
    case 116: return "⇞ PgUp"
    case 117: return "⌦ Del"
    case 119: return "↘ End"
    case 121: return "⇟ PgDn"
    case 123: return "← Left"
    case 124: return "→ Right"
    case 125: return "↓ Down"
    case 126: return "↑ Up"
    default:
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let character = chars.first!
            if character.isWhitespace || character.isNewline {
                return "Key"
            }
            // AppKit reports special keys as Private Use Area code points
            // (NSUpArrowFunctionKey etc.), which render as garbage glyphs.
            if let scalar = character.unicodeScalars.first,
               (0xF700...0xF8FF).contains(scalar.value) {
                return "Key"
            }
            return String(character).uppercased()
        }
        return "Key"
    }
}

// Helper for media key names
func getMediaKeyName(_ keyCode: Int) -> String {
    switch keyCode {
    case 7: return "🔊 Vol+"
    case 8: return "🔉 Vol-"
    case 9: return "🔇 Mute"
    case 16: return "⏯ Play"
    case 17: return "⏭ Next"
    case 18: return "⏮ Prev"
    case 1: return "🔆 Bright+"
    case 3: return "🔅 Bright-"
    default: return "Media"
    }
}

// Fullscreen window class
class BlockWindow: NSWindow {
    private let allowsKey: Bool

    init(contentRect: NSRect, contentView: NSView, allowsKey: Bool = true) {
        self.allowsKey = allowsKey
        // Create the window at its final size: laying SwiftUI out at .zero and
        // then resizing makes the content (and its animations) fly in from a corner.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Swift owns this window via ARC. With the AppKit default (true),
        // close() releases it a second time and the app crashes on the next
        // autorelease pool drain.
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.contentView = contentView
        self.level = .screenSaver
        self.backgroundColor = .black
        self.isOpaque = true
        self.ignoresMouseEvents = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.hidesOnDeactivate = false
    }
    
    override var canBecomeKey: Bool {
        return allowsKey
    }

    override var canBecomeMain: Bool {
        return allowsKey
    }
}

// Plain overlay for secondary displays so nothing behind can be clicked
struct SecondaryBlockedView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange.opacity(0.8))
                Text("КЛАВИАТУРА ЗАБЛОКИРОВАНА")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .tracking(2)
                Text("Разблокировка — на основном экране")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}

// App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var mainWindow: NSWindow!
    var blockWindow: BlockWindow?
    var secondaryBlockWindows: [BlockWindow] = []
    var eventMonitor: Any?
    var windowFocusObserver: Any?
    var screenChangeObserver: Any?
    private var sleepActivity: NSObjectProtocol?
    private var previousPresentationOptions: NSApplication.PresentationOptions = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        AppModel.shared.onBlock = { [weak self] in
            self?.enterBlockMode()
        }
        
        AppModel.shared.onUnblock = { [weak self] in
            self?.exitBlockMode()
        }
        
        let hostingView = NSHostingView(rootView: ReadyView())
        // Size the window to the SwiftUI content so nothing gets clipped.
        let contentSize = hostingView.fittingSize

        mainWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        mainWindow.isReleasedWhenClosed = false
        mainWindow.title = "Keyboard Cleaner"
        mainWindow.contentView = hostingView
        mainWindow.setContentSize(contentSize)
        mainWindow.center()
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titleVisibility = .hidden
        mainWindow.isMovableByWindowBackground = true
        mainWindow.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainMenu() -> NSMenu {
        let appName = "Keyboard Cleaner"
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "О программе \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Показать все", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    // Primary overlay goes on the main window's screen; every other display
    // gets a plain overlay so no other app can be clicked during cleaning.
    private func layoutBlockWindows() {
        guard let window = blockWindow else { return }

        let primaryScreen = blockScreen()
        let primaryFrame = primaryScreen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        if window.frame != primaryFrame {
            window.setFrame(primaryFrame, display: true)
        }

        closeSecondaryBlockWindows()
        for screen in NSScreen.screens where screen != primaryScreen {
            let secondary = BlockWindow(
                contentRect: screen.frame,
                contentView: NSHostingView(rootView: SecondaryBlockedView()),
                allowsKey: false
            )
            secondary.setFrame(screen.frame, display: false)
            secondary.orderFrontRegardless()
            secondaryBlockWindows.append(secondary)
        }
    }

    private func closeSecondaryBlockWindows() {
        for window in secondaryBlockWindows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        secondaryBlockWindows.removeAll()
    }

    private func blockScreen() -> NSScreen? {
        return mainWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    func enterBlockMode() {
        guard let mainWindow, blockWindow == nil else { return }

        let screenFrame = blockScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let hostingView = NSHostingView(rootView: BlockedView())
        let window = BlockWindow(contentRect: screenFrame, contentView: hostingView)
        window.setFrame(screenFrame, display: false)

        self.blockWindow = window
        layoutBlockWindows()

        // Fade the whole overlay in at the window level; animating SwiftUI
        // opacity while the window is being shown looked jumpy.
        window.alphaValue = 0.0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            window.animator().alphaValue = 1.0
        }

        // Hide main window immediately
        mainWindow.orderOut(nil)

        // Keep the display awake: cleaning takes a while without touching the
        // mouse, and a sleeping screen would hide the unlock button.
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Keyboard is blocked for cleaning"
        )

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layoutBlockWindows()
        }
        
        // Strict kiosk presentation options
        previousPresentationOptions = NSApp.presentationOptions
        let options: NSApplication.PresentationOptions = [
            .disableProcessSwitching,
            .disableAppleMenu,
            .hideDock,
            .hideMenuBar,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication
        ]
        NSApp.presentationOptions = options
        
        // 1. Try global event tap first
        let success = GlobalEventTap.shared.start()
        AppModel.shared.isFullyBlocked = success
        
        // 2. Fallback to local monitor if global event tap fails (no accessibility permissions)
        if !success {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { event in
                if event.type == .systemDefined {
                    if event.subtype.rawValue == 8 {
                        let keyCode = ((event.data1 & 0xFFFF0000) >> 16)
                        let name = getMediaKeyName(keyCode)
                        DispatchQueue.main.async {
                            AppModel.shared.logEvent(name)
                        }
                        return nil // Swallow local media event
                    }
                    return event
                }
                
                let name = displayName(for: event)
                if event.type == .keyDown || event.type == .flagsChanged {
                    DispatchQueue.main.async {
                        AppModel.shared.logEvent(name)
                    }
                }
                return nil // Swallow event
            }
        }
        
        // Keep window key - reactivate if it resigns focus
        windowFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if AppModel.shared.isBlocked {
                self.blockWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func exitBlockMode() {
        // Stop global event tap
        GlobalEventTap.shared.stop()
        AppModel.shared.isFullyBlocked = false
        
        // Stop local event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        // Remove focus observer
        if let observer = windowFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            windowFocusObserver = nil
        }

        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }

        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }

        // Restore window presentation options
        NSApp.presentationOptions = previousPresentationOptions

        // Order main window back in
        mainWindow.makeKeyAndOrderFront(nil)

        // Tear down the hosting view synchronously on the main thread. Delaying
        // close lets SwiftUI timers/animations outlive the window and race with
        // Objective-C object destruction.
        if let window = blockWindow {
            self.blockWindow = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        closeSecondaryBlockWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalEventTap.shared.stop()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        if let observer = windowFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            windowFocusObserver = nil
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Custom NSApplication subclass to override event dispatching as a local fallback shield
class CleanerApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if AppModel.shared.isBlocked {
            if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged || event.type == .systemDefined {
                let name = displayName(for: event)
                // Filter out duplicates on keyUp
                if event.type == .keyDown || event.type == .flagsChanged {
                    AppModel.shared.logEvent(name)
                }
                return // Swallow the event at the application level
            }
        }
        super.sendEvent(event)
    }
}

// Entry Point
let app = CleanerApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
