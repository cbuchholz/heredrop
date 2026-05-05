import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

private enum AppConstants {
    static let bundleIdentifier = "com.cortbuchholz.heredrop"
    static let clientHeader = "heredrop/macos-app"
    static let apiBaseURL = URL(string: "https://here.now")!
    static let avatarSize = NSSize(width: 118, height: 118)
    static let frameDefaultsKey = "avatarFrame"
    static let lastURLDefaultsKey = "lastPublishedURL"
    static let lastClaimURLDefaultsKey = "lastClaimURL"
}

private enum UploadError: LocalizedError {
    case noFiles
    case cannotReadFile(URL)
    case cannotBuildRequest
    case unexpectedResponse(String)
    case api(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "No readable files were dropped."
        case .cannotReadFile(let url):
            return "Cannot read \(url.lastPathComponent)."
        case .cannotBuildRequest:
            return "Could not build the here.now request."
        case .unexpectedResponse(let detail):
            return "Unexpected here.now response: \(detail)"
        case .api(let message):
            return message
        case .http(let status, let context):
            return "\(context) failed with HTTP \(status)."
        }
    }
}

private struct LocalUploadFile: Sendable {
    let path: String
    let localURL: URL
    let size: Int64
    let contentType: String
    let hash: String
}

private struct FileDescriptor: Encodable {
    let path: String
    let size: Int64
    let contentType: String
    let hash: String
}

private struct ViewerDescriptor: Encodable {
    let title: String
    let description: String
}

private struct PublishRequest: Encodable {
    let files: [FileDescriptor]
    let viewer: ViewerDescriptor
}

private struct FinalizeRequest: Encodable {
    let versionId: String
}

private struct APIErrorResponse: Decodable {
    let error: String?
    let details: String?
}

private struct PublishCreateResponse: Decodable {
    let slug: String
    let siteUrl: String
    let upload: UploadInfo
    let claimUrl: String?
    let expiresAt: String?
    let anonymous: Bool?
}

private struct UploadInfo: Decodable {
    let versionId: String
    let uploads: [UploadTarget]
    let finalizeUrl: String
}

private struct UploadTarget: Decodable {
    let path: String
    let method: String?
    let url: String
    let headers: [String: String]?
}

private struct FinalizeResponse: Decodable {
    let success: Bool?
    let siteUrl: String?
}

private struct PublishResult: Sendable {
    let siteURL: String
    let claimURL: String?
    let expiresAt: String?
    let isAuthenticated: Bool
    let fileCount: Int
}

private final class HereNowUploader {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(fileURLs: [URL]) async throws -> PublishResult {
        let localFiles = try collectFiles(from: fileURLs)
        guard !localFiles.isEmpty else {
            throw UploadError.noFiles
        }

        let apiKey = loadAPIKey()
        let requestPayload = PublishRequest(
            files: localFiles.map {
                FileDescriptor(
                    path: $0.path,
                    size: $0.size,
                    contentType: $0.contentType,
                    hash: $0.hash
                )
            },
            viewer: ViewerDescriptor(
                title: localFiles.count == 1 ? localFiles[0].path : "Shared files",
                description: "Uploaded with HereDrop"
            )
        )

        let createResponse = try await createPublish(payload: requestPayload, apiKey: apiKey)
        let fileByPath = Dictionary(uniqueKeysWithValues: localFiles.map { ($0.path, $0) })

        for target in createResponse.upload.uploads {
            guard let file = fileByPath[target.path] else {
                throw UploadError.unexpectedResponse("Missing upload source for \(target.path)")
            }
            try await upload(file: file, to: target)
        }

        let finalizedURL = try await finalize(
            finalizeURL: createResponse.upload.finalizeUrl,
            versionID: createResponse.upload.versionId,
            apiKey: apiKey
        )

        return PublishResult(
            siteURL: finalizedURL ?? createResponse.siteUrl,
            claimURL: createResponse.claimUrl,
            expiresAt: createResponse.expiresAt,
            isAuthenticated: apiKey != nil,
            fileCount: localFiles.count
        )
    }

