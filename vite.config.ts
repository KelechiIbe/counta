import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['icon-brand.svg', 'logo-brand.svg'],
      manifest: {
        name: 'Counta by TaxStreem',
        short_name: 'Counta',
        description: 'Stock, receipts and counts for your shop, posted straight to your books.',
        start_url: '/m',
        scope: '/',
        display: 'standalone',
        background_color: '#ffffff',
        theme_color: '#0072F5',
        icons: [
          { src: '/pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' }
        ]
      },
      workbox: {
        navigateFallback: '/index.html',
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        maximumFileSizeToCacheInBytes: 4 * 1024 * 1024,
        runtimeCaching: [
          {
            urlPattern: ({ url }) => url.origin === 'https://fonts.googleapis.com' || url.origin === 'https://fonts.gstatic.com',
            handler: 'StaleWhileRevalidate',
            options: { cacheName: 'fonts' }
          }
        ]
      }
    })
  ],
  build: { chunkSizeWarningLimit: 1600 }
});
