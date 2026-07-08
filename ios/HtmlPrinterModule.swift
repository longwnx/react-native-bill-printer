/**
 * HtmlPrinterModule.swift — iOS implementation
 *
 * Hai chế độ in:
 *   1. Silent print qua IPP (printerUrl != "") — UIPrinter(url:) → in thẳng không dialog
 *   2. Print dialog (printerUrl == "")          — UIPrintInteractionController hiện dialog
 *   3. ESC/POS TCP — HTML → WKWebView offscreen → snapshot → 1-bit dither → GS v 0 → TCP:port
 *
 * Supported page sizes:
 *   A4  → 595.28 × 841.89 pt
 *   A5  → 419.53 × 595.28 pt
 *   K80 → 204.09 pt wide (72mm thermal roll)
 *   K58 → 136.06 pt wide (48mm thermal roll)
 */

import UIKit
import WebKit
import Foundation

// RCTPromiseResolveBlock / RCTPromiseRejectBlock defined via ObjC bridge (.mm).
// Dùng typealias để Swift thấy type mà không cần bridging header.
typealias RCTPromiseResolveBlock = @convention(block) (Any?) -> Void
typealias RCTPromiseRejectBlock  = @convention(block) (String?, String?, Error?) -> Void

// MARK: - Paper size (points: 1pt = 1/72 inch)

private enum PaperSize {
  static let A4  = CGSize(width: 595.28, height: 841.89)
  static let A5  = CGSize(width: 419.53, height: 595.28)
  static let K80 = CGSize(width: 204.09, height: 3000)
  static let K58 = CGSize(width: 136.06, height: 3000)

  static func from(_ key: String) -> CGSize {
    switch key {
    case "A5":  return A5
    case "K80": return K80
    case "K58": return K58
    default:    return A4
    }
  }
}

// MARK: - Module

// Tên @objc phải khớp với RCT_EXTERN_MODULE và TurboModuleRegistry.get() trong JS.
// Dùng "HtmlPrinter" để đồng nhất với Android getName() = "HtmlPrinter".
@objc(HtmlPrinter)
class HtmlPrinterModule: NSObject {

  @objc static func requiresMainQueueSetup() -> Bool { false }