    private func createPublish(payload: PublishRequest, apiKey: String?) async throws -> PublishCreateResponse {
        let url = AppConstants.apiBaseURL.appendingPathComponent("api/v1/publish")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(AppConstants.clientHeader, forHTTPHeaderField: "x-herenow-client")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data, context: "Create publish")
        return try decodeOrThrow(PublishCreateResponse.self, from: data)
    }

    private func upload(file: LocalUploadFile, to target: UploadTarget) async throws {
        guard let uploadURL = URL(string: target.url) else {
            throw UploadError.cannotBuildRequest
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = target.method ?? "PUT"
        if let headers = target.headers {
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.upload(for: request, fromFile: file.localURL)
        try validateHTTP(response, data: data, context: "Upload \(file.path)")
    }

    private func finalize(finalizeURL: String, versionID: String, apiKey: String?) async throws -> String? {
        guard let url = URL(string: finalizeURL) else {
            throw UploadError.cannotBuildRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(AppConstants.clientHeader, forHTTPHeaderField: "x-herenow-client")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        request.httpBody = try encoder.encode(FinalizeRequest(versionId: versionID))

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response, data: data, context: "Finalize publish")
        let finalizeResponse = try decodeOrThrow(FinalizeResponse.self, from: data)
        return finalizeResponse.siteUrl
    }

    private func validateHTTP(_ response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UploadError.unexpectedResponse(context)
        }
        guard 200..<300 ~= http.statusCode else {
            if let apiError = try? decoder.decode(APIErrorResponse.self, from: data),
               let message = apiError.error {
                let details = apiError.details.map { " (\($0))" } ?? ""
                throw UploadError.api(message + details)
            }
            throw UploadError.http(http.statusCode, context)
        }
    }

    private func decodeOrThrow<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let apiError = try? decoder.decode(APIErrorResponse.self, from: data),
           let message = apiError.error {
            let details = apiError.details.map { " (\($0))" } ?? ""
            throw UploadError.api(message + details)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw UploadError.unexpectedResponse(body)
        }
    }

    private func loadAPIKey() -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["HERENOW_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentKey.isEmpty {
            return environmentKey
        }

        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".herenow")
            .appendingPathComponent("credentials")
        guard let credentials = try? String(contentsOf: credentialsURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !credentials.isEmpty else {
            return nil
        }
        return credentials
    }

    private func collectFiles(from urls: [URL]) throws -> [LocalUploadFile] {
        var files: [LocalUploadFile] = []
        var usedPaths = Set<String>()
        let multipleRoots = urls.count > 1

        for url in urls {
            let resolvedURL = url.standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: resolvedURL.path) else {
                throw UploadError.cannotReadFile(resolvedURL)
            }

            if try isDirectory(resolvedURL) {
                let rootPrefix = multipleRoots ? sanitizePathComponent(resolvedURL.lastPathComponent) + "/" : ""
                let discovered = try filesInsideDirectory(resolvedURL, rootPrefix: rootPrefix, usedPaths: &usedPaths)
                files.append(contentsOf: discovered)
            } else {
                let path = uniquePath(sanitizePathComponent(resolvedURL.lastPathComponent), usedPaths: &usedPaths)
                files.append(try makeLocalUploadFile(localURL: resolvedURL, path: path))
            }
        }

        return files
    }

    private func filesInsideDirectory(_ directoryURL: URL, rootPrefix: String, usedPaths: inout Set<String>) throws -> [LocalUploadFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw UploadError.cannotReadFile(directoryURL)
        }

        var files: [LocalUploadFile] = []
        let rootPath = directoryURL.path

        for case let fileURL as URL in enumerator {
            guard try !isDirectory(fileURL) else {
                continue
            }
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                continue
            }

            let relativePath = String(fileURL.path.dropFirst(rootPath.count + 1))
            guard relativePath != ".DS_Store",
                  !relativePath.hasPrefix(".herenow/") else {
                continue
            }

            let cleanPath = rootPrefix + relativePath
                .split(separator: "/")
                .map { sanitizePathComponent(String($0)) }
                .joined(separator: "/")
            let path = uniquePath(cleanPath, usedPaths: &usedPaths)
            files.append(try makeLocalUploadFile(localURL: fileURL.standardizedFileURL, path: path))
        }

        return files
    }

    private func makeLocalUploadFile(localURL: URL, path: String) throws -> LocalUploadFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw UploadError.cannotReadFile(localURL)
        }
        return LocalUploadFile(
            path: path,
            localURL: localURL,
            size: size.int64Value,
            contentType: contentType(for: localURL),
            hash: try sha256Hex(for: localURL)
        )
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        return values.isDirectory == true
    }

    private func contentType(for url: URL) -> String {
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private func sha256Hex(for url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw UploadError.cannotReadFile(url)
        }
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sanitizePathComponent(_ component: String) -> String {
        let cleaned = component
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "file" : cleaned
    }

    private func uniquePath(_ path: String, usedPaths: inout Set<String>) -> String {
        if !usedPaths.contains(path) {
            usedPaths.insert(path)
            return path
        }

        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let ext = nsPath.pathExtension
        let base = ext.isEmpty ? nsPath.lastPathComponent : nsPath.deletingPathExtension.components(separatedBy: "/").last ?? nsPath.lastPathComponent

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.isEmpty || directory == "." ? candidateName : "\(directory)/\(candidateName)"
            if !usedPaths.contains(candidate) {
                usedPaths.insert(candidate)
                return candidate
            }
            index += 1
        }
    }
}

