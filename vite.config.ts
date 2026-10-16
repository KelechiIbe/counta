import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon-brand.svg', 'logo-brand.svg', 'apple-touch-icon.png', 'badge-96.png'],
      manifest: {
        name: 'Counta by TaxStreem',
        short_name: 'Counta',
        description: 'Stock, receipts and counts for your shop, posted straight to your books.',
        id: '/',
        start_url: '/',
        scope: '/',
        display: 'standalone',
        background_color: '#ffffff',
        theme_color: '#0072F5',
        icons: [
          { src: '/pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
        ],
        shortcuts: [
          { name: 'Scan an item', short_name: 'Scan', url: '/m/scan', icons: [{ src: '/pwa-192.png', sizes: '192x192' }] },
          { name: 'Record a sale', short_name: 'Sell', url: '/m/sell', icons: [{ src: '/pwa-192.png', sizes: '192x192' }] },
          { name: 'Receive stock', short_name: 'Receive', url: '/m/receive', icons: [{ src: '/pwa-192.png', sizes: '192x192' }] }
        ]
      },
      workbox: {
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        // Export libraries load only when someone downloads a file, so phones do not install them up front.
        globIgnores: ['**/push-sw.js', '**/exceljs*.js', '**/xlsx-*.js', '**/pdf-vendor-*.js'],
        importScripts: ['push-sw.js'],
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        runtimeCaching: [
          {
            urlPattern: ({ url }) => url.origin === 'https://fonts.googleapis.com' || url.origin === 'https://fonts.gstatic.com',
            handler: 'StaleWhileRevalidate',
            options: { cacheName: 'fonts' }
          },
          {
            urlPattern: ({ url }) => /\/assets\/(exceljs|xlsx-|pdf-vendor-)/.test(url.pathname),
            handler: 'CacheFirst',
            options: { cacheName: 'export-libs', expiration: { maxEntries: 12 } }
          },
          {
            // The barcode reader for iPhones (no built-in BarcodeDetector). Cached on first scan.
            urlPattern: ({ url }) => url.pathname.endsWith('.wasm'),
            handler: 'CacheFirst',
            options: { cacheName: 'wasm', expiration: { maxEntries: 4 } }
          }
        ]
      }
    })
  ],
  build: {
    chunkSizeWarningLimit: 1600,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes('vite/preload-helper') || id.includes('commonjsHelpers')) return 'runtime';
          if (/node_modules\/(jspdf|jspdf-autotable|canvg|html2canvas|dompurify|rgbcolor|stackblur-canvas|svg-pathdata)\//.test(id)) return 'pdf-vendor';
          return undefined;
        }
      }
    }
  }
});
