import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Proxy API, canvas + websocket to the Phoenix backend so everything is same-origin
// in dev (no CORS, no hardcoded backend host in the client).
export default defineConfig({
  plugins: [react()],
  // noVNC (the browser pane) uses top-level await.
  build: { target: 'es2022' },
  optimizeDeps: { esbuildOptions: { target: 'es2022' } },
  server: {
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true },
      '/canvas/': { target: 'http://localhost:4000', changeOrigin: true },
      '/canvas-files/': { target: 'http://localhost:4000', changeOrigin: true },
      '/vendor/': { target: 'http://localhost:4000', changeOrigin: true },
      '/browser/': { target: 'ws://localhost:4000', ws: true, changeOrigin: true },
      '/socket': { target: 'ws://localhost:4000', ws: true, changeOrigin: true },
      // loom-node: install script, binaries, and the devices' own socket.
      '/node/': { target: 'http://localhost:4000', ws: true, changeOrigin: true },
    },
  },
})
