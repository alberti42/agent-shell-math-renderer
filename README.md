# agent-shell-math-renderer

Render LaTeX math in [`agent-shell`](https://github.com/xenodium/agent-shell)'s
streamed markdown output. Display equations and inline math in an agent's
response are compiled with `latex` → `dvisvgm` and shown as crisp,
theme-matched SVG images — while the original LaTeX stays in the buffer, so
copy and save round-trip renderable source.

<!-- Add a screenshot here, e.g.:
![screenshot](images/demo.png)
-->

## What it renders

| Form | Example | Default |
|------|---------|---------|
| Bracket display math | `\[ E = mc^2 \]` | on |
| Dollar display math | `$$ E = mc^2 $$` | on |
| Fenced math | ```` ```math ```` / ```` ```latex ```` / ```` ```tex ```` blocks | on |
| Inline math | `\(x^2\)` | on |

- **Display delimiters** are matched only at **block level** — the opener must
  start its line and the closer must be flush — which is what makes `$$…$$`
  safe enough to enable by default without tripping on prose or currency.
- **Fenced math** blocks are rewritten to `\[…\]` under the image, so copying a
  rendered equation yields portable LaTeX rather than markdown backticks.
- **Inline `$…$` is intentionally not matched** — a lone `$` is too common in
  prose to detect safely. Use `\(…\)` for inline math.
- Math inside code fences and inline `` `code` `` spans is left untouched.

Images are **theme-aware**: the SVG is compiled once, color-independent, and
tinted to the buffer foreground at display time, so a theme or light/dark
switch re-tints with no recompile. Sizing tracks the buffer font.

## Requirements

- **Emacs 29.1+**
- **[`agent-shell`](https://github.com/xenodium/agent-shell)** (0.57.4 or newer —
  the release that exposes `:inline-code-ranges` to render hooks)
- A **LaTeX toolchain** providing `latex` and `dvisvgm` (e.g. TeX Live /
  MacTeX; `dvisvgm` ships with TeX Live). Without it, equations fall back to a
  bordered placeholder or the raw LaTeX text.
- An Emacs build with **SVG support** for the images (raw LaTeX is shown
  otherwise).

## Installation

The package hooks into `agent-shell` through its public
`agent-shell-markdown-render-functions` extension point — no patching, no
advice.

### `use-package` + `:vc` (Emacs 30+)

The built-in way — no `straight`, no manual `package-vc-install`:

```elisp
(use-package agent-shell-math-renderer
  :vc (:url "https://github.com/alberti42/agent-shell-math-renderer" :rev :newest)
  :after agent-shell
  :config
  (setq agent-shell-math-renderer-enabled t))
```

### `use-package` + `straight`

```elisp
(use-package agent-shell-math-renderer
  :straight (agent-shell-math-renderer
             :type git :host github
             :repo "alberti42/agent-shell-math-renderer")
  :after agent-shell
  :config
  (setq agent-shell-math-renderer-enabled t))
```

### `package-vc-install` (Emacs 29+)

For Emacs 29, where `use-package` has no `:vc` keyword:

```elisp
(package-vc-install "https://github.com/alberti42/agent-shell-math-renderer")
(require 'agent-shell-math-renderer)
(setq agent-shell-math-renderer-enabled t)
```

## Usage

Rendering is gated by a master switch, off by default:

```elisp
(setq agent-shell-math-renderer-enabled t)
```

With it on, math in the agent's responses renders automatically as it streams.
The text renders immediately and the image pops in when the (asynchronous)
compile finishes; the on-disk cache makes every repeat instant.

### Enabling per project

Prefer to render math only in some projects? Leave the global switch off and
enable it per directory. `agent-shell-math-renderer-enabled` is marked safe, so
a `.dir-locals.el` sets it without a confirmation prompt:

```elisp
;; .dir-locals.el at a project root
((agent-shell-mode . ((agent-shell-math-renderer-enabled . t))))
```

The same works for the other side-effect-free options (`-delimiters`,
`-fence-languages`, `-render-inline`, `-font-scale`, …). The toolchain and
preamble options (`-latex-program`, `-dvisvgm-program`, `-preamble`,
`-appended-preamble`, `-cache-directory`) are **not** marked safe — a
`.dir-locals.el` lives inside the repo, and those feed a compiler or run a
program, so Emacs will ask before applying them.

### Extra LaTeX packages

Need extra packages in your equations? Append to the preamble — the value is
folded into the cache key, so changing it invalidates stale images
automatically:

```elisp
(setq agent-shell-math-renderer-appended-preamble
      "\\usepackage{physics}
\\usepackage{siunitx}")
```

### Command

- `M-x agent-shell-math-renderer-refresh` — re-render displayed equations for
  the current theme/appearance and font size. Equations already re-render
  lazily on theme, buffer-display, and zoom changes; this forces it now (and
  after a pure global font-size change).

## Customization

All options live in the `agent-shell-math-renderer` customization group
(`M-x customize-group RET agent-shell-math-renderer`).

| Option | Default | Description |
|--------|---------|-------------|
| `agent-shell-math-renderer-enabled` | `nil` | Master switch. Off → the renderer is a no-op. |
| `agent-shell-math-renderer-delimiters` | `(bracket dollar)` | Which display delimiters to recognize: `bracket` (`\[…\]`) and/or `dollar` (`$$…$$`). |
| `agent-shell-math-renderer-fence-languages` | `("math" "latex" "tex")` | Fenced-code languages rendered as display math. `nil` leaves them as code. |
| `agent-shell-math-renderer-render-inline` | `t` | Recognize inline `\(…\)` math. |
| `agent-shell-math-renderer-font-scale` | `1.0` | Equation size relative to the buffer font (`1.0` = match). |
| `agent-shell-math-renderer-appended-preamble` | `""` | Extra LaTeX appended to the base preamble (load packages here). |
| `agent-shell-math-renderer-preamble` | standalone + amsmath/amssymb/xcolor | The base LaTeX preamble. |
| `agent-shell-math-renderer-latex-program` | `"latex"` | Program compiling LaTeX → DVI. |
| `agent-shell-math-renderer-dvisvgm-program` | `"dvisvgm"` | Program converting DVI → SVG. |
| `agent-shell-math-renderer-use-placeholder` | `nil` | Draw the placeholder panel instead of typesetting (also the automatic fallback when the toolchain is missing). |
| `agent-shell-math-renderer-render-on-non-graphic` | `nil` | Compile images even on a non-graphical frame (for daemon setups viewed later in a GUI). |
| `agent-shell-math-renderer-cache-directory` | `nil` | Where SVGs are cached; `nil` uses agent-shell's shared cache. |

The `agent-shell-math-renderer` face styles the raw LaTeX shown on a
non-graphical display (behind the image on a graphical one).

## How it works

- The package adds `agent-shell-math-renderer--render-hook` to
  `agent-shell-markdown-render-functions`; agent-shell's markdown renderer
  calls it once per streaming chunk, after its own passes.
- Each equation is compiled by a standalone LaTeX document → DVI (`latex`) →
  SVG (`dvisvgm --no-fonts --exact-bbox --currentcolor`). Compilation is
  **asynchronous** and off the output path, so its latency is masked by the
  agent's own streaming.
- The SVG is **cached on disk** keyed by content (LaTeX + preamble + style), so
  each unique equation compiles at most once, ever, and survives restarts. It
  is color- and font-independent; tint and size are applied cheaply at display
  time.
- The raw LaTeX is kept under the image via a `display` property, so
  selection/copy/save give back the source.

## Credits

Built on and for [`agent-shell`](https://github.com/xenodium/agent-shell) by
Álvaro Ramírez (xenodium). Rendering approach inspired by karthink's
`org-latex-preview` work, but fully standalone (no Org dependency).

## License

GPL-3.0-or-later. See the header of `agent-shell-math-renderer.el`.
