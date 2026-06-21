# react-native-bill-printer

Print HTML to physical printers from React Native (iOS & Android).

Supports two print modes:
- **ESC/POS** — thermal POS printers via TCP socket (port 9100). Flow: HTML → WebView offscreen render → 1-bit Floyd-Steinberg dither → `GS v 0` raster chunks → TCP.
- **IPP** — network printers via IPP protocol. Silent print (no dialog) or system print dialog (AirPrint / Android PrintManager).

Tested with: Xprinter, EPSON TM-T82/T88, Bixolon SRP-350, Star TSP100, EPSON TM-m30II.

---

## Requirements

- React Native >= 0.73 (New Architecture / Turbo Modules)
- iOS >= 15.0
- Android API >= 26

---

## Installation

```bash
yarn add react-native-bill-printer
# or
npm install react-native-bill-printer
```

### iOS

```bash
cd ios && pod install
```

### Android

No extra steps — auto-linked by React Native.

#### Permissions

The package declares these permissions in its own `AndroidManifest.xml` (auto-merged by Gradle):

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.PRINT" />
```

If they are not merged automatically, add them manually to `android/app/src/main/AndroidManifest.xml`:

| Permission | Required for |
|---|---|
| `INTERNET` | TCP socket to printer port 9100 |
| `ACCESS_NETWORK_STATE` | Check network before connecting |
| `ACCESS_WIFI_STATE` | Detect LAN/WiFi connectivity |
| `PRINT` | Android PrintManager (IPP print) |

#### iOS

No permission entries needed — `UIPrintInteractionController` and `WKWebView` are available without Info.plist entries.

---

## Usage

### ESC/POS (thermal POS printer)

```ts
import { BillPrinter, BillPrinterPageSize } from 'react-native-bill-printer';

await BillPrinter.printEscPos(htmlString, {
  printerIp: '192.168.1.100',
  pageSize: BillPrinterPageSize.K80,   // K80 (72mm) | K58 (48mm)
  feedLines: 3,                         // extra line feeds after print
  cutPaper: true,                       // send cut command
});
```

### IPP — silent print (no dialog)

```ts
await BillPrinter.print(htmlString, {
  printerUrl: 'ipp://192.168.1.100',
  pageSize: BillPrinterPageSize.A5,
  jobName: 'Receipt #1234',
});
```

### IPP — system print dialog

```ts
// Omit printerUrl to open AirPrint / Android PrintManager dialog
await BillPrinter.print(htmlString, {
  pageSize: BillPrinterPageSize.A4,
});
```

### Check availability

```ts
if (!BillPrinter.isAvailable()) {
  // Native module not linked — pod install not run
}
```

---

## API

### `BillPrinter.printEscPos(html, options)`

| Option | Type | Default | Description |
|---|---|---|---|
| `printerIp` | `string` | required | Printer IP address |
| `printerPort` | `number` | `9100` | TCP port |
| `pageSize` | `BillPrinterPageSize` | `K80` | Paper size |
| `paperWidthPx` | `number` | auto | Override paper width in pixels |
| `feedLines` | `number` | `3` | Extra line feeds after print |
| `cutPaper` | `boolean` | `true` | Send cut command after print |

### `BillPrinter.print(html, options)`

| Option | Type | Default | Description |
|---|---|---|---|
| `pageSize` | `BillPrinterPageSize` | `A4` | Paper size |
| `jobName` | `string` | `"Print"` | Job name in print queue |
| `printerUrl` | `string` | `""` | IPP URL for silent print. Empty → system dialog |

### `BillPrinterPageSize`

| Value | Paper | Width (px @ 203dpi) |
|---|---|---|
| `K80` | 72mm thermal roll | 576 |
| `K58` | 48mm thermal roll | 384 |
| `A4` | 210 × 297 mm | 1654 |
| `A5` | 148 × 210 mm | 1169 |

---

## How ESC/POS printing works

1. HTML string is loaded into an offscreen `WKWebView` (iOS) / `WebView` (Android)
2. WebView renders the full content and takes a bitmap snapshot
3. Bitmap is scaled to `paperWidthPx`
4. Floyd-Steinberg dithering converts the image to 1-bit black & white
5. Image is encoded as ESC/POS `GS v 0` raster commands, split into chunks of ≤255 rows to avoid printer buffer overflow
6. Data is sent over TCP socket to `printerIp:printerPort`
7. Optional: line feed (`ESC d n`) and paper cut (`GS V 0`) commands are appended

---

## HTML tips for thermal printers

```html
<html>
<head>
<meta charset="UTF-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    width: 576px;        /* K80: 576px | K58: 384px */
    font-family: monospace;
    font-size: 24px;
    background: white;
    color: black;
  }
  .divider { border-top: 2px dashed #000; margin: 8px 0; }
  .row { display: flex; justify-content: space-between; }
</style>
</head>
<body>
  <h2 style="text-align:center">RECEIPT</h2>
  <div class="divider"></div>
  <div class="row"><span>Item A</span><span>50,000</span></div>
  <div class="divider"></div>
  <div class="row"><b>TOTAL</b><b>50,000</b></div>
</body>
</html>
```

- Use `px` units (not `pt`, `em`, `rem`) — the WebView renders at 1:1 pixel ratio
- Set `body { width: Npx }` matching `paperWidthPx` to prevent layout wrapping
- Avoid images with external URLs — load base64 or inline SVG instead
- Use high-contrast black on white for best dither quality

---

## Metro config (monorepo / local development)

If using this package as a local path dependency, add to `metro.config.js`:

```js
const path = require('path');

module.exports = {
  watchFolders: [path.resolve(__dirname, 'packages')],
  resolver: {
    extraNodeModules: {
      'react-native-bill-printer': path.resolve(__dirname, 'packages/react-native-bill-printer'),
    },
  },
};
```

---

## License

MIT
