/**
 * react-native-bill-printer
 *
 * Hỗ trợ 2 chế độ in HTML:
 *   1. IPP  — in qua dialog hệ thống hoặc silent print (máy in có IPP)
 *   2. ESC/POS — in qua TCP:9100, tương thích mọi thermal POS printer
 *
 * Usage ESC/POS (Xprinter, EPSON TM cũ, ...):
 *   import { BillPrinter, BillPrinterPageSize } from 'react-native-bill-printer';
 *   await BillPrinter.printEscPos(htmlString, {
 *     printerIp: '192.168.1.100',
 *     pageSize: BillPrinterPageSize.K80,
 *     feedLines: 3,
 *     cutPaper: true,
 *   });
 *
 * Usage IPP (EPSON TM-m30II, Star mC-Print, ...):
 *   await BillPrinter.print(htmlString, {
 *     printerUrl: 'ipp://192.168.1.100',
 *     pageSize: BillPrinterPageSize.A5,
 *   });
 */

import NativeHtmlPrinter from './NativeHtmlPrinter';
import { BillPrinterPageSize, PAPER_WIDTH_PX } from './html-printer.types';
import type {
  BillPrintOptions,
  EscPosPrintOptions,
  PrinterErrorCallback,
  PrinterErrorInfo,
} from './html-printer.types';

export { BillPrinterPageSize, PAPER_WIDTH_PX } from './html-printer.types';
export type {
  BillPrintOptions,
  EscPosPrintOptions,
  PrinterErrorCallback,
  PrinterErrorInfo,
} from './html-printer.types';

// ─── Error code extraction ─────────────────────────────────────────────────────

// Thứ tự: specific codes trước general — tránh false-match khi dùng startsWith/includes
const KNOWN_ERROR_CODES = [
  'TCP_CONNECT_ERROR', 'TCP_WRITE_ERROR', 'TCP_ERROR',
  'IPP_SEND_ERROR', 'IPP_ERROR',
  'WEBVIEW_ERROR', 'RENDER_ERROR',
  'OOM_ERROR', 'NO_ACTIVITY', 'NO_VIEW_CONTROLLER',
  'PDF_ERROR', 'IMAGE_ERROR', 'PRINT_ERROR', 'INVALID_URL',
  'PRINTER_MODULE_UNAVAILABLE',
];

/**
 * Trich xuất error code từ native error message.
 * Native module reject với message format: "ERROR_CODE: detail message"
 */
const parseErrorCode = (error: Error): string => {
  for (const code of KNOWN_ERROR_CODES) {
    if (error.message.startsWith(code) || error.message.includes(code)) {
      return code;
    }
  }
  return 'UNKNOWN';
};

/**
 * Gọi onError callback nếu có, rồi re-throw error.
 * Caller nhận được PrinterErrorInfo với errorCode đã parse để tránh parse lại.
 */
const handlePrintError = (error: unknown, onError?: PrinterErrorCallback): never => {
  const err = error instanceof Error ? error : new Error(String(error));
  if (onError) {
    const info: PrinterErrorInfo = {
      errorCode: parseErrorCode(err),
      message: err.message,
      nativeError: err,
    };
    onError(info);
  }
  throw err;
};

// ─── BillPrinter API ──────────────────────────────────────────────────────────

export const BillPrinter = {
  /**
   * In HTML qua IPP.
   * - printerUrl có giá trị → silent print (không dialog)
   * - printerUrl rỗng/undefined → mở print dialog hệ thống
   *
   * @param onError - Optional callback nhận PrinterErrorInfo trước khi error throw.
   *                  Dùng để capture lên Sentry hoặc log mà không cần parse error message.
   */
  async print(
    html: string,
    options: BillPrintOptions & { onError?: PrinterErrorCallback } = {},
  ): Promise<void> {
    const { onError, ...printOptions } = options;
    if (!NativeHtmlPrinter) {
      handlePrintError(new Error('PRINTER_MODULE_UNAVAILABLE: pod install chưa được chạy'), onError);
    }
    const pageSize = printOptions.pageSize ?? BillPrinterPageSize.A4;
    const jobName = printOptions.jobName ?? 'Print';
    const printerUrl = printOptions.printerUrl ?? '';
    try {
      return await NativeHtmlPrinter!.printHtml(html, pageSize, jobName, printerUrl);
    } catch (error) {
      handlePrintError(error, onError);
    }
  },

  /**
   * In HTML qua ESC/POS TCP socket.
   *
   * Flow native:
   *   HTML → WebView offscreen render → screenshot bitmap
   *   → Floyd-Steinberg dither thành 1-bit
   *   → ESC/POS GS v 0 raster image command
   *   → TCP connect → send bytes → addFeedLine → addCut → disconnect
   *
   * Tương thích: Xprinter, EPSON TM-T82/T88, Bixolon SRP-350, Star TSP100, ...
   *
   * @param onError - Optional callback nhận PrinterErrorInfo trước khi error throw.
   *                  Dùng để capture lên Sentry hoặc log mà không cần parse error message.
   */
  async printEscPos(
    html: string,
    options: EscPosPrintOptions & { onError?: PrinterErrorCallback },
  ): Promise<void> {
    const { onError, ...escPosOptions } = options;
    if (!NativeHtmlPrinter) {
      handlePrintError(new Error('PRINTER_MODULE_UNAVAILABLE: pod install chưa được chạy'), onError);
    }
    const pageSize = escPosOptions.pageSize ?? BillPrinterPageSize.K80;
    const paperWidthPx = escPosOptions.paperWidthPx ?? PAPER_WIDTH_PX[pageSize];
    try {
      return await NativeHtmlPrinter!.printHtmlEscPos(
        html,
        escPosOptions.printerIp,
        escPosOptions.printerPort ?? 9100,
        paperWidthPx,
        escPosOptions.feedLines ?? 3,
        escPosOptions.cutPaper ?? true,
      );
    } catch (error) {
      handlePrintError(error, onError);
    }
  },

  /** True nếu native module đã được link thành công */
  isAvailable(): boolean {
    return NativeHtmlPrinter != null;
  },
};
