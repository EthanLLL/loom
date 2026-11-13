import { HugeiconsIcon, type IconSvgElement } from "@hugeicons/react"
import type { ComponentProps, ReactNode } from "react"
import { Button, buttonVariants } from "@/components/ui/button"
import { cn } from "cn"

/**
 * The bar over each pane of the right-hand column — the canvas, the browser,
 * the apps, each terminal: its title on the left, its buttons on the right,
 * in the chat header's type and colours.
 *
 * The column's first bar (`main`) is as tall as the chat's and the sidebar's
 * (`--head-h`), so their bottom edges make one line across the window; a
 * terminal stacked under another gets a slimmer one. On a touch screen in a
 * card it keeps clear of the round corners; on a phone, where the column has
 * the screen and its own safe-area padding, it is a plain 52px. `pane-head`
 * is what the hidden-title-bar rules in App.css find it by.
 */
export function PaneHead({
  main,
  title,
  children,
}: {
  main?: boolean
  title: ReactNode
  children?: ReactNode
}) {
  return (
    <div
      className={cn(
        "pane-head flex h-10 shrink-0 items-center gap-2 border-b bg-background pr-1.5 pl-3 font-sans text-sm text-muted-foreground pointer-coarse:h-[52px] sm:pointer-coarse:pr-3.5 sm:pointer-coarse:pl-5",
        main && "pane-head-main h-(--head-h) pointer-coarse:h-(--head-h) max-sm:h-[52px]!",
      )}
    >
      <div className="flex min-w-0 flex-1 items-center gap-1.5 pointer-coarse:gap-2">{title}</div>
      <div className="flex shrink-0 items-center gap-0.5 pointer-coarse:gap-1">{children}</div>
    </div>
  )
}

/** The pane's name, cut short rather than pushing its buttons out. */
export function PaneTitle({ children, hint }: { children: ReactNode; hint?: string }) {
  return (
    <span className="truncate font-medium text-foreground pointer-coarse:text-base" title={hint}>
      {children}
    </span>
  )
}

const PANE_BUTTON = "text-muted-foreground aria-pressed:bg-muted aria-pressed:text-foreground"

/** A bar's icon button; `pressed` for one that is a switch, shown on. */
export function PaneButton({
  icon,
  pressed,
  className,
  ...props
}: Omit<ComponentProps<typeof Button>, "children"> & { icon: IconSvgElement; pressed?: boolean }) {
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      aria-pressed={pressed}
      className={cn(PANE_BUTTON, className)}
      {...props}
    >
      <HugeiconsIcon icon={icon} />
    </Button>
  )
}

/** The same, as a link. */
export function PaneLink({ icon, className, ...props }: ComponentProps<"a"> & { icon: IconSvgElement }) {
  return (
    <a className={cn(buttonVariants({ variant: "ghost", size: "icon-sm" }), PANE_BUTTON, className)} {...props}>
      <HugeiconsIcon icon={icon} />
    </a>
  )
}

/** A word in the middle of an empty or failed pane. */
export function PaneNote({ failed, children }: { failed?: boolean; children: ReactNode }) {
  return (
    <div className={cn("px-6 py-8 text-center font-sans text-sm text-muted-foreground", failed && "text-destructive")}>
      {children}
    </div>
  )
}
