import { lazy, StrictMode, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import './fonts.css'
import './index.css'
// Global too, the iOS app's pages included: color-scheme, the bars' height,
// and how the iOS conversation scrolls.
import './App.css'
import './theme'
import { surface } from './native'
import { registerWorker } from './push'
import { fitToKeyboard } from './viewport'

// The iOS app sizes its web views itself, keyboard included, and has no
// service worker to give push to.
if (surface === null) {
  fitToKeyboard()
  registerWorker()
}

// Each surface loads only its own code: the iOS app's two pages have no use
// for the browser's whole layout, nor the browser for theirs.
const Root =
  surface === 'main'
    ? lazy(() => import('./ios/Main').then((m) => ({ default: m.NativeMain })))
    : surface === 'pane'
      ? lazy(() => import('./ios/Pane').then((m) => ({ default: m.NativePane })))
      : lazy(() => import('./App.tsx'))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Suspense>
      <Root />
    </Suspense>
  </StrictMode>,
)
