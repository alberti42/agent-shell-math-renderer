;;; agent-shell-math-renderer.el --- Display-math rendering for agent-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/agent-shell-math-renderer
;; Version: 0.17.1
;; Package-Requires: ((emacs "29.1") (agent-shell "0.89.4") (latex-to-svg-backend "0.18.1"))
;; Keywords: tex, llm, math, education

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Display-math support for `agent-shell-markdown': intercept LaTeX
;; display equations in agent output and overlay them with an image.
;;
;; Two block-level delimiter styles are recognized, toggled
;; independently via `agent-shell-math-renderer-delimiters':
;;
;;   bracket  `\[X\]'    (default; unambiguous)
;;   dollar   `$$X$$'    (default; safe because matched block-level only)
;;
;; Inline math `\(X\)' is recognized separately (toggle
;; `agent-shell-math-renderer-render-inline', default on) and typeset
;; in text style.  Inline `$X$' is intentionally not matched — a lone
;; `$' is too common in prose to be safe.
;;
;; The raw LaTeX is kept in the buffer (so copy / save round-trips the
;; source) and, on a graphical display, an equation image is layered on
;; top with a `display' text property.  A blank line can't appear inside
;; LaTeX display math, so a candidate block whose body would span one is
;; rejected — this bounds detection and stops a stray delimiter from
;; swallowing the rest of a streaming response.
;;
;; Agent responses are rendered through
;; `agent-shell-markdown-render-functions': agent-shell's markdown
;; renderer calls `agent-shell-math-renderer--render-hook' once per
;; streaming chunk, after its own passes.  The hook styles the delimiter
;; and inline math, renders fenced math, and returns a watermark when an
;; unclosed block still needs streaming protection.
;;
;; When `agent-shell-math-renderer-render-submitted-prompts' is non-nil,
;; submitted prompts are rendered after they are sent, using the same
;; delimiter, inline-math, and fenced-math handling as agent responses.
;; The prompts a restored session replays are rendered the same way.
;; This path obtains the same markdown context through agent-shell's
;; public `agent-shell-markdown-context', so it stays in sync with the
;; streaming render hook and uses no private agent-shell API.
;;
;; Equation typesetting is delegated to the `latex-to-svg-backend' library: this
;; module handles the markdown-specific detection (delimiters, inline
;; math, fenced blocks, streaming watermark) and image *placement* (via
;; `display' text properties), while `latex-to-svg-backend' compiles each unique
;; equation to a color- and size-independent SVG (cached on disk by
;; content, tinted and scaled at display time).  Compilation is
;; asynchronous; the image is overlaid when ready.  When a program of
;; the engine is not found, the backend warns, naming the engine and
;; the program, and the source stays as text.  The engine
;; that typesets (LaTeX, RaTeX without a TeX installation, or texres) is
;; chosen by `agent-shell-math-renderer-engine'.  Backend settings (programs,
;; preamble, cache directory, font scale) live in the
;; `latex-to-svg-backend-*' customization group.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'agent-shell)
(require 'agent-shell-markdown)
(require 'comint)
(require 'icons)
(require 'latex-to-svg-backend)
(require 'map)
(require 'seq)

(defconst agent-shell-math-renderer-version "0.17.1"
  "The version of the loaded package, as in the `Version:' header.")

(defconst agent-shell-math-renderer--backend-version "0.18.1"
  "The oldest `latex-to-svg-backend' this package works with.
The same version as in the `Package-Requires' header.")

(defun agent-shell-math-renderer--check-backend-version ()
  "Signal an error if the loaded backend is older than this package needs.
The backend's version is `latex-to-svg-backend-version', of the backend
in memory: after an upgrade in a running Emacs, the file on disk can be
new while the backend loaded before it is old.  A backend with no
`latex-to-svg-backend-version' is older than 0.16.1, which added it.
Called when this file is loaded."
  (let ((version (bound-and-true-p latex-to-svg-backend-version)))
    (unless (and (stringp version)
                 (version<= agent-shell-math-renderer--backend-version version))
      (error "%s %s needs %s %s or newer, but Emacs loaded %s from %s.  \
Update %s to %s or newer, then restart Emacs"
             'agent-shell-math-renderer agent-shell-math-renderer-version
             'latex-to-svg-backend agent-shell-math-renderer--backend-version
             (if (stringp version)
                 (concat "version " version)
               "a version older than 0.16.1")
             (or (symbol-file 'latex-to-svg-backend 'defun) "an unknown file")
             'latex-to-svg-backend agent-shell-math-renderer--backend-version))))

(agent-shell-math-renderer--check-backend-version)

(defgroup agent-shell-math-renderer nil
  "Render LaTeX math in agent-shell's streamed markdown output.
Display equations (`\\=\\[...\\]', `$$...$$', and ```math fences) and
inline `\\(...\\)' are compiled to SVG, by `latex' + `dvisvgm' or
by RaTeX (see `agent-shell-math-renderer-engine'), and overlaid on
the raw LaTeX (kept in the buffer so copy/save round-trips the
source)."
  :group 'agent-shell
  :prefix "agent-shell-math-renderer-")

(defface agent-shell-math-renderer
  '((t :inherit font-lock-constant-face))
  "Face applied to rendered display-math source.
On a graphical display the source is hidden behind an equation
image; this face is the fallback styling for the raw LaTeX shown
on a non-graphical display."
  :group 'agent-shell-math-renderer)

(defconst agent-shell-math-renderer--delimiters
  '((dollar . ("$$" . "$$"))
    (bracket . ("\\[" . "\\]")))
  "Map of display-math delimiter styles to their (OPEN . CLOSE) tokens.
`dollar' is `$$...$$'; `bracket' is `\\=\\[...\\]'.  The keys of this
map are the values accepted in `agent-shell-math-renderer-delimiters'.")

(defconst agent-shell-math-renderer--inline-open "\\("
  "Opening delimiter for inline math (a literal backslash and paren).")

(defconst agent-shell-math-renderer--inline-close "\\)"
  "Closing delimiter for inline math (a literal backslash and paren).")

(defcustom agent-shell-math-renderer-delimiters '(bracket dollar)
  "Display-math delimiter styles recognized when rendering markdown.

A list whose members are keys of
`agent-shell-math-renderer--delimiters':

  `bracket'  recognize `\\=\\[...\\]'
  `dollar'   recognize `$$...$$'

The two are independent — add or drop one to toggle it.  An empty
list disables the delimiter styles (fenced math via
`agent-shell-math-renderer-fence-languages' is separate); turning
`agent-shell-math-renderer-mode' off disables everything.

Both styles are matched only as block-level equations: the opener
must start its line (after optional indentation) and the closer
must be flush — either start or end its line.  Genuinely inline
display math is therefore not recognized (agents don't emit it,
and truly inline math should use `\\(...\\)' / `$...$', which are
left untouched).  That anchoring makes `$$' safe enough to enable
by default; set to \\='(bracket) to drop it if `$$' still
collides with your prose."
  :type '(set (const bracket) (const dollar))
  :safe (lambda (v)
          (and (listp v)
               (seq-every-p (lambda (x) (memq x '(bracket dollar))) v)))
  :group 'agent-shell-math-renderer)

(defvar agent-shell-math-renderer-mode)

(defun agent-shell-math-renderer--active-p ()
  "Return non-nil when math rendering should act in the current buffer.
True when the buffer-local `agent-shell-math-renderer-mode' is on."
  agent-shell-math-renderer-mode)

(defcustom agent-shell-math-renderer-fence-languages '("math")
  "Fenced-code-block languages rendered as display math.

A fenced block whose info string is one of these (compared
case-insensitively), e.g.

  ```math
  E = mc^2
  ```

is typeset as an equation instead of shown as a code block — but
only when `agent-shell-math-renderer-mode' is on.  This
complements the `\\=\\[...\\]' / `$$...$$' delimiter styles.

`math' is the sole default because it names a *role*: it is
GitHub's display-math fence, so a block tagged with it is an
equation.  `latex' and `tex' are deliberately excluded — they name
a *language*.  An agent tagging a fence `latex' is usually quoting
LaTeX source (a preamble, a `tabular', a `tikzpicture', a whole
`\\begin{align}' environment), which belongs in a code block and
would not even compile wrapped in `\\=\\[...\\]'.  Add them if your
agent emits bare display math under those tags:

  (setq agent-shell-math-renderer-fence-languages
        \\='(\"math\" \"latex\" \"tex\"))

Set to nil to leave every fence as code."
  :type '(repeat string)
  :safe (lambda (v) (and (listp v) (seq-every-p #'stringp v)))
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-render-inline t
  "When non-nil, recognize inline math `\\(...\\)' in agent responses.

Only effective when `agent-shell-math-renderer-mode' is on.
Inline math is
typeset in text style and overlaid in place,
so it sits within the surrounding line rather than on its own.

Unlike the block-level delimiters, `\\(...\\)' is matched anywhere
on a line (it is inline by nature), but its body may not cross a
line break — the closer must appear on the same line as the
opener, which bounds the match and keeps a stray `\\(' from
swallowing the rest of a streaming response.

Inline `$...$' is deliberately NOT recognized: a lone `$' is far
too common in prose, currency, and shell snippets to match safely.
Only the unambiguous `\\(...\\)' form is detected; `$...$' support
can be added later if agents prove to need it."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-center-display-math nil
  "Whether to center display-math equations in the window.

Display math is centered the way a LaTeX document centers it, rather
than starting where the surrounding chat text starts.  Inline math is
never centered: it belongs in the run of text.

This is a display-time indent, not part of the image: the equation
keeps its own size and any `agent-shell-math-renderer-padding-display'
box, and the line it sits on gets a `line-prefix' stretching to put the image's
center on the window's center.  Redisplay evaluates that stretch, so it
follows a window resize, a split or a font change on its own.
Setting it with `setq', `setq-local' or Customize updates the
equations on its own.

Centering replaces agent-shell's own indentation for that line, since
the position is measured from the window rather than from the
surrounding text.  An equation wider than the window simply stays where
it is: the stretch cannot pull it left."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-engine 'latex
  "Engine that typesets the equations: the symbol `latex', `ratex' or `texres'.

`latex' runs `latex' and `dvisvgm': full LaTeX, with any package the
backend's preamble loads.  `ratex' runs RaTeX's `render-svg': no TeX
installation, for the math KaTeX supports and no packages.  An
equation RaTeX cannot parse is typeset with LaTeX instead, or keeps its
source as text when `agent-shell-math-renderer-fallback' is nil.
`texres' runs the `pdflatex' of texres, then `pdftocairo': full LaTeX
with the LaTeX engine's preamble, from one program instead of a TeX
installation.  Where the programs are is set in the backend (see
`latex-to-svg-backend-latex-program',
`latex-to-svg-backend-ratex-program' and
`latex-to-svg-backend-texres-program').

Passed to `latex-to-svg-backend' as `:engine'.  Each engine has its
own cache entries, so switching back and forth does not recompile an
equation already compiled by both.  Setting it with `setq',
`setq-local' or Customize updates the equations on its own."
  :type '(choice (const :tag "LaTeX (latex + dvisvgm)" latex)
                 (const :tag "RaTeX (render-svg)" ratex)
                 (const :tag "texres (pdflatex + pdftocairo)" texres))
  :safe (lambda (v) (memq v '(latex ratex texres)))
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-fallback t
  "Whether LaTeX typesets an equation the chosen engine cannot.

When non-nil and `agent-shell-math-renderer-engine' is `ratex', a
formula that engine rejects, such as one using siunitx's `\\SI',
`\\DeclareMathOperator' or an environment RaTeX lacks, is typeset with
LaTeX instead: passed to `latex-to-svg-backend' as `:fallback'.  The
backend records the failure, so a later request goes straight to the
LaTeX picture in the cache.

Two consequences: a fallback equation is typeset in LaTeX's style
\(Computer Modern) next to RaTeX's (KaTeX's fonts), and it takes about
300 ms to compile instead of about 6 ms.  Hovering over an equation
shows which engine typeset it.  The fallback needs `latex'
and `dvisvgm'; without them the backend warns, and you either install
them or set this option to nil.  When nil, an equation the engine
rejects keeps its source as text.  Setting it with `setq', `setq-local' or
Customize updates the equations on its own."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defun agent-shell-math-renderer--fallback-for (engine)
  "Return the fallback engine for an equation typeset by ENGINE, or nil.
That is `latex' when `agent-shell-math-renderer-fallback' is on and
ENGINE is `ratex'.  `texres' has none: it typesets with LaTeX, so an
equation it rejects has a LaTeX error that `latex' rejects too."
  (and agent-shell-math-renderer-fallback
       (eq engine 'ratex)
       'latex))

(defcustom agent-shell-math-renderer-quiet nil
  "Whether the backend stays silent about an equation it cannot typeset.

When nil (the default), the backend warns once per equation per buffer
about an equation it cannot typeset, naming the buffer and linking to
the log.  When non-nil, it does not; the equation keeps its source as
text.  Passed to `latex-to-svg-backend' as `:quiet'.  Configuration
problems, such as missing programs, still warn.  Set it buffer-locally,
in a mode hook or in `.dir-locals.el', to silence one kind of chat."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-failure-mark t
  "Whether to mark an equation that no engine could typeset.

When non-nil (the default), the icon `agent-shell-math-renderer-failure'
is shown before the source of a failed equation, with the same tooltip
as the source: the engine, the error, and the command that opens the
log, `agent-shell-math-renderer-show-error-log'.  When nil, a failed
equation looks like an equation not typeset yet.  Change the icon with
`customize-icon'.  Setting the option with `setq', `setq-local' or
Customize updates the equations on its own."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(define-icon agent-shell-math-renderer-failure nil
  '((emoji "⚠️") (symbol "⚠") (text "[!]"))
  "Mark before an equation that no engine could typeset.
See `agent-shell-math-renderer-failure-mark'."
  :version "29.1")

(defvar agent-shell-math-renderer--obsolete-warned nil
  "The obsolete options already reported in this session.")

(defun agent-shell-math-renderer--warn-obsolete (option value)
  "Warn that OPTION is obsolete when VALUE is non-nil, once per session.
The warning says what `make-obsolete-variable' recorded for OPTION: the
version and what to set instead.  Emacs reports an obsolete variable
only when it compiles the code that sets it, which an init file seldom
is."
  (when (and value
             (not (memq option agent-shell-math-renderer--obsolete-warned)))
    (push option agent-shell-math-renderer--obsolete-warned)
    (pcase-let ((`(,current ,_ ,version) (get option 'byte-obsolete-variable)))
      (display-warning
       'agent-shell-math-renderer
       (format "`%s' is obsolete since %s; %s" option version
               (if (stringp current)
                   current
                 (format "use `%s' instead." current)))
       :warning))))

(defconst agent-shell-math-renderer--obsolete-aliases-set
  (seq-filter (lambda (alias)
                (or (boundp alias) (get alias 'saved-value)))
              '(agent-shell-math-renderer-inline-rescale
                agent-shell-math-renderer-display-rescale
                agent-shell-math-renderer-background-padding))
  "The obsolete aliases the user set before this file loaded.
An alias bound, or saved by Customize, before this file defines it was
set by the user's init file.  Once the alias exists, setting it cannot
be told from setting its option: both are one variable.")

;; Before the defcustoms on purpose, like the padding alias below:
;; `defvaralias' discards a value the obsolete name already holds.
(define-obsolete-variable-alias 'agent-shell-math-renderer-inline-rescale
  'agent-shell-math-renderer-rescale-inline "0.12.0")
(define-obsolete-variable-alias 'agent-shell-math-renderer-display-rescale
  'agent-shell-math-renderer-rescale-display "0.12.0")

(defcustom agent-shell-math-renderer-rescale-inline 1.0
  "Size multiplier for inline math previews (`\\(...\\)').
Applied on top of the backend's global `latex-to-svg-backend-font-scale' via
`latex-to-svg-backend's `:rescale-by'.  Re-scales from cache (no
recompile).  Setting it with `setq', `setq-local' or Customize updates the
equations on its own."
  :type 'number
  :safe #'numberp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-rescale-display 1.0
  "Size multiplier for display math previews.
Applies to `\\=\\[...\\]', `$$...$$', and fenced math blocks.
Applied on top of the backend's global `latex-to-svg-backend-font-scale' via
`latex-to-svg-backend's `:rescale-by' — e.g. set to 1.1 for display equations a
touch larger than inline.  Re-scales from cache (no recompile).
Setting it with `setq', `setq-local' or Customize updates the
equations on its own."
  :type 'number
  :safe #'numberp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-foreground-color nil
  "Color of equations in text drawn in the default foreground, or nil.

Each equation is tinted with the foreground of the text at its opening
delimiter, so an equation in a heading, a link or a block quote has the
color of that text.  When that text has no foreground of its own, or
the foreground of the `default' face, the equation is tinted with this
color instead, if it is non-nil: a `#rrggbb' string or any name
`color-values' understands (e.g. \"black\", \"#1a1a1a\").  Nil (the
default) leaves those equations in the foreground of the `default'
face, which tracks the theme.
Colors are read on the frame that shows the buffer, and a name that
frame cannot resolve, or a value that is not a string, is reported
with a warning and treated as nil.

Passed to `latex-to-svg-backend' as `:color', as a `#rrggbb' string;
it re-tints from cache (no recompile).  Setting it with `setq',
`setq-local' or Customize updates the equations on its own."
  :type '(choice (const :tag "Follow the default foreground" nil)
                 (color :tag "Color for default-colored text"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-foreground-ignored-faces nil
  "Faces whose foreground the color of an equation does not follow.
Each equation is tinted with the foreground of the text at its opening
delimiter (see `agent-shell-math-renderer-foreground-color').  A face
in this list is skipped when that foreground is read, and the next face
of the text that specifies a foreground is used.  When no face is left,
the equation is tinted with `agent-shell-math-renderer-foreground-color',
or the foreground of the `default' face.  A face that inherits from a
face in this list is not skipped.  The face `agent-shell-math-renderer',
which every equation carries, is always skipped.

With `agent-shell-markdown-header-1' (and the other levels) or
`agent-shell-markdown-link' in this list, an equation in a heading or a
link is drawn in the color of the text around it, not in the heading's
or the link's.  Setting it with `setq', `setq-local' or Customize
updates the equations on its own."
  :type '(repeat face)
  :safe (lambda (v) (and (listp v) (seq-every-p #'symbolp v)))
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-background-color nil
  "Box color painted behind equations, or nil for transparent.

When nil (the default) equations are transparent and blend into
the buffer.  Set to a color — a `#rrggbb' string or any name
`color-values' understands (e.g. \"gray97\", \"#f7f7f7\") — to
paint that color behind every equation.  A very light gray reads
best; keep it subtle so it doesn't fight the buffer background.  The
color is read on the frame that shows the buffer, and a name that
frame cannot resolve, or a value that is not a string, is reported
with a warning and treated as nil.

Passed to `latex-to-svg-backend' as `:background', as a `#rrggbb'
string; it applies from cache (no recompile).  Setting it with
`setq', `setq-local' or Customize updates the equations on its own."
  :type '(choice (const :tag "Transparent" nil)
                 (color :tag "Box color"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'agent-shell-math-renderer)

;; Before the defcustom on purpose: `defvaralias' discards a value the
;; obsolete name already holds, so a config that sets the old name before
;; this file loads would silently lose it if the alias came afterwards.
(define-obsolete-variable-alias 'agent-shell-math-renderer-background-padding
  'agent-shell-math-renderer-padding "0.10.0")
;; The option it names is obsolete too, so say what to set instead.
(make-obsolete-variable
 'agent-shell-math-renderer-background-padding
 "set `agent-shell-math-renderer-padding-inline' and \
`agent-shell-math-renderer-padding-display'."
 "0.10.0")

(defconst agent-shell-math-renderer--padding-type
  '(choice (const :tag "None" nil)
           (number :tag "All four sides (pt)")
           (list :tag "Per side (pt)"
                 (number :tag "Top   ")
                 (number :tag "Right ")
                 (number :tag "Bottom")
                 (number :tag "Left  ")))
  "Customize type of the padding options.")

(defun agent-shell-math-renderer--padding-p (value)
  "Non-nil when VALUE is a padding the backend accepts: nil, or 1-4 numbers.
The `:safe' predicate of the padding options.  A file-local value is
hand-written Lisp, so it accepts every shape the backend does, not just
the two Customize offers."
  (or (null value) (numberp value)
      (and (consp value) (<= 1 (length value) 4)
           (seq-every-p #'numberp value))))

(defcustom agent-shell-math-renderer-padding nil
  "Padding (in pt) added around every rendered equation.
Obsolete: set `agent-shell-math-renderer-padding-inline' and
`agent-shell-math-renderer-padding-display' instead.  A kind whose own
option is nil takes this value, so setting it still pads both kinds.
The values are the same as theirs."
  :type agent-shell-math-renderer--padding-type
  :safe #'agent-shell-math-renderer--padding-p
  :group 'agent-shell-math-renderer)
(make-obsolete-variable
 'agent-shell-math-renderer-padding
 "set `agent-shell-math-renderer-padding-inline' and \
`agent-shell-math-renderer-padding-display'."
 "0.12.0")

(defcustom agent-shell-math-renderer-padding-inline nil
  "Padding (in pt) added around inline math (`\\(...\\)').

Grows the box beyond the equation ink, so the ink is not flush
against the box edge, and scales with the equation.  Either a
number of pt (e.g. 3) applied to all four sides, or a list of four
numbers (TOP RIGHT BOTTOM LEFT) to pad each side separately -- so
a left gutter and nothing else is (0 0 0 6).  0 crops the box to
the ink.  nil takes the value of the obsolete
`agent-shell-math-renderer-padding', which crops too unless it is
set.  Set from Lisp, the shorter CSS forms the backend accepts work
too (one, two or three numbers: see `latex-to-svg-backend'), but
Customize offers only the number and the four-side list.

This mainly matters with
`agent-shell-math-renderer-background-color' set, since padding is
what separates the ink from the box edge.  Without a box color the
padding is transparent, so a symmetric value is invisible but an
asymmetric one still shifts the equation within its own image (a
left-only pad indents it).

Passed to `latex-to-svg-backend' as `:padding'; it applies from
cache (no recompile).  Setting it with `setq', `setq-local' or
Customize updates the equations on its own.  See
`agent-shell-math-renderer-padding-display' for display math."
  :type agent-shell-math-renderer--padding-type
  :safe #'agent-shell-math-renderer--padding-p
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-padding-display nil
  "Padding (in pt) added around display math.
Display math is `\\=\\[...\\]', `$$...$$' and fenced math blocks.  The
values are those of `agent-shell-math-renderer-padding-inline', which
pads inline math: a number for all four sides, a list (TOP RIGHT
BOTTOM LEFT), 0 to crop to the ink, or nil for the value of the
obsolete `agent-shell-math-renderer-padding'.  Applies from cache (no
recompile).  Setting it with `setq', `setq-local' or Customize updates
the equations on its own."
  :type agent-shell-math-renderer--padding-type
  :safe #'agent-shell-math-renderer--padding-p
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-render-submitted-prompts nil
  "When non-nil, render math in submitted user prompts.

This option has an effect only when
`agent-shell-math-renderer-mode' is also on.

The usual delimiter and inline settings apply: prompts render
`\\=\\[...\\]' / `$$...$$' according to
`agent-shell-math-renderer-delimiters', and inline `\\(...\\)'
according to `agent-shell-math-renderer-render-inline'.

This uses agent-shell's existing `input-submitted' event and
shell-maker/comint's `comint-last-input-start' /
`comint-last-input-end' markers to find the prompt that was just
submitted.  Rendering is deferred out of the submit command.

The prompts a restored session replays are rendered too, when
agent-shell emits `session-restored'."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defvar-local agent-shell-math-renderer--rendered-appearance nil
  "The appearance signature this buffer's equations were rendered for.
A list (FOREGROUND BACKGROUND X-HEIGHT) — see
`agent-shell-math-renderer--appearance'.  Buffer-local:
each buffer tracks its own last-rendered appearance, so a refresh
can re-render just the affected buffer and leave the others to
re-render lazily when they are next displayed (see
`agent-shell-math-renderer--refresh-if-changed').  Updated whenever
an equation renders.")

(defvar-local agent-shell-math-renderer--present nil
  "Non-nil in a buffer that has rendered display-math regions.
Lets `agent-shell-math-renderer-refresh' visit only relevant buffers.")

(defvar-local agent-shell-math-renderer--prompt-subscriptions nil
  "Subscription tokens for submitted-prompt rendering in this buffer.")

(defun agent-shell-math-renderer--delimiter-flush-p (start end)
  "Return non-nil if the delimiter spanning START..END is flush on its line.
Flush means it begins the line (only whitespace before it) or ends
the line (only whitespace after it) — the shape display-math
delimiters take in practice."
  (or (save-excursion (goto-char start) (skip-chars-backward " \t") (bolp))
      (save-excursion (goto-char end) (skip-chars-forward " \t") (eolp))))

(defun agent-shell-math-renderer--blocks (&optional avoid-ranges)
  "Return display-math blocks in the current buffer.

Each element is a plist (:start S :end E :open O :close C): S..E
spans the whole delimited block (delimiters included), and O / C
are the opening / closing delimiter token lengths, so the LaTeX
body is the buffer text in [S+O, E-C).

Only the delimiter styles listed in
`agent-shell-math-renderer-delimiters' are recognized (`$$...$$'
and/or `\\=\\[...\\]'), and only as BLOCK-LEVEL equations:

  - the opener must start its line (after optional indentation), and
  - the closer must be flush — start or end its line.

Genuinely inline display math is thus not matched; this keeps
prose / currency (`$$') from false-positiving.

Scanning resolves each opener immediately: from just after an
opener, look for the first of its matching flush closer or a blank
line (a paragraph break, which LaTeX display math can't contain).
A closer that is not flush is treated as body and the search
continues.

  - Flush closer first: a valid block, recorded; scanning resumes
    after the closer.
  - Blank line first (or no closer): the opener is a false
    positive, so scanning resumes just after the OPENER, so a real
    block on a later line is still found.
  - Neither yet (end of buffer): a still-streaming block extending
    to `point-max' with :close 0, so a genuine equation stays
    protected as the buffer grows — mirroring how `agent-shell' keeps a
    still-open fenced block protected as it streams.

A delimiter inside any of AVOID-RANGES (a sorted vector, typically
fenced code) is ignored — both openers and closers — so blocks
never overlap AVOID-RANGES.  Because openers are resolved one at a
time and bodies never cross a blank line, returned blocks never
overlap each other.

For example, with `bracket' enabled and buffer \"\\=\\[E=mc^2\\]\",
returns ((:start 1 :end 11 :open 2 :close 2))."
  (let* ((specs (seq-keep (lambda (style)
                            (map-elt agent-shell-math-renderer--delimiters style))
                          agent-shell-math-renderer-delimiters))
         (blocks '())
         (case-fold-search nil))
    (when specs
      (save-excursion
        (goto-char (point-min))
        ;; Opener anchored at line start (after optional indentation);
        ;; group 1 is the delimiter token itself.
        (let ((open-re (concat "^[ \t]*\\(" (regexp-opt (mapcar #'car specs))
                               "\\)")))
          (while (re-search-forward open-re nil t)
            (let* ((open-token (match-string-no-properties 1))
                   (open-start (match-beginning 1))
                   (open-end (match-end 1))
                   (avoid (agent-shell-markdown-in-avoid-range-p
                           open-start open-end avoid-ranges)))
              (if avoid
                  (goto-char (cdr avoid))
                (let* ((close-token (cdr (seq-find
                                          (lambda (spec)
                                            (string= open-token (car spec)))
                                          specs)))
                       ;; First flush closer or blank line after the body.
                       ;; A closer in an avoid-range (code) or not flush
                       ;; on its line is body — skip it and keep looking.
                       (hit (save-excursion
                              (goto-char open-end)
                              (let ((re (concat (regexp-quote close-token)
                                                "\\|\n[ \t]*\n"))
                                    (result nil))
                                (while (and (not result)
                                            (re-search-forward re nil t))
                                  (let ((mb (match-beginning 0))
                                        (me (match-end 0))
                                        (tok (match-string-no-properties 0)))
                                    (cond
                                     ((agent-shell-markdown-in-avoid-range-p
                                       mb me avoid-ranges)
                                      (goto-char
                                       (cdr (agent-shell-markdown-in-avoid-range-p
                                             mb me avoid-ranges))))
                                     ;; Blank line: paragraph-break terminator.
                                     ((string-match-p "\n" tok)
                                      (setq result (cons tok me)))
                                     ;; Flush closer: a real block end.
                                     ((agent-shell-math-renderer--delimiter-flush-p
                                       mb me)
                                      (setq result (cons tok me))))))
                                result))))
                  (cond
                   ;; Flush closer reached with no blank line before it.
                   ((and hit (string= (car hit) close-token))
                    (push (list :start open-start :end (cdr hit)
                                :open (length open-token)
                                :close (length close-token))
                          blocks)
                    (goto-char (cdr hit)))
                   ;; Blank line first: false-positive opener.  Resume
                   ;; right after the opener so a later real block is seen.
                   (hit (goto-char open-end))
                   ;; Neither yet: still-streaming open block.
                   (t (push (list :start open-start :end (point-max)
                                  :open (length open-token) :close 0)
                            blocks)
                      (goto-char (point-max)))))))))))
    (nreverse blocks)))

(defun agent-shell-math-renderer--block-ranges (&optional avoid-ranges)
  "Return list of (start . end) ranges covering display-math blocks.

Thin adapter over `agent-shell-math-renderer--blocks' for callers
that only need the protected spans (avoid-ranges, watermark
back-off).  AVOID-RANGES is forwarded.

For example, with `bracket' enabled and buffer \"\\=\\[E=mc^2\\]\",
returns ((1 . 11))."
  (mapcar (lambda (block)
            (cons (plist-get block :start) (plist-get block :end)))
          (agent-shell-math-renderer--blocks avoid-ranges)))

(defun agent-shell-math-renderer--re-search-unescaped-forward (regexp &optional bound)
  "Search forward for REGEXP before BOUND, skipping escaped matches.

A match preceded by an odd number of backslashes is escaped and is
skipped, the search resuming after it: `\\\\(' is a literal backslash
plus `(', not an inline-math opener.  An even count (including none)
is a real match.

Point and the match data are left as `re-search-forward' leaves them;
failure returns nil rather than signalling.

Escapes are still intact at this point.  We cannot rely on `agent-shell'
since it resolves them in `--encode-escapes', which only runs after the
render functions."
  (let (found)
    (while (and (not found) (re-search-forward regexp bound t))
      (setq found (zerop (% (save-excursion
                              (goto-char (match-beginning 0))
                              (- (point) (progn (skip-chars-backward "\\\\")
                                                (point))))
                            2))))
    found))

(defun agent-shell-math-renderer--inline-spans (&optional avoid-ranges)
  "Return inline-math spans `\\(...\\)' in the current buffer.

Each element is a plist (:start S :end E :open O :close C), with
the same shape as `agent-shell-math-renderer--blocks': S..E spans
the whole delimited span (delimiters included) and the LaTeX body
is the buffer text in [S+O, E-C).

Inline math is matched anywhere on a line, but only when the
closing `\\)' appears on the SAME line as the opening `\\(' — a
single-line bound that keeps a stray opener from swallowing the
buffer and means the renderer's start-of-last-line watermark
already covers the still-streaming case (no open-span bookkeeping
needed, unlike `agent-shell-math-renderer--blocks').

A delimiter inside any of AVOID-RANGES (a sorted vector, typically
fenced code, display math, or inline code) is ignored, and a
candidate whose body would overlap an avoid-range is rejected, so
returned spans never overlap AVOID-RANGES or each other.

An escaped delimiter is not a delimiter: `\\\\(' is a literal
backslash plus `(' and opens nothing, and a `\\\\)' inside a span is
body rather than its end (see
`agent-shell-math-renderer--re-search-unescaped-forward').

For example, with buffer \"see \\=\\(E=mc^2\\=\\) here\", returns
\((:start 5 :end 15 :open 2 :close 2))."
  (let ((spans '())
        (open agent-shell-math-renderer--inline-open)
        (close agent-shell-math-renderer--inline-close)
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (let ((open-re (regexp-quote open))
            (close-re (regexp-quote close)))
        (while (agent-shell-math-renderer--re-search-unescaped-forward
                open-re)
          (let* ((open-start (match-beginning 0))
                 (open-end (match-end 0))
                 (avoid (agent-shell-markdown-in-avoid-range-p
                         open-start open-end avoid-ranges)))
            (if avoid
                (goto-char (cdr avoid))
              ;; Look for the closer on this line only; skip a closer
              ;; that sits inside an avoid-range (it is protected text)
              ;; or is escaped.  Markdown escaping is applied uniformly,
              ;; so an escaped `\\)' stays body: it reaches LaTeX as
              ;; `\\\\)', a line break followed by a paren.
              (let ((eol (line-end-position))
                    (close-end nil))
                (save-excursion
                  (goto-char open-end)
                  (while (and (not close-end)
                              (agent-shell-math-renderer--re-search-unescaped-forward
                               close-re eol))
                    (let ((in (agent-shell-markdown-in-avoid-range-p
                               (match-beginning 0) (match-end 0) avoid-ranges)))
                      (if in
                          (goto-char (cdr in))
                        (setq close-end (match-end 0))))))
                (cond
                 ;; Clean closer on the line and nothing protected sits
                 ;; between the delimiters: a valid inline span.
                 ((and close-end
                       (not (seq-some
                             (lambda (range)
                               (and (< (car range) close-end)
                                    (> (cdr range) open-start)))
                             avoid-ranges)))
                  (push (list :start open-start :end close-end
                              :open (length open) :close (length close))
                        spans)
                  (goto-char close-end))
                 ;; No usable closer on the line (false positive, or the
                 ;; span is still streaming on the buffer's last line):
                 ;; resume just after the opener so a later real span is
                 ;; still found.  The start-of-last-line watermark re-scans
                 ;; an unclosed tail on the next chunk.
                 (t (goto-char open-end)))))))))
    (nreverse spans)))

(defun agent-shell-math-renderer--inline-ranges (&optional avoid-ranges)
  "Return list of (start . end) ranges covering inline-math spans.
Thin adapter over `agent-shell-math-renderer--inline-spans' for
callers that only need the protected spans.  AVOID-RANGES is
forwarded."
  (mapcar (lambda (span)
            (cons (plist-get span :start) (plist-get span :end)))
          (agent-shell-math-renderer--inline-spans avoid-ranges)))

(cl-defun agent-shell-math-renderer--style-inline (&key avoid-ranges)
  "Overlay inline-math spans `\\(...\\)' with a text-style equation image.

Mirrors `agent-shell-math-renderer--style-blocks' but for inline
`\\(...\\)' spans (see `agent-shell-math-renderer--inline-spans'):
the raw delimited text is kept and the region handed to
`agent-shell-math-renderer--apply-region' with INLINE non-nil, so
it is typeset in text style.  Spans inside AVOID-RANGES, or with an
empty body, are left untouched.

A span that lands on already-`agent-shell-markdown-frozen' text is
also skipped.  AVOID-RANGES alone can't catch this: an earlier
pass (notably inline code) may have rewritten its region in the
same call, collapsing the range markers we were handed — the live
`frozen' property is the reliable signal, so a backticked
`\\(x\\)' stays literal code."
  (dolist (span (agent-shell-math-renderer--inline-spans avoid-ranges))
    (when-let* ((start (plist-get span :start))
                ((not (get-text-property start 'agent-shell-markdown-frozen)))
                (end (plist-get span :end))
                (latex (string-trim
                        (buffer-substring-no-properties
                         (+ start (plist-get span :open))
                         (- end (plist-get span :close)))))
                ((not (string-empty-p latex))))
      (agent-shell-math-renderer--apply-region
       (current-buffer) start end latex t))))

(cl-defun agent-shell-math-renderer--style-blocks (&key avoid-ranges)
  "Overlay display-math blocks with an equation image.

Recognizes the delimiter styles in
`agent-shell-math-renderer-delimiters' (`$$...$$' and/or
`\\=\\[...\\]').  For each complete block with a non-empty body, the
raw delimited text is left in the buffer (so copy / save
round-trips the LaTeX source) and the region is faced with
`agent-shell-math-renderer' and tagged
`agent-shell-markdown-frozen' so later passes and subsequent
streaming calls leave it alone.  The equation image is then
applied by `agent-shell-math-renderer--render' (immediately when
cached, otherwise once an async compile finishes).  Blocks inside
any of AVOID-RANGES (typically fenced code) are left untouched, as
is an empty block.

Adds only text properties (no insert / delete), so the block
positions returned by `agent-shell-math-renderer--blocks' stay
valid while iterating.

For example, with the buffer:

  \\=\\[E=mc^2\\]

the `\\=\\[E=mc^2\\]' text is kept but shows an equation image in its
place, faced `agent-shell-math-renderer' and frozen."
  (dolist (block (agent-shell-math-renderer--blocks avoid-ranges))
    ;; A still-open block (no closing delimiter yet) reports :close 0
    ;; and runs to `point-max'; leave it raw until the closer streams in.
    (when-let* ((close (plist-get block :close))
                ((> close 0))
                (start (plist-get block :start))
                (end (plist-get block :end))
                (latex (string-trim
                        (buffer-substring-no-properties
                         (+ start (plist-get block :open))
                         (- end close))))
                ((not (string-empty-p latex))))
      (agent-shell-math-renderer--apply-region (current-buffer) start end latex))))

(defun agent-shell-math-renderer--fence-language-p (lang)
  "Return non-nil if fenced-block language LANG renders as display math.
Compares LANG case-insensitively against
`agent-shell-math-renderer-fence-languages'.  LANG may be nil or
empty (a fence with no info string), which is not a math language."
  (and lang
       (not (string-empty-p lang))
       (member (downcase lang) agent-shell-math-renderer-fence-languages)
       t))

(defun agent-shell-math-renderer--help-echo-text (latex)
  "Return LATEX quoted so that `help-echo' shows it as written.
Emacs passes a `help-echo' string through `substitute-command-keys'
before showing it, which reads `\\=\\[' as the start of a key reference,
`\\=\\{' as a keymap, and turns quotes into curved ones: `\\=\\[x=1\\=\\]'
would show as the key binding of a command named \"x=1\\\".  A `\\=\\='
before each backslash, backquote and apostrophe makes
`substitute-command-keys' copy it literally."
  (replace-regexp-in-string "[\\`']" "\\\\=\\&" latex))

(defun agent-shell-math-renderer--engine-name (engine)
  "Return the name of ENGINE to show a user: \"LaTeX\", \"RaTeX\" or \"texres\"."
  (pcase engine
    ('ratex "RaTeX")
    ('texres "texres")
    (_ "LaTeX")))

(defun agent-shell-math-renderer--help-echo (doc latex engine fallback)
  "Return the `help-echo' of an equation LATEX, sent to the backend as DOC.
It names the engine that typeset the picture, then shows LATEX:
\"Typeset with RaTeX: LATEX\".  ENGINE and FALLBACK are the ones DOC
was sent with; when the picture came from FALLBACK, because ENGINE
could not typeset DOC (see `latex-to-svg-backend-engine-used'), it
says so: \"Typeset with LaTeX (RaTeX could not parse it): LATEX\"."
  (let* ((engine (or engine 'latex))
         (used (or (latex-to-svg-backend-engine-used doc engine fallback)
                   engine)))
    (concat (if (eq used engine)
                (format "Typeset with %s"
                        (agent-shell-math-renderer--engine-name used))
              (format "Typeset with %s (%s could not parse it)"
                      (agent-shell-math-renderer--engine-name used)
                      (agent-shell-math-renderer--engine-name engine)))
            ": "
            (agent-shell-math-renderer--help-echo-text latex))))

(defun agent-shell-math-renderer--failure-help-echo (failure &optional tooltip)
  "Return the `help-echo' of an equation whose request ended in FAILURE.
FAILURE is the plist the backend passes to the callback (see
`latex-to-svg-backend').  For a `formula' failure it names the engine
and gives the message: \"LaTeX could not typeset it: MESSAGE.\", or
\"RaTeX could not parse it: MESSAGE.\".  For a `setup' failure it gives
the message, which names the program that was not found or says that
the preamble could not be precompiled.  The text
ends with a full stop, unless it already ends with `.', `!' or `?'.
With TOOLTIP, when FAILURE has a log, a sentence follows on the same
line, so that a tooltip shown on one line reads well: \"Call
\\[agent-shell-math-renderer-show-error-log] with point in the equation
to open the log.\"  The log file is not named."
  (let* ((engine (plist-get failure :engine))
         (message (plist-get failure :message))
         (text (if (eq (plist-get failure :kind) 'setup)
                   (or message
                       (format "%s could not run `%s'"
                               (agent-shell-math-renderer--engine-name engine)
                               (plist-get failure :program)))
                 (concat (format "%s could not %s it"
                                 (agent-shell-math-renderer--engine-name engine)
                                 (if (eq engine 'ratex) "parse" "typeset"))
                         (and message (concat ": " message))))))
    (concat (agent-shell-math-renderer--help-echo-text
             (if (string-match-p "[.!?]\\'" text) text (concat text ".")))
            (and tooltip (plist-get failure :log)
                 " Call \\[agent-shell-math-renderer-show-error-log] with \
point in the equation to open the log."))))

(defun agent-shell-math-renderer--show-failure (buffer start end failure)
  "Record FAILURE on BUFFER's equation START..END and mark it.
FAILURE is the plist the backend passed to the callback.  It is stored
in the `agent-shell-math-renderer-failure' text property and shown as
the `help-echo' (see `agent-shell-math-renderer--failure-help-echo').
With `agent-shell-math-renderer-failure-mark' on, an overlay over the
equation shows the icon `agent-shell-math-renderer-failure' as its
`before-string', with the same tooltip; an overlay, so that copying the
equation does not copy the icon.  START / END may be markers.  Nothing
is done when BUFFER is dead or the region no longer holds an equation."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((s (if (markerp start) (marker-position start) start))
            (e (if (markerp end) (marker-position end) end))
            (help-echo (agent-shell-math-renderer--failure-help-echo
                        failure t)))
        (when-let* (((and s e (<= (point-min) s) (< s e) (<= e (point-max))))
                    (latex (get-text-property
                            s 'agent-shell-math-renderer-source)))
          (agent-shell-math-renderer--clear-failure s e latex)
          (with-silent-modifications
            (put-text-property s e 'agent-shell-math-renderer-failure failure)
            (put-text-property s e 'help-echo help-echo))
          (when agent-shell-math-renderer-failure-mark
            (let ((ov (make-overlay s e)))
              (overlay-put ov 'agent-shell-math-renderer-failure t)
              (overlay-put ov 'evaporate t)
              (overlay-put ov 'before-string
                           (concat (propertize
                                    (icon-string
                                     'agent-shell-math-renderer-failure)
                                    'help-echo help-echo)
                                   " ")))))))))

(defun agent-shell-math-renderer--clear-failure (start end latex)
  "Remove the failure of the equation LATEX at START..END, if it has one.
Deletes the failure mark, removes the `agent-shell-math-renderer-failure'
text property, and gives the region back the `help-echo' of its source.
Runs in the equation's buffer, before each render."
  (when (get-text-property start 'agent-shell-math-renderer-failure)
    (with-silent-modifications
      (remove-text-properties start end '(agent-shell-math-renderer-failure nil))
      (put-text-property start end 'help-echo
                         (agent-shell-math-renderer--help-echo-text latex))))
  (dolist (ov (overlays-in start end))
    (when (overlay-get ov 'agent-shell-math-renderer-failure)
      (delete-overlay ov))))

(defun agent-shell-math-renderer-show-error-log ()
  "Open the log of the equation at point that no engine could typeset.
When the failure has no log (a RaTeX parse error, or a program that
could not run) or the log file is gone, show the error in the echo
area instead."
  (interactive)
  (let* ((failure (get-text-property (point) 'agent-shell-math-renderer-failure))
         (log (plist-get failure :log)))
    (cond
     ((null failure) (user-error "No equation here failed to typeset"))
     ((and log (file-exists-p log)) (find-file-other-window log))
     (t (message "%s" (substitute-command-keys
                       (agent-shell-math-renderer--failure-help-echo
                        failure)))))))

(defun agent-shell-math-renderer--apply-region (buffer start end latex &optional inline)
  "Mark BUFFER's START..END as math with source LATEX and render it.

Keeps the underlying text in place, faces the region
`agent-shell-math-renderer', tags it `agent-shell-markdown-frozen'
\(so later passes / streaming calls skip it) with LATEX stashed in
`agent-shell-math-renderer-source', then hands off to
`agent-shell-math-renderer--render' for the equation image.

INLINE non-nil typesets LATEX in text style (for `\\(...\\)'
inline math) rather than as a display equation; it is stashed in
`agent-shell-math-renderer-inline' so a later refresh re-renders in
the same style.  The region is not rendered now but tagged
`agent-shell-math-renderer--deferred' and rendered from a timer (see
`agent-shell-math-renderer--render-deferred'): the faces of the text
around it, such as a heading's or a link's, which its color and size
follow, are put on by agent-shell's passes after this hook returns.

Shared by the delimiter pass (`agent-shell-math-renderer--style-blocks'),
the inline pass (`agent-shell-math-renderer--style-inline'), and the
fenced-block path in `agent-shell-math-renderer--render-hook' (for ```math
fences, per `agent-shell-math-renderer-fence-languages').  Every caller
leaves the buffer text untouched: the fenced path passes START..END over
the whole backtick-fenced block and LATEX over its body, so what is
frozen is always the agent\'s own markdown and what is typeset is always
the bare equation."
  (with-current-buffer buffer
    (setq agent-shell-math-renderer--present t)
    (add-face-text-property start end 'agent-shell-math-renderer)
    (add-text-properties
     start end
     `(help-echo ,(agent-shell-math-renderer--help-echo-text latex)
                 agent-shell-math-renderer-source ,latex
                 agent-shell-math-renderer-inline ,inline
                 agent-shell-markdown-frozen t
                 rear-nonsticky (agent-shell-markdown-frozen)))
    (put-text-property start end 'agent-shell-math-renderer--deferred t)
    (agent-shell-math-renderer--schedule-deferred buffer)))

(defvar-local agent-shell-math-renderer--deferred-timer nil
  "Timer of a pending `agent-shell-math-renderer--render-deferred'.")

(defun agent-shell-math-renderer--schedule-deferred (buffer)
  "Render BUFFER's deferred equations from a timer, once.
Several regions tagged in one render, or in several before the timer
runs, are rendered by the same run."
  (with-current-buffer buffer
    (unless agent-shell-math-renderer--deferred-timer
      (setq agent-shell-math-renderer--deferred-timer
            (run-at-time 0 nil #'agent-shell-math-renderer--render-deferred
                         buffer)))))

(defun agent-shell-math-renderer--render-deferred (buffer)
  "Render each region of BUFFER tagged `agent-shell-math-renderer--deferred'.
Runs after agent-shell's markdown passes, so the faces of the text at
each equation's opening delimiter are the ones it ends with, and the
region is where those passes left it: a heading or a link pass deletes
and reinserts its text, and the tag rides along with it.  Each region
ends where its `agent-shell-math-renderer-source' does, so two adjacent
equations stay two."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-shell-math-renderer--deferred-timer nil)
      (save-restriction
        (widen)
        (let ((pos (point-min)))
          (while (setq pos (text-property-not-all
                            pos (point-max)
                            'agent-shell-math-renderer--deferred nil))
            (let ((end (next-single-property-change
                        pos 'agent-shell-math-renderer-source nil (point-max)))
                  (latex (get-text-property
                          pos 'agent-shell-math-renderer-source))
                  (inline (get-text-property
                           pos 'agent-shell-math-renderer-inline)))
              (with-silent-modifications
                (remove-text-properties
                 pos end '(agent-shell-math-renderer--deferred nil)))
              (when latex
                (agent-shell-math-renderer--render
                 buffer pos end latex inline))
              (setq pos end))))))))

(defun agent-shell-math-renderer--overlay-image (buffer start end image
                                                        &optional inline
                                                        help-echo)
  "Lay IMAGE over BUFFER's START..END as a `display' property.

START / END may be markers (async case) or integers (sync case).
No-ops when BUFFER is dead or the region is no longer valid (it
was edited or killed away).  Runs with `with-silent-modifications'
so an async overlay doesn't flag the buffer modified, and carries
the region's existing `line-prefix' / `wrap-prefix' so indentation
is preserved.

With `agent-shell-math-renderer-center-display-math' on and INLINE
nil, the `line-prefix' instead becomes a stretch reaching the window
center less half the image, which centers the equation -- see that
option.  Nothing measures IMAGE: the stretch names it and redisplay
sizes it (`image-size' on an SVG is not reliable, see
`latex-to-svg-backend').

HELP-ECHO, when non-nil, replaces the region's `help-echo': the
tooltip can name the engine only once the image exists (see
`agent-shell-math-renderer--help-echo')."
  (when (and image (buffer-live-p buffer))
    (with-current-buffer buffer
      (let ((s (if (markerp start) (marker-position start) start))
            (e (if (markerp end) (marker-position end) end)))
        (when (and s e (<= (point-min) s) (< s e) (<= e (point-max)))
          (with-silent-modifications
            (let ((line-prefix (get-text-property s 'line-prefix))
                  (wrap-prefix (get-text-property s 'wrap-prefix))
                  (center (and agent-shell-math-renderer-center-display-math
                               (not inline)
                               `(space :align-to
                                       (- center (0.5 . ,image))))))
              (put-text-property s e 'display image)
              (put-text-property s e 'mouse-face 'highlight)
              (when help-echo
                (put-text-property s e 'help-echo help-echo))
              ;; Centering measures from the window, so it replaces the
              ;; surrounding indentation rather than adding to it.
              (cond (center (put-text-property s e 'line-prefix center))
                    (line-prefix
                     (put-text-property s e 'line-prefix line-prefix)))
              (when wrap-prefix
                (put-text-property s e 'wrap-prefix wrap-prefix)))))))))

;; Defined only in an Emacs built with a window system; it is called only
;; while a graphical window shows the buffer.
(declare-function font-info "font.c" (name &optional frame))

(defvar-local agent-shell-math-renderer--font-warned nil
  "Non-nil once an unmeasurable buffer font has been reported in this buffer.")

(defun agent-shell-math-renderer--x-height-ratio (name frame)
  "Return the x-height of the font NAME on FRAME as a fraction of its size.
That is the ascent of its glyph for `x' divided by its pixel size,
read with the font opened at 1000 pixels: `font-get-glyphs' gives
whole pixels, which at a text size of 18 pixels is off by up to 5%.
Emacs keeps a font it has opened, so a repeat costs about a
microsecond.  Nil when FRAME finds no font NAME, or the font has no
glyph for `x', as a symbol font has none."
  (when-let* ((entity (find-font (font-spec :name name) frame))
              (font (open-font entity 1000 frame))
              (glyph (aref (font-get-glyphs font 0 1 "x") 0)))
    (/ (aref glyph 7) 1000.0)))

(defun agent-shell-math-renderer--x-height (&optional buffer)
  "Return the x-height of BUFFER's default font in a graphical frame, or nil.
That is the height of the lowercase `x' of the font of the `default'
face, in pixels: its pixel size, slot 2 of `font-info' of `face-font',
times its ratio (`agent-shell-math-renderer--x-height-ratio').
`face-font' follows the buffer's face remapping, so `text-scale-mode'
applies.

Measured against the frame that actually displays BUFFER, so the size
is right even when the selected frame is a TTY/daemon frame (an async
compile callback firing while a terminal frame is current).  Uses
`with-selected-frame' (a temporary, non-raising, non-focus-stealing
selection), so it never makes a parked child frame appear.  Returns
nil when BUFFER is shown in no graphical window, in which case the
backend compiles the equation but sizes nothing, and the display hook
draws it once a graphical window shows BUFFER.

A font the frame cannot open, or one with no glyph for `x', yields nil
as well, but is reported once per buffer rather than passed over."
  (let ((buffer (or buffer (current-buffer))))
    (when-let* ((frame (agent-shell-math-renderer--display-frame buffer)))
      (with-selected-frame frame
        (with-current-buffer buffer
          (let* ((font (face-font 'default))
                 (info (and font (font-info font)))
                 (ratio (and info (agent-shell-math-renderer--x-height-ratio
                                   font frame))))
            (if ratio
                (* (aref info 2) ratio)
              (unless agent-shell-math-renderer--font-warned
                (setq agent-shell-math-renderer--font-warned t)
                (display-warning
                 'agent-shell-math-renderer
                 (format "Cannot measure the x-height of the buffer font: %S"
                         font)
                 :warning))
              nil)))))))

(defun agent-shell-math-renderer--x-height-at (pos &optional buffer)
  "Return the x-height of the font of the text at POS in BUFFER, or nil.
That is the height of the lowercase `x' of the font Emacs uses at POS,
the opening delimiter of an equation, in a window showing BUFFER (see
`agent-shell-math-renderer--display-window'), in pixels: its pixel
size, slot 2 of `query-font', times its ratio
\(`agent-shell-math-renderer--x-height-ratio').  The faces at POS and
their `:height' apply, and so does `text-scale-mode'; so would a
`:height' on the face `agent-shell-math-renderer', which sets none.
When POS is outside the accessible part of BUFFER, no font is found
at POS, or the font has no glyph for `x', it is
`agent-shell-math-renderer--x-height', which is nil when BUFFER is
shown in no graphical window.  It mirrors the latex-to-svg front-end's
function of the same name."
  (let ((buffer (or buffer (current-buffer))))
    (or (when-let* ((win (agent-shell-math-renderer--display-window buffer)))
          (with-selected-frame (window-frame win)
            (with-current-buffer buffer
              (when-let* ((font (and (<= (point-min) pos) (< pos (point-max))
                                     (font-at pos win)))
                          (info (query-font font))
                          (ratio (agent-shell-math-renderer--x-height-ratio
                                  (aref info 0) (window-frame win))))
                (* (aref info 2) ratio)))))
        (agent-shell-math-renderer--x-height buffer))))

(defun agent-shell-math-renderer--display-window (buffer)
  "Return a window showing BUFFER on a graphical frame, or nil.
Equations are measured and tinted against its frame (see
`agent-shell-math-renderer--x-height')."
  (when-let* ((win (get-buffer-window buffer t))
              ((display-graphic-p (window-frame win))))
    win))

(defun agent-shell-math-renderer--display-frame (buffer)
  "Return the graphical frame of a window showing BUFFER, or nil.
See `agent-shell-math-renderer--display-window'."
  (when-let* ((win (agent-shell-math-renderer--display-window buffer)))
    (window-frame win)))

(defun agent-shell-math-renderer--graphical-p ()
  "Return non-nil if some live frame is graphical.
That is whether an equation image can be displayed in this session,
now or once a window shows its buffer.  It reads no frame's font or
colors, and selects none (see `agent-shell-math-renderer--display-frame'
for the frame equations are measured and tinted against)."
  (seq-some #'display-graphic-p (frame-list)))

(defun agent-shell-math-renderer--hex-color (color frame)
  "Return COLOR as a `#rrggbb' string, resolved on FRAME, or nil.
A `#rrggbb' string is returned as it is.  Other colors are read with
`color-values', whose 16-bit components are rounded to 8 bits.  Nil
when COLOR is nil or FRAME cannot resolve it."
  (cond ((null color) nil)
        ((string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color) color)
        ((when-let* ((values (color-values color frame)))
           (apply #'format "#%02x%02x%02x"
                  (mapcar (lambda (v) (round (* v 255) 65535)) values))))))

(defun agent-shell-math-renderer--option-color (option frame)
  "Return the color in OPTION as a `#rrggbb' string resolved on FRAME, or nil.
Nil when OPTION is nil.  A value FRAME cannot resolve, or one that is
not a string, is nil too, with no warning: this runs for every
equation drawn.  `agent-shell-math-renderer--check-options' reports
such a value when the mode turns on."
  (when-let* ((color (symbol-value option)))
    (and (stringp color)
         (agent-shell-math-renderer--hex-color color frame))))

(defun agent-shell-math-renderer--check-options ()
  "Warn about each color option whose value is not a color.
Run when the mode turns on, and in each buffer updated after a watched
option changed (see `agent-shell-math-renderer--update-after-option').
The options are `agent-shell-math-renderer-foreground-color' and
`agent-shell-math-renderer-background-color'; a value that is not a
string, or that a graphical frame cannot resolve, is ignored when
equations are drawn (see `agent-shell-math-renderer--option-color').  A
color resolves on a frame, so the check uses the frame that shows the
buffer, else any graphical frame; with none, as in a daemon that has
opened no graphical frame yet, it checks nothing."
  (when-let* ((frame (or (agent-shell-math-renderer--display-frame
                          (current-buffer))
                         (seq-find #'display-graphic-p (frame-list)))))
    (dolist (option '(agent-shell-math-renderer-foreground-color
                      agent-shell-math-renderer-background-color))
      (when-let* ((color (symbol-value option))
                  ((not (agent-shell-math-renderer--option-color
                         option frame))))
        (display-warning
         'agent-shell-math-renderer
         (format "%s: `%s' is %S, which is not a color; ignoring it"
                 (buffer-name) option color)
         :warning)))))

(defun agent-shell-math-renderer--text-foreground (pos &optional frame)
  "Return the foreground the faces of the text at POS give it, or nil.
Follows `foreground-color-at-point' (see `faces--attribute-at-point'),
with five differences.  It reads text properties only, not overlays.
It reads the faces on FRAME (nil: the selected frame).  It skips the
face `agent-shell-math-renderer', which this package puts on every
equation, so the face of the text around the equation decides.  It
skips the faces in
`agent-shell-math-renderer-foreground-ignored-faces'.  When
no other face at POS specifies a foreground, it returns nil, not the
foreground of the `default' face.

The faces are the `font-lock-face' property when `font-lock-mode' is
on and the text has one, else the `face' property: a face, a list of
faces (the first that specifies a foreground wins), or an anonymous
face such as (:foreground \"gold\") or (foreground-color . \"gold\").

It is a copy of the latex-to-svg front-end's function of the same
name, but for the face `agent-shell-math-renderer';
`scripts/emacs-faces-check.el' watches the two Emacs functions it
follows."
  (let ((faces (or (and font-lock-mode
                        (get-text-property pos 'font-lock-face))
                   (get-text-property pos 'face)))
        (found nil))
    (dolist (face (if (face-list-p faces) faces (list faces)))
      (cond (found)
            ((eq face 'agent-shell-math-renderer))
            ((memq face agent-shell-math-renderer-foreground-ignored-faces))
            ((and face (symbolp face))
             (let ((value (face-attribute-specified-or
                           (face-attribute face :foreground frame t)
                           nil)))
               (unless (member value '(nil "unspecified-fg" "unspecified-bg"))
                 (setq found value))))
            ((consp face)
             (setq found (cond ((memq 'foreground-color face)
                                (cdr (memq 'foreground-color face)))
                               ((memq :foreground face)
                                (cadr (memq :foreground face))))))))
    found))

(defun agent-shell-math-renderer--default-foreground-p (color &optional frame)
  "Return non-nil if COLOR is the foreground of the `default' face on FRAME.
Colors compare by value, so \"white\" and \"#ffffff\" are the same.  A
color without values, such as \"unspecified-fg\" on a terminal, is
never the default."
  (let ((rgb (color-values color frame)))
    (and rgb
         (equal rgb (color-values (face-foreground 'default frame t) frame)))))

(defun agent-shell-math-renderer--foreground-for (pos frame)
  "Return the `#rrggbb' color to tint the equation that opens at POS with.
That is the foreground of the text at POS, the opening delimiter of the
equation (see `agent-shell-math-renderer--text-foreground'), read on
FRAME.  When the text has no foreground of its own, or the foreground
of the `default' face, it is `agent-shell-math-renderer-foreground-color',
and when that is nil, the foreground of the `default' face on FRAME.
Each is resolved on FRAME (see `agent-shell-math-renderer--hex-color').
Nil only when FRAME is nil: the buffer is shown in no graphical window."
  (when frame
    (let ((text (agent-shell-math-renderer--text-foreground pos frame)))
      (or (and text
               (not (agent-shell-math-renderer--default-foreground-p
                     text frame))
               (agent-shell-math-renderer--hex-color text frame))
          (agent-shell-math-renderer--option-color
           'agent-shell-math-renderer-foreground-color frame)
          (agent-shell-math-renderer--hex-color
           (face-foreground 'default frame t) frame)))))

(defun agent-shell-math-renderer--background-for (frame)
  "Return the `#rrggbb' color of the box behind each equation, or nil.
That is `agent-shell-math-renderer-background-color', resolved on
FRAME.  Nil, a transparent box, when the option is nil or FRAME is nil."
  (and frame
       (agent-shell-math-renderer--option-color
        'agent-shell-math-renderer-background-color frame)))

(defun agent-shell-math-renderer--appearance (&optional buffer)
  "Return the appearance signature of BUFFER's equations (default current).
A list (FOREGROUND BACKGROUND X-HEIGHT): the foreground and the
background of the `default' face on the frame that shows BUFFER (see
`agent-shell-math-renderer--display-frame'), and
`agent-shell-math-renderer--x-height'.  All three are nil when
BUFFER is shown in no graphical window."
  (let* ((buffer (or buffer (current-buffer)))
         (frame (agent-shell-math-renderer--display-frame buffer)))
    (list (and frame (face-foreground 'default frame t))
          (and frame (face-background 'default frame t))
          (agent-shell-math-renderer--x-height buffer))))

(defun agent-shell-math-renderer--wrap (latex &optional inline)
  "Return LATEX wrapped as the string sent to the backend.
That is `$LATEX$' when INLINE is non-nil, `\\=\\[ LATEX \\=\\]' otherwise.  The
backend's cache key is a hash of this exact string, so
`agent-shell-math-renderer--render' and a recompile by
`agent-shell-math-renderer-refresh' both build it here."
  (if inline
      (format "$%s$" latex)
    (format "\\[ %s \\]" latex)))

(defun agent-shell-math-renderer--padding-for (inline)
  "Return the `:padding' for an INLINE (else display) equation.
That is `agent-shell-math-renderer-padding-inline' or
`agent-shell-math-renderer-padding-display', or, when it is nil, the
obsolete `agent-shell-math-renderer-padding'."
  (or (if inline
          agent-shell-math-renderer-padding-inline
        agent-shell-math-renderer-padding-display)
      (with-suppressed-warnings ((obsolete agent-shell-math-renderer-padding))
        agent-shell-math-renderer-padding)))

(defun agent-shell-math-renderer--render (buffer start end latex &optional inline)
  "Render LATEX over BUFFER's START..END as an equation image.

Delegates typesetting to `latex-to-svg-backend': overlays the image
immediately when available (cached SVG), else
captures START / END as markers and overlays the result once the
async compile finishes (so the overlay lands even after more output
streams in).  When this Emacs cannot display SVG images (see
`latex-to-svg-backend-available-p'), the backend warns once per
session and returns no image, and the raw faced text stays.  When no
frame is graphical (`agent-shell-math-renderer--graphical-p'), it does
nothing and clears the appearance signature, so the display hook
renders the equation once a graphical window shows BUFFER.

LATEX is the equation body with delimiters stripped; INLINE non-nil
typesets it in text style, otherwise display style.  Since
`latex-to-svg-backend' renders its argument *verbatim*, we wrap the body
into valid body LaTeX (`$body$' inline, `\\=\\[ body \\]' display, see
`agent-shell-math-renderer--wrap') and pass that; the delimiters also
choose inline vs display style, for either engine.  The engine is
`agent-shell-math-renderer-engine' (via `:engine'), and its fallback is
`agent-shell-math-renderer-fallback' (via `:fallback', see
`agent-shell-math-renderer--fallback-for'), and
`agent-shell-math-renderer-quiet' is passed as `:quiet'; all three are
read when the render is scheduled, so the callback of an async compile
uses the values that compile ran with.  Color and size
are not baked in —
`latex-to-svg-backend' tints the color-independent SVG and scales it
to the buffer font at display time, the latter by
`agent-shell-math-renderer-rescale-inline' / `-rescale-display' (via
`:rescale-by') for INLINE / display math.  The tint and the box color
are read on the frame that shows BUFFER
\(`agent-shell-math-renderer--foreground-for' /
`agent-shell-math-renderer--background-for', via `:color' /
`:background'), and so is the x-height of the font (via
`:x-height'), so neither depends on which frame is selected.  The
equation takes the color and the x-height of the text at START, its
opening delimiter, so one in a heading or a link looks like that text
\(`agent-shell-math-renderer--x-height-at').  The padding is
`agent-shell-math-renderer--padding-for' (via `:padding').  When
BUFFER is shown in no graphical window, all three are nil: the backend
compiles the SVG and returns no image, and the display hook re-renders
once the buffer is shown, from the cache.  The callback of an
async compile reads all three again, on the frame that shows BUFFER
then.  When the request ends without a picture, the callback leaves
the source as it is and marks it (see
`agent-shell-math-renderer--show-failure'); each render first removes
the mark of the previous one."
  (let ((frame (agent-shell-math-renderer--display-frame buffer)))
    (cond
     ((not (agent-shell-math-renderer--graphical-p))
      ;; Clear the signature, so the display hook renders the buffer when a
      ;; graphical window shows it, even when the buffer was rendered there
      ;; before and nothing else changed.
      (with-current-buffer buffer
        (setq agent-shell-math-renderer--rendered-appearance nil)))
     (t
      (agent-shell-math-renderer--clear-failure start end latex)
      (let* ((x-height (agent-shell-math-renderer--x-height-at start buffer))
             (doc (agent-shell-math-renderer--wrap latex inline))
             (engine agent-shell-math-renderer-engine)
             (fallback (agent-shell-math-renderer--fallback-for engine))
             (quiet agent-shell-math-renderer-quiet)
             (rescale (if inline
                          agent-shell-math-renderer-rescale-inline
                        agent-shell-math-renderer-rescale-display))
             (color (agent-shell-math-renderer--foreground-for start frame))
             (background (agent-shell-math-renderer--background-for frame))
             (padding (agent-shell-math-renderer--padding-for inline))
             (image (latex-to-svg-backend doc :engine engine :fallback fallback
                                          :quiet quiet :rescale-by rescale
                                          :color color :background background
                                          :padding padding
                                          :x-height x-height)))
        ;; Record the appearance (colors + x-height) this render is for,
        ;; so a later theme / frame / font change can detect the difference
        ;; and re-render (a color change re-tints; it no longer recompiles).
        (setq agent-shell-math-renderer--rendered-appearance
              (agent-shell-math-renderer--appearance buffer))
        (if image
            (agent-shell-math-renderer--overlay-image
             buffer start end image inline
             (agent-shell-math-renderer--help-echo doc latex engine fallback))
          ;; Not ready yet: schedule and overlay when the SVG lands.  Capture
          ;; the region as markers so it survives further streaming output.
          (let ((s (copy-marker start))
                (e (copy-marker end)))
            (latex-to-svg-backend
             doc
             :engine engine :fallback fallback :quiet quiet
             :rescale-by rescale :color color
             :background background :padding padding :x-height x-height
             :callback
             (lambda (outcome)
               (if outcome
                   (agent-shell-math-renderer--show-failure buffer s e outcome)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     ;; Read again: the buffer may be displayed now even if it
                     ;; was not when the compile was scheduled, or on another
                     ;; frame.
                     (let ((frame (agent-shell-math-renderer--display-frame
                                   buffer)))
                       (agent-shell-math-renderer--overlay-image
                        buffer s e
                        (latex-to-svg-backend
                         doc :engine engine :fallback fallback :quiet quiet
                         :rescale-by rescale
                         :color (agent-shell-math-renderer--foreground-for
                                 s frame)
                         :background (agent-shell-math-renderer--background-for
                                      frame)
                         :padding padding
                         :x-height (agent-shell-math-renderer--x-height-at
                                    s buffer))
                        inline
                        (agent-shell-math-renderer--help-echo
                         doc latex engine fallback)))))))))))))))

(defun agent-shell-math-renderer--refresh-buffer (buffer &optional recompile)
  "Re-render every display-math region in BUFFER for the current colors.
Each `agent-shell-math-renderer-source' region is handed back to
`agent-shell-math-renderer--render', which recomputes the cache key
\(so a foreground change yields a fresh image and an unchanged one
is reused from cache).

With RECOMPILE non-nil, first delete each region's cache entry with
`latex-to-svg-backend-invalidate', for the engine and for its fallback
when there is one, so the equation is compiled again.  That also
deletes a failure record, so an engine that failed is tried again.
When the engine or its fallback is `latex' or `texres', the buffer's
`.fmt' files are deleted too (`latex-to-svg-backend-invalidate-format',
one per TeX program): each holds the files the preamble loads as they
were when it was dumped, so an edit to one, such as the `macros.tex' of
an `\\input{macros.tex}', would not reach the recompiled equations.  The
next compile dumps them again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and recompile
                 (seq-intersection
                  '(latex texres)
                  (list agent-shell-math-renderer-engine
                        (agent-shell-math-renderer--fallback-for
                         agent-shell-math-renderer-engine)))
                 (text-property-not-all (point-min) (point-max)
                                        'agent-shell-math-renderer-source nil))
        (latex-to-svg-backend-invalidate-format))
      (save-excursion
        (let ((pos (point-min)))
          (while (setq pos (text-property-not-all
                            pos (point-max)
                            'agent-shell-math-renderer-source nil))
            (let ((latex (get-text-property
                          pos 'agent-shell-math-renderer-source))
                  (inline (get-text-property
                           pos 'agent-shell-math-renderer-inline))
                  (end (or (next-single-property-change
                            pos 'agent-shell-math-renderer-source nil (point-max))
                           (point-max))))
              (when recompile
                (let* ((doc (agent-shell-math-renderer--wrap latex inline))
                       (engine agent-shell-math-renderer-engine)
                       (fallback (agent-shell-math-renderer--fallback-for
                                  engine)))
                  (latex-to-svg-backend-invalidate doc engine)
                  (when fallback
                    (latex-to-svg-backend-invalidate doc fallback))))
              (agent-shell-math-renderer--render buffer pos end latex inline)
              (setq pos end))))))))

(defun agent-shell-math-renderer-refresh (&optional buffer recompile)
  "Re-render displayed equations for the current colors and font.
Re-render BUFFER, defaulting to the current buffer.  With RECOMPILE
non-nil (interactively, a prefix argument), recompile the equations in
BUFFER instead, bypassing the cache: the way to retry after a fix the
cache cannot see, such as installing a missing TeX package or upgrading
RaTeX.  Setting an option that affects the equations needs no refresh:
see `agent-shell-math-renderer--watched-options'.
Call after a theme, appearance, or font-size change so equation images
pick up the new colors and size.

Images are rebuilt at the current font scale from the on-disk SVGs —
cheap, with no recompile: colors and size apply at display time.  The
exception is a change of `agent-shell-math-renderer-engine': an
equation the new engine has not typeset yet is compiled.  The
`latex-to-svg-backend' in-memory image cache is keyed per display scale, so a
new size just adds entries and a sibling buffer's warm images survive
— no clear needed.  Each re-rendered buffer records its new appearance
via `agent-shell-math-renderer--render', so unchanged buffers stay
fast and untouched buffers refresh lazily when next displayed."
  (interactive (list nil current-prefix-arg))
  (agent-shell-math-renderer--refresh-buffer (or buffer (current-buffer))
                                             recompile))

(defconst agent-shell-math-renderer--watched-options
  '(agent-shell-math-renderer-engine
    agent-shell-math-renderer-fallback
    agent-shell-math-renderer-foreground-color
    agent-shell-math-renderer-foreground-ignored-faces
    agent-shell-math-renderer-background-color
    agent-shell-math-renderer-padding
    agent-shell-math-renderer-padding-inline
    agent-shell-math-renderer-padding-display
    agent-shell-math-renderer-rescale-inline
    agent-shell-math-renderer-rescale-display
    agent-shell-math-renderer-center-display-math
    agent-shell-math-renderer-failure-mark
    latex-to-svg-backend-preamble-base
    latex-to-svg-backend-preamble-packages
    latex-to-svg-backend-preamble-not-precompiled
    latex-to-svg-backend-preamble-package-files
    latex-to-svg-backend-preamble-not-precompiled-files
    latex-to-svg-backend-line-width
    latex-to-svg-backend-ratex-macros)
  "Options whose change updates the equations on its own.
Each has a variable watcher (`agent-shell-math-renderer--option-changed').
The last seven are the backend's options in the cache key, which a
project sets in `.dir-locals.el'.")

(defvar agent-shell-math-renderer--option-buffers nil
  "Buffers whose local value of a watched option changed, to update.")

(defvar agent-shell-math-renderer--option-defaults nil
  "Watched options whose default value changed.
The buffers that use the default value of one of them are updated.")

(defvar agent-shell-math-renderer--option-timer nil
  "Timer of the pending update after an option changed, or nil.")

(defun agent-shell-math-renderer--option-changed
    (symbol _newval operation where)
  "Schedule the update after SYMBOL, one of `--watched-options', changed.
A variable watcher: OPERATION is how it changed and WHERE the buffer
whose local value changed, or nil for the default value.  A change of
the default value (`setq' of a global value, `setq-default', Customize)
updates every buffer with equations that has no local value of SYMBOL;
a buffer-local one (`setq-local', `.dir-locals.el') updates that buffer.
A let-binding updates nothing.  The watcher runs before the value is
set, so the update runs from a timer, which also takes several changes
in one go (a block of `setq's in an init file)."
  (when (eq operation 'set)
    (if where
        (cl-pushnew where agent-shell-math-renderer--option-buffers)
      (cl-pushnew symbol agent-shell-math-renderer--option-defaults))
    (unless (timerp agent-shell-math-renderer--option-timer)
      (setq agent-shell-math-renderer--option-timer
            (run-at-time
             0 nil #'agent-shell-math-renderer--update-after-option)))))

(defun agent-shell-math-renderer--update-after-option ()
  "Re-render the buffers `--option-changed' collected.
That is each buffer with rendered equations whose local value of a
watched option changed, or that has no local value of an option whose
default changed (see `agent-shell-math-renderer--refresh-buffer').
Each is checked first (see `agent-shell-math-renderer--check-options'),
so a color option set to a value that is not a color warns once per
buffer."
  (let ((buffers agent-shell-math-renderer--option-buffers)
        (defaults agent-shell-math-renderer--option-defaults))
    (setq agent-shell-math-renderer--option-buffers nil
          agent-shell-math-renderer--option-defaults nil
          agent-shell-math-renderer--option-timer nil)
    (dolist (buf (if defaults (buffer-list) buffers))
      (when (and (buffer-live-p buf)
                 (buffer-local-value 'agent-shell-math-renderer--present buf)
                 (or (memq buf buffers)
                     (seq-some (lambda (option)
                                 (not (local-variable-p option buf)))
                               defaults)))
        (with-current-buffer buf
          (agent-shell-math-renderer--check-options))
        (agent-shell-math-renderer--refresh-buffer buf)))))

(dolist (option agent-shell-math-renderer--watched-options)
  (add-variable-watcher option #'agent-shell-math-renderer--option-changed))

(defun agent-shell-math-renderer--maybe-refresh (&rest _)
  "Re-render equations if the appearance changed since they were rendered.
Hooked to buffer display (`window-buffer-change-functions'), theme
enabling (`enable-theme-functions'), and buffer zoom
\(`text-scale-mode-hook').  A no-op when math rendering is off;
otherwise the actual comparison and refresh are deferred to the next
idle moment, by which point a freshly applied theme / text scale is
fully in effect (and rapid repeat triggers collapse, since the first
refresh updates the recorded appearance)."
  (when agent-shell-math-renderer--present
    (let ((buffer (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer
                         (agent-shell-math-renderer--refresh-if-changed))))))))

(defun agent-shell-math-renderer--refresh-if-changed ()
  "Re-render the current buffer's equations if its appearance changed.
Acts only on the current buffer — the one the firing hook just made
relevant (displayed, themed, or zoomed) — so making one chat visible
never re-renders the others; each refreshes lazily when it is itself
displayed.  The appearance signature folds in both colors and the
x-height of the buffer font (see `agent-shell-math-renderer--appearance'),
so a font-size change is picked up just like a color change.  Nothing happens
while no graphical window shows the buffer, since nothing can be drawn
there: the check runs again when one does."
  (when (and agent-shell-math-renderer--present
             (agent-shell-math-renderer--display-frame (current-buffer))
             (not (equal (agent-shell-math-renderer--appearance)
                         agent-shell-math-renderer--rendered-appearance)))
    (agent-shell-math-renderer-refresh (current-buffer))))

;; Appearance-change refresh.  `agent-shell-math-renderer-mode' installs the
;; per-buffer triggers buffer-locally: `window-buffer-change-functions' for
;; redisplay and `text-scale-mode-hook' for a buffer-local zoom.  Theme
;; switching and a frame font change are global events with no per-buffer
;; hook, so they are left for the user to install if wanted (one handler
;; for both: `agent-shell-math-renderer-on-appearance-change').
;; All go through the same cheap appearance-changed check (colors + font
;; size), so they no-op unless something actually changed.

;;;###autoload
(defun agent-shell-math-renderer-on-appearance-change (&rest _)
  "Refresh every present buffer whose appearance changed.

The mode tracks per-buffer changes itself (redisplay and buffer-local
zoom), but a theme switch and a *frame* font change are global events
with no per-buffer hook, so nothing is installed on your behalf.  For
rendered math to follow them immediately, add this one function to both
global hooks, mirroring how the mode itself is enabled:

  (add-hook \\='enable-theme-functions
            #\\='agent-shell-math-renderer-on-appearance-change)
  (add-hook \\='after-setting-font-hook
            #\\='agent-shell-math-renderer-on-appearance-change)

The second covers `set-frame-font', `doom/increase-font-size' and
`doom-big-font-mode'.  Both are optional: equations otherwise re-tint
and rescale on their next redisplay.

Each buffer is appearance-checked individually (colors + measured font
size), so buffers on a frame the change did not touch cost nothing,
and nothing is recompiled \=-- images are re-fetched from the cache."
  (run-at-time
   0 nil
   (lambda ()
     (dolist (buf (buffer-list))
       (when (buffer-local-value 'agent-shell-math-renderer--present buf)
         (with-current-buffer buf
           (agent-shell-math-renderer--refresh-if-changed)))))))

;;;###autoload
(define-obsolete-function-alias 'agent-shell-math-renderer-on-theme-change
  #'agent-shell-math-renderer-on-appearance-change "0.8.0")

;;; Hook integration with agent-shell-markdown

(defun agent-shell-math-renderer--render-fenced-block (start end latex)
  "Render the fenced math block spanning START..END, source LATEX.

START..END cover the whole fenced block (backtick fences included); LATEX
is its already-trimmed body.  The buffer text is left exactly as the agent
wrote it — the fence is *not* rewritten — and the equation image is
overlaid on the whole block via
`agent-shell-math-renderer--apply-region' (freeze + overlay), so a copy of
the region yields the agent\'s own ```math fence and
`agent-shell-copy-as-markdown' round-trips it.

START..END come from agent-shell-markdown and are wider than the fence on
both sides: `:block :start' sits on the newline of the blank line *before*
the opening fence, and `:block :end' at the start of the line after the
closing one.  Both are trimmed off the math region — otherwise the image\'s
`display\' property would cover them and the blank line separating the
equation from the preceding paragraph would visibly disappear, and
following content would lose its own line.

Freezing the block also keeps upstream\'s `--style-source-blocks' off it
\(that pass checks `agent-shell-markdown-frozen' at the body start), so the
fence gets no code-block chrome under the image.

Called from `agent-shell-math-renderer--render-hook' with START/END from
agent-shell-markdown\'s `:block' positions."
  (let ((start (save-excursion (goto-char start) (skip-chars-forward "\n") (point)))
        (end (if (eq (char-before end) ?\n) (1- end) end)))
    (when (< start end)
      (agent-shell-math-renderer--apply-region
       (current-buffer) start end latex))))

(defun agent-shell-math-renderer--source-ranges (source-blocks)
  "Return sorted block ranges for SOURCE-BLOCKS."
  (agent-shell-markdown-sort-ranges
   (mapcar (lambda (sb)
             (cons (map-nested-elt sb '(:block :start))
                   (map-nested-elt sb '(:block :end))))
           source-blocks)))

(defun agent-shell-math-renderer--inline-tail (avoid-ranges)
  "Return a marker at a still-open inline `\\(' on the last line, or nil.

An unclosed inline `\\(' whose `\\)' hasn't streamed in yet sits on the
buffer's last line.  Returned as the `:watermark', the marker makes
`agent-shell' leave the text from the `\\(' on as it is for the rest of
the chunk (agent-shell 0.89.4), so its escape pass cannot turn `\\('
into `(', and re-scan it next chunk.  An opener already frozen
\(rendered math), inside AVOID-RANGES, escaped (`\\\\('), or followed by
its `\\)' on the line is not a streaming tail."
  (let ((open-re (regexp-quote agent-shell-math-renderer--inline-open))
        (close-re (regexp-quote agent-shell-math-renderer--inline-close))
        (case-fold-search nil))
    (save-excursion
      (goto-char (point-max))
      (beginning-of-line)
      (catch 'found
        (while (agent-shell-math-renderer--re-search-unescaped-forward
                open-re)
          (let ((os (match-beginning 0))
                (oe (match-end 0)))
            (when (and (not (agent-shell-markdown-in-avoid-range-p
                             os oe avoid-ranges))
                       (not (get-text-property
                             os 'agent-shell-markdown-frozen))
                       (not (save-excursion
                              (goto-char oe)
                              (agent-shell-math-renderer--re-search-unescaped-forward
                               close-re))))
              (throw 'found (copy-marker os)))))
        nil))))

(defun agent-shell-math-renderer--render-context (context &optional streaming)
  "Render math in CONTEXT.

CONTEXT is the alist supplied by the `agent-shell' markdown renderer,
or an equivalent alist built for a submitted prompt.  When
STREAMING is non-nil, return a `:watermark' result for `agent-shell'
at the earliest still-open display block or inline span."
  (let* ((source-blocks (map-elt context :source-blocks))
         (inline-code-ranges (map-elt context :inline-code-ranges))
         (source-ranges
          (agent-shell-math-renderer--source-ranges source-blocks))
         (watermarks '()))
    (agent-shell-math-renderer--style-blocks :avoid-ranges source-ranges)
    (when streaming
      (let ((open-block (seq-find (lambda (b) (zerop (plist-get b :close)))
                                  (agent-shell-math-renderer--blocks source-ranges))))
        (when open-block
          ;; Return the frontier as a MARKER, not a raw integer.  We run
          ;; before agent-shell's link/image passes, which delete markup
          ;; (`[text](url)' -> `text', `![](url)' -> image) later in this
          ;; same pass.  A deletion on a line above the opener shifts the
          ;; `\[' down; a plain integer captured now would then point past
          ;; it, so `--update-watermark' would stamp a frontier beyond the
          ;; opener and the next chunk would never re-scan the block (it
          ;; stays unrendered).  A marker tracks those edits, so the `min'
          ;; in `--update-watermark' reads its live position.
          (push (copy-marker (plist-get open-block :start)) watermarks))))
    ;; Inline `\(...\)': avoid code fences, display-math blocks, and
    ;; inline `code' spans.  The inline-code ranges come from CONTEXT,
    ;; so a literal `\(x\)' meant as code is not rendered as math.
    (when agent-shell-math-renderer-render-inline
      (let ((math-ranges (agent-shell-markdown-sort-ranges
                          source-ranges
                          (agent-shell-math-renderer--block-ranges source-ranges)
                          inline-code-ranges)))
        (agent-shell-math-renderer--style-inline :avoid-ranges math-ranges)
        ;; Hold the frontier at a still-open inline `\(' on the last line
        ;; (see `--inline-tail').
        (when streaming
          (when-let* ((wm (agent-shell-math-renderer--inline-tail
                           math-ranges)))
            (push wm watermarks)))))
    ;; Fenced math (```math, per `-fence-languages'): overlay the equation
    ;; image on the whole block — backtick fences included — leaving the
    ;; buffer text exactly as the agent wrote it.  Like the `$$...$$' /
    ;; `\[...\]' / `\(...\)' paths, nothing is rewritten, so a copy of the
    ;; region round-trips the agent's own markdown.
    (dolist (sb source-blocks)
      (when-let* ((lang (map-elt sb :language))
                  ((agent-shell-math-renderer--fence-language-p lang))
                  ((map-elt sb :complete))
                  (start (map-nested-elt sb '(:block :start)))
                  (end (map-nested-elt sb '(:block :end)))
                  ((not (get-text-property start 'agent-shell-markdown-frozen)))
                  (body (map-elt sb :body))
                  (latex (string-trim body))
                  ((not (string-empty-p latex))))
        ;; The block's :end sits at the start of the line after the
        ;; closing fence, so a trailing newline is folded in and kept out
        ;; of the frozen region (see `--render-fenced-block').
        (agent-shell-math-renderer--render-fenced-block start end latex)))
    ;; Hand agent-shell the earliest (leftmost) frontier so both a still-open
    ;; display block and a still-open inline tail are re-scanned next chunk.
    (when watermarks
      (list (cons :watermark
                  (car (sort watermarks
                             (lambda (a b)
                               (< (marker-position a)
                                  (marker-position b))))))))))

(defun agent-shell-math-renderer--render-hook (context)
  "Hook function for `agent-shell-markdown-render-functions'.
Detect and render display-math blocks, inline math, and fenced
math blocks in the current (narrowed) buffer.  CONTEXT is an
alist with `:source-blocks' (fenced-block descriptors) and
`:inline-code-ranges' (marker ranges over inline `code' span
bodies, used to keep `\\(...\\)' inside a code span literal).
Returns an alist with `:watermark' when an unclosed delimiter
needs streaming protection, nil otherwise.

Note: this hook is not invoked on agent-shell's single-line UI
labels (e.g. a tool-command right-label).  `agent-shell' renders
those with external render functions disabled -- see the
`external-renderers' argument of `agent-shell--render-markdown'
in `agent-shell' 0.66.1+ (xenodium PR #747).  That is why this
hook needs no guard against a tool command whose `\\(...\\)' shell
grouping would otherwise false-positive as math: `agent-shell' never
hands us the label in the first place.  See \"Integration\" in the
package's architecture notes for the full history."
  (when (agent-shell-math-renderer--active-p)
    (agent-shell-math-renderer--render-context context t)))

;;; Submitted-prompt rendering

(defun agent-shell-math-renderer--submitted-prompt-region ()
  "Return markers around the most recently submitted comint input."
  (when-let* (((boundp 'comint-last-input-start))
              ((boundp 'comint-last-input-end))
              ((markerp comint-last-input-start))
              ((markerp comint-last-input-end))
              (start (marker-position comint-last-input-start))
              (end (marker-position comint-last-input-end))
              ((< start end)))
    (cons (copy-marker start)
          (copy-marker end))))

(defun agent-shell-math-renderer--render-submitted-prompt
    (buffer start-marker end-marker)
  "Render submitted prompt math in BUFFER from START-MARKER to END-MARKER."
  (unwind-protect
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and agent-shell-math-renderer-render-submitted-prompts
                     (agent-shell-math-renderer--active-p))
            (when-let* ((start (marker-position start-marker))
                        (end (marker-position end-marker))
                        ((< start end)))
              (with-silent-modifications
                (let ((inhibit-read-only t))
                  (save-excursion
                    (save-restriction
                      (widen)
                      (narrow-to-region start end)
                      (agent-shell-math-renderer--render-context
                       (agent-shell-markdown-context))))))))))
    (set-marker start-marker nil)
    (set-marker end-marker nil)))

(defun agent-shell-math-renderer--schedule-submitted-prompt (buffer)
  "Schedule submitted-prompt math rendering in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and agent-shell-math-renderer-render-submitted-prompts
                 (agent-shell-math-renderer--active-p))
        (when-let* ((region (agent-shell-math-renderer--submitted-prompt-region)))
          (run-at-time 0 nil
                       #'agent-shell-math-renderer--render-submitted-prompt
                       buffer (car region) (cdr region)))))))

(defun agent-shell-math-renderer--on-input-submitted (_event)
  "Render the current buffer's submitted prompt after submit returns."
  (agent-shell-math-renderer--schedule-submitted-prompt (current-buffer)))

(defun agent-shell-math-renderer--replayed-prompt-regions ()
  "Return markers around the input of each prompt sent in the current buffer.
The prompts are those `agent-shell-prompt-ranges' returns, less the live
prompt, whose input starts at the shell process mark."
  (save-restriction
    (widen)
    (let ((live-start (when-let* ((process (get-buffer-process
                                            (current-buffer))))
                        (marker-position (process-mark process)))))
      (seq-keep (lambda (range)
                  (let ((start (map-elt range :input-start))
                        (end (map-elt range :input-end)))
                    (when (and (< start end)
                               (or (null live-start) (< start live-start)))
                      (cons (copy-marker start) (copy-marker end)))))
                (agent-shell-prompt-ranges)))))

(defun agent-shell-math-renderer--on-session-restored (_event)
  "Render the prompts a session restore replayed in the current buffer.
agent-shell inserts them without running its markdown renderer and
without emitting `input-submitted'."
  (when (and agent-shell-math-renderer-render-submitted-prompts
             (agent-shell-math-renderer--active-p))
    (dolist (region (agent-shell-math-renderer--replayed-prompt-regions))
      (run-at-time 0 nil
                   #'agent-shell-math-renderer--render-submitted-prompt
                   (current-buffer) (car region) (cdr region)))))

(defun agent-shell-math-renderer--maybe-subscribe-prompts ()
  "Subscribe current `agent-shell' buffer to submitted-prompt rendering."
  (unless agent-shell-math-renderer--prompt-subscriptions
    (setq-local agent-shell-math-renderer--prompt-subscriptions
                (list
                 (agent-shell-subscribe-to
                  :shell-buffer (current-buffer)
                  :event 'input-submitted
                  :on-event
                  #'agent-shell-math-renderer--on-input-submitted)
                 (agent-shell-subscribe-to
                  :shell-buffer (current-buffer)
                  :event 'session-restored
                  :on-event
                  #'agent-shell-math-renderer--on-session-restored)))))

(defun agent-shell-math-renderer--unsubscribe-prompts ()
  "Unsubscribe the current buffer from submitted-prompt rendering."
  (dolist (subscription agent-shell-math-renderer--prompt-subscriptions)
    (agent-shell-unsubscribe :subscription subscription))
  (setq-local agent-shell-math-renderer--prompt-subscriptions nil))

;;;###autoload
(define-minor-mode agent-shell-math-renderer-mode
  "Render LaTeX math in this `agent-shell' buffer's markdown output.

Enable it per buffer from `agent-shell-mode-hook', e.g.

  (add-hook \\='agent-shell-mode-hook #\\='agent-shell-math-renderer-mode)

While on, this buffer's streamed (and, per
`agent-shell-math-renderer-render-submitted-prompts', submitted) markdown
has its display and inline LaTeX rendered as SVG images.  The mode
installs its buffer-local render and appearance hooks on activation and
removes them on deactivation, so merely loading this package has no
effect until the mode is turned on.  What gets recognized is controlled
by `agent-shell-math-renderer-delimiters' and
`agent-shell-math-renderer-fence-languages'."
  :lighter nil
  (if agent-shell-math-renderer-mode
      (progn
        (add-hook 'agent-shell-markdown-render-functions
                  #'agent-shell-math-renderer--render-hook nil t)
        (add-hook 'window-buffer-change-functions
                  #'agent-shell-math-renderer--maybe-refresh nil t)
        (add-hook 'text-scale-mode-hook
                  #'agent-shell-math-renderer--maybe-refresh nil t)
        (agent-shell-math-renderer--maybe-subscribe-prompts)
        (agent-shell-math-renderer--check-options))
    (remove-hook 'agent-shell-markdown-render-functions
                 #'agent-shell-math-renderer--render-hook t)
    (remove-hook 'window-buffer-change-functions
                 #'agent-shell-math-renderer--maybe-refresh t)
    (remove-hook 'text-scale-mode-hook
                 #'agent-shell-math-renderer--maybe-refresh t)
    (agent-shell-math-renderer--unsubscribe-prompts)))

(defcustom agent-shell-math-renderer-enabled nil
  "Obsolete master switch for math rendering in all `agent-shell' buffers.

Prefer enabling the buffer-local `agent-shell-math-renderer-mode', e.g.

  (add-hook \\='agent-shell-mode-hook #\\='agent-shell-math-renderer-mode)

For backward compatibility, setting this non-nil (through Customize or
`setopt') installs an `agent-shell-mode-hook' that turns the mode on in
every `agent-shell' buffer, and enables it in existing ones; setting it
nil removes that hook and disables the mode.  A plain `setq' does not
take effect — use `setopt' or the hook above."
  :type 'boolean
  :safe #'booleanp
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (if value
             (add-hook 'agent-shell-mode-hook
                       #'agent-shell-math-renderer-mode)
           (remove-hook 'agent-shell-mode-hook
                        #'agent-shell-math-renderer-mode))
         (dolist (buf (buffer-list))
           (with-current-buffer buf
             (when (derived-mode-p 'agent-shell-mode)
               (agent-shell-math-renderer-mode (if value 1 -1))))))
  :group 'agent-shell-math-renderer)
(make-obsolete-variable
 'agent-shell-math-renderer-enabled
 "add `agent-shell-math-renderer-mode' to `agent-shell-mode-hook'."
 "0.6.0")

(defconst agent-shell-math-renderer--obsolete-options
  '(agent-shell-math-renderer-padding agent-shell-math-renderer-enabled)
  "The obsolete options reported when they are set non-nil.
The obsolete aliases are not among them: an alias and its option are
one variable, so the value does not tell which name the user set.  An
alias set before this file loaded is reported when it loads (see
`agent-shell-math-renderer--obsolete-aliases-set').")

(defun agent-shell-math-renderer--obsolete-option-set
    (symbol newval operation _where)
  "Report SYMBOL, an obsolete option, when OPERATION sets it to NEWVAL.
A variable watcher on each of `--obsolete-options'.  It acts on `set'
only, as `agent-shell-math-renderer--option-changed' does."
  (when (eq operation 'set)
    (agent-shell-math-renderer--warn-obsolete symbol newval)))

(dolist (option agent-shell-math-renderer--obsolete-options)
  (add-variable-watcher option
                        #'agent-shell-math-renderer--obsolete-option-set)
  (agent-shell-math-renderer--warn-obsolete option (default-value option)))

(dolist (alias agent-shell-math-renderer--obsolete-aliases-set)
  (agent-shell-math-renderer--warn-obsolete alias t))

(provide 'agent-shell-math-renderer)

;; Local Variables:
;; checkdoc-symbol-words: ("display-time")
;; End:

;;; agent-shell-math-renderer.el ends here
