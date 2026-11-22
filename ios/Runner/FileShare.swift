import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// File transfer over `/file` (docs/protocol.md 10절) for the iOS app: the host of
/// `FileTransfers`, with files on disk, the document picker to choose what to send,
/// the export screens (Files, share sheet) for what was received, and a local
/// notification when an offer or a finished file arrives while the app isn't active.
/// Everything runs on the main queue with the engine; file I/O on `ioQueue`.
final class FileShare: NSObject, FileTransferHost, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
  private(set) var transfers: FileTransfers!
  private let emit: (String, [String: Any]) -> Void
  private let deviceIdOf: (PeerId) -> String
  private let peerNameOf: (PeerId) -> String
  private let ioQueue = DispatchQueue(label: "com.rouddy.bluetooth_communicator.file-io")

  /// Received files, one directory each so the original name can be kept.
  private let receivedRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("received", isDirectory: true)
  /// Received files older than this are deleted at launch.
  private let keepReceivedFor: TimeInterval = 24 * 60 * 60

  /// What's on screen: the picker for a file to send, or an export screen.
  private enum Presentation {
    case pick(PeerId, FlutterResult)
    case save(FlutterResult)
    case share
  }

  private var presentation: Presentation?
  /// Transfers whose offer notification is up.
  private var offerNotifications: Set<Int64> = []
  private var askedForNotifications = false

  init(
    engine: ProtocolEngine, scheduler: EngineScheduler, emit: @escaping (String, [String: Any]) -> Void,
    deviceId: @escaping (PeerId) -> String, peerName: @escaping (PeerId) -> String
  ) {
    self.emit = emit
    self.deviceIdOf = deviceId
    self.peerNameOf = peerName
    super.init()
    transfers = FileTransfers(engine: engine, scheduler: scheduler, host: self)
    pruneReceived()
  }

  // MARK: - Channel

  /// `sendFile`: offers the file at `path`, or one the user picks; the result is
  /// whether a file was offered.
  func sendFile(peerId: PeerId, path: String?, result: @escaping FlutterResult) {
    if let path {
      do {
        try offer(peerId: peerId, url: URL(fileURLWithPath: path), deleteOnClose: false)
        result(true)
      } catch {
        result(FlutterError(code: "READ_FAILED", message: error.localizedDescription, details: nil))
      }
      return
    }
    guard presentation == nil else {
      return result(FlutterError(code: "BUSY", message: "A picker is already open", details: nil))
    }
    guard let top = topViewController() else {
      return result(FlutterError(code: "NO_UI", message: "Nothing on screen to show the picker from", details: nil))
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presentation = .pick(peerId, result)
    top.present(picker, animated: true)
    picker.presentationController?.delegate = self
  }

  func respond(id: Int64, accept: Bool) {
    transfers.respond(id: id, accept: accept)
  }

  func cancel(id: Int64) {
    transfers.cancel(id: id)
  }

  func dismiss(id: Int64) {
    transfers.dismiss(id: id)
  }

  /// `exportFile`: `save` exports a received file to Files (true once saved, false if
  /// cancelled); `share` shows the share sheet (true once it's up).
  func export(id: Int64, action: String, result: @escaping FlutterResult) {
    guard let transfer = transfers[id], !transfer.outgoing, transfer.state == .completed, let path = transfer.path,
      FileManager.default.fileExists(atPath: path)
    else {
      return result(FlutterError(code: "NOT_FOUND", message: "No received file \(id)", details: nil))
    }
    guard presentation == nil else {
      return result(FlutterError(code: "BUSY", message: "An export is already open", details: nil))
    }
    guard let top = topViewController() else {
      return result(FlutterError(code: "NO_UI", message: "Nothing on screen to export from", details: nil))
    }
    let url = URL(fileURLWithPath: path)
    switch action {
    case "save":
      let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
      picker.delegate = self
      presentation = .save(result)
      top.present(picker, animated: true)
      picker.presentationController?.delegate = self
    case "share":
      let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = controller.popoverPresentationController {
        // iPad: anchored to the middle of the screen.
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
        if case .share = self?.presentation {
          self?.presentation = nil
        }
      }
      presentation = .share
      top.present(controller, animated: true) { result(true) }
    default:
      result(FlutterError(code: "BAD_ARGS", message: "Unknown export action \(action)", details: nil))
    }
  }

  /// Tells a newly attached Dart side the transfers in progress and the received files
  /// waiting to be saved; asks once for permission to post notifications.
  func replay() {
    transfers.all().forEach { emit("fileTransfer", event($0)) }
    if !askedForNotifications {
      askedForNotifications = true
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
  }

  // MARK: - Sending

  private func offer(peerId: PeerId, url: URL, deleteOnClose: Bool) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if attributes[.type] as? FileAttributeType == .typeDirectory {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let handle = try FileHandle(forReadingFrom: url)
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? FileMessage.defaultMime
    let source = HandleSource(handle: handle, url: url, deleteOnClose: deleteOnClose, queue: ioQueue)
    transfers.offer(peerId: peerId, name: url.lastPathComponent, size: size, mime: mime, source: source)
  }

  // MARK: - FileTransferHost

  func createSink(_ transfer: FileTransfer) -> FileSink? {
    let manager = FileManager.default
    if let free = try? receivedRoot.deletingLastPathComponent()
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
      free < transfer.size
    {
      return nil
    }
    let directory = receivedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent(transfer.name)
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      guard manager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
      let handle = try FileHandle(forWritingTo: url)
      return HandleSink(handle: handle, url: url, directory: directory, queue: ioQueue)
    } catch {
      try? manager.removeItem(at: directory)
      return nil
    }
  }

  func onTransferChanged(_ transfer: FileTransfer) {
    emit("fileTransfer", event(transfer))
    guard !transfer.outgoing else { return }
    let identifier = "file-\(transfer.id)"
    let center = UNUserNotificationCenter.current()
    if transfer.state != .offered, offerNotifications.remove(transfer.id) != nil {
      center.removePendingNotificationRequests(withIdentifiers: [identifier])
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    guard UIApplication.shared.applicationState != .active else { return }
    let content = UNMutableNotificationContent()
    switch transfer.state {
    case .offered:
      guard offerNotifications.insert(transfer.id).inserted else { return }
      let size = ByteCountFormatter.string(fromByteCount: transfer.size, countStyle: .file)
      content.title = "파일 받기 요청: \(peerNameOf(transfer.peerId))"
      content.body = "\(transfer.name) (\(size)) · 눌러서 확인하세요"
    case .completed:
      content.title = "파일을 받았습니다: \(transfer.name)"
      content.body = "눌러서 저장하거나 공유하세요"
    default:
      return
    }
    content.sound = .default
    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }

  private func event(_ transfer: FileTransfer) -> [String: Any] {
    var event: [String: Any] = [
      "id": Int(transfer.id),
      "deviceId": deviceIdOf(transfer.peerId),
      "peerId": transfer.peerId.description,
      "direction": transfer.outgoing ? "send" : "receive",
      "name": transfer.name,
      "size": Int(transfer.size),
      "mime": transfer.mime,
      "state": FileShare.stateName(transfer.state),
      "bytes": Int(transfer.bytes),
      "byPeer": transfer.byPeer,
    ]
    event["reason"] = transfer.reason
    event["status"] = transfer.status
    event["path"] = transfer.path
    return event
  }

  /// Names for the platform channel (`fileTransfer.state`).
  static func stateName(_ state: TransferState) -> String {
    switch state {
    case .offered: return "offered"
    case .waiting: return "waiting"
    case .transferring: return "transferring"
    case .completed: return "completed"
    case .declined: return "declined"
    case .canceled: return "canceled"
    case .failed: return "failed"
    }
  }

  private func pruneReceived() {
    let root = receivedRoot
    let cutoff = Date().addingTimeInterval(-keepReceivedFor)
    ioQueue.async {
      let manager = FileManager.default
      let entries = (try? manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
      for entry in entries {
        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if (modified ?? .distantPast) < cutoff {
          try? manager.removeItem(at: entry)
        }
      }
    }
  }

  // MARK: - Presenting

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let current = presentation
    presentation = nil
    switch current {
    case .pick(let peerId, let result):
      guard let url = urls.first else { return result(false) }
      do {
        try offer(peerId: peerId, url: url, deleteOnClose: true)
        result(true)
      } catch {
        try? FileManager.default.removeItem(at: url)
        result(FlutterError(code: "READ_FAILED", message: error.localizedDescription, details: nil))
      }
    case .save(let result):
      result(true)
    case .share, nil:
      break
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pickerClosed()
  }

  /// Swiped away instead of cancelled.
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    pickerClosed()
  }

  private func pickerClosed() {
    let current = presentation
    switch current {
    case .pick(_, let result), .save(let result):
      presentation = nil
      result(false)
    case .share, nil:
      break
    }
  }
}

/// Reads a file front to back on the I/O queue; answers on the main queue.
private final class HandleSource: FileSource {
  private let handle: FileHandle
  private let url: URL
  /// A picker's copy, deleted once the transfer ends.
  private let deleteOnClose: Bool
  private let queue: DispatchQueue
  private var closed = false

  init(handle: FileHandle, url: URL, deleteOnClose: Bool, queue: DispatchQueue) {
    self.handle = handle
    self.url = url
    self.deleteOnClose = deleteOnClose
    self.queue = queue
  }

  func read(_ maxBytes: Int, _ done: @escaping (Data?) -> Void) {
    guard !closed else { return done(nil) }
    let handle = handle
    queue.async {
      let data: Data?
      do {
        data = try handle.read(upToCount: maxBytes) ?? Data()
      } catch {
        data = nil
      }
      DispatchQueue.main.async { done(data) }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    let (handle, url, deleteOnClose) = (handle, url, deleteOnClose)
    queue.async {
      try? handle.close()
      if deleteOnClose {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}

/// Writes a received file on the I/O queue; answers on the main queue.
private final class HandleSink: FileSink {
  private let handle: FileHandle
  private let url: URL
  /// The file's own directory, removed with it on abort.
  private let directory: URL
  private let queue: DispatchQueue
  /// Only touched on `queue`.
  private var closed = false

  init(handle: FileHandle, url: URL, directory: URL, queue: DispatchQueue) {
    self.handle = handle
    self.url = url
    self.directory = directory
    self.queue = queue
  }

  func write(_ bytes: Data, _ done: @escaping (Bool) -> Void) {
    queue.async { [self] in
      var written = false
      if !closed {
        do {
          try handle.write(contentsOf: bytes)
          written = true
        } catch {}
      }
      DispatchQueue.main.async { done(written) }
    }
  }

  func finish(_ done: @escaping (String?) -> Void) {
    queue.async { [self] in
      var path: String?
      if !closed {
        closed = true
        do {
          try handle.synchronize()
          try handle.close()
          path = url.path
        } catch {}
      }
      DispatchQueue.main.async { done(path) }
    }
  }

  func abort() {
    queue.async { [self] in
      if !closed {
        closed = true
        try? handle.close()
      }
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
