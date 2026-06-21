/**
 * Types & enums cho react-native-bill-printer.
 */

/**
 * Khổ giấy hỗ trợ.
 *
 * A4  → 210 × 297 mm  (ISO standard)
 * A5  → 148 × 210 mm  (ISO standard)
 * K80 → 72mm wide thermal roll  (576px @ 203dpi)
 * K58 → 48mm wide thermal roll  (384px @ 203dpi)
 */
export enum BillPrinterPageSize {
  A4  = 'A4',
  A5  = 'A5',
  K80 = 'K80',
  K58 = 'K58',
}

/** Paper width tính bằng pixel tại 203dpi (chuẩn thermal printer) */
export const PAPER_WIDTH_PX: Record<BillPrinterPageSize, number> = {
  [BillPrinterPageSize.K80]: 576,   // 72mm × 203dpi / 25.4
  [BillPrinterPageSize.K58]: 384,   // 48mm × 203dpi / 25.4
  [BillPrinterPageSize.A4]: 1654,   // 210mm × 200dpi / 25.4 (ít dùng với ESC/POS)
  [BillPrinterPageSize.A5]: 1169,   // 148mm × 200dpi / 25.4
};

/** Options cho IPP print (dialog hoặc silent) */
export interface BillPrintOptions {
  /** Khổ giấy — mặc định A4 */
  pageSize?: BillPrinterPageSize;
  /** Tên job in hiển thị trong print queue / dialog */
  jobName?: string;
  /**
   * URL máy in IPP để silent print qua LAN — không mở dialog.
   * Format: "ipp://192.168.1.100" | "ipp://192.168.1.100:631" | "TCP:192.168.1.100"
   * Nếu không truyền → mở print dialog hệ thống (AirPrint / PrintManager).
   */
  printerUrl?: string;
}

/**
 * Thông tin lỗi máy in — truyền cho caller qua onError callback.
 * Caller (empos-app) tự quyết định gửi lên Sentry hay xử lý khác.
 * Thư viện KHÔNG phụ thuộc Sentry — zero dependency.
 */
export interface PrinterErrorInfo {
  /** Mã lỗi từ native module (TCP_ERROR, RENDER_ERROR, etc.) */
  errorCode: string;
  /** Message gốc từ native */
  message: string;
  /** Error gốc — để caller log hoặc re-throw */
  nativeError: Error;
}

/**
 * Callback gọi khi xảy ra lỗi in.
 * Được gọi TRƯỚC khi throw error, cho phép caller capture trước khi propagate.
 */
export type PrinterErrorCallback = (info: PrinterErrorInfo) => void;

/** Options cho ESC/POS TCP print */
export interface EscPosPrintOptions {
  /** IP máy in, ví dụ "192.168.1.100" */
  printerIp: string;
  /** TCP port — mặc định 9100 */
  printerPort?: number;
  /** Khổ giấy — dùng để tính paperWidthPx. Mặc định K80 */
  pageSize?: BillPrinterPageSize;
  /** Override chiều rộng giấy tính bằng pixel nếu không dùng pageSize mặc định */
  paperWidthPx?: number;
  /** Số dòng feed sau khi in — mặc định 3 */
  feedLines?: number;
  /** Cắt giấy sau khi in — mặc định true */
  cutPaper?: boolean;
}
