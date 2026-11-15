import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './fonts.css'
import './index.css'
import './theme'
import App from './App.tsx'
import { NativeMain } from './ios/Main'
import { NativePane } from './ios/Pane'
import { surface } from './native'
import { registerWorker } from './push'
import { fitToKeyboard } from './viewport'

// The iOS app sizes its web views itself, keyboard included, and has no
// service worker to give push to.
if (surface === null) {
  fitToKeyboard()
  registerWorker()
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {surface === 'main' ? <NativeMain /> : surface === 'pane' ? <NativePane /> : <App />}
  </StrictMode>,
)
