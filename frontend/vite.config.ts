import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import path from 'node:path'

// Proxy API, canvas + websocket to the Phoenix backend so everything is same-origin
// in dev (no CORS, no hardcoded backend host in the client).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { '@': path.resolve(import.meta.dirname, './src') } },
  // noVNC (the browser pane) uses top-level await.
  build: {
    target: 'es2022',
    rolldownOptions: {
      output: {
        // The libraries in chunks of their own: under the size Vite warns
        // at, and kept by browsers across deploys, which change only the app.
        // Not the UI components: in one chunk, a page took all of them for
        // the few it shows; split as they are used, the iOS app's
        // conversation page goes without the browser's menus and dialogs.
        codeSplitting: {
          groups: [
            { name: 'react', test: /node_modules[\\/](react|react-dom|scheduler)[\\/]/ },
            { name: 'xterm', test: /node_modules[\\/]@xterm[\\/]/ },
          ],
        },
      },
    },
  },
  optimizeDeps: { rolldownOptions: { transform: { target: 'es2022' } } },
  server: {
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true },
      '/canvas/': { target: 'http://localhost:4000', changeOrigin: true },
      '/canvas-files/': { target: 'http://localhost:4000', changeOrigin: true },
      '/app-icons/': { target: 'http://localhost:4000', changeOrigin: true },
      '/vendor/': { target: 'http://localhost:4000', changeOrigin: true },
      '/browser/': { target: 'ws://localhost:4000', ws: true, changeOrigin: true },
      '/socket': { target: 'ws://localhost:4000', ws: true, changeOrigin: true },
      // loom-node: install script, binaries, and the devices' own socket.
      '/node/': { target: 'http://localhost:4000', ws: true, changeOrigin: true },
    },
  },
})
