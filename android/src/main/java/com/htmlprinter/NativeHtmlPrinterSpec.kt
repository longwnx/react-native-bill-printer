/**
 * NativeHtmlPrinterSpec — abstract base cho Turbo Module Android.
 *
 * Viết thủ công thay vì dùng codegen vì package nằm trong monorepo app.
 * Khi tách thành standalone npm package có codegen pipeline riêng,
 * file này sẽ được sinh tự động từ NativeHtmlPrinter.ts spec.
 */

package com.htmlprinter

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule

abstract class NativeHtmlPrinterSpec(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

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
