# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.4.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alberti42/agent-shell-math-renderer/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/alberti42/agent-shell-math-renderer/releases/tag/v0.1.0
