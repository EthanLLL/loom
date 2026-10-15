import { createContext, useContext, useMemo, type ReactNode } from "react"
import { marked, type Token, type Tokens } from "marked"

/**
 * Markdown for assistant messages, rendered from `marked`'s token stream.
 *
 * Only assistant messages go through here. A user's own message is shown as
 * they typed it — turning their `*` into emphasis would be rewriting it — and
 * tool input and output are shown verbatim because they are not prose: a diff,
 * a build log and a JSON argument list all mean something different after a
 * markdown pass.
 *
 * ## Why the token stream rather than HTML
 *
 * `marked.parse()` and every other markdown library's happy path produce an
 * HTML string, which has to reach the DOM through `dangerouslySetInnerHTML`.
 * This agent fetches web pages and quotes what it finds, so model output can
 * carry whatever a page contained — and the one thing that must never happen is
 * that reaching the DOM as markup. Rendering tokens as React elements makes
 * that structurally impossible instead of depending on a sanitiser staying
 * correct. `html` tokens are deliberately rendered as the literal text they
 * were written as.
 *
 * It is also a third of the weight: measured against a plain React bundle,
 * `marked`'s lexer adds 14 KB gzipped where `react-markdown` + `remark-gfm` add
 * 47 KB and `marked` + `DOMPurify` add 26 KB.
 *
 * ## Streaming
 *
 * Re-lexed on every delta, which is affordable (a few KB of markdown is
 * sub-millisecond) and `useMemo` keeps it to once per distinct string. Partial
 * input is the normal case, not an edge case: `marked` closes an unterminated
 * fence on its own, and a half-written table stays a paragraph until its
 * delimiter row arrives. Both read fine mid-stream.
 */
/**
 * How a link into the session's output directory is rendered.
 *
 * The agent is asked to write `[name](output/<path>)` for files it made (see
 * `Loom.Agent.Output`). That is not a URL the browser can follow — the file is
 * behind the API's token — so whoever renders the conversation supplies the
 * element, and without one such a link is shown like any other.
 */
export const OutputLink = createContext<
  ((path: string, label: ReactNode) => ReactNode) | null
>(null)

export function Markdown({ text }: { text: string }) {
  const tokens = useMemo(() => marked.lexer(text, { gfm: true }), [text])
  return <div className="md">{blocks(tokens)}</div>
}

function blocks(tokens: Token[]): ReactNode[] {
  return tokens.map((token, i) => <Block key={i} token={token} />).filter(Boolean)
}