  @objc func printHtml(
    _ html: String,
    pageSize pageSizeKey: String,
    jobName: String,
    printerUrl: String,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      // Build HTML formatter
      let formatter = UIMarkupTextPrintFormatter(markupText: html)
      formatter.perPageContentInsets = .zero

      // Cấu hình print info
      let printInfo = UIPrintInfo.printInfo()
      printInfo.jobName = jobName
      printInfo.outputType = .general
      printInfo.duplex = .none

      // Cấu hình controller
      let controller = UIPrintInteractionController.shared
      controller.printInfo = printInfo
      controller.printFormatter = formatter
      controller.showsPageRange = false
      controller.showsNumberOfCopies = false

      let completionHandler: UIPrintInteractionController.CompletionHandler = { [weak controller] _, _, error in
        controller?.dismiss(animated: false)
        if let error = error {
          reject("PRINT_ERROR", error.localizedDescription, error)
        } else {
          resolve(nil)
        }
      }

      if !printerUrl.isEmpty {
        // ── Chế độ 1: Silent print qua IPP ───────────────────────────────────
        // Parse "TCP:192.168.1.100" hoặc "ipp://192.168.1.100" → IPP URL chuẩn
        let ippUrlString = Self.normalizeIppUrl(printerUrl)
        guard let url = URL(string: ippUrlString) else {
          reject("INVALID_URL", "Invalid printer URL: \(printerUrl)", nil)
          return
        }
        // UIPrinter(url:) kết nối trực tiếp qua IPP — không mở dialog
        let printer = UIPrinter(url: url)
        controller.print(to: printer, completionHandler: completionHandler)
      } else {
        // ── Chế độ 2: Print dialog ────────────────────────────────────────────
        guard UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene })
          .flatMap({ $0.windows })
          .first(where: { $0.isKeyWindow })?
          .rootViewController != nil else {
          reject("NO_VIEW_CONTROLLER", "Cannot find root view controller", nil)
          return
        }
        controller.present(animated: true, completionHandler: completionHandler)
      }
    }
  }

  // MARK: - ESC/POS TCP print

  /**
   * In HTML qua ESC/POS TCP socket.
   *
   * Flow:
   *   HTML → WKWebView offscreen render → UIGraphicsImageRenderer snapshot
   *   → Floyd-Steinberg dither → 1-bit bitmap
   *   → chia thành chunks (mỗi chunk <= 255 dòng) để tránh buffer overflow máy in
   *   → encode mỗi chunk thành GS v 0 raster command
   *   → TCP connect printerIp:printerPort → gửi bytes → feed lines → cut → disconnect
   */
  @objc func printHtmlEscPos(
    _ html: String,
    printerIp: String,
    printerPort: Int,
    paperWidthPx: Int,
    feedLines: Int,
    cutPaper: Bool,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      // Tạo WKWebView offscreen với kích thước paperWidthPx (pixel)
      // Chiều cao đặt lớn để render toàn bộ nội dung — sẽ lấy contentSize sau
      let webViewSize = CGSize(width: CGFloat(paperWidthPx), height: 10000)
      let webView = WKWebView(frame: CGRect(origin: .zero, size: webViewSize))
      webView.scrollView.isScrollEnabled = false
      webView.isOpaque = false
      webView.backgroundColor = .white

      // Ẩn webView (không add vào window để tránh flash)
      let container = UIView(frame: CGRect(origin: .zero, size: webViewSize))
      container.isHidden = true
      if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) {
        window.addSubview(container)
        container.addSubview(webView)
      }

      // Navigation delegate để biết khi render xong
      let delegate = WebViewSnapshotDelegate { [weak container] image in
        container?.removeFromSuperview()
        guard let image = image else {
          reject("RENDER_ERROR", "Failed to render HTML to image", nil)
          return
        }
        // Gửi dữ liệu in trên background thread
        DispatchQueue.global(qos: .userInitiated).async {
          Self.sendEscPosJob(
            image: image,
            paperWidthPx: paperWidthPx,
            printerIp: printerIp,
            printerPort: printerPort,
            feedLines: feedLines,
            cutPaper: cutPaper,
            resolve: resolve,
            reject: reject
          )
        }
      }
      webView.navigationDelegate = delegate
      // Giữ delegate sống trong suốt quá trình render
      objc_setAssociatedObject(webView, &AssociatedKeys.delegate, delegate, .OBJC_ASSOCIATION_RETAIN)

      webView.loadHTMLString(html, baseURL: nil)
    }
  }

  // MARK: - ESC/POS helpers

  /**
   * Chụp snapshot WKWebView sau khi render xong, sau đó xử lý dither + gửi TCP.
   */
  private static func sendEscPosJob(
    image: UIImage,
    paperWidthPx: Int,
    printerIp: String,
    printerPort: Int,
    feedLines: Int,
    cutPaper: Bool,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    // Scale image xuống paperWidthPx nếu cần
    let targetWidth = CGFloat(paperWidthPx)
    let scale = targetWidth / image.size.width
    let targetHeight = ceil(image.size.height * scale)
    let scaledSize = CGSize(width: targetWidth, height: targetHeight)

    UIGraphicsBeginImageContextWithOptions(scaledSize, true, 1.0)
    UIColor.white.setFill()
    UIRectFill(CGRect(origin: .zero, size: scaledSize))
    image.draw(in: CGRect(origin: .zero, size: scaledSize))
    let scaledImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    guard let cgImage = scaledImage?.cgImage else {
      reject("IMAGE_ERROR", "Failed to scale image", nil)
      return
    }

    // Lấy pixel data RGBA
    let width  = cgImage.width
    let height = cgImage.height
    guard let pixelData = cgImage.dataProvider?.data,
          let ptr = CFDataGetBytePtr(pixelData) else {
      reject("IMAGE_ERROR", "Failed to get pixel data", nil)
      return
    }
    let bytesPerRow = cgImage.bytesPerRow
    let bitsPerPixel = cgImage.bitsPerPixel
    let bytesPerPixel = bitsPerPixel / 8

    // Floyd-Steinberg dither → 1-bit grayscale array
    // error buffer dùng Float để tích lũy lỗi dither
    var gray = [Float](repeating: 0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * bytesPerPixel
        let r = Float(ptr[offset])
        let g = Float(ptr[offset + 1])
        let b = Float(ptr[offset + 2])
        // Luminance (ITU-R BT.601)
        gray[y * width + x] = 0.299 * r + 0.587 * g + 0.114 * b
      }
    }

    var bits = [UInt8](repeating: 0, count: width * height) // 0=black, 1=white
    for y in 0..<height {
      for x in 0..<width {
        let idx = y * width + x
        let old = gray[idx]
        let new_: Float = old < 128 ? 0 : 255
        bits[idx] = new_ < 128 ? 0 : 1
        let err = old - new_
        // Floyd-Steinberg error diffusion
        if x + 1 < width  { gray[idx + 1]         += err * 7 / 16 }
        if y + 1 < height {
          if x > 0         { gray[idx + width - 1] += err * 3 / 16 }
                             gray[idx + width]      += err * 5 / 16
          if x + 1 < width { gray[idx + width + 1] += err * 1 / 16 }
        }
      }
    }

    // Đóng gói thành ESC/POS data, chia chunk tối đa 255 dòng
    var escData = Data()

    // ESC @ — khởi tạo máy in
    escData.append(contentsOf: [0x1B, 0x40])

    let maxChunkHeight = 255
    let bytesPerLine = (width + 7) / 8

    var y = 0
    while y < height {
      let chunkH = min(maxChunkHeight, height - y)

      // GS v 0 — raster bit image
      // Format: GS v 0 m xL xH yL yH [data]
      // m=0: normal density
      // xL, xH: bytes per line (width / 8)
      // yL, yH: number of lines
      escData.append(contentsOf: [0x1D, 0x76, 0x30, 0x00])
      let xL = UInt8(bytesPerLine & 0xFF)
      let xH = UInt8((bytesPerLine >> 8) & 0xFF)
      let yL = UInt8(chunkH & 0xFF)
      let yH = UInt8((chunkH >> 8) & 0xFF)
      escData.append(contentsOf: [xL, xH, yL, yH])

      // Encode từng dòng trong chunk thành 1-bit packed bytes
      for row in y..<(y + chunkH) {
        var byteCol = 0
        while byteCol < bytesPerLine {
          var byte: UInt8 = 0
          for bit in 0..<8 {
            let col = byteCol * 8 + bit
            // bit 7 là leftmost pixel — đen = 0 trong grayscale → in = 1 trong ESC/POS
            if col < width && bits[row * width + col] == 0 {
              byte |= (0x80 >> bit)
            }
          }
          escData.append(byte)
          byteCol += 1
        }
      }
      y += chunkH
    }

    // ESC d n — feed n lines
    if feedLines > 0 {
      escData.append(contentsOf: [0x1B, 0x64, UInt8(min(feedLines, 255))])
    }

    // GS V 0 — full cut
    if cutPaper {
      escData.append(contentsOf: [0x1D, 0x56, 0x00])
    }

    // Gửi qua TCP
    Self.sendTcp(data: escData, host: printerIp, port: printerPort, resolve: resolve, reject: reject)
  }

  /**
   * Gửi data qua TCP socket (Stream-based, synchronous trên background thread).
   */
  private static func sendTcp(
    data: Data,
    host: String,
    port: Int,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    // OutputStream(host:port:) không available trên iOS — dùng Stream.getStreamsToHost
    var inputS: InputStream?
    var outputS: OutputStream?
    Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputS, outputStream: &outputS)
    guard let outputS = outputS else {
      reject("TCP_ERROR", "Failed to create TCP stream to \(host):\(port)", nil)
      return
    }
    outputS.open()
    defer { outputS.close() }

    // Đợi stream ready (timeout 10s)
    var waited = 0
    while outputS.streamStatus == .opening && waited < 100 {
      Thread.sleep(forTimeInterval: 0.1)
      waited += 1
    }

    guard outputS.streamStatus == .open else {
      let err = outputS.streamError
      reject("TCP_CONNECT_ERROR", "Cannot connect to \(host):\(port) — \(err?.localizedDescription ?? "timeout")", err)
      return
    }

    // Ghi data theo từng chunk (max 4096 bytes mỗi lần write)
    var offset = 0
    let bytes = [UInt8](data)
    while offset < bytes.count {
      let chunkSize = min(4096, bytes.count - offset)
      let written = outputS.write(Array(bytes[offset..<(offset + chunkSize)]), maxLength: chunkSize)
      if written < 0 {
        let err = outputS.streamError
        reject("TCP_WRITE_ERROR", "Write failed: \(err?.localizedDescription ?? "unknown")", err)
        return
      }
      offset += written
    }

    resolve(nil)
  }

  // MARK: - mDNS/Bonjour printer discovery

  /**
   * Quét mạng tìm máy in qua mDNS/Bonjour.
   *
   * Tìm 2 loại service:
   *   _ipp._tcp          → máy in IPP (AirPrint, EPSON TM-m30II, ...)
   *   _pdl-datastream._tcp → máy in ESC/POS qua TCP port 9100 (Xprinter, Star, ...)
   *
   * Mỗi service được resolve để lấy host + port trước khi trả về.
   * Kết quả trả về mảng JSON string — mỗi phần tử là 1 DiscoveredPrinter.
   */
  @objc func discoverPrinters(
    _ timeoutMs: Int,
    resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    let scanner = PrinterBonjourScanner(timeoutMs: timeoutMs) { printers in
      let jsonArray = printers.compactMap { printer -> String? in
        guard let data = try? JSONSerialization.data(withJSONObject: [
          "name": printer.name,
          "host": printer.host,
          "port": printer.port,
          "type": printer.type,
        ]) else { return nil }
        return String(data: data, encoding: .utf8)
      }
      resolve(jsonArray)
    }
    // Giữ scanner sống cho đến khi hoàn thành
    objc_setAssociatedObject(self, &AssociatedKeys.bonjourScanner, scanner, .OBJC_ASSOCIATION_RETAIN)
    scanner.start()
  }

  // MARK: - IPP helpers

  /**
   * Chuẩn hoá printer address sang IPP URL.
   *
   * Các format đầu vào:
   *   "TCP:192.168.1.100"       → "ipp://192.168.1.100:631"
   *   "192.168.1.100"           → "ipp://192.168.1.100:631"
   *   "ipp://192.168.1.100"     → giữ nguyên
   *   "ipp://192.168.1.100:631" → giữ nguyên
   */
  private static func normalizeIppUrl(_ raw: String) -> String {
    var s = raw
    // Bỏ prefix "TCP:" (từ PrinterTarget.target format trong app)
    if s.uppercased().hasPrefix("TCP:") { s = String(s.dropFirst(4)) }
    // Đã là IPP URL → giữ nguyên
    if s.lowercased().hasPrefix("ipp://") { return s }
    // IP thuần → thêm scheme và port mặc định IPP
    return "ipp://\(s):631"
  }
}

