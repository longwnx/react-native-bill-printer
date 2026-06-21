/**
 * react-native.config.js — autolink config cho react-native-bill-printer.
 * RN CLI dùng file này để tự động link native modules.
 */
module.exports = {
  dependency: {
    platforms: {
      ios: {
        podspecPath: './react-native-bill-printer.podspec',
      },
      android: {
        sourceDir: './android',
        packageImportPath: 'import com.htmlprinter.HtmlPrinterPackage;',
        packageInstance: 'new HtmlPrinterPackage()',
      },
    },
  },
};
