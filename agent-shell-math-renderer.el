;;; agent-shell-math-renderer.el --- Display-math rendering for agent-shell -*- lexical-binding: t -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/agent-shell-math-renderer
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.58.1") (latex-to-svg "0.3.1"))
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
;; This path obtains the same markdown context through agent-shell's
;; public `agent-shell-markdown-context', so it stays in sync with the
;; streaming render hook and uses no private agent-shell API.
;;
;; Equation typesetting is delegated to the `latex-to-svg' library: this
;; module handles the markdown-specific detection (delimiters, inline
;; math, fenced blocks, streaming watermark) and image *placement* (via
;; `display' text properties), while `latex-to-svg' compiles each unique
;; equation to a color- and size-independent SVG (cached on disk by
;; content, tinted and scaled at display time).  Compilation is
;; asynchronous; the image is overlaid when ready.  When the toolchain is
;; absent or `latex-to-svg-use-placeholder' is set, a placeholder panel
;; boxing the raw LaTeX is shown instead.  Rendering-engine settings
;; (LaTeX/dvisvgm programs, preamble, cache directory, font scale,
;; placeholder / non-graphic behaviour) live in the `latex-to-svg-*'
;; customization group.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'agent-shell)
(require 'agent-shell-markdown)
(require 'comint)
(require 'latex-to-svg)
(require 'map)
(require 'seq)

(defgroup agent-shell-math-renderer nil
  "Render LaTeX math in agent-shell's streamed markdown output.
Display equations (`\\=\\[...\\]', `$$...$$', and ```math / ```latex /
```tex fences) and inline `\\(...\\)' are compiled to SVG with
`latex' + `dvisvgm' and overlaid on the raw LaTeX (kept in the
buffer so copy/save round-trips the source)."
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
`agent-shell-math-renderer-fence-languages' is separate); the
master switch `agent-shell-math-renderer-enabled' disables
everything.

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

(defcustom agent-shell-math-renderer-enabled nil
  "Master switch for rendering display math in agent responses.

Nil (the default) disables math rendering entirely — delimiters
and fenced math blocks are left as plain text / ordinary code
blocks.  Set non-nil to opt in; what then gets recognized is
controlled by `agent-shell-math-renderer-delimiters' (both
`\\=\\[...\\]' and `$$...$$' on by default) and
`agent-shell-math-renderer-fence-languages' (`math' / `latex' /
`tex' fenced blocks, on by default).

Checked by `agent-shell-math-renderer--render-hook', which
agent-shell's markdown renderer calls via
`agent-shell-markdown-render-functions'; when nil the hook is a
no-op."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-fence-languages '("math" "latex" "tex")
  "Fenced-code-block languages rendered as display math.

A fenced block whose info string is one of these (compared
case-insensitively), e.g.

  ```math
  E = mc^2
  ```

is typeset as an equation instead of shown as a code block — but
only when `agent-shell-math-renderer-enabled' is non-nil.  Several
agents emit `math'/`latex' fences (GitHub renders ```math as
display math), so this complements the `\\=\\[...\\]' / `$$...$$'
delimiter styles.  Set to nil to leave such fences as code."
  :type '(repeat string)
  :safe (lambda (v) (and (listp v) (seq-every-p #'stringp v)))
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-render-inline t
  "When non-nil, recognize inline math `\\(...\\)' in agent responses.

Only effective when the master switch
`agent-shell-math-renderer-enabled' is non-nil.  Inline math is
typeset in text style (no `\\displaystyle') and overlaid in place,
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

(defcustom agent-shell-math-renderer-inline-rescale 1.0
  "Size multiplier for inline math previews (`\\(...\\)').
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg's `:rescale-by'.  Re-scales from cache (no recompile);
after changing it, run `agent-shell-math-renderer-refresh' to apply."
  :type 'number
  :safe #'numberp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-display-rescale 1.0
  "Size multiplier for display math previews (`\\=\\[...\\]', `$$...$$', fences).
Applied on top of the engine's global `latex-to-svg-font-scale' via
`latex-to-svg's `:rescale-by' — e.g. set to 1.1 for display equations a
touch larger than inline.  Re-scales from cache (no recompile); after
changing it, run `agent-shell-math-renderer-refresh' to apply."
  :type 'number
  :safe #'numberp
  :group 'agent-shell-math-renderer)

(defcustom agent-shell-math-renderer-render-submitted-prompts nil
  "When non-nil, render math in submitted user prompts.

This option has an effect only when
`agent-shell-math-renderer-enabled' is also non-nil.

The usual delimiter and inline settings apply: prompts render
`\\=\\[...\\]' / `$$...$$' according to
`agent-shell-math-renderer-delimiters', and inline `\\(...\\)'
according to `agent-shell-math-renderer-render-inline'.

This uses agent-shell's existing `input-submitted' event and
shell-maker/comint's `comint-last-input-start' /
`comint-last-input-end' markers to find the prompt that was just
submitted.  Rendering is deferred out of the submit command."
  :type 'boolean
  :safe #'booleanp
  :group 'agent-shell-math-renderer)

(defvar-local agent-shell-math-renderer--rendered-appearance nil
  "The appearance signature this buffer's equations were rendered for.
A list (FOREGROUND BACKGROUND FONT-HEIGHT) — see
`latex-to-svg-appearance'.  Buffer-local:
each buffer tracks its own last-rendered appearance, so a refresh
can re-render just the affected buffer and leave the others to
re-render lazily when they are next displayed (see
`agent-shell-math-renderer--refresh-if-changed').  Updated whenever
an equation renders.")

(defvar-local agent-shell-math-renderer--present nil
  "Non-nil in a buffer that has rendered display-math regions.
Lets `agent-shell-math-renderer-refresh' visit only relevant buffers.")

(defvar-local agent-shell-math-renderer--prompt-subscription nil
  "Subscription token for submitted-prompt rendering in this buffer.")

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
        (while (re-search-forward open-re nil t)
          (let* ((open-start (match-beginning 0))
                 (open-end (match-end 0))
                 (avoid (agent-shell-markdown-in-avoid-range-p
                         open-start open-end avoid-ranges)))
            (if avoid
                (goto-char (cdr avoid))
              ;; Look for the closer on this line only; skip a closer
              ;; that sits inside an avoid-range (it is protected text).
              (let ((eol (line-end-position))
                    (close-end nil))
                (save-excursion
                  (goto-char open-end)
                  (while (and (not close-end)
                              (re-search-forward close-re eol t))
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
the same style.

Shared by the delimiter pass (`agent-shell-math-renderer--style-blocks'),
the inline pass (`agent-shell-math-renderer--style-inline'), and the
fenced-block path in `agent-shell-math-renderer--render-hook' (for ```math /
```latex / ```tex fences).  The fenced path first rewrites the block in
place — the backtick fences are dropped and the body wrapped in `\\=\\[...\\]'
delimiters — and passes START..END over that `\\=\\[...\\]' text, so all three
callers hand this function a delimited (LaTeX-renderable) region."
  (with-current-buffer buffer
    (setq agent-shell-math-renderer--present t)
    (add-face-text-property start end 'agent-shell-math-renderer)
    (add-text-properties
     start end
     `(help-echo ,latex
                 agent-shell-math-renderer-source ,latex
                 agent-shell-math-renderer-inline ,inline
                 agent-shell-markdown-frozen t
                 rear-nonsticky (agent-shell-markdown-frozen)))
    (agent-shell-math-renderer--render buffer start end latex inline)))

(defun agent-shell-math-renderer--overlay-image (buffer start end image)
  "Lay IMAGE over BUFFER's START..END as a `display' property.

START / END may be markers (async case) or integers (sync case).
No-ops when BUFFER is dead or the region is no longer valid (it
was edited or killed away).  Runs with `with-silent-modifications'
so an async overlay doesn't flag the buffer modified, and carries
the region's existing `line-prefix' / `wrap-prefix' so indentation
is preserved."
  (when (and image (buffer-live-p buffer))
    (with-current-buffer buffer
      (let ((s (if (markerp start) (marker-position start) start))
            (e (if (markerp end) (marker-position end) end)))
        (when (and s e (<= (point-min) s) (< s e) (<= e (point-max)))
          (with-silent-modifications
            (let ((line-prefix (get-text-property s 'line-prefix))
                  (wrap-prefix (get-text-property s 'wrap-prefix)))
              (put-text-property s e 'display image)
              (put-text-property s e 'mouse-face 'highlight)
              (when line-prefix
                (put-text-property s e 'line-prefix line-prefix))
              (when wrap-prefix
                (put-text-property s e 'wrap-prefix wrap-prefix)))))))))

(defun agent-shell-math-renderer--render (buffer start end latex &optional inline)
  "Render LATEX over BUFFER's START..END as an equation image.

Delegates typesetting to `latex-to-svg': overlays the image
immediately when available (cached SVG or placeholder), else
captures START / END as markers and overlays the result once the
async compile finishes (so the overlay lands even after more output
streams in).  Does nothing when equations aren't renderable (see
`latex-to-svg-available-p') — the raw faced text stands in.

LATEX is the equation body with delimiters stripped; INLINE non-nil
typesets it in text style, otherwise display style.  Since
`latex-to-svg' renders its argument *verbatim*, we wrap the body
here into valid body LaTeX (`$body$' inline, `$\\displaystyle body$'
display) and pass that.  Color and size are not baked in —
`latex-to-svg' tints the color-independent SVG to the buffer
foreground and scales it to the buffer font at display time, the
latter by `agent-shell-math-renderer-inline-rescale' /
`-display-rescale' (via `:rescale-by') for INLINE / display math."
  (when (latex-to-svg-available-p)
    ;; Record the appearance (colors + font height) this render is for,
    ;; so a later theme / frame / font change can detect the difference
    ;; and re-render (a color change re-tints; it no longer recompiles).
    (setq agent-shell-math-renderer--rendered-appearance
          (latex-to-svg-appearance))
    (let* ((doc (if inline
                    (format "$%s$" latex)
                  (format "$\\displaystyle %s$" latex)))
           (rescale (if inline
                        agent-shell-math-renderer-inline-rescale
                      agent-shell-math-renderer-display-rescale))
           (image (latex-to-svg doc :rescale-by rescale)))
      (if image
          (agent-shell-math-renderer--overlay-image buffer start end image)
        ;; Not ready yet: schedule and overlay when the SVG lands.  Capture
        ;; the region as markers so it survives further streaming output.
        (let ((s (copy-marker start))
              (e (copy-marker end)))
          (latex-to-svg
           doc
           :rescale-by rescale
           :callback
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (agent-shell-math-renderer--overlay-image
                  buffer s e
                  (latex-to-svg doc :rescale-by rescale)))))))))))

(defun agent-shell-math-renderer--refresh-buffer (buffer)
  "Re-render every display-math region in BUFFER for the current colors.
Each `agent-shell-math-renderer-source' region is handed back to
`agent-shell-math-renderer--render', which recomputes the cache key
\(so a foreground change yields a fresh image and an unchanged one
is reused from cache)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
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
              (agent-shell-math-renderer--render buffer pos end latex inline)
              (setq pos end))))))))

(defun agent-shell-math-renderer-refresh (&optional buffer)
  "Re-render displayed equations for the current colors and font.
With BUFFER, re-render only that buffer; otherwise (the interactive
default) every buffer that has rendered equations.  Call after a
theme, appearance, or font-size change so equation images pick up
the new colors and size.

The pixels-per-point calibration is dropped (via `latex-to-svg-flush-metrics')
so it is re-measured (e.g. after a display / scaling change); images
are then rebuilt at the current font scale from the on-disk SVGs —
cheap, no LaTeX recompile unless the color also changed.  The
`latex-to-svg' in-memory image cache is keyed per display scale, so a
new size just adds entries and a sibling buffer's warm images survive
— no clear needed.  Each re-rendered buffer records its new appearance
via `agent-shell-math-renderer--render', so unchanged buffers stay
fast and untouched buffers refresh lazily when next displayed."
  (interactive)
  (latex-to-svg-flush-metrics)
  (dolist (buf (if buffer
                   (list buffer)
                 (seq-filter
                  (lambda (b)
                    (buffer-local-value 'agent-shell-math-renderer--present b))
                  (buffer-list))))
    (agent-shell-math-renderer--refresh-buffer buf)))

(defun agent-shell-math-renderer--maybe-refresh (&rest _)
  "Re-render equations if the appearance changed since they were rendered.
Hooked to buffer display (`window-buffer-change-functions'), theme
enabling (`enable-theme-functions'), and buffer zoom
\(`text-scale-mode-hook').  A no-op when math rendering is off;
otherwise the actual comparison and refresh are deferred to the next
idle moment, by which point a freshly applied theme / text scale is
fully in effect (and rapid repeat triggers collapse, since the first
refresh updates the recorded appearance)."
  (when agent-shell-math-renderer-enabled
    (run-at-time 0 nil #'agent-shell-math-renderer--refresh-if-changed)))

(defun agent-shell-math-renderer--refresh-if-changed ()
  "Re-render the current buffer's equations if its appearance changed.
Acts only on the current buffer — the one the firing hook just made
relevant (displayed, themed, or zoomed) — so making one chat visible
never re-renders the others; each refreshes lazily when it is itself
displayed.  The appearance signature folds in both colors and the
buffer font height (see `latex-to-svg-appearance'), so a font-size
change is picked up just like a color change."
  (when (and agent-shell-math-renderer-enabled
             agent-shell-math-renderer--present
             (not (equal (latex-to-svg-appearance)
                         agent-shell-math-renderer--rendered-appearance)))
    (agent-shell-math-renderer-refresh (current-buffer))))

;; Re-render lazily, when an equation buffer is next displayed, rather than
;; eagerly on every event that might recolor the default face.
;; `window-buffer-change-functions' is the workhorse: whatever changed the
;; colors (a theme, a macOS/Linux system light/dark toggle on any platform,
;; a graphical client attaching to a daemon after a TTY render), we notice
;; the next time the buffer is shown in a window and repaint if stale.
;; `enable-theme-functions' (Emacs 29+, cross-platform) covers the one case
;; display alone misses: a theme enabled while the buffer stays visible and
;; untouched.  `text-scale-mode-hook' covers the other: a buffer-local zoom
;; (`text-scale-adjust', C-x C-+/-) changes the font height without a
;; display or theme event, so without this hook equations only re-size on
;; the next buffer switch.  All three go through the same appearance-changed
;; check (colors + font height), so they're cheap no-ops when nothing
;; changed (or math rendering is off).
(add-hook 'window-buffer-change-functions
          #'agent-shell-math-renderer--maybe-refresh)
(add-hook 'enable-theme-functions #'agent-shell-math-renderer--maybe-refresh)
(add-hook 'text-scale-mode-hook #'agent-shell-math-renderer--maybe-refresh)

;;; Hook integration with agent-shell-markdown

(defun agent-shell-math-renderer--rewrite-fenced-block (start end latex)
  "Rewrite fenced math spanning START..END as `\\=\\[LATEX\\]' and render it.

START..END cover the whole fenced block (backtick fences included); LATEX
is its already-trimmed body.  The backtick fences are dropped and the body
re-wrapped in `\\=\\[...\\]' display delimiters, then that region is routed to
`agent-shell-math-renderer--apply-region' (freeze + overlay).  A trailing
newline just inside END (present unless the closing fence is the buffer's
last, newline-less line) is kept outside the frozen math region so following
content stays on its own line.

Called from `agent-shell-math-renderer--render-hook' with START/END from
agent-shell-markdown's `:block' positions."
  (save-excursion
    (goto-char start)
    (let ((trailing-newline (eq (char-before end) ?\n)))
      (delete-region start end)
      (let ((open (point)))
        (insert "\\[\n" latex "\n\\]")
        (let ((close (point)))
          (when trailing-newline (insert "\n"))
          (agent-shell-math-renderer--apply-region
           (current-buffer) open close latex))))))

(defun agent-shell-math-renderer--source-ranges (source-blocks)
  "Return sorted block ranges for SOURCE-BLOCKS."
  (agent-shell-markdown-sort-ranges
   (mapcar (lambda (sb)
             (cons (map-nested-elt sb '(:block :start))
                   (map-nested-elt sb '(:block :end))))
           source-blocks)))

(defun agent-shell-math-renderer--render-context (context &optional streaming)
  "Render math in CONTEXT.

CONTEXT is the alist supplied by agent-shell's markdown renderer,
or an equivalent alist built for a submitted prompt.  When
STREAMING is non-nil, protect still-open display blocks and return
a `:watermark' result for agent-shell."
  (let* ((source-blocks (map-elt context :source-blocks))
         (inline-code-ranges (map-elt context :inline-code-ranges))
         (source-ranges
          (agent-shell-math-renderer--source-ranges source-blocks))
         (watermark nil))
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
          ;; stays frozen-but-unrendered).  A marker tracks those edits, so
          ;; the `min' in `--update-watermark' reads its live position.
          (setq watermark (copy-marker (plist-get open-block :start)))
          (put-text-property (plist-get open-block :start)
                             (plist-get open-block :end)
                             'agent-shell-markdown-frozen t))))
    ;; Inline `\(...\)': avoid code fences, display-math blocks, and
    ;; inline `code' spans.  The inline-code ranges come from CONTEXT,
    ;; so a literal `\(x\)' meant as code is not rendered as math.
    (when agent-shell-math-renderer-render-inline
      (let ((math-ranges (agent-shell-markdown-sort-ranges
                          source-ranges
                          (agent-shell-math-renderer--block-ranges source-ranges)
                          inline-code-ranges)))
        (agent-shell-math-renderer--style-inline :avoid-ranges math-ranges)))
    ;; Fenced math (```math / ```latex / ```tex): replace the whole
    ;; block — backtick fences included — with the LaTeX body wrapped
    ;; in `\[...\]' display delimiters, then overlay the equation image
    ;; on that.  Dropping the fences (rather than keeping them under the
    ;; image) means a copy of the rendered region yields renderable
    ;; LaTeX, not markdown backticks — matching the `$$...$$' / `\[...\]'
    ;; delimiter paths, which likewise keep their (LaTeX) delimiters.
    ;; Iterate bottom-up so replacing one block never shifts the
    ;; positions of earlier, not-yet-processed ones.
    (dolist (sb (reverse source-blocks))
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
        ;; of the frozen region (see `--rewrite-fenced-block').
        (agent-shell-math-renderer--rewrite-fenced-block start end latex)))
    (when watermark
      (list (cons :watermark watermark)))))

(defun agent-shell-math-renderer--render-hook (context)
  "Hook function for `agent-shell-markdown-render-functions'.
Detect and render display-math blocks, inline math, and fenced
math blocks in the current (narrowed) buffer.  CONTEXT is an
alist with `:source-blocks' (fenced-block descriptors) and
`:inline-code-ranges' (marker ranges over inline `code' span
bodies, used to keep `\\(...\\)' inside a code span literal).
Returns an alist with `:watermark' when an unclosed delimiter
needs streaming protection, nil otherwise."
  (when agent-shell-math-renderer-enabled
    (agent-shell-math-renderer--render-context context t)))

(add-hook 'agent-shell-markdown-render-functions
          #'agent-shell-math-renderer--render-hook)

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
                     agent-shell-math-renderer-enabled)
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
                 agent-shell-math-renderer-enabled)
        (when-let* ((region (agent-shell-math-renderer--submitted-prompt-region)))
          (run-at-time 0 nil
                       #'agent-shell-math-renderer--render-submitted-prompt
                       buffer (car region) (cdr region)))))))

(defun agent-shell-math-renderer--on-input-submitted (_event)
  "Render the current buffer's submitted prompt after submit returns."
  (agent-shell-math-renderer--schedule-submitted-prompt (current-buffer)))

(defun agent-shell-math-renderer--maybe-subscribe-prompts ()
  "Subscribe current agent-shell buffer to submitted-prompt rendering."
  (unless agent-shell-math-renderer--prompt-subscription
    (setq-local agent-shell-math-renderer--prompt-subscription
                (agent-shell-subscribe-to
                 :shell-buffer (current-buffer)
                 :event 'input-submitted
                 :on-event
                 #'agent-shell-math-renderer--on-input-submitted))))

(add-hook 'agent-shell-mode-hook
          #'agent-shell-math-renderer--maybe-subscribe-prompts)

(provide 'agent-shell-math-renderer)

;;; agent-shell-math-renderer.el ends here
