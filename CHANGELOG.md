# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Requires `latex-to-svg-backend` 0.18.1. Before it, the texres engine
  cut off the right side of an equation wider than the `varwidth` box
  (`latex-to-svg-backend-line-width`, default `\linewidth` ≈ 345pt).

## [0.17.1] - 2026-10-27

### Changed

- Requires agent-shell 0.89.4 or newer. Since that release agent-shell
  leaves the text after a render function's watermark untouched for the
  rest of the chunk (xenodium/agent-shell#915), so the package no longer
  freezes an equation that is still streaming to keep agent-shell's
  escape pass from turning `\(` into `(` or `\[` into `[`.

## [0.17.0] - 2026-10-23

### Added

- Setting the obsolete `agent-shell-math-renderer-padding` or
  `agent-shell-math-renderer-enabled` non-nil shows a warning, once per
  session, that says what to set instead. Before, Emacs reported them only
  when it compiled the code that set them, which an init file seldom is.
  The obsolete names `agent-shell-math-renderer-background-padding`,
  `agent-shell-math-renderer-inline-rescale` and
  `agent-shell-math-renderer-display-rescale` warn when they are set before
  the package loads, as an init file does; set after it loads, they cannot
  be told from the options they name.

### Changed

- Requires `latex-to-svg-backend` 0.18.0. Its 0.17.0 renames
  `latex-to-svg-backend-preamble` to `latex-to-svg-backend-preamble-base`.
  The old name still works and shows a warning.
- The equations follow the names of `latex-to-svg-backend` 0.18.0:
  setting `latex-to-svg-backend-preamble-not-precompiled` or
  `latex-to-svg-backend-preamble-not-precompiled-files` updates them.
  The obsolete `-preamble-macros` and `-preamble-macro-files` still
  work. The README puts macro files in
  `latex-to-svg-backend-preamble-packages`, listed in
  `latex-to-svg-backend-preamble-package-files`.
- Requires agent-shell 0.89.1 or newer. The prompts of a restored session
  are found with `agent-shell-prompt-ranges`, which agent-shell added for
  this package (xenodium/agent-shell#882), instead of by the
  `user_message_chunk` id agent-shell builds internally. Text typed into
  the live prompt while a session is restored is not rendered.

## [0.16.0] - 2026-10-20

### Added

- Setting `latex-to-svg-backend-preamble-package-files` or
  `latex-to-svg-backend-preamble-macro-files`, the files the project's
  preambles load (backend 0.16.0), updates the equations, as setting a
  preamble does. The README's section on a project's preamble describes
  the four options.
- Loading the package over a `latex-to-svg-backend` older than the one it
  requires signals an error that names the backend's file and says to
  update the backend and restart Emacs. Before, an old backend failed at
  the first equation with an error about a keyword argument such as
  `:x-height`. `Package-Requires` does not prevent this: straight does
  not check versions, and after an upgrade in a running Emacs the backend
  loaded before stays loaded (latex-to-svg issue #12).
  `agent-shell-math-renderer-version` holds the package's version.

### Changed

- Requires latex-to-svg-backend 0.16.1 or newer, whose option names
  (`latex-to-svg-backend-preamble-packages`,
  `latex-to-svg-backend-preamble-macros`) and file lists the README and
  the watched options use, and whose `latex-to-svg-backend-version` the
  check at load reads.

## [0.15.0] - 2026-10-18

### Added

- An equation that no engine could typeset shows a warning icon before its
  source, with the tooltip of the source: the engine, the error and the
  command that opens the log (latex-to-svg issue #7). Before, it looked
  like an equation not typeset yet. `agent-shell-math-renderer-failure-mark`
  (default t) turns it off; `customize-icon` changes the icon
  (`agent-shell-math-renderer-failure`).
- `agent-shell-math-renderer-show-error-log` opens the log of the failed
  equation at point, or shows the error in the echo area when there is no
  log. The tooltip of a failed equation names it.

### Changed

- A color option (`agent-shell-math-renderer-foreground-color`,
  `agent-shell-math-renderer-background-color`) whose value is not a color
  is reported when `agent-shell-math-renderer-mode` turns on and when an
  option of this package is set, in each buffer with equations, instead of
  once for the life of the Emacs process, when an equation was first
  drawn. Drawing an equation ignores such a value with no warning, as it
  ignored it before after the first warning.

## [0.14.0] - 2026-10-14

### Changed

- Requires latex-to-svg-backend 0.15.0 or newer. That backend reports to
  this package whether a compile succeeded or failed;
  agent-shell-math-renderer 0.13.1 and earlier signal
  `wrong-number-of-arguments` on that report and show no image after any
  compile. A package that brings in backend 0.15.0, such as latex-to-svg
  0.22.0, needs this release alongside it.
- An equation that fails to compile stays as source in the buffer, as in
  0.13.1. The error is not shown yet.

## [0.13.1] - 2026-10-14

### Changed

- Requires agent-shell 0.67.1 or newer, the first release that emits
  `session-restored`.

### Fixed

- With `agent-shell-math-renderer-render-submitted-prompts` on, the user
  prompts of a restored session are rendered too. agent-shell replays
  them without running its markdown renderer and without emitting
  `input-submitted`, so they stayed raw LaTeX. They are rendered when
  agent-shell emits `session-restored`.

## [0.13.0] - 2026-10-10

### Added

- A third engine, `texres`: `agent-shell-math-renderer-engine` sends an
  equation to the backend with `:engine 'texres`, which compiles it with the
  `pdflatex` of [texres](https://github.com/leoliu0/texres) and converts the
  PDF with `pdftocairo`. `C-u M-x agent-shell-math-renderer-refresh` deletes
  texres's `.fmt` file too. An equation texres rejects has a LaTeX error, so
  it gets no fallback.
- Each equation takes the color and the x-height of the text at its
  opening delimiter: one in a heading, a link or a block quote has the
  color and the size of that text. The color is read again at every
  refresh, so a theme change re-tints them. Equations in plain text look
  as before.
- `agent-shell-math-renderer-foreground-ignored-faces`: faces whose
  foreground the color of an equation does not follow. The next face of
  the text at the opening delimiter that specifies a foreground is used,
  else `agent-shell-math-renderer-foreground-color`. With
  `agent-shell-markdown-header-1` or `agent-shell-markdown-link` in it, an
  equation in a heading or a link keeps the color of the text around it.

### Changed

- `agent-shell-math-renderer-foreground-color` now colors the equations
  in text drawn in the default foreground; an equation in colored text
  keeps the color of the text. Before, it colored every equation.
- Equations are sized by the x-height of the text, the height of its
  lowercase x, passed to the backend as `:x-height`: a lowercase letter in
  an equation is as tall as one in the text, as CSS's `font-size-adjust`
  does, whatever the font. Capitals and digits come out about 10% larger
  than the text's. Before, they were sized by the line height
  (`default-font-height`), so equations came out larger than the text.
  The size no longer differs between Emacs ports, and inline equations sit
  on the text's baseline; both come from `latex-to-svg-backend` 0.14.0.
  Every equation compiles once more after the update, for the backend's
  new cache.
- In an Emacs that cannot display SVG images (built without librsvg), the
  equations are still sent to the backend, which warns once per session
  and returns no image; the LaTeX source stays. Before, this package sent
  nothing and nothing said why the equations stayed as source.
- Requires `latex-to-svg-backend` 0.14.0, which reads no faces and no
  frames. This package reads the colors on the frame that shows the buffer
  and passes them to the backend as `#rrggbb` strings: the tint, when
  `agent-shell-math-renderer-foreground-color` is nil, is the foreground of
  the `default` face on that frame, and a name in
  `agent-shell-math-renderer-foreground-color` or
  `agent-shell-math-renderer-background-color` is resolved there. A name the
  frame cannot resolve, or a value that is not a string, is reported with
  a warning and treated as nil.
- When the compile of an equation ends, its tint is read again with its
  font height, on the frame that shows the buffer then. Before, the tint
  was the one read when the compile was scheduled.
- The check for a theme or font change compares the colors of the
  `default` face on the frame that shows the buffer, where it compared
  those of the selected frame.
- An equation is compiled while some frame is graphical, whether or not a
  window shows its buffer. While every frame is a terminal frame, nothing
  is compiled, and the equations are compiled when a graphical window
  shows the buffer. Before, the backend compiled them only while the
  selected frame was graphical, unless
  `latex-to-svg-backend-render-on-non-graphic` was set, so a buffer
  rendered while a terminal client's frame was selected waited for its
  next display even in a session with a graphical frame. 0.14.0 makes that
  option obsolete and without effect, and this package has no replacement
  for it.
- The check for a theme or font change does nothing while no graphical
  window shows the buffer.
- When a program of the engine is not found, the backend warns once per
  session, naming the engine and the program, and the equation's source stays
  as text. Before, the backend drew its placeholder panel. The commentary and
  README now say so.

### Fixed

- An inline equation in a heading or a link got no image when it was not
  yet in the cache: the heading's and the link's passes delete and
  reinsert their text, which collapsed the region the compile's callback
  held. Equations are now rendered after those passes.

## [0.12.0] - 2026-09-28

### Added

- `agent-shell-math-renderer-padding-inline` and
  `agent-shell-math-renderer-padding-display` set the padding of inline and
  display equations separately, with the values
  `agent-shell-math-renderer-padding` takes. They are safe as file-local
  values and update the equations when set.
- Setting one of the backend's options in the cache key that a project sets
  in `.dir-locals.el` (`latex-to-svg-backend-preamble`,
  `latex-to-svg-backend-appended-preamble`,
  `latex-to-svg-backend-preamble-not-precompiled`,
  `latex-to-svg-backend-line-width`, `latex-to-svg-backend-ratex-macros`)
  updates the equations on its own, like this package's own options: a
  buffer-local value (from `.dir-locals.el`) updates that chat, a default
  value every chat that uses it.

### Changed

- Requires `latex-to-svg-backend` 0.11.1, which reads its preamble options in
  the buffer that asks for an equation: a chat started in a project typesets
  with the project's preamble from `.dir-locals.el`.
- A change of an option's default value no longer updates a chat that has
  its own local value of that option, since the change does not reach it.
- `C-u M-x agent-shell-math-renderer-refresh` also deletes the buffer's
  `.fmt` file (`latex-to-svg-backend-invalidate-format`) when the engine or
  its fallback is `latex`. The file holds the files the preamble loads as
  they were when it was dumped, so before, an edit to one, such as the
  `macros.tex` of an `\input{macros.tex}`, did not reach the recompiled
  equations. The next compile dumps it again.
- The README says how a chat takes a project's preamble from
  `.dir-locals.el` and how to trust the project's directory.

### Deprecated

- `agent-shell-math-renderer-padding`, which padded both kinds alike. It
  still works: a kind whose own option is nil (the default) takes its value.
- `agent-shell-math-renderer-inline-rescale` and
  `agent-shell-math-renderer-display-rescale` are renamed
  `agent-shell-math-renderer-rescale-inline` and
  `agent-shell-math-renderer-rescale-display`, so the four per-kind options
  share their roots and complete together. The old names keep working as
  obsolete aliases.

## [0.11.0] - 2026-09-27

### Added

- `agent-shell-math-renderer-engine` (default `latex`) chooses the engine
  that typesets the equations: `latex` runs `latex` and `dvisvgm`, `ratex`
  runs RaTeX's `render-svg`, which needs no TeX installation and typesets
  the math KaTeX supports, with no packages. It is passed to
  `latex-to-svg-backend` as `:engine`; an async compile's callback uses the
  engine the compile was scheduled with. Each engine has its own cache
  entries. The option is safe as a file- or directory-local variable for
  its two values.
- `agent-shell-math-renderer-fallback` (default t): when the engine is not
  `latex`, an equation it rejects, such as one using siunitx's `\SI`,
  `\DeclareMathOperator` or an environment RaTeX lacks, is typeset with LaTeX
  instead. It is passed to `latex-to-svg-backend` as `:fallback`, and the
  callback of an async compile uses the value read when the compile was
  scheduled. A fallback equation is typeset in LaTeX's style (Computer
  Modern) next to RaTeX's (KaTeX's fonts), and takes about 300 ms to compile
  instead of about 6 ms. The fallback needs `latex` and `dvisvgm`. With the
  option off, an equation the engine rejects keeps its source as text.
- `agent-shell-math-renderer-quiet` (default nil): when non-nil, the backend
  gives no warning about an equation it cannot typeset, and the equation
  keeps its source as text. It is passed to `latex-to-svg-backend` as
  `:quiet`.
  Configuration problems, such as missing programs, still warn. When nil,
  the backend warns once per equation per buffer, naming the buffer and
  linking to the log.
- Hovering over an equation names the engine that typeset it before its
  LaTeX: "Typeset with RaTeX: …", or "Typeset with LaTeX (RaTeX could not
  parse it): …" for a fallback picture. The tooltip is set when the image
  is laid, from `latex-to-svg-backend-engine-used`; until then it shows the
  LaTeX alone.
- Setting an option that affects the equations (`-engine`, `-fallback`,
  `-foreground-color`, `-background-color`, `-padding`, `-inline-rescale`,
  `-display-rescale`, `-center-display-math`) with `setq`, `setq-local` or
  Customize updates the equations on its own, through a variable watcher:
  a change of the default value updates every buffer with equations, a
  buffer-local one that buffer, and a `let` nothing. The update runs from a
  timer, so several changes in one go update once. Before, each of these
  options needed a refresh of every buffer.
- `C-u M-x agent-shell-math-renderer-refresh` (RECOMPILE non-nil from Lisp)
  recompiles the equations in the current buffer, bypassing the cache: the
  way to retry after a fix the cache cannot see, such as installing a missing
  TeX package or upgrading RaTeX. For each equation it calls
  `latex-to-svg-backend-invalidate` with the engine, and with the fallback
  engine when there is one, which also deletes the record of a failed
  compile; then it renders the equation again.

### Changed

- Requires `latex-to-svg-backend` 0.10.0, for `:engine`, `:fallback` and
  `:quiet`.
- Display math is passed to the backend as `\[ body \]` instead of
  `$\displaystyle body$`. The backend's `varwidth` preamble typesets both at
  the same size and with the same glyphs. The cache key changes, so each
  display equation is compiled once more; the old entries expire through the
  backend's cache GC.
- `C-u M-x agent-shell-math-renderer-refresh` recompiles the current buffer
  (see Added) instead of refreshing every buffer with equations. The
  every-buffer form existed for global option changes, which now update the
  equations on their own. The second argument of
  `agent-shell-math-renderer-refresh` is now RECOMPILE (was ALL).
- In the documentation, "engine" now names the program that typesets an
  equation, LaTeX or RaTeX, and "backend" names `latex-to-svg-backend`. The
  released versions' entries below use "engine" for the backend, as they
  were written.

### Fixed

- Hovering over an equation shows its LaTeX as written. Emacs passes a
  `help-echo` string through `substitute-command-keys`, which read `\[` as
  the start of a key reference and `\{` as a keymap, and turned quotes into
  curved ones, so `\{ x \}` showed as "Uses keymap ‘ x \’, which is not
  currently defined" and `f'(x)` as "f’(x)". The `help-echo` now puts `\=`
  before each backslash, backquote and apostrophe, which
  `substitute-command-keys` copies literally.
- The docstring of `agent-shell-math-renderer-refresh` no longer says a
  color change recompiles: colors and size apply at display time, and only
  a change of engine compiles the equations the new engine has not typeset.
  The color, box and padding options say "(no recompile)" instead of "(no
  LaTeX recompile)", which no engine does.

## [0.10.0] - 2026-09-09

### Added

- `agent-shell-math-renderer-center-display-math` (default nil): center
  display-math equations in the window, the way a LaTeX document centers them.
  Inline math is never centered. This is a display-time indent, not part of
  the image — the line's `line-prefix` becomes
  `(space :align-to (- center (0.5 . IMAGE)))`, so redisplay re-centers on a
  window resize, a split or a font change, and nothing measures the image
  (`image-size` on an undisplayed SVG is not reliable). Centering replaces
  agent-shell's indentation for that line, since the position is measured from
  the window rather than the surrounding text.
- Per-side padding: `agent-shell-math-renderer-padding` now takes a list of
  four numbers (TOP RIGHT BOTTOM LEFT) as well as a single number, so the box
  can have a left gutter (or any other asymmetric inset) instead of the same
  inset all round — a left gutter and nothing else is `(0 0 0 6)`. A plain
  number keeps its meaning (all four sides). The `:safe` predicate accepts
  every shape the engine does, so a file-local value can use the engine's
  shorter CSS forms too. Requires `latex-to-svg-backend` 0.9.0.

### Changed

- `agent-shell-math-renderer-background-padding` is renamed
  `agent-shell-math-renderer-padding`: with per-side values the option is no
  longer only about the background box — without a box color the padding is
  transparent, so a symmetric value is invisible, but an asymmetric one still
  shifts the equation within its own image (a left-only pad indents it). The
  old name keeps working as an obsolete alias, declared *before* the
  `defcustom` so a config that sets it before this file loads is still
  honored.

## [0.9.1] - 2026-09-03

### Changed

- Installation now pulls the rendering engine from MELPA. `latex-to-svg-backend`
  was accepted there, so it arrives through the `Package-Requires` header and
  the recipes install only this package; the instructions no longer carry a
  second recipe per installer.
- A buffer font the frame cannot measure is now reported once per buffer,
  instead of being passed over silently. The height stays unknown either way,
  so the engine still defers sizing to display time; the difference is that a
  frame whose font cannot be opened now says so.

## [0.9.0] - 2026-08-25

### Changed

- **Fenced math no longer rewrites the buffer.** A ```` ```math ```` block used
  to have its backtick fences deleted and its body re-wrapped as `\[…\]`
  before the image went on top; the buffer then held text the agent never
  wrote, and neither a plain copy nor `M-x agent-shell-copy-as-markdown` could
  recover the original fence. The fence is now kept verbatim under the image,
  matching the `$$…$$` / `\[…\]` / `\(…\)` paths — every form this package
  renders now leaves the agent's text exactly as it arrived. Copying a rendered
  equation yields the agent's own markdown again.

  The trade-off this reverses: a plain `M-w` over a rendered fence now puts
  markdown backticks on the clipboard rather than renderable `\[…\]` LaTeX.

- **`agent-shell-math-renderer-fence-languages` now defaults to `("math")`
  alone** — a ```` ```latex ```` or ```` ```tex ```` fence is left as an
  ordinary code block instead of being typeset. The two kinds of tag mean
  different things: `math` names a *role* (it is GitHub's display-math
  fence, so its body is an equation), while `latex`/`tex` name a *language*. An
  agent tagging a fence `latex` is usually quoting LaTeX source — a preamble, a
  `tabular`, a `tikzpicture`, a whole `\begin{align}` environment — which
  belongs in a code block and often would not even compile as an equation.

  To restore the old behaviour:

  ```elisp
  (setopt agent-shell-math-renderer-fence-languages '("math" "latex" "tex"))
  ```

### Fixed

- **A blank line before a ```` ```math ```` block no longer disappears.**
  agent-shell-markdown's block range starts on the newline of the blank line
  *preceding* the opening fence, and the whole range was being taken as the
  math region — so the equation image's `display` property covered that
  newline and the gap between the equation and the paragraph above it closed
  up. (Before 0.9.0 the same off-by-one deleted the blank line outright, since
  the block range was what got rewritten.) The math region now starts at the
  fence itself.

## [0.8.0] - 2026-08-19

### Added

- Rendered math now follows a **frame** font change (`set-frame-font`,
  `doom/increase-font-size`, `doom-big-font-mode`, …): add the handler to
  `after-setting-font-hook`. `text-scale-mode-hook`, which the mode installs
  itself, only covers buffer-local zoom, so equations previously rescaled only
  on their next redisplay. As with the theme hook, nothing is installed on
  your behalf.

### Changed

- One handler for both global appearance hooks:
  `agent-shell-math-renderer-on-appearance-change`. Theme switch and frame
  font change need the exact same work (an appearance-checked sweep of the
  present buffers), so there is one function to add to both hooks:

  ```elisp
  (add-hook 'enable-theme-functions
            #'agent-shell-math-renderer-on-appearance-change)
  (add-hook 'after-setting-font-hook
            #'agent-shell-math-renderer-on-appearance-change)
  ```

  Mirrors `latex-to-svg-frontend` 0.14.0.

### Deprecated

- `agent-shell-math-renderer-on-theme-change` is now an obsolete alias of
  `agent-shell-math-renderer-on-appearance-change`. Existing configurations
  keep working; update them at your convenience.

## [0.7.1] - 2026-08-15

### Fixed

- Escaped inline delimiters are no longer mistaken for math. `\\(t=0\\)` —
  markdown for *showing* `\(t=0\)` — used to be matched from its second
  backslash and rendered as an equation with the malformed body `t=0\`,
  which failed to compile. Both the opener and closer searches now skip a
  delimiter preceded by an odd number of backslashes, so the literal stays
  text and an escaped `\\)` inside a span counts as body. Thanks to
  [@jsilve24](https://github.com/jsilve24) for the report and the fix
  ([#6](https://github.com/alberti42/agent-shell-math-renderer/pull/6)).

## [0.7.0] - 2026-08-14

### Changed

- `agent-shell-math-renderer-refresh` now re-renders **only one buffer** by
  default (the current one, or BUFFER when called from Lisp), matching the
  sibling `latex-to-svg` front-end. Pass a prefix argument
  (`C-u M-x agent-shell-math-renderer-refresh`) — or non-nil ALL from Lisp —
  for the old sweep over every buffer with rendered equations, which is what
  you want after changing a global setting such as
  `agent-shell-math-renderer-foreground-color`. Theme switches are already
  covered by `agent-shell-math-renderer-on-theme-change`, which sweeps all
  buffers but repaints only those whose appearance actually changed.

### Fixed

- The deferred appearance check (`window-buffer-change-functions` /
  `text-scale-mode-hook`) now captures the triggering buffer instead of
  running in whatever buffer happens to be current when the timer fires, so
  a burst of window changes can no longer check (and refresh) the wrong
  buffer.

## [0.6.0] - 2026-08-10

### Added

- `agent-shell-math-renderer-mode`: a buffer-local minor mode that is now the
  way to turn rendering on. Enable it per agent-shell buffer, e.g.

      (add-hook 'agent-shell-mode-hook #'agent-shell-math-renderer-mode)

- `agent-shell-math-renderer-on-theme-change`: a function you can add to
  `enable-theme-functions` for instant re-tinting when you switch themes:

      (add-hook 'enable-theme-functions
                #'agent-shell-math-renderer-on-theme-change)

### Changed

- The package no longer adds any hooks merely by being loaded. The minor mode
  installs its render hook and its redisplay/zoom refresh hooks
  **buffer-locally** on activation (and removes them on deactivation). The
  package installs no global hooks: theme re-tinting is opt-in via the function
  above (equations otherwise re-tint on their next redisplay).

### Breaking changes

- **Enable via the minor mode, not the variable.** Rendering used to turn on
  by setting `agent-shell-math-renderer-enabled` to non-nil; now enable
  `agent-shell-math-renderer-mode` (typically from `agent-shell-mode-hook`, as
  shown above).
- `agent-shell-math-renderer-enabled` is **obsolete** but still works for
  backward compatibility: setting it non-nil via Customize or `setopt`
  installs an `agent-shell-mode-hook` that enables the mode everywhere. A
  plain `setq` no longer takes effect — migrate to the hook, or use `setopt`.

### Deprecated

- `agent-shell-math-renderer-enabled` (see above); prefer
  `agent-shell-math-renderer-mode`.

## [0.5.0] - 2026-08-10

### Changed

- Measure the buffer font height against the buffer's *actual* display frame
  and pass it to the backend as `:font-height`, instead of letting the engine
  guess a frame. This fixes sizing when an async render/callback fires while a
  TTY/daemon frame is selected, and avoids the engine ever touching an
  unrelated (e.g. child) frame. When a buffer is shown in no graphical window
  the height is nil: the backend compiles/caches the size-independent SVG but
  defers building the display image until the buffer is displayed, at which
  point the existing display hook re-renders it from cache (no recompile).
  Requires `latex-to-svg-backend` 0.8.0.

## [0.4.0] - 2026-08-10

### Added

- `agent-shell-math-renderer-foreground-color`,
  `agent-shell-math-renderer-background-color`, and
  `agent-shell-math-renderer-background-padding`: customize the equation tint,
  paint an optional box color behind equations (e.g. a light-gray
  background), and pad that box beyond the ink. All default to nil (follow the
  buffer foreground / transparent / cropped to the ink, unchanged behavior)
  and are passed through to `latex-to-svg-backend` as `:color` / `:background`
  / `:padding`, so they re-tint / re-box / re-pad from cache without a LaTeX
  recompile; run `agent-shell-math-renderer-refresh' after changing them.
  Requires `latex-to-svg-backend` 0.7.0.

## [0.3.1] - 2026-08-10

### Changed

- Retargeted the engine dependency from `latex-to-svg` to the standalone
  `latex-to-svg-backend`, so agent-shell-math-renderer shares only the compile
  backend rather than the full front-end; require `latex-to-svg-backend` 0.6.0.
- Rely on agent-shell to disable external render functions on single-line UI
  labels (tool-command right-labels), dropping the package's own hook-side
  guard against `\(...\)` shell grouping being misread as math
  (requires agent-shell 0.66.1+).

### Fixed

- Handle agent-shell 0.66.1's CommonMark backslash-escape pass: freeze a
  still-streaming inline `\(` opener so the escape pass can't destroy it
  before the closing `\)` arrives.
- Cleaned up docstrings for `checkdoc`: escaped an open parenthesis in column 0
  and wrapped two over-long docstring lines (MELPA pre-submission tidy-up).

## [0.3.0] - 2026-08-02

### Added

- Separate size multipliers for inline and display math previews.

### Removed

- Dropped a call to the removed `latex-to-svg-flush-metrics`.

## [0.2.0] - 2026-08-01

### Added

- Render LaTeX math in submitted user prompts, using the same delimiter,
  inline, and fenced-math handling as agent responses (#1).
- Use agent-shell's public `agent-shell-markdown-context` to obtain the
  markdown context for submitted-prompt rendering.

### Changed

- Delegate LaTeX-to-SVG rendering to the external `latex-to-svg` library and
  adapt to its verbatim API; require `latex-to-svg` 0.2.0.

### Fixed

- Streaming display-math no longer dropped when a link precedes the opener
  (watermark tracked as a marker so link/image passes can't shift it past the
  block).

## [0.1.0] - 2026-07-06

Initial release.

### Added

- Display-math rendering for agent-shell markdown output via real
  `latex → dvisvgm` compilation, overlaid as an SVG image on the raw LaTeX
  (kept in the buffer so copy/save round-trips the source).
- Block-level delimiter styles `\[...\]` and `$$...$$`, toggled independently,
  matched block-level only so `$$` is safe to default on.
- Inline `\(...\)` math, typeset in text style (toggle
  `agent-shell-math-renderer-render-inline`).
- Fenced math blocks ` ```math `/` ```latex `/` ```tex `, rewritten in place
  to `\[...\]` so copies yield LaTeX rather than backticks.
- Master switch `agent-shell-math-renderer-enabled` gating all styling.
- Skip inline math inside inline `` `code` `` spans via the hook's
  `:inline-code-ranges` context.
- Font-matched sizing: equations sized to the buffer font at image-creation
  time, re-sized from cache on font-size or `text-scale` change.
- Color-independent SVGs cached on disk and tinted to the buffer foreground at
  display time, so one compile serves every theme.
- Async, disk- and memory-cached compilation off the output path; per-buffer,
  lazy re-render on buffer display, theme/appearance change, and text-scale
  change.
- Opt-in rendering on non-graphic frames for daemon use
  (`agent-shell-math-renderer-render-on-non-graphic`).
- User-configurable preamble via
  `agent-shell-math-renderer-appended-preamble`.
- LaTeX compile failures reported with a clickable log link.
- Cache stored under agent-shell's shared, XDG/OS-aware cache directory.

### Changed

- Integrate with agent-shell only through the public
  `agent-shell-markdown-render-functions` hook and public range/cache helpers;
  require agent-shell 0.57.4 for `:inline-code-ranges`.

[Unreleased]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.17.1...HEAD
[0.17.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.17.0...v0.17.1
[0.17.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.16.0...v0.17.0
[0.16.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.13.1...v0.14.0
[0.13.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.13.0...v0.13.1
[0.13.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alberti42/agent-shell-math-renderer/releases/tag/v0.1.0
