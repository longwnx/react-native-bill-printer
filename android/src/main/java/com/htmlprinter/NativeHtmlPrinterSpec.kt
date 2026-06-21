/**
 * NativeHtmlPrinterSpec — abstract base cho Turbo Module Android.
 *
 * Implement TurboModule để hỗ trợ New Architecture (JSI).
 * Cũng tương thích với Old Architecture qua ReactContextBaseJavaModule.
 *
 * Khi codegen chạy từ NativeHtmlPrinter.ts spec, file này sẽ được
 * thay bằng generated spec. Hiện tại viết thủ công để tương thích cả hai arch.
 */

package com.htmlprinter

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.turbomodule.core.interfaces.TurboModule

abstract class NativeHtmlPrinterSpec(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext), TurboModule {

  abstract fun printHtml(html: String, pageSize: String, jobName: String, printerUrl: String, promise: Promise)

  abstract fun printHtmlEscPos(
    html: String,
    printerIp: String,
    printerPort: Double,
    paperWidthPx: Double,
    feedLines: Double,
    cutPaper: Boolean,
    promise: Promise,
  )
}
