/**
 * HtmlPrinterModule.kt — Android implementation
 *
 * Hai chế độ in:
 *   1. Silent print qua IPP (printerUrl != "") — gửi PDF trực tiếp tới máy in qua HTTP/IPP
 *   2. Print dialog (printerUrl == "")          — PrintManager hiện dialog chọn máy in
 *
 * Silent print flow (IPP):
 *   WebView render HTML → Canvas → Bitmap → PdfDocument → PDF bytes
 *   → HTTP POST tới ipp://IP:631 (IPP over HTTP port 631)
 *
 * Supported page sizes:
 *   A4  → ISO_A4  (210×297mm)
 *   A5  → ISO_A5  (148×210mm)
 *   K80 → custom  72mm wide thermal
 *   K58 → custom  48mm wide thermal
 */

package com.htmlprinter

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.print.PrintAttributes
import android.print.PrintManager
import android.webkit.WebView
import android.webkit.WebViewClient
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.Socket
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList

@ReactModule(name = HtmlPrinterModule.NAME)
class HtmlPrinterModule(
  private val reactContext: ReactApplicationContext,
) : NativeHtmlPrinterSpec(reactContext) {

  companion object {
    const val NAME = "HtmlPrinter"

    /** Chuẩn hoá printer address → HTTP URL để gọi IPP over HTTP */
    fun normalizeIppHttpUrl(raw: String): String {
      var s = raw
      // Bỏ prefix "TCP:" (từ PrinterTarget.target format trong app)
      if (s.uppercase().startsWith("TCP:")) s = s.substring(4)
      // IPP URL → đổi scheme sang http để dùng HttpURLConnection
      if (s.lowercase().startsWith("ipp://")) {
        s = "http://" + s.substring(6)
        // Đảm bảo có port 631
        if (!s.contains(Regex(":\\d+/"))) {
          val slashIdx = s.indexOf('/', 7)
          s = if (slashIdx >= 0) s.substring(0, slashIdx) + ":631" + s.substring(slashIdx)
              else "$s:631"
        }
        return s
      }
      // IP thuần → thêm http scheme và port 631
      return "http://$s:631"
    }
  }

  override fun getName(): String = NAME

  private fun getMediaSize(pageSizeKey: String): PrintAttributes.MediaSize = when (pageSizeKey) {
    "A5"  -> PrintAttributes.MediaSize.ISO_A5
    "K80" -> PrintAttributes.MediaSize("K80_THERMAL", "K80 Thermal (72mm)", 2835, 118110)
    "K58" -> PrintAttributes.MediaSize("K58_THERMAL", "K58 Thermal (48mm)", 1890, 118110)
    else  -> PrintAttributes.MediaSize.ISO_A4
  }

  override fun printHtml(
    html: String,
    pageSize: String,
    jobName: String,
    printerUrl: String,
    promise: Promise,
  ) {
    val activity = reactContext.currentActivity
    if (activity == null) {
      promise.reject("NO_ACTIVITY", "No current Activity found")
      return
    }

    activity.runOnUiThread {
      val webView = WebView(activity)
      webView.settings.javaScriptEnabled = false

      val attrs = PrintAttributes.Builder()
        .setMediaSize(getMediaSize(pageSize))
        .setResolution(PrintAttributes.Resolution("default", "300dpi", 300, 300))
        .setMinMargins(PrintAttributes.Margins.NO_MARGINS)
        .build()

      webView.webViewClient = object : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String) {
          if (printerUrl.isNotEmpty()) {
            // ── Chế độ 1: Silent print qua IPP ─────────────────────────────
            // WebView → Bitmap → PdfDocument → PDF bytes → IPP over HTTP
            renderWebViewToPdf(view, attrs) { pdfBytes, error ->
              if (error != null || pdfBytes == null) {
                promise.reject("PDF_ERROR", error ?: "Failed to generate PDF")
                return@renderWebViewToPdf
              }
              // Gửi PDF tới máy in qua IPP over HTTP trên background thread
              Thread {
                sendIppPrintJob(printerUrl, jobName, pdfBytes, promise)
              }.start()
            }
          } else {
            // ── Chế độ 2: Print dialog ──────────────────────────────────────
            try {
              val printManager = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
              val adapter = view.createPrintDocumentAdapter(jobName)
              printManager.print(jobName, adapter, attrs)
              promise.resolve(null)
            } catch (e: Exception) {
              promise.reject("PRINT_ERROR", e.message ?: "Print failed", e)
            }
          }
        }

        override fun onReceivedError(
          view: WebView, errorCode: Int, description: String, failingUrl: String,
        ) {
          promise.reject("WEBVIEW_ERROR", "WebView error: $description")
        }
      }

      webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
    }
  }

  /**
   * Render WebView sang Bitmap rồi encode thành PDF bytes.
   * Tránh dùng PrintDocumentAdapter vì LayoutResultCallback/WriteResultCallback
   * có package-private constructor không thể subclass từ ngoài package android.print.
   */
  private fun renderWebViewToPdf(
    view: WebView,
    attrs: PrintAttributes,
    callback: (ByteArray?, String?) -> Unit,
  ) {
    try {
      val mediaSize = attrs.mediaSize ?: PrintAttributes.MediaSize.ISO_A4
      // Tính kích thước trang theo pixel (300 DPI)
      val dpi = 300
      val pageWidthPx  = (mediaSize.widthMils  * dpi / 1000f).toInt()
      val pageHeightPx = (mediaSize.heightMils * dpi / 1000f).toInt()

      // Đo và layout WebView để lấy content height thực
      val wSpec = android.view.View.MeasureSpec.makeMeasureSpec(pageWidthPx, android.view.View.MeasureSpec.EXACTLY)
      val hSpec = android.view.View.MeasureSpec.makeMeasureSpec(0, android.view.View.MeasureSpec.UNSPECIFIED)
      view.measure(wSpec, hSpec)
      view.layout(0, 0, pageWidthPx, view.measuredHeight)

      val contentHeight = maxOf(view.contentHeight, view.measuredHeight, 1)

      // Tạo bitmap toàn bộ nội dung
      val bitmap = Bitmap.createBitmap(pageWidthPx, contentHeight, Bitmap.Config.ARGB_8888)
      val canvas = Canvas(bitmap)
      canvas.drawColor(Color.WHITE)
      view.draw(canvas)

      // Chia nội dung thành các trang PDF
      val pdfDoc = PdfDocument()
      var yOffset = 0
      var pageNum = 1

      while (yOffset < contentHeight) {
        val sliceHeight = minOf(pageHeightPx, contentHeight - yOffset)
        val pageInfo = PdfDocument.PageInfo.Builder(pageWidthPx, sliceHeight, pageNum).create()
        val page = pdfDoc.startPage(pageInfo)

        // Vẽ phần bitmap tương ứng với trang này
        val paint = Paint()
        page.canvas.drawBitmap(bitmap, 0f, -yOffset.toFloat(), paint)
        pdfDoc.finishPage(page)

        yOffset += sliceHeight
        pageNum++
      }

      bitmap.recycle()

      // Encode PDF thành bytes
      val out = ByteArrayOutputStream()
      pdfDoc.writeTo(out)
      pdfDoc.close()
      callback(out.toByteArray(), null)
    } catch (e: Exception) {
      callback(null, e.message ?: "Failed to render PDF")
    }
  }

  /**
   * Gửi PDF tới máy in qua IPP over HTTP (RFC 2911).
   *
   * IPP request dạng multipart: IPP header + PDF data body.
   * Máy in IPP nhận trên cổng 631, endpoint /ipp/print hoặc /.
   */
  private fun sendIppPrintJob(
    printerUrlRaw: String,
    jobName: String,
    pdfBytes: ByteArray,
    promise: Promise,
  ) {
    try {
      val httpUrl = normalizeIppHttpUrl(printerUrlRaw)
      val url = URL("$httpUrl/ipp/print")

      val conn = (url.openConnection() as HttpURLConnection).apply {
        requestMethod = "POST"
        doOutput = true
        connectTimeout = 10_000
        readTimeout = 30_000
        setRequestProperty("Content-Type", "application/ipp")
        setRequestProperty("Accept", "application/ipp, application/octet-stream")
      }

      // Build IPP request header (binary protocol)
      // Ref: RFC 8011 - Print-Job operation (0x0002)
      val ippHeader = buildIppPrintJobRequest(jobName)
      val body = ippHeader + pdfBytes

      conn.setRequestProperty("Content-Length", body.size.toString())
      conn.outputStream.use { it.write(body) }

      val responseCode = conn.responseCode
      conn.disconnect()

      if (responseCode in 200..299) {
        promise.resolve(null)
      } else {
        promise.reject("IPP_ERROR", "IPP server responded with HTTP $responseCode")
      }
    } catch (e: Exception) {
      promise.reject("IPP_SEND_ERROR", e.message ?: "Failed to send IPP job", e)
    }
  }

  /**
   * Build IPP Print-Job request header (binary).
   *
   * IPP binary format:
   *   [2B] version (2.0 = 0x0200)
   *   [2B] operation (Print-Job = 0x0002)
   *   [4B] request-id (1)
   *   [1B] begin-attribute-group (operation-attributes-tag = 0x01)
   *   ... attributes ...
   *   [1B] end-of-attributes (0x03)
   */
  private fun buildIppPrintJobRequest(jobName: String): ByteArray {
    val buf = ByteArrayOutputStream()
    val out = DataOutputStream(buf)

    // IPP version 2.0
    out.writeShort(0x0200)
    // Operation: Print-Job
    out.writeShort(0x0002)
    // Request ID
    out.writeInt(1)

    // Operation attributes group
    out.writeByte(0x01)

    // attributes-charset = utf-8
    writeIppAttribute(out, 0x47, "attributes-charset", "utf-8")
    // attributes-natural-language = en
    writeIppAttribute(out, 0x48, "attributes-natural-language", "en")
    // printer-uri (placeholder — máy in đọc từ HTTP Host header)
    writeIppAttribute(out, 0x45, "printer-uri", "ipp://localhost/ipp/print")
    // job-name
    writeIppAttribute(out, 0x42, "job-name", jobName)
    // document-format = application/pdf
    writeIppAttribute(out, 0x49, "document-format", "application/pdf")

    // End of attributes
    out.writeByte(0x03)

    out.flush()
    return buf.toByteArray()
  }

  /** Ghi 1 IPP string attribute vào output stream */
  private fun writeIppAttribute(
    out: DataOutputStream,
    valueTag: Int,
    name: String,
    value: String,
  ) {
    out.writeByte(valueTag)
    val nameBytes = name.toByteArray(Charsets.UTF_8)
    out.writeShort(nameBytes.size)
    out.write(nameBytes)
    val valueBytes = value.toByteArray(Charsets.UTF_8)
    out.writeShort(valueBytes.size)
    out.write(valueBytes)
  }

  // ── mDNS printer discovery (NsdManager) ────────────────────────────────────

  /**
   * Quét mạng tìm máy in qua mDNS (NsdManager).
   *
   * Tìm 2 loại service:
   *   _ipp._tcp            → máy in IPP (AirPrint, network printer)
   *   _pdl-datastream._tcp → máy in ESC/POS thermal (Xprinter, Star, ...)
   *
   * Kết quả trả về mảng JSON string — mỗi phần tử là 1 DiscoveredPrinter.
   */
  override fun discoverPrinters(timeoutMs: Double, promise: Promise) {
    val context = reactContext.applicationContext
    val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    if (nsdManager == null) {
      promise.resolve(Arguments.makeNativeArray(emptyArray<String>()))
      return
    }

    val results = CopyOnWriteArrayList<String>()
    val serviceTypes = listOf(
      "_ipp._tcp." to "ipp",
      "_pdl-datastream._tcp." to "escpos",
    )

    // Track active listeners để stop sau timeout
    val discoveryListeners = mutableListOf<NsdManager.DiscoveryListener>()
    val resolveQueue = ArrayDeque<Pair<NsdServiceInfo, String>>()
    var resolving = false

    fun resolveNext() {
      if (resolveQueue.isEmpty()) { resolving = false; return }
      resolving = true
      val (serviceInfo, printerType) = resolveQueue.removeFirst()

      nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
        override fun onResolveFailed(info: NsdServiceInfo?, errorCode: Int) {
          resolveNext()
        }

        override fun onServiceResolved(info: NsdServiceInfo) {
          val host: String = try {
            info.host?.hostAddress ?: info.host?.canonicalHostName ?: return resolveNext()
          } catch (_: Exception) { return resolveNext() }
          val port = info.port
          if (port <= 0 || host.isEmpty()) return resolveNext()

          val json = JSONObject().apply {
            put("name", info.serviceName ?: "Unknown Printer")
            put("host", host)
            put("port", port)
            put("type", printerType)
          }.toString()
          results.add(json)
          resolveNext()
        }
      })
    }

    for ((serviceType, printerType) in serviceTypes) {
      val listener = object : NsdManager.DiscoveryListener {
        override fun onStartDiscoveryFailed(type: String?, errorCode: Int) {}
        override fun onStopDiscoveryFailed(type: String?, errorCode: Int) {}
        override fun onDiscoveryStarted(type: String?) {}
        override fun onDiscoveryStopped(type: String?) {}
        override fun onServiceLost(info: NsdServiceInfo?) {}

        override fun onServiceFound(info: NsdServiceInfo) {
          resolveQueue.add(info to printerType)
          if (!resolving) resolveNext()
        }
      }
      discoveryListeners.add(listener)
      try {
        nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
      } catch (_: Exception) { /* service type không hỗ trợ → bỏ qua */ }
    }

    // Dừng scan sau timeout
    Handler(Looper.getMainLooper()).postDelayed({
      for (listener in discoveryListeners) {
        try { nsdManager.stopServiceDiscovery(listener) } catch (_: Exception) {}
      }
      promise.resolve(Arguments.makeNativeArray(results.toTypedArray()))
    }, timeoutMs.toLong())
  }

  // ── ESC/POS TCP Print ───────────────────────────────────────────────────────

  /**
   * In HTML qua ESC/POS TCP socket.
   *
   * Flow:
   *   HTML → WebView offscreen render → Canvas.draw() → Bitmap
   *   → Floyd-Steinberg dither → 1-bit array
   *   → chia chunk (tối đa 255 dòng) → encode GS v 0 raster command
   *   → TCP Socket printerIp:printerPort → gửi bytes → feed → cut → close
   */
  override fun printHtmlEscPos(
    html: String,
    printerIp: String,
    printerPort: Double,
    paperWidthPx: Double,
    feedLines: Double,
    cutPaper: Boolean,
    promise: Promise,
  ) {
    val activity = reactContext.currentActivity
    if (activity == null) {
      promise.reject("NO_ACTIVITY", "No current Activity found")
      return
    }

    val widthPx  = paperWidthPx.toInt()
    val port     = printerPort.toInt()
    val feed     = feedLines.toInt()

    // Render WebView trên main thread
    Handler(Looper.getMainLooper()).post {
      val webView = WebView(activity)
      webView.settings.javaScriptEnabled = false
      webView.isDrawingCacheEnabled = true
      webView.setBackgroundColor(Color.WHITE)
      val measuredWidth  = android.view.View.MeasureSpec.makeMeasureSpec(widthPx, android.view.View.MeasureSpec.EXACTLY)
      val measuredHeight = android.view.View.MeasureSpec.makeMeasureSpec(30000, android.view.View.MeasureSpec.AT_MOST)

      webView.webViewClient = object : WebViewClient() {
        override fun onPageFinished(view: WebView, url: String) {
          // Đo lại layout sau khi nội dung load xong
          view.measure(measuredWidth, measuredHeight)
          view.layout(0, 0, view.measuredWidth, view.measuredHeight)

          val contentHeight = view.contentHeight
          if (contentHeight <= 0) {
            promise.reject("RENDER_ERROR", "WebView contentHeight is 0")
            return
          }

          val bitmap = try {
            Bitmap.createBitmap(widthPx, contentHeight, Bitmap.Config.ARGB_8888)
          } catch (e: OutOfMemoryError) {
            promise.reject("OOM_ERROR", "Not enough memory to render HTML (height=$contentHeight)")
            return
          }

          val canvas = Canvas(bitmap)
          canvas.drawColor(Color.WHITE)
          view.draw(canvas)

          // Xử lý dither + gửi TCP trên background thread
          Thread {
            try {
              val escData = bitmapToEscPos(bitmap, feed, cutPaper)
              bitmap.recycle()
              sendEscPosTcp(escData, printerIp, port, promise)
            } catch (e: Exception) {
              bitmap.recycle()
              promise.reject("ESCPOS_ERROR", e.message ?: "ESC/POS processing failed", e)
            }
          }.start()
        }

        override fun onReceivedError(
          view: WebView, errorCode: Int, description: String, failingUrl: String,
        ) {
          promise.reject("WEBVIEW_ERROR", "WebView error: $description")
        }
      }

      webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
    }
  }

  /**
   * Chuyển Bitmap → ESC/POS bytes (Floyd-Steinberg dither + GS v 0 chunks).
   */
  private fun bitmapToEscPos(bitmap: Bitmap, feedLines: Int, cutPaper: Boolean): ByteArray {
    val width  = bitmap.width
    val height = bitmap.height

    val pixels = IntArray(width * height)
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

    // Chuyển sang grayscale float array
    val gray = FloatArray(width * height)
    for (i in pixels.indices) {
      val p = pixels[i]
      gray[i] = 0.299f * Color.red(p) + 0.587f * Color.green(p) + 0.114f * Color.blue(p)
    }

    // Floyd-Steinberg dither → bits (0=đen/in, 1=trắng/không in)
    val bits = ByteArray(width * height)
    for (y in 0 until height) {
      for (x in 0 until width) {
        val idx  = y * width + x
        val old  = gray[idx]
        val new_ = if (old < 128f) 0f else 255f
        bits[idx] = if (new_ < 128f) 0 else 1
        val err = old - new_
        if (x + 1 < width)  gray[idx + 1]         += err * 7f / 16f
        if (y + 1 < height) {
          if (x > 0)         gray[idx + width - 1] += err * 3f / 16f
                             gray[idx + width]      += err * 5f / 16f
          if (x + 1 < width) gray[idx + width + 1] += err * 1f / 16f
        }
      }
    }

    val buf = ByteArrayOutputStream()

    // ESC @ — khởi tạo máy in
    buf.write(byteArrayOf(0x1B, 0x40))

    val bytesPerLine = (width + 7) / 8
    val maxChunkH    = 255
    var y = 0

    while (y < height) {
      val chunkH = minOf(maxChunkH, height - y)

      // GS v 0 0 xL xH yL yH [data]
      buf.write(byteArrayOf(0x1D, 0x76, 0x30, 0x00))
      val xL = (bytesPerLine and 0xFF).toByte()
      val xH = ((bytesPerLine shr 8) and 0xFF).toByte()
      val yL = (chunkH and 0xFF).toByte()
      val yH = ((chunkH shr 8) and 0xFF).toByte()
      buf.write(byteArrayOf(xL, xH, yL, yH))

      for (row in y until y + chunkH) {
        for (byteCol in 0 until bytesPerLine) {
          var byte_ = 0
          for (bit in 0 until 8) {
            val col = byteCol * 8 + bit
            // bit 7 = leftmost; đen (0) → in = bit set
            if (col < width && bits[row * width + col] == 0.toByte()) {
              byte_ = byte_ or (0x80 ushr bit)
            }
          }
          buf.write(byte_)
        }
      }
      y += chunkH
    }

    // ESC d n — feed n lines
    if (feedLines > 0) {
      buf.write(byteArrayOf(0x1B, 0x64, minOf(feedLines, 255).toByte()))
    }

    // GS V 0 — full cut
    if (cutPaper) {
      buf.write(byteArrayOf(0x1D, 0x56, 0x00))
    }

    return buf.toByteArray()
  }

  /**
   * Gửi ESC/POS bytes qua TCP socket.
   */
  private fun sendEscPosTcp(data: ByteArray, host: String, port: Int, promise: Promise) {
    try {
      Socket(host, port).use { socket ->
        socket.soTimeout = 30_000
        val out = socket.getOutputStream()
        var offset = 0
        val chunkSize = 4096
        while (offset < data.size) {
          val len = minOf(chunkSize, data.size - offset)
          out.write(data, offset, len)
          offset += len
        }
        out.flush()
      }
      promise.resolve(null)
    } catch (e: Exception) {
      promise.reject("TCP_ERROR", "Failed to send to $host:$port — ${e.message}", e)
    }
  }
}
