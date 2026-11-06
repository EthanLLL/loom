import { useId } from "react"
import type { AgentBackend } from "./api"

/**
 * Which engine runs a conversation, as its own mark: Claude Code's pixel
 * critter, Codex's cloud with a prompt. The binding is permanent and the two
 * behave differently, so the chat's header always says which one it is.
 */
export function BackendIcon({ backend }: { backend: AgentBackend }) {
  const gradient = useId()

  if (backend === "codex") {
    return (
      <svg className="backend-icon" viewBox="0 0 24 24" role="img" aria-label="Codex">
        <title>Codex</title>
        <defs>
          <linearGradient id={gradient} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#B6A6FF" />
            <stop offset="1" stopColor="#3D5CFF" />
          </linearGradient>
        </defs>
        <g fill={`url(#${gradient})`}>
          <circle cx="12" cy="12" r="8" />
          {[0, 45, 90, 135, 180, 225, 270, 315].map((a) => (
            <circle
              key={a}
              cx={12 + 6.5 * Math.cos((a * Math.PI) / 180)}
              cy={12 + 6.5 * Math.sin((a * Math.PI) / 180)}
              r="4"
            />
          ))}
        </g>
        <path
          d="M8 9l3 3-3 3M13 15h4"
          fill="none"
          stroke="#fff"
          strokeWidth="1.8"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
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