function Block({ token }: { token: Token }): ReactNode {
  switch (token.type) {
    case "heading": {
      const t = token as Tokens.Heading
      // Capped at h3: these sit inside a chat bubble, so an h1 rendered at its
      // usual size would dwarf the conversation around it.
      const level = Math.min(t.depth, 3)
      const Tag = `h${level}` as "h1" | "h2" | "h3"
      return <Tag className="md-h">{inline(t.tokens)}</Tag>
    }

    case "paragraph":
      return <p className="md-p">{inline((token as Tokens.Paragraph).tokens)}</p>

    case "code": {
      const t = token as Tokens.Code
      return (
        <pre className="code">
          {t.lang ? <span className="code-lang">{t.lang}</span> : null}
          {t.text}
        </pre>
      )
    }

    case "blockquote":
      return (
        <blockquote className="md-quote">
          {blocks((token as Tokens.Blockquote).tokens)}
        </blockquote>
      )

    case "list": {
      const t = token as Tokens.List
      const Tag = t.ordered ? "ol" : "ul"
      return (
        <Tag className="md-list" start={t.ordered ? Number(t.start) || 1 : undefined}>
          {t.items.map((item, i) => (
            <li key={i} className={item.task ? "md-task" : undefined}>
              {item.task ? <span className="md-check">{item.checked ? "✓" : "○"}</span> : null}
              {blocks(item.tokens)}
            </li>
          ))}
        </Tag>
      )
    }

    case "table": {
      const t = token as Tokens.Table
      return (
        <div className="md-table-wrap">
          <table className="md-table">
            <thead>
              <tr>
                {t.header.map((cell, i) => (
                  <th key={i} style={align(t.align[i])}>
                    {inline(cell.tokens)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {t.rows.map((row, r) => (
                <tr key={r}>
                  {row.map((cell, c) => (
                    <td key={c} style={align(t.align[c])}>
                      {inline(cell.tokens)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )
    }

    case "hr":
      return <hr className="md-hr" />

    // Never as markup. See the moduledoc: this is the whole reason for
    // rendering tokens instead of HTML.
    case "html":
      return <p className="md-p">{(token as Tokens.HTML).raw}</p>

    case "text":
      return <p className="md-p">{inlineOrText(token as Tokens.Text)}</p>

    // `space` is layout that CSS already handles; `def` is a link definition
    // with nothing to show.
    case "space":
    case "def":
      return null

    default:
      return <p className="md-p">{(token as { raw?: string }).raw ?? ""}</p>
  }
}

function inline(tokens: Token[] | undefined): ReactNode[] {
  return (tokens ?? []).map((token, i) => <Inline key={i} token={token} />)
}

function inlineOrText(token: Tokens.Text): ReactNode {
  return token.tokens ? inline(token.tokens) : token.text
}

function Inline({ token }: { token: Token }): ReactNode {
  const renderOutput = useContext(OutputLink)

  switch (token.type) {
    case "text":
      return inlineOrText(token as Tokens.Text)

    case "escape":
      return (token as Tokens.Escape).text

    case "codespan":
      return <code>{(token as Tokens.Codespan).text}</code>

    case "strong":
      return <strong>{inline((token as Tokens.Strong).tokens)}</strong>

    case "em":
      return <em>{inline((token as Tokens.Em).tokens)}</em>

    case "del":
      return <del>{inline((token as Tokens.Del).tokens)}</del>

    case "br":
      return <br />

    case "link": {
      const t = token as Tokens.Link
      const output = outputPath(t.href)
      if (output !== null && renderOutput) return renderOutput(output, inline(t.tokens))

      const href = safeHref(t.href)
      // An unsafe scheme still shows its label and its target, just not as
      // something clickable — silently dropping either would hide what the
      // model said.
      if (!href) {
        return (
          <span className="md-link-blocked" title={t.href}>
            {inline(t.tokens)}
          </span>
        )
      }
      return (
        <a href={href} target="_blank" rel="noopener noreferrer" title={t.title ?? t.href}>
          {inline(t.tokens)}
        </a>
      )
    }

    // Not rendered as an image: the source is arbitrary and loading it would
    // call out to whatever host the model named. The alt text and the URL say
    // what it was.
    case "image": {
      const t = token as Tokens.Image
      return <span className="md-image">🖼 {t.text || t.href}</span>
    }

    case "html":
      return (token as Tokens.HTML).raw

    default:
      return (token as { raw?: string }).raw ?? ""
  }
}

function align(value: "center" | "left" | "right" | null) {
  return value ? { textAlign: value } : undefined
}

// Everything else — `javascript:`, `data:`, `vbscript:` — is refused. The model
// composes these from pages it fetched, so the scheme is not trustworthy.
const SAFE_SCHEME = /^(https?:|mailto:|#|\/|\.{0,2}\/)/i

// `output/report.xlsx` or `./output/report.xlsx`, percent-decoded, since the
// model escapes spaces to keep the link valid. Anything with `..` is left to be
// an ordinary (and useless) relative link; the server would refuse it anyway.
function outputPath(href: string): string | null {
  const m = /^(?:\.\/)?output\/(.+)$/.exec((href ?? "").trim())
  if (!m) return null
  let path: string
  try {
    path = decodeURIComponent(m[1])
  } catch {
    path = m[1]
  }
  return path.split("/").includes("..") ? null : path
}

function safeHref(href: string): string | null {
  const trimmed = (href ?? "").trim()
  return SAFE_SCHEME.test(trimmed) ? trimmed : null
}
