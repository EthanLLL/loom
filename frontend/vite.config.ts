import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Proxy API, canvas + websocket to the Phoenix backend so everything is same-origin
// in dev (no CORS, no hardcoded backend host in the client).
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': { target: 'http://localhost:4000', changeOrigin: true },
      '/canvas/': { target: 'http://localhost:4000', changeOrigin: true },
      '/socket': { target: 'ws://localhost:4000', ws: true, changeOrigin: true },
    },
  },
})
