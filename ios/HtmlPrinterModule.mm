/**
 * HtmlPrinterModule.mm — ObjC++ bridge (New Architecture / Turbo Module)
 *
 * Exports Swift implementation sang React Native JS bridge.
 * install_modules_dependencies trong podspec xử lý codegen linkage tự động.
 */

#import <React/RCTBridgeModule.h>

// Tên phải khớp với @objc(HtmlPrinter) trong Swift và TurboModuleRegistry.get('HtmlPrinter') trong JS.
@interface RCT_EXTERN_MODULE(HtmlPrinter, NSObject)

RCT_EXTERN_METHOD(
  printHtml:(NSString *)html
  pageSize:(NSString *)pageSize
  jobName:(NSString *)jobName
  printerUrl:(NSString *)printerUrl
  resolve:(RCTPromiseResolveBlock)resolve
  reject:(RCTPromiseRejectBlock)reject
)

RCT_EXTERN_METHOD(
  printHtmlEscPos:(NSString *)html
  printerIp:(NSString *)printerIp
  printerPort:(NSInteger)printerPort
  paperWidthPx:(NSInteger)paperWidthPx
  feedLines:(NSInteger)feedLines
  cutPaper:(BOOL)cutPaper
  resolve:(RCTPromiseResolveBlock)resolve
  reject:(RCTPromiseRejectBlock)reject
)

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

@end
