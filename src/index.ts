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
import type { BillPrintOptions, EscPosPrintOptions } from './html-printer.types';

export { BillPrinterPageSize, PAPER_WIDTH_PX } from './html-printer.types';
export type { BillPrintOptions, EscPosPrintOptions } from './html-printer.types';

export const BillPrinter = {
  /**
   * In HTML qua IPP.
   * - printerUrl có giá trị → silent print (không dialog)
   * - printerUrl rỗng/undefined → mở print dialog hệ thống
   */
  print(html: string, options: BillPrintOptions = {}): Promise<void> {
    if (!NativeHtmlPrinter) {
      return Promise.reject(new Error('PRINTER_MODULE_UNAVAILABLE: pod install chưa được chạy'));
    }
    const pageSize = options.pageSize ?? BillPrinterPageSize.A4;
    const jobName = options.jobName ?? 'Print';
    const printerUrl = options.printerUrl ?? '';
    return NativeHtmlPrinter.printHtml(html, pageSize, jobName, printerUrl);
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
   */
  printEscPos(html: string, options: EscPosPrintOptions): Promise<void> {
    if (!NativeHtmlPrinter) {
      return Promise.reject(new Error('PRINTER_MODULE_UNAVAILABLE: pod install chưa được chạy'));
    }
    const pageSize = options.pageSize ?? BillPrinterPageSize.K80;
    const paperWidthPx = options.paperWidthPx ?? PAPER_WIDTH_PX[pageSize];
    return NativeHtmlPrinter.printHtmlEscPos(
      html,
      options.printerIp,
      options.printerPort ?? 9100,
      paperWidthPx,
      options.feedLines ?? 3,
      options.cutPaper ?? true,
    );
  },

  /** True nếu native module đã được link thành công */
  isAvailable(): boolean {
    return NativeHtmlPrinter != null;
  },
};