private enum AvatarState: Equatable {
    case idle
    case hover
    case uploading
    case success
    case failure
}

@MainActor
private protocol AvatarViewDelegate: AnyObject {
    func avatarView(_ avatarView: AvatarView, didReceiveFileURLs urls: [URL])
    func avatarViewDidMove(_ avatarView: AvatarView)
}

@MainActor
private final class AvatarView: NSView {
    weak var delegate: AvatarViewDelegate?

    private var state: AvatarState = .idle
    private var statusText: String = ""
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func setState(_ state: AvatarState, text: String = "") {
        self.state = state
        self.statusText = text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let avatarRect = bounds.insetBy(dx: 8, dy: 8)
        let radius: CGFloat = 28
        let path = NSBezierPath(roundedRect: avatarRect, xRadius: radius, yRadius: radius)

        let colors: (NSColor, NSColor) = {
            switch state {
            case .idle:
                return (NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.52, alpha: 1.0),
                        NSColor(calibratedRed: 0.13, green: 0.62, blue: 0.43, alpha: 1.0))
            case .hover:
                return (NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.62, alpha: 1.0),
                        NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.44, alpha: 1.0))
            case .uploading:
                return (NSColor(calibratedRed: 0.11, green: 0.39, blue: 0.70, alpha: 1.0),
                        NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.76, alpha: 1.0))
            case .success:
                return (NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.30, alpha: 1.0),
                        NSColor(calibratedRed: 0.42, green: 0.70, blue: 0.27, alpha: 1.0))
            case .failure:
                return (NSColor(calibratedRed: 0.74, green: 0.19, blue: 0.17, alpha: 1.0),
                        NSColor(calibratedRed: 0.91, green: 0.39, blue: 0.25, alpha: 1.0))
            }
        }()

        NSGradient(starting: colors.0, ending: colors.1)?.draw(in: path, angle: -35)

        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        if state == .hover {
            NSColor.white.withAlphaComponent(0.90).setStroke()
            let ring = NSBezierPath(roundedRect: avatarRect.insetBy(dx: 5, dy: 5), xRadius: radius - 5, yRadius: radius - 5)
            ring.lineWidth = 3
            ring.stroke()
        }

        drawPrimaryLabel(in: avatarRect)
        if !statusText.isEmpty {
            drawStatusText(in: avatarRect)
        }
    }

    private func drawPrimaryLabel(in rect: NSRect) {
        let label: String
        switch state {
        case .uploading:
            label = "..."
        case .success:
            label = "OK"
        case .failure:
            label = "ERR"
        default:
            label = "HN"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 25 : 34, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: 0
        ]
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let size = attributed.size()
        let point = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2 - 5
        )
        attributed.draw(at: point)
    }

    private func drawStatusText(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .kern: 0
        ]
        let attributed = NSAttributedString(string: statusText, attributes: attributes)
        let size = attributed.size()
        let maxWidth = rect.width - 20
        let clippedWidth = min(size.width, maxWidth)
        let textRect = NSRect(
            x: rect.midX - clippedWidth / 2,
            y: rect.maxY - 30,
            width: clippedWidth,
            height: 16
        )
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            return []
        }
        if state != .uploading {
            setState(.hover, text: "")
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if state == .hover {
            setState(.idle)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            return false
        }
        delegate?.avatarView(self, didReceiveFileURLs: urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = dragStartMouseLocation,
              let startOrigin = dragStartWindowOrigin else {
            return
        }

        let currentMouse = NSEvent.mouseLocation
        let nextOrigin = NSPoint(
            x: startOrigin.x + currentMouse.x - startMouse.x,
            y: startOrigin.y + currentMouse.y - startMouse.y
        )
        window.setFrameOrigin(nextOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.avatarViewDidMove(self)
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        NSApp.sendAction(#selector(AppDelegate.showStatusMenuFromAvatar), to: nil, from: self)
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, AvatarViewDelegate {
    private var panel: NSPanel?
    private var avatarView: AvatarView?
    private var statusItem: NSStatusItem?
    private var lastPublishedURL: String?
    private var lastClaimURL: String?
    private var lastError: String?
    private var isUploading = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastPublishedURL = UserDefaults.standard.string(forKey: AppConstants.lastURLDefaultsKey)
        lastClaimURL = UserDefaults.standard.string(forKey: AppConstants.lastClaimURLDefaultsKey)
        createPanel()
        createStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func avatarView(_ avatarView: AvatarView, didReceiveFileURLs urls: [URL]) {
        guard !isUploading else {
            return
        }

        isUploading = true
        lastError = nil
        avatarView.setState(.uploading, text: "Uploading")
        rebuildMenu()

        Task.detached(priority: .userInitiated) { [urls] in
            do {
                let result = try await HereNowUploader().upload(fileURLs: urls)
                await MainActor.run {
                    self.handleUploadSuccess(result)
                }
            } catch {
                await MainActor.run {
                    self.handleUploadFailure(error)
                }
            }
        }
    }

    func avatarViewDidMove(_ avatarView: AvatarView) {
        guard let frame = avatarView.window?.frame else {
            return
        }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: AppConstants.frameDefaultsKey)
    }

    @objc func showStatusMenuFromAvatar() {
        guard let button = statusItem?.button else {
            return
        }
        button.performClick(nil)
    }

    @objc private func copyLastURL() {
        guard let lastPublishedURL else {
            return
        }
        copyToClipboard(lastPublishedURL)
        avatarView?.setState(.success, text: "Copied")
        scheduleIdleReset()
    }

    @objc private func openLastURL() {
        guard let lastPublishedURL,
              let url = URL(string: lastPublishedURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyClaimURL() {
        guard let lastClaimURL else {
            return
        }
        copyToClipboard(lastClaimURL)
        avatarView?.setState(.success, text: "Claim")
        scheduleIdleReset()
    }

    @objc private func showAvatar() {
        panel?.orderFrontRegardless()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func createPanel() {
        let frame = restoredFrame() ?? defaultFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let avatarView = AvatarView(frame: NSRect(origin: .zero, size: AppConstants.avatarSize))
        avatarView.delegate = self
        panel.contentView = avatarView
        panel.orderFrontRegardless()

        self.avatarView = avatarView
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "HN"
        item.button?.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: isUploading ? "HereDrop: uploading" : "HereDrop", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        if let lastPublishedURL {
            let displayURL = truncated(lastPublishedURL, maxLength: 52)
            let lastURLItem = NSMenuItem(title: displayURL, action: nil, keyEquivalent: "")
            lastURLItem.isEnabled = false
            menu.addItem(lastURLItem)
            menu.addItem(NSMenuItem(title: "Copy Last URL", action: #selector(copyLastURL), keyEquivalent: "c"))
            menu.addItem(NSMenuItem(title: "Open Last URL", action: #selector(openLastURL), keyEquivalent: "o"))
        }

        if lastClaimURL != nil {
            menu.addItem(NSMenuItem(title: "Copy Claim URL", action: #selector(copyClaimURL), keyEquivalent: ""))
            let claimItem = NSMenuItem(title: "Anonymous uploads expire in 24h", action: nil, keyEquivalent: "")
            claimItem.isEnabled = false
            menu.addItem(claimItem)
        }

        if let lastError {
            let errorItem = NSMenuItem(title: "Error: \(truncated(lastError, maxLength: 56))", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Avatar", action: #selector(showAvatar), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit HereDrop", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func handleUploadSuccess(_ result: PublishResult) {
        isUploading = false
        lastPublishedURL = result.siteURL
        lastClaimURL = result.claimURL
        lastError = nil

        UserDefaults.standard.set(result.siteURL, forKey: AppConstants.lastURLDefaultsKey)
        if let claimURL = result.claimURL {
            UserDefaults.standard.set(claimURL, forKey: AppConstants.lastClaimURLDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.lastClaimURLDefaultsKey)
        }

        copyToClipboard(result.siteURL)
        avatarView?.setState(.success, text: "Copied")
        NSSound(named: "Glass")?.play()
        rebuildMenu()
        scheduleIdleReset()
    }

    private func handleUploadFailure(_ error: Error) {
        isUploading = false
        lastError = error.localizedDescription
        avatarView?.setState(.failure, text: "Failed")
        NSSound(named: "Basso")?.play()
        rebuildMenu()
        scheduleIdleReset(after: 4.0)
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func scheduleIdleReset(after delay: TimeInterval = 2.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isUploading else {
                return
            }
            self.avatarView?.setState(.idle)
        }
    }

    private func defaultFrame() -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screenFrame.maxX - AppConstants.avatarSize.width - 36,
            y: screenFrame.minY + 80,
            width: AppConstants.avatarSize.width,
            height: AppConstants.avatarSize.height
        )
    }

    private func restoredFrame() -> NSRect? {
        guard let frameString = UserDefaults.standard.string(forKey: AppConstants.frameDefaultsKey) else {
            return nil
        }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }
        return frame
    }

    private func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }
        let prefix = value.prefix(maxLength - 3)
        return "\(prefix)..."
    }
}

@MainActor
private func runCommandLineUpload(arguments: [String]) -> Bool {
    guard let uploadIndex = arguments.firstIndex(of: "--upload") else {
        return false
    }
    let paths = arguments.dropFirst(uploadIndex + 1).map { $0 }
    guard !paths.isEmpty else {
        fputs("usage: HereDrop --upload <file-or-dir> [more-files]\n", stderr)
        exit(2)
    }

    let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    Task.detached(priority: .userInitiated) {
        do {
            let result = try await HereNowUploader().upload(fileURLs: urls)
            print(result.siteURL)
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.siteURL, forType: .string)
            }
            if let claimURL = result.claimURL {
                fputs("anonymous publish expires in 24h\nclaim URL: \(claimURL)\n", stderr)
            } else if result.isAuthenticated {
                fputs("authenticated publish is permanent\n", stderr)
            }
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    RunLoop.main.run()
    return true
}

@main
@MainActor
private struct HereDropMain {
    static func main() {
        if runCommandLineUpload(arguments: CommandLine.arguments) {
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
