import { useId } from "react"
import type { AgentBackend } from "./api"

/**
 * Which engine runs a conversation, as its own mark: Claude Code's pixel
 * critter, Codex's cloud with a prompt and Kiro's ghost (both lobe-icons). The binding is permanent
 * and they behave differently, so the chat's header always says which one it is.
 */
export function BackendIcon({ backend }: { backend: AgentBackend }) {
  const gradient = useId()

  if (backend === "kiro") {
    return (
      <svg className="backend-icon" viewBox="0 0 24 24" role="img" aria-label="Kiro">
        <title>Kiro</title>
        <path fill="#9046FF" fillRule="evenodd" d="M4.594 6.677C6.67-2.226 18.746-2.211 21.16 6.632c.353 1.297 1.725 7.582-1.673 13.747-1.545 2.797-5.841 5.49-6.99 1.883C8.6 25.477 3.315 24.1 5.789 18.609l-.318.143c-3.57 1.305-3.863-1.208-3.173-2.513.45-.84.727-1.335.937-1.897.353-.975.458-1.568.593-2.498.27-1.837.277-3.607.765-5.167zm8.37.01a.92.92 0 00-.81.428c-.217.323-.33.825-.33 1.462 0 .705.15 1.89 1.14 1.89h.008c.757 0 1.214-.705 1.214-1.89 0-.622-.127-1.125-.367-1.455a1.014 1.014 0 00-.855-.435zm4.08 0a.92.92 0 00-.81.428c-.217.323-.33.825-.33 1.462 0 .705.15 1.89 1.14 1.89h.008c.757 0 1.215-.705 1.215-1.89 0-.622-.128-1.125-.368-1.455a1.014 1.014 0 00-.855-.435z" />
      </svg>
    )
  }

  if (backend === "codex") {
    return (
      <svg className="backend-icon" viewBox="0 0 24 24" role="img" aria-label="Codex">
        <title>Codex</title>
        <defs>
          <linearGradient id={gradient} gradientUnits="userSpaceOnUse" x1="12" x2="12" y1="3" y2="21">
            <stop stopColor="#B1A7FF" />
            <stop offset=".5" stopColor="#7A9DFF" />
            <stop offset="1" stopColor="#3941FF" />
          </linearGradient>
        </defs>
        <path fill={`url(#${gradient})`} d="M9.064 3.344a4.578 4.578 0 012.285-.312c1 .115 1.891.54 2.673 1.275.01.01.024.017.037.021a.09.09 0 00.043 0 4.55 4.55 0 013.046.275l.047.022.116.057a4.581 4.581 0 012.188 2.399c.209.51.313 1.041.315 1.595a4.24 4.24 0 01-.134 1.223.123.123 0 00.03.115c.594.607.988 1.33 1.183 2.17.289 1.425-.007 2.71-.887 3.854l-.136.166a4.548 4.548 0 01-2.201 1.388.123.123 0 00-.081.076c-.191.551-.383 1.023-.74 1.494-.9 1.187-2.222 1.846-3.711 1.838-1.187-.006-2.239-.44-3.157-1.302a.107.107 0 00-.105-.024c-.388.125-.78.143-1.204.138a4.441 4.441 0 01-1.945-.466 4.544 4.544 0 01-1.61-1.335c-.152-.202-.303-.392-.414-.617a5.81 5.81 0 01-.37-.961 4.582 4.582 0 01-.014-2.298.124.124 0 00.006-.056.085.085 0 00-.027-.048 4.467 4.467 0 01-1.034-1.651 3.896 3.896 0 01-.251-1.192 5.189 5.189 0 01.141-1.6c.337-1.112.982-1.985 1.933-2.618.212-.141.413-.251.601-.33.215-.089.43-.164.646-.227a.098.098 0 00.065-.066 4.51 4.51 0 01.829-1.615 4.535 4.535 0 011.837-1.388zm3.482 10.565a.637.637 0 000 1.272h3.636a.637.637 0 100-1.272h-3.636zM8.462 9.23a.637.637 0 00-1.106.631l1.272 2.224-1.266 2.136a.636.636 0 101.095.649l1.454-2.455a.636.636 0 00.005-.64L8.462 9.23z" />
      </svg>
    )
  }

  return (
    <svg className="backend-icon" viewBox="0 -3 16 16" role="img" aria-label="Claude Code">
      <title>Claude Code</title>
      <path
        fill="#D97757"
        fillRule="evenodd"
        d="M2 0h12v4h2v2h-2v2h-1v2h-1v-2h-1v2h-1v-2h-4v2h-1v-2h-1v2h-1v-2h-1v-2h-2v-2h2zM4 2v2h1v-2zM11 2v2h1v-2z"
      />
    </svg>
  )
}
