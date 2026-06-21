/**
 * NativeHtmlPrinter — Turbo Native Module spec.
 *
 * File này được RN codegen đọc để sinh C++ bridge (JSI).
 * Tên module phải khớp với tên đăng ký trên native:
 *   iOS:     @objc(HtmlPrinterModule) / RCT_EXTERN_MODULE
 *   Android: getName() = "HtmlPrinter"
 *
 * KHÔNG import trực tiếp — dùng index.ts.
 */

import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  /**
   * In HTML qua IPP (PDF) hoặc mở print dialog.
   * @param html       - Full HTML string
   * @param pageSize   - "A4" | "A5" | "K80" | "K58"
   * @param jobName    - Tên job in
   * @param printerUrl - IPP URL ("ipp://192.168.1.100"). Rỗng → print dialog.
   */
  printHtml(html: string, pageSize: string, jobName: string, printerUrl: string): Promise<void>;

  /**
   * In HTML qua ESC/POS TCP socket (port 9100 mặc định).
   *
   * Flow: HTML → WebView render bitmap → 1-bit dither → ESC/POS raster image → TCP socket
   *
   * @param html         - Full HTML string
   * @param printerIp    - IP máy in, ví dụ "192.168.1.100"
   * @param printerPort  - Port TCP (mặc định 9100)
   * @param paperWidthPx - Chiều rộng in tính bằng pixel (K80=576, K58=384)
   * @param feedLines    - Số dòng feed thêm sau khi in (mặc định 3)
   * @param cutPaper     - true → gửi lệnh cắt giấy sau khi in
   */
  printHtmlEscPos(
    html: string,
    printerIp: string,
    printerPort: number,
    paperWidthPx: number,
    feedLines: number,
    cutPaper: boolean,
  ): Promise<void>;
}

// Dùng get() thay vì getEnforcing() để không crash khi native chưa link.
// BillPrinter.isAvailable() sẽ trả về false và caller hiển thị toast lỗi.
// Tên 'HtmlPrinter' khớp với:
//   iOS:     @objc(HtmlPrinter) trong Swift + RCT_EXTERN_MODULE(HtmlPrinter) trong .mm
//   Android: getName() = "HtmlPrinter" trong HtmlPrinterModule.kt
export default TurboModuleRegistry.get<Spec>('HtmlPrinter');