// MARK: - Associated object keys

private enum AssociatedKeys {
  static var delegate       = "WebViewSnapshotDelegate"
  static var bonjourScanner = "PrinterBonjourScanner"
}

// MARK: - mDNS Bonjour scanner

private struct PrinterInfo {
  let name: String
  let host: String
  let port: Int
  let type: String  // "ipp" | "escpos"
}

/**
 * Quét Bonjour để tìm máy in trong mạng LAN.
 *
 * Tìm 2 loại service:
 *   _ipp._tcp            → IPP printers (AirPrint, network laser/inkjet)
 *   _pdl-datastream._tcp → ESC/POS thermal printers (Xprinter, Star TSP, ...)
 *
 * Flow: browse → found service → resolve → lấy host+port → thêm vào results
 * Sau `timeoutMs`, dừng browse và gọi completion với danh sách tìm được.
 */
private class PrinterBonjourScanner: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

  private let timeoutMs: Int
  private let completion: ([PrinterInfo]) -> Void

  private var browsers: [NetServiceBrowser] = []
  private var pendingServices: Set<NetService> = []
  private var results: [PrinterInfo] = []
  private var timer: Timer?
  private var isDone = false

  // (serviceType, printerType) cần scan
  private let serviceTypes: [(String, String)] = [
    ("_ipp._tcp.", "ipp"),
    ("_pdl-datastream._tcp.", "escpos"),
  ]

  init(timeoutMs: Int, completion: @escaping ([PrinterInfo]) -> Void) {
    self.timeoutMs = timeoutMs
    self.completion = completion
  }

  func start() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Tạo 1 browser cho mỗi loại service
      for (serviceType, _) in self.serviceTypes {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
        self.browsers.append(browser)
      }
      // Timeout — dừng scan và trả kết quả
      self.timer = Timer.scheduledTimer(
        withTimeInterval: TimeInterval(self.timeoutMs) / 1000.0,
        repeats: false
      ) { [weak self] _ in
        self?.finish()
      }
    }
  }

  private func finish() {
    guard !isDone else { return }
    isDone = true
    timer?.invalidate()
    timer = nil
    browsers.forEach { $0.stop() }
    browsers.removeAll()
    pendingServices.removeAll()
    completion(results)
  }

  // MARK: NetServiceBrowserDelegate

  func netServiceBrowser(
    _ browser: NetServiceBrowser,
    didFind service: NetService,
    moreComing: Bool
  ) {
    pendingServices.insert(service)
    service.delegate = self
    service.resolve(withTimeout: 5.0)
  }

  // MARK: NetServiceDelegate

  func netServiceDidResolveAddress(_ sender: NetService) {
    defer {
      pendingServices.remove(sender)
      // Nếu hết pending và đã timeout → kết thúc sớm (không chờ thêm)
    }

    // Lấy host từ địa chỉ IPv4 đầu tiên
    guard let addresses = sender.addresses, !addresses.isEmpty else { return }
    var hostCString = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    var resolved = false

    for addressData in addresses {
      let success = addressData.withUnsafeBytes { ptr -> Bool in
        guard let sockaddr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return false }
        return getnameinfo(
          sockaddr, socklen_t(addressData.count),
          &hostCString, socklen_t(NI_MAXHOST),
          nil, 0,
          NI_NUMERICHOST  // trả về IP string, không resolve DNS
        ) == 0
      }
      if success {
        resolved = true
        break
      }
    }

    guard resolved else { return }
    let host = String(cString: hostCString)
    let port = sender.port
    guard port > 0, !host.isEmpty else { return }

    // Xác định loại máy in từ tên service type
    let printerType: String
    if sender.type.contains("pdl-datastream") {
      printerType = "escpos"
    } else {
      printerType = "ipp"
    }

    let info = PrinterInfo(
      name: sender.name,
      host: host,
      port: port,
      type: printerType
    )
    results.append(info)
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    pendingServices.remove(sender)
  }
}

// MARK: - WKNavigationDelegate để chụp snapshot sau khi render xong

private class WebViewSnapshotDelegate: NSObject, WKNavigationDelegate {
  private let completion: (UIImage?) -> Void

  init(completion: @escaping (UIImage?) -> Void) {
    self.completion = completion
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    // Đợi JS / layout xong (1 runloop cycle)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak webView] in
      guard let self, let webView else { return }

      // Lấy chiều cao thực của content
      webView.evaluateJavaScript("document.body.scrollHeight") { [weak webView] result, _ in
        guard let webView else { return }
        let contentHeight = (result as? CGFloat) ?? webView.scrollView.contentSize.height
        let contentWidth  = webView.frame.width

        // Resize webView để capture toàn bộ nội dung
        webView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: max(contentHeight, 1))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak webView] in
          guard let webView else { return }
          let config = WKSnapshotConfiguration()
          config.rect = CGRect(origin: .zero, size: webView.frame.size)
          webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.completion(image)
          }
        }
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    completion(nil)
  }
}
