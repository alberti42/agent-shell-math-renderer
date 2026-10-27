;;; agent-shell-math-renderer-tests.el --- Tests for agent-shell-math-renderer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-4-8
;; URL: https://github.com/alberti42/agent-shell-math-renderer

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/agent-shell-math-renderer-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)
;; Defines `text-scale-mode-hook', which a test reads.
(require 'face-remap)
;; `lm-header' reads the package's headers in the drift guard.
(require 'lisp-mnt)
;; `display-warning' is autoloaded, and `cl-letf' resolving that autoload loads
;; warnings.el, which redefines it -- clobbering a stub installed in the same
;; `cl-letf'.  Load it up front so stubbing it is deterministic.
(require 'warnings)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

;; `latex-to-svg-backend' (the backend, a hard dependency of the
;; renderer) is a sibling repo; add it to `load-path' so the module's
;; `(require 'latex-to-svg-backend)' resolves when running the suite from a checkout.
;; Override the location with LATEX_TO_SVG_DIR for other layouts.
(let ((dir (or (getenv "LATEX_TO_SVG_DIR")
               (expand-file-name "../../latex-to-svg-backend"
                                 (file-name-directory
                                  (or load-file-name buffer-file-name))))))
  (when (file-directory-p dir)
    (add-to-list 'load-path dir)))

;; Loads `agent-shell-markdown' (from load path) and our renderer.
;; The math passes run through `agent-shell-markdown-convert', so the
;; tests exercise the hook integration rather than the module in
;; isolation.
;;
;; NOTE: these tests call `agent-shell-markdown--deconstruct' (a private
;; agent-shell helper that turns propertized text into (STRING . FACES)
;; runs) for their assertions.  That dependency is test-only: if
;; upstream renames or drops `--deconstruct', adapt the assertions or
;; inline an equivalent.
(require 'agent-shell-markdown)
(require 'agent-shell-math-renderer)

;; The renderer now installs its render hook buffer-locally via
;; `agent-shell-math-renderer-mode'.  These tests drive the pipeline through
;; `agent-shell-markdown-convert' in throwaway buffers (no mode), so install
;; the hook globally for the suite; it still no-ops unless a test opts in by
;; binding the default value of `agent-shell-math-renderer-mode' (checked via
;; `--active-p').  A plain `let' of the mode variable would bind only the
;; current buffer's value, which a `with-temp-buffer' inside it does not see.
(add-hook 'agent-shell-markdown-render-functions
          #'agent-shell-math-renderer--render-hook)

(defmacro agent-shell-math-renderer-tests--enabled (&rest body)
  "Evaluate BODY with math rendering enabled.
`agent-shell-math-renderer-mode' is off by default, so every test
that expects equations to render must opt in; this binds its default
value for the default delimiter set (`bracket')."
  (declare (indent 0) (debug t))
  `(cl-letf (((default-value 'agent-shell-math-renderer-mode) t))
     ,@body))

(defmacro agent-shell-math-renderer-tests--with-dollar (&rest body)
  "Evaluate BODY with math rendering on and `$$...$$' enabled.
`agent-shell-math-renderer-delimiters' defaults to `bracket' only,
so the dollar-delimited tests opt into `dollar' (and
`agent-shell-math-renderer-mode') through this one binding."
  (declare (indent 0) (debug t))
  `(cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
             (agent-shell-math-renderer-delimiters '(dollar bracket)))
     ,@body))

(ert-deftest agent-shell-math-renderer-display-math-protects-markup ()
  ;; A complete `$$...$$' block is faced `agent-shell-math-renderer'
  ;; as a single run; the LaTeX source is kept literal (no bold /
  ;; italic / subscript processing of its interior).  On the
  ;; non-graphical batch display no equation image is overlaid, so
  ;; `--deconstruct' sees only the math face.
  (agent-shell-math-renderer-tests--with-dollar
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "$$ **x** $$"))
                   '(("$$ **x** $$" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-display-math-block ()
  ;; Multi-line block form: the whole `$$\\n...\\n$$' region is one
  ;; math-faced run.
  (agent-shell-math-renderer-tests--with-dollar
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "$$
E=mc^2
$$"))
                   '(("$$
E=mc^2
$$" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-open-math-protects-rest ()
  ;; An unclosed `$$' protects the rest of the buffer as still
  ;; streaming, just like an open fence: markup after it is left raw
  ;; until the closing `$$' arrives.
  (agent-shell-math-renderer-tests--with-dollar
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "before **b**
$$
streaming **not bold**"))
                   '(("before " nil)
                     ("b" (agent-shell-markdown-bold))
                     ("
$$
streaming **not bold**" nil))))))

(ert-deftest agent-shell-math-renderer-display-math-in-fenced-block-untouched ()
  ;; A `$$' inside a fenced code block is body text, not display
  ;; math: it must not get the math face (even with `dollar' enabled).
  (agent-shell-math-renderer-tests--with-dollar
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "```
$$ x $$
```"))
                   '(("
" (agent-shell-markdown-source-block))
                     ("snippet ⧉" (agent-shell-markdown-source-block-language))
                     ("

$$ x $$

" (agent-shell-markdown-source-block)))))))

(ert-deftest agent-shell-math-renderer-bracket-math-protects-markup ()
  ;; A complete block-level `\\[...\\]' is recognized as display math
  ;; and faced `agent-shell-math-renderer', keeping its interior literal.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[ **x** \\]"))
                   '(("\\[ **x** \\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-open-bracket-math-protects-rest ()
  ;; A line-start `\\[' with no closer yet protects the rest of the
  ;; buffer until the closing `\\]' arrives, mirroring open `$$' /
  ;; open fences.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "before **b**
\\[ streaming **not bold**"))
                   '(("before " nil)
                     ("b" (agent-shell-markdown-bold))
                     ("
\\[ streaming **not bold**" nil))))))

(ert-deftest agent-shell-math-renderer-math-delimiters-independent ()
  ;; `agent-shell-math-renderer-delimiters' toggles each style
  ;; independently: with only `bracket' enabled, a block-level
  ;; `\\[...\\]' renders while `$$...$$' is left as plain text (and its
  ;; `**' inside is processed as ordinary markup).
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
            (agent-shell-math-renderer-delimiters '(bracket)))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "$$ **b** $$
\\[ **d** \\]"))
                   '(("$$ " nil)
                     ("b" (agent-shell-markdown-bold))
                     (" $$
" nil)
                     ("\\[ **d** \\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-math-delimiters-disabled ()
  ;; An empty `agent-shell-math-renderer-delimiters' disables the
  ;; delimiter styles even with the master switch on: delimiters are
  ;; plain text and inner markup is processed normally.  Unclaimed, the
  ;; `\[' / `\]' are shown as `[' / `]' -- agent-shell 0.66.1+ unescapes
  ;; backslash-escaped punctuation per CommonMark (only frozen math is
  ;; spared, so this text isn't).
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
            (agent-shell-math-renderer-delimiters '()))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "x \\[ **y** \\] z"))
                   '(("x [ " nil)
                     ("y" (agent-shell-markdown-bold))
                     (" ] z" nil))))))

(ert-deftest agent-shell-math-renderer-math-no-cross-delimiter-nesting ()
  ;; A `$$' inside a `\\[...\\]' block is body, not a delimiter: the
  ;; block runs to the matching `\\]' and is one math-faced run.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[ a $$ b \\]"))
                   '(("\\[ a $$ b \\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-math-multiline-body ()
  ;; LaTeX allows newlines (but not blank lines) inside display math,
  ;; so `\\[\\nE=mc^2\\n\\]' renders as one block.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[
E=mc^2
\\]"))
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-math-blank-line-rejected ()
  ;; A blank line can't appear inside LaTeX display math, so a block
  ;; whose body would span one is rejected (left as plain text rather
  ;; than mis-rendered as a single equation).  Unclaimed, the `\[' / `\]'
  ;; show unescaped as `[' / `]' (agent-shell 0.66.1+ CommonMark).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[
E=mc^2

extra
\\]"))
                   '(("[
E=mc^2

extra
]" nil))))))

(ert-deftest agent-shell-math-renderer-math-stray-opener-recovers-real-blocks ()
  ;; A stray line-start opener that never closes before a blank line is
  ;; a false positive; scanning resumes just after it, so a real
  ;; block-level equation on a later line is still rendered (rather than
  ;; the stray opener swallowing it).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[ stray opener

\\[ E=mc^2 \\]"))
                   '(("[ stray opener

" nil)
                     ("\\[ E=mc^2 \\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-math-inline-opener-ignored ()
  ;; An opener not at line start is inline, not block-level display
  ;; math: it is left as plain text and inner markup is processed.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "see \\[ **x** \\] here"))
                   '(("see [ " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" ] here" nil))))))

(ert-deftest agent-shell-math-renderer-math-non-flush-closer-rejected ()
  ;; A line-start opener whose closer sits mid-line (text follows on the
  ;; same line) is not a flush block; it is rejected and left as plain
  ;; text rather than rendered.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "\\[ E=mc^2 \\] and text"))
                   '(("\\[ E=mc^2 \\] and text" nil))))))

(ert-deftest agent-shell-math-renderer-math-dollar-on-by-default ()
  ;; `dollar' is part of the default `agent-shell-math-renderer-delimiters'
  ;; now that block-level anchoring makes it safe, so `$$...$$' renders
  ;; without opting in (only the master switch need be on here).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "$$ E=mc^2 $$"))
                   '(("$$ E=mc^2 $$" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-fenced-math-renders ()
  ;; A ```math fence renders as display math with its buffer text left
  ;; exactly as the agent wrote it — the fence is kept under the image (so
  ;; a copy round-trips the agent's markdown) and math-faced as one run.
  ;; Freezing it also keeps upstream's source-block pass off it, so the
  ;; block gets no code-block face or language label.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "```math
E=mc^2
```"))
                   '(("```math
E=mc^2
```" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-fenced-latex-stays-code ()
  ;; A ```latex fence is *not* math by default: `latex'/`tex' name a
  ;; language, not a role, so such a fence is usually quoted LaTeX
  ;; source and stays a code block (see
  ;; `agent-shell-math-renderer-fence-languages').
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-markdown--deconstruct
                 (agent-shell-markdown-convert "```latex
E=mc^2
```"))))
      (should-not (seq-some (lambda (run)
                              (memq 'agent-shell-math-renderer (cadr run)))
                            runs))
      (should (seq-some (lambda (run)
                          (memq 'agent-shell-markdown-source-block (cadr run)))
                        runs)))))

(ert-deftest agent-shell-math-renderer-fenced-latex-opt-in ()
  ;; Adding `latex' to `agent-shell-math-renderer-fence-languages' makes
  ;; such a fence render as display math, just like ```math.
  (agent-shell-math-renderer-tests--enabled
    (let ((agent-shell-math-renderer-fence-languages '("math" "latex")))
      (should (equal (agent-shell-markdown--deconstruct
                      (agent-shell-markdown-convert "```latex
E=mc^2
```"))
                     '(("```latex
E=mc^2
```" (agent-shell-math-renderer))))))))

(ert-deftest agent-shell-math-renderer-fenced-math-keeps-following-content ()
  ;; When content follows the fence, the block's trailing newline is
  ;; preserved (kept out of the math run) so following prose stays on
  ;; its own line and is otherwise untouched.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "```math
E=mc^2
```
after"))
                   '(("```math
E=mc^2
```" (agent-shell-math-renderer))
                     ("
after" nil))))))

(ert-deftest agent-shell-math-renderer-fenced-math-keeps-preceding-blank-line ()
  ;; agent-shell-markdown's `:block :start' sits on the newline of the
  ;; blank line *before* the opening fence, so taking the block range as
  ;; given would put that blank line under the image's `display' property
  ;; and visibly close the gap between the equation and the paragraph
  ;; above it.  The math run must start at the fence itself.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "text

```math
E=mc^2
```"))
                   '(("text\n\n" nil)
                     ("```math
E=mc^2
```" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-fenced-math-copies-as-markdown ()
  ;; The rendered region round-trips: because the fence is kept in the
  ;; buffer rather than rewritten, `agent-shell-copy-as-markdown' (via the
  ;; public `agent-shell-markdown-reconstruct') hands back the agent's own
  ;; ```math block, not the equation's visible text.
  (agent-shell-math-renderer-tests--enabled
    (let ((markdown "```math
E=mc^2
```"))
      (with-temp-buffer
        (insert (agent-shell-markdown-convert markdown))
        (should (equal (agent-shell-markdown-reconstruct (point-min) (point-max))
                       markdown))))))

(ert-deftest agent-shell-math-renderer-fenced-non-math-stays-code ()
  ;; A non-math language fence is unaffected by math rendering — it
  ;; still renders as a code block (no math face), even with the
  ;; master switch on.
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-markdown--deconstruct
                 (agent-shell-markdown-convert "```python
x = 1
```"))))
      (should-not (seq-some (lambda (run)
                              (memq 'agent-shell-math-renderer (cadr run)))
                            runs))
      (should (seq-some (lambda (run)
                          (memq 'agent-shell-markdown-source-block (cadr run)))
                        runs)))))

(ert-deftest agent-shell-math-renderer-math-master-switch-off ()
  ;; With the master switch off (the default), `\\[...\\]' is plain
  ;; text and its inner markup is processed normally (here `**x**'
  ;; becomes bold) — math rendering is fully gated.  The unclaimed
  ;; `\[' / `\]' show unescaped as `[' / `]' (agent-shell 0.66.1+
  ;; CommonMark backslash-unescaping).
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "before \\[ **x** \\] after"))
                   '(("before [ " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" ] after" nil))))))

(ert-deftest agent-shell-math-renderer-fenced-math-as-code-when-off ()
  ;; With the master switch off, a ```math fence is left as an ordinary
  ;; code block (source-block face), not a math equation.
  (cl-letf* (((default-value 'agent-shell-math-renderer-mode) nil)
             (runs (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "```math
E=mc^2
```"))))
    (should-not (seq-some (lambda (run)
                            (memq 'agent-shell-math-renderer (cadr run)))
                          runs))
    (should (seq-some (lambda (run)
                        (memq 'agent-shell-markdown-source-block (cadr run)))
                      runs))))

(ert-deftest agent-shell-math-renderer-math-degrades-without-svg ()
  ;; On a build without SVG support, math rendering degrades gracefully:
  ;; even on a graphical frame and with the feature on, equations are still
  ;; recognized and faced (markup protected), but no image is overlaid and
  ;; conversion never errors — the raw LaTeX simply shows as faced text.
  ;; (A user who doesn't want even that turns `agent-shell-math-renderer-mode'
  ;; off; there is deliberately no PNG fallback.)
  (agent-shell-math-renderer-tests--enabled
    (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) nil))
              ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      ;; Block-level display math: faced, no image.
      (should (equal (agent-shell-markdown--deconstruct
                      (agent-shell-markdown-convert "\\[ E=mc^2 \\]"))
                     '(("\\[ E=mc^2 \\]" (agent-shell-math-renderer)))))
      ;; Inline math: faced, and crucially no `display' image property
      ;; anywhere (nothing was overlaid).
      (let ((out (agent-shell-markdown-convert "a \\(x^2\\) b")))
        (should (equal (agent-shell-markdown--deconstruct out)
                       '(("a " nil)
                         ("\\(x^2\\)" (agent-shell-math-renderer))
                         (" b" nil))))
        (should-not (text-property-not-all 0 (length out) 'display nil out))))))

(ert-deftest agent-shell-math-renderer-refresh-buffer-revisits-each-region ()
  ;; A refresh hands every `agent-shell-math-renderer-source' region
  ;; back to --math-render (with its own latex), so a theme change
  ;; re-tints all equations.  Stub --math-render to record the visits.
  (let ((calls '()))
    (cl-letf (((symbol-function 'agent-shell-math-renderer--render)
               (lambda (_buffer start end latex &optional _inline)
                 (push (list start end latex) calls))))
      (with-temp-buffer
        (insert "first eq then second eq")
        ;; Two separate math-source regions with distinct latex.
        (put-text-property 1 6 'agent-shell-math-renderer-source "A")
        (put-text-property 15 21 'agent-shell-math-renderer-source "B")
        (agent-shell-math-renderer--refresh-buffer (current-buffer))))
    (should (equal (nreverse calls)
                   '((1 6 "A") (15 21 "B"))))))

(ert-deftest agent-shell-math-renderer-help-echo-shows-latex-as-written ()
  ;; Emacs passes `help-echo' through `substitute-command-keys', which read
  ;; `\{' as a keymap and curved the apostrophe of `f'(x)'.  Compare after
  ;; that function, since that is what the user reads; the source property
  ;; stays unquoted.
  (agent-shell-math-renderer-tests--enabled
    (dolist (case '(("a \\(\\{ x \\}\\) b" . "\\{ x \\}")
                    ("a \\(f'(x)\\) b" . "f'(x)")
                    ("\\[ \\sum_i x_i \\]" . "\\sum_i x_i")))
      (let* ((out (agent-shell-markdown-convert (car case)))
             (pos (text-property-not-all
                   0 (length out) 'agent-shell-math-renderer-source nil out)))
        (should pos)
        (should (equal (cdr case)
                       (get-text-property
                        pos 'agent-shell-math-renderer-source out)))
        (should (equal (cdr case)
                       (substitute-command-keys
                        (get-text-property pos 'help-echo out))))))))

(ert-deftest agent-shell-math-renderer-inline-math-protects-markup ()
  ;; Inline `\\(...\\)' is matched anywhere on a line (not just block
  ;; level) and faced `agent-shell-math-renderer', keeping its interior
  ;; literal (here `**x**' is not turned bold).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "a \\( **x** \\) b"))
                   '(("a " nil)
                     ("\\( **x** \\)" (agent-shell-math-renderer))
                     (" b" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-multiple-per-line ()
  ;; Several inline spans on one line each render independently.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "\\(a\\) and \\(b\\)"))
                   '(("\\(a\\)" (agent-shell-math-renderer))
                     (" and " nil)
                     ("\\(b\\)" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-escaped-inline-delimiters-untouched ()
  ;; Regression: an escaped opener `\\\\(' is a literal backslash plus `(',
  ;; markdown for showing `\\(' rather than opening math.  The scan used to
  ;; match from the SECOND backslash, claiming `\\(t=0\\)' as math with the
  ;; broken body `t=0\\'.  It must stay text (agent-shell's escape pass
  ;; later unescapes it to `\\(t=0\\)'), while a real `\\(x\\)' alongside it
  ;; still renders.
  (agent-shell-math-renderer-tests--enabled
    (let ((rendered
           (agent-shell-markdown-convert
            "literal \\\\(t=0\\\\), math \\(x\\)")))
      (should-not
       (get-text-property (string-match "t=0" rendered)
                          'agent-shell-math-renderer-source rendered))
      ;; The literal survives as visible text, unescaped exactly once.
      (should (string-prefix-p "literal \\(t=0\\), "
                               (substring-no-properties rendered)))
      (should
       (equal (get-text-property (string-match "x" rendered)
                                 'agent-shell-math-renderer-source rendered)
              "x")))))

(ert-deftest agent-shell-math-renderer-escaped-inline-closer-skipped ()
  ;; The same rule applies to the closer: an escaped `\\\\)' is body, not the
  ;; end of the span, so the search continues to the real `\\)'.  (Markdown
  ;; escaping is applied uniformly, so the body reaches LaTeX as `a\\\\)b' —
  ;; a line break followed by a paren.)
  (with-temp-buffer
    (insert "\\(a\\\\)b\\)")
    (let* ((span (car (agent-shell-math-renderer--inline-spans)))
           (start (+ (plist-get span :start) (plist-get span :open)))
           (end (- (plist-get span :end) (plist-get span :close))))
      (should (equal (buffer-substring-no-properties start end)
                     "a\\\\)b")))))

(ert-deftest agent-shell-math-renderer-escaped-inline-tail-no-watermark ()
  ;; An escaped opener is no opener, so there is no still-streaming inline
  ;; tail: `--inline-tail' must return nil rather than hold the frontier
  ;; (which would also keep the escape pass from ever unescaping the
  ;; literal).
  (with-temp-buffer
    (insert "\\\\(t=0")
    (should-not (agent-shell-math-renderer--inline-tail nil))))

(ert-deftest agent-shell-math-renderer-inline-math-in-inline-code-untouched ()
  ;; A `\\(...\\)' inside an inline-code span is literal code, not math:
  ;; it keeps the inline-code face and gets no math face.
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-markdown--deconstruct
                 (agent-shell-markdown-convert "`\\(x\\)`"))))
      (should-not (seq-some (lambda (run)
                              (memq 'agent-shell-math-renderer (cadr run)))
                            runs))
      (should (seq-some (lambda (run)
                          (memq 'agent-shell-markdown-inline-code (cadr run)))
                        runs)))))

(ert-deftest agent-shell-math-renderer-inline-math-beside-inline-code ()
  ;; With both a backticked `\\(x\\)' (literal code) and a real `\\(y\\)'
  ;; on one line, only the real one renders as math — the code span keeps
  ;; its inline-code face and gets no math face.  Exercises the
  ;; `:inline-code-ranges' avoid-range: it must exclude the code span
  ;; *without* swallowing the real math beside it.
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-markdown--deconstruct
                 (agent-shell-markdown-convert "`\\(x\\)` and \\(y\\)"))))
      ;; The code span's body is inline-code faced, never math.
      (should (seq-some (lambda (run)
                          (and (member "\\(x\\)" (list (car run)))
                               (memq 'agent-shell-markdown-inline-code (cadr run))))
                        runs))
      ;; The real math span is math faced.
      (should (seq-some (lambda (run)
                          (and (equal (car run) "\\(y\\)")
                               (memq 'agent-shell-math-renderer (cadr run))))
                        runs)))))

(ert-deftest agent-shell-math-renderer-inline-math-in-fenced-block-untouched ()
  ;; A `\\(...\\)' inside a fenced code block is body text, not math.
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-markdown--deconstruct
                 (agent-shell-markdown-convert "```
\\(x\\)
```"))))
      (should-not (seq-some (lambda (run)
                              (memq 'agent-shell-math-renderer (cadr run)))
                            runs)))))

(ert-deftest agent-shell-math-renderer-inline-math-closer-must-be-same-line ()
  ;; The closer must be on the opener's line; a `\\(' whose `\\)' is on a
  ;; later line is not matched (left as plain text), which bounds the
  ;; single-line inline form.
  ;; Unclaimed, the `\(' / `\)' show unescaped as `(' / `)'
  ;; (agent-shell 0.66.1+ CommonMark backslash-unescaping).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "\\(
x
\\)"))
                   '(("(
x
)" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-streaming-tail ()
  ;; An unclosed `\\(' on the buffer's last line is left raw (the closer
  ;; may still stream in); the start-of-last-line watermark re-scans it.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "text \\(E=mc^2"))
                   '(("text \\(E=mc^2" nil))))))

(defun agent-shell-math-renderer-tests--stream (text step)
  "Feed TEXT into a temp buffer STEP chars at a time, rendering each time.
Mimics agent-shell streaming: text is appended in chunks and
`agent-shell-markdown-replace-markup' runs after every chunk, so the
watermark drives incremental rendering.  Returns the buffer string."
  (with-temp-buffer
    (let ((i 0) (n (length text)))
      (while (< i n)
        (let ((end (min n (+ i step))))
          (goto-char (point-max))
          (insert (substring text i end))
          (setq i end))
        (agent-shell-markdown-replace-markup)))
    (buffer-string)))

(ert-deftest agent-shell-math-renderer-streaming-display-block-after-link ()
  ;; Regression: a display block whose opener sits just below a Markdown
  ;; link must still render when streamed.  Our hook runs BEFORE
  ;; agent-shell's link pass, which deletes the `](url)' markup later in
  ;; the same pass; the open-block watermark must track that deletion (a
  ;; marker, not a stale integer) or the frontier stamps past the `\['
  ;; and the completed block is never re-scanned -- left frozen but
  ;; unrendered.  Stream at several chunk sizes to hit the boundary that
  ;; splits the block across chunks.
  (agent-shell-math-renderer-tests--enabled
    (dolist (step '(1 5 11 40 100))
      (let ((rendered
             (agent-shell-math-renderer-tests--stream
              "fit to [Dalibard theory, Eq. (3)](https://example.com/a/b/c/d/e#L181):

\\[
T=T_0+\\frac{a}{b}
\\]

after text.
"
              step)))
        (should (equal (get-text-property (string-match "T=T_0" rendered)
                                          'agent-shell-math-renderer-source
                                          rendered)
                       "T=T_0+\\frac{a}{b}"))))))

(ert-deftest agent-shell-math-renderer-streaming-inline-across-chunks ()
  ;; Regression: inline `\(...\)' whose opener and closer arrive in
  ;; different streaming chunks must still render.  agent-shell 0.66.1+
  ;; unescapes an unclaimed `\(' (`\(' -> `(') during its CommonMark
  ;; escape pass, which would destroy the opener before the closer
  ;; streams in.  The watermark `--inline-tail' returns at the still-open
  ;; opener makes agent-shell (0.89.4+) leave the tail alone for the rest
  ;; of the chunk, so the delimiter survives and the completed span
  ;; renders.  Stream at several chunk sizes to hit the boundary that
  ;; splits the span.
  (agent-shell-math-renderer-tests--enabled
    (dolist (step '(1 2 3 5 40 100))
      (let ((rendered
             (agent-shell-math-renderer-tests--stream
              "text \\(E=mc^2\\) done" step)))
        ;; The completed span renders (source metadata present) ...
        (should (equal (get-text-property (string-match "E=mc" rendered)
                                          'agent-shell-math-renderer-source
                                          rendered)
                       "E=mc^2"))
        ;; ... and the raw LaTeX delimiters are kept (not unescaped away).
        (should (string-match-p "\\\\(E=mc\\^2\\\\)" rendered))))))

(ert-deftest agent-shell-math-renderer-inline-math-can-be-disabled ()
  ;; `agent-shell-math-renderer-render-inline' nil disables `\\(...\\)'
  ;; even with the master switch on: delimiters are plain and inner
  ;; markup (`**x**') is processed normally.
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
            (agent-shell-math-renderer-render-inline nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "a \\( **x** \\) b"))
                   '(("a ( " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" ) b" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-master-switch-off ()
  ;; With the master switch off, inline `\\(...\\)' is plain text and
  ;; inner markup is processed (here `**x**' becomes bold).  The
  ;; unclaimed `\(' / `\)' show unescaped as `(' / `)' (agent-shell
  ;; 0.66.1+ CommonMark backslash-unescaping).
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "a \\( **x** \\) b"))
                   '(("a ( " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" ) b" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-tags-source-and-inline ()
  ;; Inline math stashes its source and the inline flag, while display
  ;; math stashes its source with the flag nil — so a refresh re-renders
  ;; each in the right style.
  (agent-shell-math-renderer-tests--enabled
    (let ((inline (agent-shell-markdown-convert "a \\(x\\) b"))
          (display (agent-shell-markdown-convert "\\[ x \\]")))
      (should (equal (get-text-property 2 'agent-shell-math-renderer-source inline)
                     "x"))
      (should (get-text-property 2 'agent-shell-math-renderer-inline inline))
      (should (equal (get-text-property 0 'agent-shell-math-renderer-source display)
                     "x"))
      (should-not (get-text-property 0 'agent-shell-math-renderer-inline display)))))

(defmacro agent-shell-math-renderer-tests--with-appearance (x-height &rest body)
  "Evaluate BODY with the buffer shown on a graphical frame.
The `default' face there is #000000 on #ffffff and the x-height of its
font is X-HEIGHT, which is what `agent-shell-math-renderer--appearance'
reads."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
              (lambda (&rest _) (selected-frame)))
             ((symbol-function 'face-foreground) (lambda (&rest _) "#000000"))
             ((symbol-function 'face-background) (lambda (&rest _) "#ffffff"))
             ((symbol-function 'agent-shell-math-renderer--x-height)
              (lambda (&rest _) ,x-height)))
     ,@body))

(ert-deftest agent-shell-math-renderer-refresh-if-changed-detects-font ()
  ;; `--refresh-if-changed' triggers a refresh when only the x-height
  ;; moved (colors unchanged), and targets just the current buffer (the
  ;; one the hook made relevant) rather than every buffer.
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
            (refreshed nil))
    (with-temp-buffer
      (setq agent-shell-math-renderer--present t)
      ;; Buffer was last rendered at x-height 20; same colors.
      (setq agent-shell-math-renderer--rendered-appearance
            '("#000000" "#ffffff" 20))
      (agent-shell-math-renderer-tests--with-appearance 30
        (cl-letf (((symbol-function 'agent-shell-math-renderer-refresh)
                   (lambda (&optional buffer) (setq refreshed (or buffer t)))))
          (agent-shell-math-renderer--refresh-if-changed)))
      ;; Refreshed, and scoped to this buffer.
      (should (eq refreshed (current-buffer)))
      ;; At the recorded size nothing changed, so nothing is refreshed.
      (setq refreshed nil)
      (agent-shell-math-renderer-tests--with-appearance 20
        (cl-letf (((symbol-function 'agent-shell-math-renderer-refresh)
                   (lambda (&optional buffer) (setq refreshed (or buffer t)))))
          (agent-shell-math-renderer--refresh-if-changed)))
      (should-not refreshed))))

(ert-deftest agent-shell-math-renderer-x-height-is-size-times-ratio ()
  ;; The x-height is the pixel size of the `default' face's font, slot 2 of
  ;; `font-info', times the ratio of its x's ascent to its size, read with
  ;; the font opened at 1000 pixels.
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
               (lambda (&rest _) (selected-frame)))
              ((symbol-function 'face-font) (lambda (&rest _) "some-font"))
              ((symbol-function 'font-info)
               (lambda (name &rest _)
                 (and (equal name "some-font") (vector name name 18 23))))
              ((symbol-function 'find-font) (lambda (&rest _) 'entity))
              ((symbol-function 'open-font)
               (lambda (entity size &rest _)
                 (should (eq entity 'entity))
                 (should (= size 1000))
                 'font-at-1000))
              ((symbol-function 'font-get-glyphs)
               (lambda (font &rest _)
                 (should (eq font 'font-at-1000))
                 ;; FROM TO C CODE LBEARING RBEARING WIDTH ASCENT DESCENT
                 (vector (vector 0 0 ?x 91 40 560 600 550 0)))))
      (should (= (* 18 0.55) (agent-shell-math-renderer--x-height))))))

(ert-deftest agent-shell-math-renderer-x-height-reports-unmeasurable-font ()
  ;; A font the frame cannot open, or one with no x glyph, leaves the
  ;; x-height unknown, so the backend defers sizing -- but it is reported,
  ;; once per buffer, never swallowed.
  (dolist (stubs (list (list (cons 'font-info #'ignore))
                       (list (cons 'font-info
                                   (lambda (name &rest _) (vector name name 18 23)))
                             (cons 'agent-shell-math-renderer--x-height-ratio
                                   #'ignore))))
    (let ((warnings 0)
          (originals (mapcar (lambda (stub) (cons (car stub)
                                                  (symbol-function (car stub))))
                             stubs)))
      (unwind-protect
          (progn
            (dolist (stub stubs) (fset (car stub) (cdr stub)))
            (with-temp-buffer
              (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
                         (lambda (&rest _) (selected-frame)))
                        ((symbol-function 'face-font) (lambda (&rest _) "some-font"))
                        ((symbol-function 'display-warning)
                         (lambda (&rest _) (cl-incf warnings))))
                (should-not (agent-shell-math-renderer--x-height))
                (should-not (agent-shell-math-renderer--x-height))
                ;; One diagnosis for the buffer, not one per equation.
                (should (= 1 warnings)))))
        (dolist (original originals) (fset (car original) (cdr original)))))))

(ert-deftest agent-shell-math-renderer-refresh-if-changed-skips-non-present ()
  ;; In a buffer with no equations (`--present' nil), a hook firing is a
  ;; no-op even if the appearance differs — nothing to re-render.
  (cl-letf (((default-value 'agent-shell-math-renderer-mode) t)
            (refreshed nil))
    (with-temp-buffer
      (setq agent-shell-math-renderer--present nil)
      (setq agent-shell-math-renderer--rendered-appearance nil)
      (agent-shell-math-renderer-tests--with-appearance 30
        (cl-letf (((symbol-function 'agent-shell-math-renderer-refresh)
                   (lambda (&optional _buffer) (setq refreshed t))))
          (agent-shell-math-renderer--refresh-if-changed)))
      (should-not refreshed))))

(ert-deftest agent-shell-math-renderer-centers-display-math-only ()
  ;; Centering is a display-time indent: the line carrying a display
  ;; equation gets a `line-prefix' stretch reaching the window center less
  ;; half the image.  Inline math belongs in the run of text, so it keeps
  ;; whatever indentation agent-shell gave it.
  (let ((agent-shell-math-renderer-center-display-math t))
    (with-temp-buffer
      (insert "xx")
      ;; Display math: the stretch names the image, so redisplay can size it
      ;; without anyone measuring the SVG.
      (agent-shell-math-renderer--overlay-image
       (current-buffer) (point-min) (point-max) 'fake-image nil)
      (should (equal (get-text-property (point-min) 'display) 'fake-image))
      (should (equal (get-text-property (point-min) 'line-prefix)
                     '(space :align-to (- center (0.5 . fake-image)))))))
  (let ((agent-shell-math-renderer-center-display-math t))
    (with-temp-buffer
      (insert "xx")
      ;; Inline: not centered, and the surrounding indentation is preserved.
      (put-text-property (point-min) (point-max) 'line-prefix "  ")
      (agent-shell-math-renderer--overlay-image
       (current-buffer) (point-min) (point-max) 'fake-image t)
      (should (equal (get-text-property (point-min) 'line-prefix) "  ")))))

(ert-deftest agent-shell-math-renderer-centering-off-preserves-indent ()
  ;; Off (the default), the region's own `line-prefix' / `wrap-prefix' are
  ;; carried as before -- agent-shell's indentation must survive a render.
  (should-not agent-shell-math-renderer-center-display-math)
  (with-temp-buffer
    (insert "xx")
    (put-text-property (point-min) (point-max) 'line-prefix "  ")
    (put-text-property (point-min) (point-max) 'wrap-prefix "    ")
    (agent-shell-math-renderer--overlay-image
     (current-buffer) (point-min) (point-max) 'fake-image nil)
    (should (equal (get-text-property (point-min) 'line-prefix) "  "))
    (should (equal (get-text-property (point-min) 'wrap-prefix) "    "))))

(ert-deftest agent-shell-math-renderer-padding-obsolete-alias-tracks-new-name ()
  ;; The pre-0.10.0 name stays usable: it is an alias for the new one, so a
  ;; config that still sets it keeps working.  (That a value set *before* this
  ;; file loads survives depends on the alias preceding the defcustom in the
  ;; source -- `defvaralias' discards a value the obsolete name already holds.)
  (should (eq (indirect-variable 'agent-shell-math-renderer-background-padding)
              'agent-shell-math-renderer-padding))
  (should (get 'agent-shell-math-renderer-background-padding
               'byte-obsolete-variable))
  (with-suppressed-warnings ((obsolete agent-shell-math-renderer-padding
                                       agent-shell-math-renderer-background-padding))
    (let ((agent-shell-math-renderer-background-padding '(0 0 0 6)))
      (should (equal agent-shell-math-renderer-padding '(0 0 0 6))))))

(ert-deftest agent-shell-math-renderer-rescale-obsolete-aliases-track-the-new-names ()
  ;; The pre-0.12.0 names `-inline-rescale' / `-display-rescale' stay usable
  ;; as obsolete aliases of `-rescale-inline' / `-rescale-display', and
  ;; setting an old name still updates the equations through the watcher on
  ;; the new one.
  (dolist (pair '((agent-shell-math-renderer-inline-rescale
                   . agent-shell-math-renderer-rescale-inline)
                  (agent-shell-math-renderer-display-rescale
                   . agent-shell-math-renderer-rescale-display)))
    (should (eq (indirect-variable (car pair)) (cdr pair)))
    (should (get (car pair) 'byte-obsolete-variable)))
  (with-suppressed-warnings ((obsolete agent-shell-math-renderer-inline-rescale))
    (let ((agent-shell-math-renderer-inline-rescale 1.3))
      (should (equal agent-shell-math-renderer-rescale-inline 1.3)))
    (let ((agent-shell-math-renderer--option-buffers nil)
          (agent-shell-math-renderer--option-defaults nil)
          (agent-shell-math-renderer--option-timer nil))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
        (with-temp-buffer
          (setq-local agent-shell-math-renderer-inline-rescale 1.3)
          (should (equal agent-shell-math-renderer--option-buffers
                         (list (current-buffer)))))))))

(defconst agent-shell-math-renderer-tests--default-foreground "#cbe3e7"
  "The foreground of the `default' face in the tests that stub it.")

(defun agent-shell-math-renderer-tests--check-colors (keys)
  "Signal an error unless KEYS meet `latex-to-svg-backend' 0.14.0.
That is: `:color' and `:background' are nil or `#rrggbb' strings,
`:x-height' is nil or a positive number, and `:color' is non-nil
whenever `:x-height' is.  The removed `:font-size' and `:font-height'
are errors."
  (let ((hex "\\`#[[:xdigit:]]\\{6\\}\\'"))
    (dolist (key '(:color :background))
      (let ((value (plist-get keys key)))
        (when (and value (not (and (stringp value) (string-match-p hex value))))
          (error "%s is not a #rrggbb string: %S" key value))))
    (dolist (key '(:font-size :font-height))
      (when (plist-member keys key)
        (error "%s is removed: pass :x-height" key)))
    (let ((x-height (plist-get keys :x-height)))
      (unless (or (null x-height) (and (numberp x-height) (> x-height 0)))
        (error ":x-height is not a positive number: %S" x-height))
      (when (and x-height (not (plist-get keys :color)))
        (error ":color is nil with :x-height %S" x-height)))))

(defmacro agent-shell-math-renderer-tests--with-backend-calls (var &rest body)
  "Evaluate BODY with `latex-to-svg-backend' stubbed, recording into VAR.
Each call pushes (LATEX . KEYS) onto VAR and returns nil, so every
render takes the async path, and signals as the backend does when the
colors break its contract (`agent-shell-math-renderer-tests--check-colors').
Nothing is overlaid.  Some frame is graphical, and the buffer is shown
on the selected frame, with
a fixed x-height and `default' foreground
\(`agent-shell-math-renderer-tests--default-foreground'), so no
graphical frame is needed."
  (declare (indent 1) (debug t))
  `(let ((,var '())
         (face-foreground (symbol-function 'face-foreground)))
     (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'always)
               ((symbol-function 'agent-shell-math-renderer--graphical-p)
                #'always)
               ((symbol-function 'agent-shell-math-renderer--display-frame)
                (lambda (&rest _) (selected-frame)))
               ((symbol-function 'agent-shell-math-renderer--x-height)
                (lambda (&rest _) 20))
               ((symbol-function 'face-foreground)
                (lambda (face &rest args)
                  (if (eq face 'default)
                      agent-shell-math-renderer-tests--default-foreground
                    (apply face-foreground face args))))
               ((symbol-function 'agent-shell-math-renderer--appearance)
                #'ignore)
               ((symbol-function 'agent-shell-math-renderer--overlay-image)
                #'ignore)
               ((symbol-function 'latex-to-svg-backend)
                (lambda (latex &rest keys)
                  (agent-shell-math-renderer-tests--check-colors keys)
                  (push (cons latex keys) ,var)
                  nil)))
       ,@body)))

(ert-deftest agent-shell-math-renderer-padding-by-kind ()
  ;; Inline and display math take their own padding, on the first render and
  ;; on a refresh.  A kind whose option is nil takes the obsolete
  ;; `agent-shell-math-renderer-padding', so an old config still pads both;
  ;; an explicit 0 does not fall back.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (with-temp-buffer
      (insert "display inline")
      (put-text-property 1 8 'agent-shell-math-renderer-source "a")
      (put-text-property 9 15 'agent-shell-math-renderer-source "b")
      (put-text-property 9 15 'agent-shell-math-renderer-inline t)
      (with-suppressed-warnings ((obsolete agent-shell-math-renderer-padding))
        (dolist (case '((2 6 nil (("$b$" . 2) ("\\[ a \\]" . 6)))
                        (nil nil (4 0 4 0) (("$b$" . (4 0 4 0))
                                            ("\\[ a \\]" . (4 0 4 0))))
                        (0 nil 5 (("$b$" . 0) ("\\[ a \\]" . 5)))))
          (let ((agent-shell-math-renderer-padding-inline (nth 0 case))
                (agent-shell-math-renderer-padding-display (nth 1 case))
                (agent-shell-math-renderer-padding (nth 2 case))
                (paddings (lambda ()
                            (sort (delete-dups
                                   (mapcar (lambda (c)
                                             (cons (car c)
                                                   (plist-get (cdr c) :padding)))
                                           calls))
                                  (lambda (x y) (string< (car x) (car y)))))))
            (setq calls nil)
            (agent-shell-math-renderer--render (current-buffer) 9 15 "b" t)
            (agent-shell-math-renderer--render (current-buffer) 1 8 "a")
            (should (equal (funcall paddings) (nth 3 case)))
            (setq calls nil)
            (agent-shell-math-renderer--refresh-buffer (current-buffer))
            (should (equal (funcall paddings) (nth 3 case)))))))))

(ert-deftest agent-shell-math-renderer-padding-is-obsolete ()
  ;; The one option for both kinds is obsolete; the two per kind are watched,
  ;; like the other appearance options.
  (should (get 'agent-shell-math-renderer-padding 'byte-obsolete-variable))
  (dolist (option '(agent-shell-math-renderer-padding-inline
                    agent-shell-math-renderer-padding-display
                    agent-shell-math-renderer-rescale-inline
                    agent-shell-math-renderer-rescale-display))
    (should (memq option agent-shell-math-renderer--watched-options))))

(ert-deftest agent-shell-math-renderer-padding-safe-matches-the-backend ()
  ;; A file-local padding is hand-written Lisp, so the `:safe' predicate
  ;; accepts every shape the backend takes (1-4 numbers) and nothing else --
  ;; a value Customize cannot express must still not need a y/n prompt.
  (dolist (option '(agent-shell-math-renderer-padding
                    agent-shell-math-renderer-padding-inline
                    agent-shell-math-renderer-padding-display))
    (let ((safe (get option 'safe-local-variable)))
      (should safe)
      (dolist (ok (list nil 3 3.5 '(0 0 0 6) '(2 6) '(1 2 3)))
        (should (funcall safe ok)))
      (dolist (bad (list "3" '(1 2 3 4 5) '(1 "2") 'x))
        (should-not (funcall safe bad))))))

(ert-deftest agent-shell-math-renderer-engine-passed-to-every-backend-call ()
  ;; The first request, the scheduled compile and the callback's re-query all
  ;; pass `:engine'.  The callback uses the engine captured at scheduling, so
  ;; changing the option while the compile runs does not change it.
  (dolist (engine '(ratex texres))
    (agent-shell-math-renderer-tests--with-backend-calls calls
      (with-temp-buffer
        (insert "xx")
        (let ((agent-shell-math-renderer-engine engine))
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "x"))
        (should (= 2 (length calls)))
        (let ((callback (plist-get (cdar calls) :callback))
              (agent-shell-math-renderer-engine 'latex))
          (funcall callback nil))
        (should (= 3 (length calls)))
        (dolist (call calls)
          (should (eq engine (plist-get (cdr call) :engine))))))))

(ert-deftest agent-shell-math-renderer-fallback-per-engine ()
  ;; `:fallback' is `latex' for `ratex', nil for `latex' and `texres', and nil
  ;; with the option off, at every call.  An equation texres rejects has a
  ;; LaTeX error that `latex' rejects too.
  (dolist (case '((ratex t latex) (latex t nil) (texres t nil) (ratex nil nil)))
    (agent-shell-math-renderer-tests--with-backend-calls calls
      (with-temp-buffer
        (insert "xx")
        (let ((agent-shell-math-renderer-engine (nth 0 case))
              (agent-shell-math-renderer-fallback (nth 1 case)))
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "x"))
        (should (= 2 (length calls)))
        (dolist (call calls)
          (should (eq (nth 2 case) (plist-get (cdr call) :fallback))))))))

(ert-deftest agent-shell-math-renderer-fallback-captured-at-scheduling ()
  ;; The callback's call uses the fallback read when the compile was
  ;; scheduled, not the option's value when the compile finishes.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (with-temp-buffer
      (insert "xx")
      (let ((agent-shell-math-renderer-engine 'ratex)
            (agent-shell-math-renderer-fallback t))
        (agent-shell-math-renderer--render
         (current-buffer) (point-min) (point-max) "x"))
      (let ((callback (plist-get (cdar calls) :callback))
            (agent-shell-math-renderer-fallback nil))
        (funcall callback nil))
      (should (= 3 (length calls)))
      (should (eq 'latex (plist-get (cdar calls) :fallback))))))

(ert-deftest agent-shell-math-renderer-quiet-passed-to-every-backend-call ()
  ;; `:quiet' is nil by default and t when the option is set, at every call,
  ;; the callback's included.
  (should-not (default-value 'agent-shell-math-renderer-quiet))
  (dolist (quiet '(nil t))
    (agent-shell-math-renderer-tests--with-backend-calls calls
      (with-temp-buffer
        (insert "xx")
        (let ((agent-shell-math-renderer-quiet quiet))
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "x"))
        (funcall (plist-get (cdar calls) :callback) nil)
        (should (= 3 (length calls)))
        (dolist (call calls)
          (should (eq quiet (plist-get (cdr call) :quiet))))))))

(ert-deftest agent-shell-math-renderer-colors-are-hex-at-every-call ()
  ;; `:color' is the option, or the `default' foreground on the frame that
  ;; shows the buffer when the option is nil, and `:background' the option;
  ;; each as `#rrggbb', a name resolved on that frame, at every call, the
  ;; callback's included.
  (dolist (case `((nil nil ,agent-shell-math-renderer-tests--default-foreground nil)
                  ("#123456" nil "#123456" nil)
                  ("orange" "gray97" "#ff8000" "#f7f7f7")))
    (agent-shell-math-renderer-tests--with-backend-calls calls
      (cl-letf (((symbol-function 'color-values)
                 (lambda (color &rest _)
                   (pcase color
                     ("orange" '(65535 32896 0))
                     ("gray97" '(63479 63479 63479))))))
        (with-temp-buffer
          (insert "xx")
          (let ((agent-shell-math-renderer-foreground-color (nth 0 case))
                (agent-shell-math-renderer-background-color (nth 1 case)))
            (agent-shell-math-renderer--render
             (current-buffer) (point-min) (point-max) "x" t)
            (funcall (plist-get (cdar calls) :callback) nil))
          (should (= 3 (length calls)))
          (dolist (call calls)
            (should (equal (nth 2 case) (plist-get (cdr call) :color)))
            (should (equal (nth 3 case) (plist-get (cdr call) :background)))))))))

(ert-deftest agent-shell-math-renderer-callback-reads-colors-again ()
  ;; A buffer shown nowhere when the compile is scheduled, in a graphical
  ;; session, is rendered with no color and no size; shown when the compile
  ;; ends, the callback reads both on the frame that shows it then, so the
  ;; backend never sees a size without a color.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (let ((shown nil))
      (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
                 (lambda (&rest _) (and shown (selected-frame))))
                ((symbol-function 'agent-shell-math-renderer--x-height)
                 (lambda (&rest _) (and shown 20))))
        (with-temp-buffer
          (insert "xx")
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "x")
          (dolist (call calls)
            (should-not (plist-get (cdr call) :color))
            (should-not (plist-get (cdr call) :x-height)))
          (setq shown t)
          (funcall (plist-get (cdar calls) :callback) nil)
          (should (= 3 (length calls)))
          (should (equal agent-shell-math-renderer-tests--default-foreground
                         (plist-get (cdar calls) :color)))
          (should (= 20 (plist-get (cdar calls) :x-height))))))))

(ert-deftest agent-shell-math-renderer-failure-leaves-source ()
  ;; A callback called with a failure plist does not call the backend
  ;; again, and leaves the source in the buffer with no image over it.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (with-temp-buffer
      (insert "\\(\\notacommand\\)")
      (agent-shell-math-renderer--render
       (current-buffer) (point-min) (point-max) "\\notacommand" t)
      (should (= 2 (length calls)))
      (funcall (plist-get (cdar calls) :callback)
               '(:kind formula :engine latex
                 :message "Undefined control sequence." :line 1 :column 13
                 :log nil :program nil))
      (should (= 2 (length calls)))
      (should (equal "\\(\\notacommand\\)" (buffer-string)))
      (should-not (get-text-property (point-min) 'display)))))

;; What the backend passes the callback when LaTeX rejects an equation.
(defconst agent-shell-math-renderer-tests--failure
  '(:kind formula :engine latex :message "Undefined control sequence"
    :line 1 :column 13 :log "/tmp/asmr-tests.log" :program nil))

(defmacro agent-shell-math-renderer-tests--with-failed-equation (calls &rest body)
  "Evaluate BODY in a buffer holding one equation whose request failed.
The equation is `\\(\\notacommand\\)', rendered with the backend
stubbed (see `agent-shell-math-renderer-tests--with-backend-calls',
which binds CALLS), and its callback called with
`agent-shell-math-renderer-tests--failure'."
  (declare (indent 1) (debug t))
  `(agent-shell-math-renderer-tests--with-backend-calls ,calls
     (with-temp-buffer
       (insert "\\(\\notacommand\\)")
       (add-text-properties
        (point-min) (point-max)
        '(agent-shell-math-renderer-source "\\notacommand"
          help-echo "\\=\\notacommand"))
       (agent-shell-math-renderer--render
        (current-buffer) (point-min) (point-max) "\\notacommand" t)
       (funcall (plist-get (cdar ,calls) :callback)
                agent-shell-math-renderer-tests--failure)
       ,@body)))

(defun agent-shell-math-renderer-tests--failure-marks ()
  "Return the failure marks in the current buffer."
  (seq-filter (lambda (ov) (overlay-get ov 'agent-shell-math-renderer-failure))
              (overlays-in (point-min) (point-max))))

(ert-deftest agent-shell-math-renderer-failure-help-echo ()
  ;; `help-echo' names the engine and gives the message, as written:
  ;; Emacs runs it through `substitute-command-keys'.  It does not name
  ;; the log: `agent-shell-math-renderer-show-error-log' opens it.
  (dolist (case
           `((,agent-shell-math-renderer-tests--failure
              . "LaTeX could not typeset it: Undefined control sequence.")
             ;; In a tooltip, the command that opens the log follows.
             ((tooltip . ,agent-shell-math-renderer-tests--failure)
              . ,(concat "LaTeX could not typeset it: Undefined control "
                         "sequence. Call M-x "
                         "agent-shell-math-renderer-show-error-log with point "
                         "in the equation to open the log."))
             ((:kind formula :engine ratex :message "Unknown command `\\x'")
              . "RaTeX could not parse it: Unknown command `\\x'.")
             ((:kind formula :engine ratex :message "Unexpected end!")
              . "RaTeX could not parse it: Unexpected end!")
             ((:kind formula :engine texres)
              . "texres could not typeset it.")
             ((:kind setup :engine texres :program "pdftocairo"
               :message "The texres engine could not run `pdftocairo': program not found.")
              . "The texres engine could not run `pdftocairo': program not found.")))
    (should (equal (substitute-command-keys
                    (if (eq (caar case) 'tooltip)
                        (agent-shell-math-renderer--failure-help-echo
                         (cdar case) t)
                      (agent-shell-math-renderer--failure-help-echo (car case))))
                   (cdr case)))))

(ert-deftest agent-shell-math-renderer-failure-mark ()
  ;; A failed equation gets the icon before its source, with the tooltip
  ;; of the source.  The next render removes the mark and gives the source
  ;; its own tooltip back; with the option off, no mark is shown.
  (agent-shell-math-renderer-tests--with-failed-equation calls
    (let* ((marks (agent-shell-math-renderer-tests--failure-marks))
           (mark (overlay-get (car marks) 'before-string)))
      (should (= 1 (length marks)))
      (should (string-prefix-p
               (substring-no-properties
                (icon-string 'agent-shell-math-renderer-failure))
               mark))
      (should (equal (get-text-property 0 'help-echo mark)
                     (get-text-property (point-min) 'help-echo)))
      (should (string-suffix-p "to open the log."
                               (substitute-command-keys
                                (get-text-property (point-min) 'help-echo))))
      (should (equal (get-text-property
                      (point-min) 'agent-shell-math-renderer-failure)
                     agent-shell-math-renderer-tests--failure))
      ;; A second failure of the same equation does not add a second mark.
      (funcall (plist-get (cdar calls) :callback)
               agent-shell-math-renderer-tests--failure)
      (should (= 1 (length (agent-shell-math-renderer-tests--failure-marks)))))
    (agent-shell-math-renderer--render
     (current-buffer) (point-min) (point-max) "\\notacommand" t)
    (should-not (agent-shell-math-renderer-tests--failure-marks))
    (should-not (get-text-property (point-min) 'agent-shell-math-renderer-failure))
    (should (equal (get-text-property (point-min) 'help-echo)
                   "\\=\\notacommand"))
    (let ((agent-shell-math-renderer-failure-mark nil))
      (funcall (plist-get (cdar calls) :callback)
               agent-shell-math-renderer-tests--failure)
      (should-not (agent-shell-math-renderer-tests--failure-marks))
      (should (get-text-property
               (point-min) 'agent-shell-math-renderer-failure)))))

(ert-deftest agent-shell-math-renderer-show-error-log ()
  ;; The command opens the log of the failed equation at point.  With no
  ;; log, or a log file that is gone, it shows the error.  Elsewhere it is
  ;; an error.
  (agent-shell-math-renderer-tests--with-failed-equation calls
    (let* ((log (make-temp-file "asmr-log"))
           (opened nil)
           (messages nil)
           (fail (lambda (log)
                   (funcall (plist-get (cdar calls) :callback)
                            (plist-put (copy-sequence
                                        agent-shell-math-renderer-tests--failure)
                                       :log log)))))
      (unwind-protect
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (file) (push file opened)))
                    ((symbol-function 'message)
                     (lambda (format &rest args)
                       (push (apply #'format-message format args) messages))))
            (funcall fail log)
            (goto-char 3)
            (agent-shell-math-renderer-show-error-log)
            (should (equal opened (list log)))
            (dolist (gone (list nil (concat log ".gone")))
              (funcall fail gone)
              (agent-shell-math-renderer-show-error-log)
              (should (string-prefix-p "LaTeX could not typeset it: Undefined"
                                       (car messages))))
            (should (= (length opened) 1))
            (goto-char (point-max))
            (should-error (agent-shell-math-renderer-show-error-log)
                          :type 'user-error))
        (delete-file log)))))

(ert-deftest agent-shell-math-renderer-no-render-without-graphical-frame ()
  ;; With no graphical frame the backend is not called and the signature is
  ;; cleared, so the display hook renders the buffer once a graphical window
  ;; shows it, even with the appearance it was rendered for before.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (cl-letf (((symbol-function 'agent-shell-math-renderer--graphical-p)
               #'ignore)
              ((symbol-function 'agent-shell-math-renderer--display-frame)
               #'ignore)
              ((symbol-function 'agent-shell-math-renderer--x-height)
               #'ignore))
      (with-temp-buffer
        (insert "xx")
        (setq agent-shell-math-renderer--present t
              agent-shell-math-renderer--rendered-appearance '("#111111" "#eeeeee" 20))
        (agent-shell-math-renderer--render
         (current-buffer) (point-min) (point-max) "x")
        (should-not calls)
        (should-not agent-shell-math-renderer--rendered-appearance)
        (let ((refreshed nil))
          (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
                     (lambda (&rest _) (selected-frame)))
                    ((symbol-function 'agent-shell-math-renderer--appearance)
                     (lambda (&rest _) '("#111111" "#eeeeee" 20)))
                    ((symbol-function 'agent-shell-math-renderer-refresh)
                     (lambda (&rest _) (setq refreshed t))))
            (agent-shell-math-renderer--refresh-if-changed))
          (should refreshed))))))

(ert-deftest agent-shell-math-renderer-refresh-needs-a-graphical-window ()
  ;; While no graphical window shows the buffer nothing can be drawn, so the
  ;; refresh does not walk its equations, though the signature differs.
  (with-temp-buffer
    (setq agent-shell-math-renderer--present t
          agent-shell-math-renderer--rendered-appearance nil)
    (let ((refreshed nil))
      (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
                 #'ignore)
                ((symbol-function 'agent-shell-math-renderer--x-height)
                 #'ignore)
                ((symbol-function 'agent-shell-math-renderer-refresh)
                 (lambda (&rest _) (setq refreshed t))))
        (agent-shell-math-renderer--refresh-if-changed))
      (should-not refreshed))))

(ert-deftest agent-shell-math-renderer-buried-buffer-renders-in-graphical-session ()
  ;; A buffer no window shows, while some frame is graphical, is compiled
  ;; ahead: the backend is called with no color and no size, and returns
  ;; no image until the buffer is shown.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
               #'ignore)
              ((symbol-function 'agent-shell-math-renderer--x-height)
               #'ignore))
      (with-temp-buffer
        (insert "xx")
        (agent-shell-math-renderer--render
         (current-buffer) (point-min) (point-max) "x")
        (should (= 2 (length calls)))
        (dolist (call calls)
          (should-not (plist-get (cdr call) :color))
          (should-not (plist-get (cdr call) :x-height)))))))

(ert-deftest agent-shell-math-renderer-graphical-p-reads-every-frame ()
  ;; Non-nil when any live frame is graphical, whichever is selected.
  (cl-letf (((symbol-function 'frame-list) (lambda () '(tty gui)))
            ((symbol-function 'display-graphic-p)
             (lambda (&optional frame) (eq frame 'gui))))
    (should (agent-shell-math-renderer--graphical-p)))
  (cl-letf (((symbol-function 'frame-list) (lambda () '(tty other-tty)))
            ((symbol-function 'display-graphic-p) #'ignore))
    (should-not (agent-shell-math-renderer--graphical-p))))

(ert-deftest agent-shell-math-renderer-no-svg-still-calls-the-backend ()
  ;; Without SVG support the backend is still asked, so it can warn that this
  ;; Emacs cannot display SVG images; it returns no image.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'ignore))
      (with-temp-buffer
        (insert "xx")
        (agent-shell-math-renderer--render
         (current-buffer) (point-min) (point-max) "x")
        (should (= 2 (length calls)))))))

(ert-deftest agent-shell-math-renderer-unresolved-option-color-is-ignored ()
  ;; A name the frame cannot resolve is ignored with no warning: the
  ;; equation takes the `default' foreground.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (let ((agent-shell-math-renderer-foreground-color "no-such-color")
          (warnings 0))
      (cl-letf (((symbol-function 'color-values) #'ignore)
                ((symbol-function 'display-warning)
                 (lambda (&rest _) (cl-incf warnings))))
        (with-temp-buffer
          (insert "xx")
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "x")
          (should (= 0 warnings))
          (dolist (call calls)
            (should (equal agent-shell-math-renderer-tests--default-foreground
                           (plist-get (cdr call) :color)))))))))

(ert-deftest agent-shell-math-renderer-hex-color-rounds ()
  ;; `color-values' gives 16-bit components; each is rounded to 8 bits, so
  ;; 32896 (128.0 of 255) is 80 and so is 32768 (127.5), which truncating
  ;; would make 7f.  A `#rrggbb' string is returned as it is, and nil when
  ;; the frame cannot resolve it.
  (cl-letf (((symbol-function 'color-values)
             (lambda (color &rest _)
               (pcase color
                 ("a" '(65535 32896 0))
                 ("b" '(0 32768 257))))))
    (should (equal "#ff8000" (agent-shell-math-renderer--hex-color "a" nil)))
    (should (equal "#008001" (agent-shell-math-renderer--hex-color "b" nil)))
    (should (equal "#AbCdEf" (agent-shell-math-renderer--hex-color "#AbCdEf" nil)))
    (should-not (agent-shell-math-renderer--hex-color "c" nil))
    (should-not (agent-shell-math-renderer--hex-color nil nil))))

(ert-deftest agent-shell-math-renderer-appearance-reads-the-display-frame ()
  ;; The signature is the `default' face's colors on the frame that shows the
  ;; buffer, and the x-height measured there; nil throughout when no
  ;; graphical window shows it.
  (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
             #'ignore)
            ((symbol-function 'agent-shell-math-renderer--x-height)
             #'ignore))
    (should (equal '(nil nil nil) (agent-shell-math-renderer--appearance))))
  (cl-letf (((symbol-function 'agent-shell-math-renderer--display-frame)
             (lambda (&rest _) (selected-frame)))
            ((symbol-function 'agent-shell-math-renderer--x-height)
             (lambda (&rest _) 20))
            ((symbol-function 'face-foreground) (lambda (&rest _) "#111111"))
            ((symbol-function 'face-background) (lambda (&rest _) "#eeeeee")))
    (should (equal '("#111111" "#eeeeee" 20)
                   (agent-shell-math-renderer--appearance)))))

;;;; Equations take the color and the size of their text

(defface agent-shell-math-renderer-tests--gold '((t :foreground "gold"))
  "A test face with a foreground."
  :group 'agent-shell-math-renderer)

(defface agent-shell-math-renderer-tests--inherits-gold
  '((t :inherit agent-shell-math-renderer-tests--gold))
  "A test face whose foreground comes through `:inherit'."
  :group 'agent-shell-math-renderer)

(defconst agent-shell-math-renderer-tests--face-values
  '(nil
    bold                                  ; a face without a foreground
    agent-shell-math-renderer-tests--gold
    agent-shell-math-renderer-tests--inherits-gold
    (bold agent-shell-math-renderer-tests--gold) ; the first with one wins
    (agent-shell-math-renderer-tests--inherits-gold bold)
    (:foreground "red")
    (:weight bold :foreground "red")
    (foreground-color . "blue"))
  "Values of the `face' property our reader and Emacs's must agree on.")

(ert-deftest agent-shell-math-renderer-text-foreground-matches-emacs ()
  ;; Drift guard: on text with no overlay, `--text-foreground' gives what
  ;; Emacs's `foreground-color-at-point' gives, for the forms a `face'
  ;; property takes, from the `face' and the `font-lock-face' property.
  ;; Where ours is nil, Emacs gives the foreground of the `default' face.
  (dolist (prop '(face font-lock-face))
    (dolist (value agent-shell-math-renderer-tests--face-values)
      (with-temp-buffer
        (insert "\\(x\\)")
        (put-text-property 1 2 prop value)
        (let ((font-lock-mode (eq prop 'font-lock-face)))
          (goto-char 1)
          (should (equal (list prop value
                               (or (agent-shell-math-renderer--text-foreground 1)
                                   (face-attribute 'default :foreground)))
                         (list prop value (foreground-color-at-point)))))))))

(ert-deftest agent-shell-math-renderer-text-foreground-skips-own-face ()
  ;; The face this package puts on every equation does not decide its color,
  ;; first or last in the list; the face of the text around it does.
  (with-temp-buffer
    (insert "\\(x\\)")
    (dolist (case '((agent-shell-math-renderer . nil)
                    ((agent-shell-math-renderer) . nil)
                    ((agent-shell-math-renderer agent-shell-math-renderer-tests--gold)
                     . "gold")
                    ((agent-shell-math-renderer-tests--gold agent-shell-math-renderer)
                     . "gold")))
      (put-text-property 1 2 'face (car case))
      (should (equal (cdr case)
                     (agent-shell-math-renderer--text-foreground 1))))))

(ert-deftest agent-shell-math-renderer-text-foreground-skips-ignored-faces ()
  ;; A face in `-foreground-ignored-faces' is skipped and the next face with
  ;; a foreground is read; with none left, nil.  A face that inherits from an
  ;; ignored face is not skipped.  The option is watched, like the other
  ;; appearance options.
  (with-temp-buffer
    (insert "\\(a\\) \\(b\\) \\(c\\)")
    (put-text-property 1 2 'face '(agent-shell-math-renderer-tests--gold
                                   (:foreground "red")))
    (put-text-property 7 8 'face 'agent-shell-math-renderer-tests--gold)
    (put-text-property 13 14 'face 'agent-shell-math-renderer-tests--inherits-gold)
    (let ((agent-shell-math-renderer-foreground-ignored-faces nil))
      (should (equal (agent-shell-math-renderer--text-foreground 1) "gold"))
      (should (equal (agent-shell-math-renderer--text-foreground 7) "gold")))
    (let ((agent-shell-math-renderer-foreground-ignored-faces
           '(agent-shell-math-renderer-tests--gold)))
      (should (equal (agent-shell-math-renderer--text-foreground 1) "red"))
      (should-not (agent-shell-math-renderer--text-foreground 7))
      (should (equal (agent-shell-math-renderer--text-foreground 13) "gold"))))
  (should (memq 'agent-shell-math-renderer-foreground-ignored-faces
                agent-shell-math-renderer--watched-options)))

(defconst agent-shell-math-renderer-tests--colors
  '(("gold" 65535 55255 0)
    ("red" 65535 0 0)
    ("white" 65535 65535 65535))
  "The values `color-values' gives these names on a graphical frame.
A batch Emacs resolves a name to the nearest of its terminal's colors.")

(defmacro agent-shell-math-renderer-tests--with-frame (&rest body)
  "Run BODY with every buffer shown on the selected frame, as if graphical.
The `default' face is white on black there, `color-values' resolves the
names in `agent-shell-math-renderer-tests--colors' and `#rrggbb'
strings, and the buffer font has an x-height of 18."
  (declare (indent 0) (debug t))
  `(let ((fg (face-attribute 'default :foreground))
         (bg (face-attribute 'default :background)))
     (unwind-protect
         (progn
           (set-face-attribute 'default nil :foreground "white" :background "black")
           (cl-letf (((symbol-function 'agent-shell-math-renderer--graphical-p)
                      #'always)
                     ((symbol-function 'agent-shell-math-renderer--display-window)
                      (lambda (buffer)
                        (set-window-buffer (selected-window) buffer)
                        (selected-window)))
                     ((symbol-function 'agent-shell-math-renderer--display-frame)
                      (lambda (_buffer) (selected-frame)))
                     ((symbol-function 'agent-shell-math-renderer--x-height)
                      (lambda (&rest _) 18))
                     ((symbol-function 'color-values)
                      (lambda (color &optional _frame)
                        (if (string-match-p "\\`#[[:xdigit:]]\\{6\\}\\'" color)
                            (mapcar (lambda (i)
                                      (* 257 (string-to-number
                                              (substring color i (+ i 2)) 16)))
                                    '(1 3 5))
                          (cdr (assoc color agent-shell-math-renderer-tests--colors))))))
             ,@body))
       (set-face-attribute 'default nil :foreground fg :background bg))))

(ert-deftest agent-shell-math-renderer-foreground-for-rule ()
  ;; An equation in colored text takes the text's color.  In text with no
  ;; foreground of its own, or the `default' face's, it takes
  ;; `-foreground-color', and when that is nil the `default' face's.  Each
  ;; is a `#rrggbb' string; with no frame, nil.
  (agent-shell-math-renderer-tests--with-frame
    (with-temp-buffer
      (insert "\\(a\\) \\(b\\) \\(c\\)")
      (put-text-property 7 8 'face 'agent-shell-math-renderer-tests--gold)
      (put-text-property 13 14 'face '(:foreground "#ffffff"))
      (let ((frame (selected-frame)))
        (let ((agent-shell-math-renderer-foreground-color nil))
          (should (equal (agent-shell-math-renderer--foreground-for 1 frame) "#ffffff"))
          (should (equal (agent-shell-math-renderer--foreground-for 7 frame) "#ffd700"))
          (should (equal (agent-shell-math-renderer--foreground-for 13 frame) "#ffffff"))
          (should-not (agent-shell-math-renderer--foreground-for 7 nil)))
        (let ((agent-shell-math-renderer-foreground-color "#123456"))
          (should (equal (agent-shell-math-renderer--foreground-for 1 frame) "#123456"))
          (should (equal (agent-shell-math-renderer--foreground-for 7 frame) "#ffd700"))
          (should (equal (agent-shell-math-renderer--foreground-for 13 frame)
                         "#123456")))))))

(ert-deftest agent-shell-math-renderer-option-color-not-a-string-is-ignored ()
  ;; A value that is not a string, such as the symbol `black', is treated
  ;; as nil with no warning, like a name the frame cannot resolve; it does
  ;; not signal, which would stop every equation from being drawn.
  (agent-shell-math-renderer-tests--with-frame
    (let ((agent-shell-math-renderer-foreground-color 'black)
          (agent-shell-math-renderer-background-color 'white)
          (warnings nil)
          (frame (selected-frame)))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (with-temp-buffer
          (insert "\\(a\\)")
          (should (equal (agent-shell-math-renderer--foreground-for 1 frame)
                         "#ffffff"))
          (should-not (agent-shell-math-renderer--background-for frame))))
      (should-not warnings))))

(ert-deftest agent-shell-math-renderer-mode-checks-color-options ()
  ;; The mode warns about each color option that is not a color, each time
  ;; it turns on, and again in each buffer updated after an option is set.
  ;; A good value, or nil, gives no warning; with no graphical frame it
  ;; checks nothing.  The subscription is stubbed so a plain buffer
  ;; suffices.
  (let ((warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings)))
              ((symbol-function 'agent-shell-subscribe-to)
               (lambda (&rest _) 'token))
              ((symbol-function 'agent-shell-unsubscribe)
               (lambda (&rest _) nil)))
      (agent-shell-math-renderer-tests--with-frame
        (let ((agent-shell-math-renderer-foreground-color "no-such-color")
              (agent-shell-math-renderer-background-color 'white))
          (with-temp-buffer
            (agent-shell-math-renderer-mode 1)
            (should (= (length warnings) 2))
            (should (seq-some
                     (lambda (w)
                       (string-match-p
                        "`agent-shell-math-renderer-foreground-color' is \"no-such-color\""
                        w))
                     warnings))
            (agent-shell-math-renderer-mode -1)
            (agent-shell-math-renderer-mode 1)
            (should (= (length warnings) 4))
            (setq warnings nil)
            (setq-local agent-shell-math-renderer--present t)
            (cl-letf (((symbol-function 'agent-shell-math-renderer--refresh-buffer)
                       #'ignore))
              (unwind-protect
                  (progn
                    (setq-local agent-shell-math-renderer-foreground-color "red")
                    (agent-shell-math-renderer--update-after-option))
                (when (timerp agent-shell-math-renderer--option-timer)
                  (cancel-timer agent-shell-math-renderer--option-timer))
                (setq agent-shell-math-renderer--option-timer nil
                      agent-shell-math-renderer--option-buffers nil
                      agent-shell-math-renderer--option-defaults nil)))
            (should (= (length warnings) 1))
            (should (string-match-p "background-color" (car warnings)))))
        (setq warnings nil)
        (let ((agent-shell-math-renderer-foreground-color "red")
              (agent-shell-math-renderer-background-color nil))
          (with-temp-buffer
            (agent-shell-math-renderer-mode 1)
            (should-not warnings))))
      (let ((agent-shell-math-renderer-foreground-color "no-such-color"))
        (with-temp-buffer
          (agent-shell-math-renderer-mode 1)
          (should-not warnings))))))

(ert-deftest agent-shell-math-renderer-render-is-deferred ()
  ;; Every equation, inline or display, is tagged and rendered from one
  ;; timer, after agent-shell's passes, in its own style.  Two adjacent
  ;; equations stay two.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (let ((scheduled nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (&rest args) (push args scheduled) 'timer)))
        (with-temp-buffer
          (insert "\\(a\\)\\(b\\) \\[c\\]")
          (agent-shell-math-renderer--apply-region (current-buffer) 1 6 "a" t)
          (agent-shell-math-renderer--apply-region (current-buffer) 6 11 "b" t)
          (should-not calls)
          (should (get-text-property 1 'agent-shell-math-renderer--deferred))
          (agent-shell-math-renderer--apply-region (current-buffer) 12 17 "c")
          (should-not calls)
          (should (= 1 (length scheduled)))
          (agent-shell-math-renderer--render-deferred (current-buffer))
          (should-not (text-property-not-all
                       1 (point-max) 'agent-shell-math-renderer--deferred nil))
          (should-not agent-shell-math-renderer--deferred-timer)
          (should (equal '("$a$" "$b$" "\\[ c \\]")
                         (sort (delete-dups (mapcar #'car calls)) #'string<))))))))

(ert-deftest agent-shell-math-renderer-equation-tinted-like-its-text ()
  ;; Through agent-shell's passes, an equation in a heading is tinted with
  ;; the heading's color; one in plain text, inline or display, with the
  ;; `default' face's.  The color is read again on refresh, so a
  ;; face changed in the meantime is followed.
  (let ((header (face-attribute 'agent-shell-markdown-header-1 :foreground))
        (header-inherit (face-attribute 'agent-shell-markdown-header-1 :inherit)))
    (unwind-protect
        (progn
          (set-face-attribute 'agent-shell-markdown-header-1 nil
                              :foreground "gold" :inherit 'unspecified)
          (agent-shell-math-renderer-tests--enabled
            (agent-shell-math-renderer-tests--with-frame
              (let ((colors nil))
                (cl-letf (((symbol-function 'latex-to-svg-backend)
                           (lambda (latex &rest args)
                             (agent-shell-math-renderer-tests--check-colors args)
                             (push (cons latex (plist-get args :color)) colors)
                             nil)))
                  (with-temp-buffer
                    (insert "# Head \\(h\\)\n\nplain \\(p\\)\n\n\\[ d \\]\n")
                    (agent-shell-markdown-replace-markup)
                    (agent-shell-math-renderer--render-deferred (current-buffer))
                    (should (equal (sort (delete-dups colors)
                                         (lambda (x y) (string< (car x) (car y))))
                                   '(("$h$" . "#ffd700") ("$p$" . "#ffffff")
                                     ("\\[ d \\]" . "#ffffff"))))
                    (setq colors nil)
                    (set-face-attribute 'agent-shell-markdown-header-1 nil
                                        :foreground "red")
                    (agent-shell-math-renderer-refresh (current-buffer))
                    (should (equal (cdr (assoc "$h$" colors)) "#ff0000"))))))))
      (set-face-attribute 'agent-shell-markdown-header-1 nil
                          :foreground header :inherit header-inherit))))

(ert-deftest agent-shell-math-renderer-image-lands-in-a-heading ()
  ;; A heading's pass deletes and reinserts its text; an inline equation in
  ;; it gets its image when an uncached compile ends, since it is rendered,
  ;; and its region marked, after that pass.
  (agent-shell-math-renderer-tests--enabled
    (agent-shell-math-renderer-tests--with-frame
      (let ((callbacks nil)
            (ready nil))
        (cl-letf (((symbol-function 'latex-to-svg-backend)
                   (lambda (_latex &rest args)
                     (cond ((plist-get args :callback)
                            (push (plist-get args :callback) callbacks)
                            nil)
                           (ready '(image :type svg :data "<svg/>"))))))
          (with-temp-buffer
            (insert "# Head \\(x\\) tail\n")
            (agent-shell-markdown-replace-markup)
            (agent-shell-math-renderer--render-deferred (current-buffer))
            (setq ready t)
            (dolist (callback callbacks) (funcall callback nil))
            (goto-char (point-min))
            (search-forward "\\(")
            (should (eq 'image (car-safe (get-text-property
                                          (match-beginning 0) 'display))))))))))

(ert-deftest agent-shell-math-renderer-equation-sized-like-its-text ()
  ;; An equation, inline or display, is sized by the x-height of the font
  ;; at its opening delimiter: its pixel size (slot 2 of `query-font')
  ;; times its x-height ratio.  Batch has no graphical window, so the fonts
  ;; are stubbed: text marked `test-big' gets a font of 27 pixels, other
  ;; text one of 18, both with a ratio of 0.5.
  (agent-shell-math-renderer-tests--with-frame
    (let ((sizes nil))
      (cl-letf (((symbol-function 'latex-to-svg-backend)
                 (lambda (latex &rest args)
                   (push (cons latex (plist-get args :x-height)) sizes)
                   nil))
                ((symbol-function 'font-at)
                 (lambda (pos &rest _)
                   (if (get-text-property pos 'test-big) 'big-font 'plain-font)))
                ((symbol-function 'query-font)
                 (lambda (font)
                   (if (eq font 'big-font)
                       ["big" nil 27 nil 28 8 nil nil nil]
                     ["plain" nil 18 nil 18 5 nil nil nil])))
                ((symbol-function 'agent-shell-math-renderer--x-height-ratio)
                 (lambda (name &rest _)
                   (and (member name '("big" "plain")) 0.5))))
        (with-temp-buffer
          (insert "\\(a\\) \\(b\\) \\[c\\]")
          (put-text-property 7 8 'test-big t)
          (put-text-property 13 14 'test-big t)
          (agent-shell-math-renderer--render (current-buffer) 1 6 "a" t)
          (agent-shell-math-renderer--render (current-buffer) 7 12 "b" t)
          (agent-shell-math-renderer--render (current-buffer) 13 18 "c")
          (should (equal (sort (delete-dups sizes)
                               (lambda (x y) (string< (car x) (car y))))
                         '(("$a$" . 9.0) ("$b$" . 13.5) ("\\[ c \\]" . 13.5)))))))))

(ert-deftest agent-shell-math-renderer-x-height-at-outside-the-buffer ()
  ;; A POS outside the accessible part of the buffer, such as the marker of
  ;; a deleted equation at `point-max', or text outside a narrowing, gets
  ;; the buffer font's x-height (18 in `--with-frame').  The stub of
  ;; `font-at' signals there, as the real one does.
  (agent-shell-math-renderer-tests--with-frame
    (cl-letf (((symbol-function 'font-at)
               (lambda (pos &rest _)
                 (unless (and (<= (point-min) pos) (< pos (point-max)))
                   (signal 'args-out-of-range
                           (list pos (point-min) (point-max))))
                 'plain-font))
              ((symbol-function 'query-font)
               (lambda (_font) ["plain" nil 20 nil 20 5 nil nil nil]))
              ((symbol-function 'agent-shell-math-renderer--x-height-ratio)
               (lambda (&rest _) 0.5)))
      (with-temp-buffer
        (insert "abc")
        (should (equal (agent-shell-math-renderer--x-height-at 2) 10.0))
        (should (equal (agent-shell-math-renderer--x-height-at 4) 18))
        (narrow-to-region 2 3)
        (should (equal (agent-shell-math-renderer--x-height-at 1) 18))))))

(ert-deftest agent-shell-math-renderer-help-echo-names-the-engine ()
  ;; Once the image is laid, the tooltip names the engine before the LaTeX,
  ;; and says so when the picture came from the fallback.  Compared after
  ;; `substitute-command-keys', which is what the user reads.
  (dolist (case '((ratex ratex "Typeset with RaTeX: \\{ f'(x) \\}")
                  (latex latex "Typeset with LaTeX: \\{ f'(x) \\}")
                  (texres texres "Typeset with texres: \\{ f'(x) \\}")
                  (ratex latex
                         "Typeset with LaTeX (RaTeX could not parse it): \\{ f'(x) \\}")))
    (let ((agent-shell-math-renderer-engine (nth 0 case))
          (queried nil))
      (cl-letf (((symbol-function 'latex-to-svg-backend-available-p) #'always)
                ((symbol-function 'agent-shell-math-renderer--graphical-p)
                 #'always)
                ((symbol-function 'agent-shell-math-renderer--display-frame)
                 (lambda (&rest _) (selected-frame)))
                ((symbol-function 'agent-shell-math-renderer--x-height)
                 (lambda (&rest _) 20))
                ((symbol-function 'agent-shell-math-renderer--foreground-for)
                 (lambda (&rest _) "#cbe3e7"))
                ((symbol-function 'agent-shell-math-renderer--appearance)
                 #'ignore)
                ((symbol-function 'latex-to-svg-backend)
                 (lambda (&rest _) 'fake-image))
                ((symbol-function 'latex-to-svg-backend-engine-used)
                 (lambda (&rest args) (setq queried args) (nth 1 case))))
        (with-temp-buffer
          (insert "xx")
          (agent-shell-math-renderer--render
           (current-buffer) (point-min) (point-max) "\\{ f'(x) \\}")
          ;; Asked with the string and arguments the image was requested with.
          (should (equal queried
                         (list "\\[ \\{ f'(x) \\} \\]" (nth 0 case)
                               (and (eq (nth 0 case) 'ratex) 'latex))))
          (should (equal (nth 2 case)
                         (substitute-command-keys
                          (get-text-property (point-min) 'help-echo)))))))))

(ert-deftest agent-shell-math-renderer-option-watcher-queues-buffers ()
  ;; Setting a watched option queues the buffers to update, on one timer: a
  ;; `setq-local' that buffer, a `setq-default' the option, a `let' none.
  (let ((agent-shell-math-renderer--option-buffers nil)
        (agent-shell-math-renderer--option-defaults nil)
        (agent-shell-math-renderer--option-timer nil)
        (scheduled 0))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf scheduled) (timer-create))))
      (let ((agent-shell-math-renderer-padding-inline 3))
        (ignore agent-shell-math-renderer-padding-inline))
      (should-not agent-shell-math-renderer--option-buffers)
      (should (= 0 scheduled))
      (with-temp-buffer
        (setq-local agent-shell-math-renderer-padding-inline 3)
        (setq-local agent-shell-math-renderer-engine 'ratex)
        (should (equal agent-shell-math-renderer--option-buffers
                       (list (current-buffer)))))
      (should (= 1 scheduled))
      (let ((old (default-value 'agent-shell-math-renderer-padding-inline)))
        (unwind-protect
            (setq-default agent-shell-math-renderer-padding-inline 3)
          (set-default 'agent-shell-math-renderer-padding-inline old)))
      (should (equal agent-shell-math-renderer--option-defaults
                     '(agent-shell-math-renderer-padding-inline)))
      (should (= 1 scheduled)))))

(ert-deftest agent-shell-math-renderer-backend-options-are-watched ()
  ;; The backend's options in the cache key that a project sets in
  ;; `.dir-locals.el' (the three preambles, the files two of them load,
  ;; the width of numbered equations, RaTeX's macros) update the equations
  ;; like this package's own options.
  (dolist (option '(latex-to-svg-backend-preamble-base
                    latex-to-svg-backend-preamble-packages
                    latex-to-svg-backend-preamble-not-precompiled
                    latex-to-svg-backend-preamble-package-files
                    latex-to-svg-backend-preamble-not-precompiled-files
                    latex-to-svg-backend-line-width
                    latex-to-svg-backend-ratex-macros))
    (should (memq #'agent-shell-math-renderer--option-changed
                  (get-variable-watchers option))))
  ;; No backend option is named by an obsolete alias: users read the new
  ;; names.
  (dolist (option agent-shell-math-renderer--watched-options)
    (when (string-prefix-p "latex-to-svg-backend-" (symbol-name option))
      (should-not (get option 'byte-obsolete-variable)))))

(ert-deftest agent-shell-math-renderer-option-default-skips-buffers-with-own-value ()
  ;; A change of `latex-to-svg-backend-preamble-packages''s default
  ;; updates the chats that use the default, not a chat with its own value
  ;; (set by its `.dir-locals.el').  A buffer-local change updates that chat.
  (let ((agent-shell-math-renderer--option-buffers nil)
        (agent-shell-math-renderer--option-defaults nil)
        (agent-shell-math-renderer--option-timer nil)
        (updated nil)
        (own (generate-new-buffer " own"))
        (uses-default (generate-new-buffer " uses-default")))
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'agent-shell-math-renderer--refresh-buffer)
                   (lambda (buf &rest _) (push buf updated))))
          (dolist (buf (list own uses-default))
            (with-current-buffer buf
              (setq agent-shell-math-renderer--present t)))
          (with-current-buffer own
            (setq-local latex-to-svg-backend-preamble-packages
                        "\\input{m}"))
          (should (equal agent-shell-math-renderer--option-buffers (list own)))
          (agent-shell-math-renderer--update-after-option)
          (should (equal updated (list own)))
          (setq updated nil)
          (let ((latex-to-svg-backend-preamble-packages ""))
            (setq latex-to-svg-backend-preamble-packages "\\input{g}")
            (agent-shell-math-renderer--update-after-option)
            (should (equal updated (list uses-default)))))
      (kill-buffer own)
      (kill-buffer uses-default))))

(ert-deftest agent-shell-math-renderer-option-update-renders-new-value ()
  ;; The timer's function re-renders the queued buffers that have equations,
  ;; with the value the option now has.
  (let ((agent-shell-math-renderer--option-buffers nil)
        (agent-shell-math-renderer--option-timer nil))
    (agent-shell-math-renderer-tests--with-backend-calls calls
      (with-temp-buffer
        (insert "xx")
        (put-text-property (point-min) (point-max)
                           'agent-shell-math-renderer-source "x")
        (setq agent-shell-math-renderer--present t)
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (setq-local agent-shell-math-renderer-engine 'ratex))
        (should (equal agent-shell-math-renderer--option-buffers
                       (list (current-buffer))))
        (agent-shell-math-renderer--update-after-option)
        (should-not agent-shell-math-renderer--option-buffers)
        (should calls)
        (should (eq 'ratex (plist-get (cdar calls) :engine)))))))

(ert-deftest agent-shell-math-renderer-refresh-recompiles-with-prefix ()
  ;; RECOMPILE (`C-u') invalidates each equation's string with the engine, and
  ;; with the fallback too when there is one, then renders it again -- in the
  ;; current buffer only.  It deletes the buffer's `.fmt' files once when the
  ;; engine or the fallback is LaTeX, or the engine is texres, which dumps a
  ;; `.fmt' file of its own.
  (dolist (case '((latex t (latex) 1)
                  (texres t (texres) 1)
                  (ratex t (ratex latex) 1)
                  (ratex nil (ratex) 0)))
    (let ((invalidated '())
          (formats 0)
          (rendered '())
          (other (generate-new-buffer " other"))
          (agent-shell-math-renderer-engine (nth 0 case))
          (agent-shell-math-renderer-fallback (nth 1 case)))
      (unwind-protect
          (cl-letf (((symbol-function 'latex-to-svg-backend-invalidate)
                     (lambda (doc &optional engine)
                       (push (list doc engine) invalidated)))
                    ((symbol-function 'latex-to-svg-backend-invalidate-format)
                     (lambda () (cl-incf formats)))
                    ((symbol-function 'agent-shell-math-renderer--render)
                     (lambda (buffer _start _end latex &optional _inline)
                       (push (cons buffer latex) rendered))))
            (with-current-buffer other
              (insert "zz")
              (put-text-property 1 3 'agent-shell-math-renderer-source "z")
              (setq agent-shell-math-renderer--present t))
            (with-temp-buffer
              (insert "display inline")
              (put-text-property 1 8 'agent-shell-math-renderer-source "a")
              (put-text-property 9 15 'agent-shell-math-renderer-source "b")
              (put-text-property 9 15 'agent-shell-math-renderer-inline t)
              (agent-shell-math-renderer-refresh nil t)
              (should (equal (nreverse rendered)
                             (list (cons (current-buffer) "a")
                                   (cons (current-buffer) "b"))))))
        (kill-buffer other))
      (should (= formats (nth 3 case)))
      (should (equal (nreverse invalidated)
                     (append
                      (mapcar (lambda (e) (list "\\[ a \\]" e)) (nth 2 case))
                      (mapcar (lambda (e) (list "$b$" e)) (nth 2 case))))))))

(ert-deftest agent-shell-math-renderer-refresh-passes-new-engine ()
  ;; A refresh after changing the option renders with the new engine.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (with-temp-buffer
      (insert "xx")
      (put-text-property (point-min) (point-max)
                         'agent-shell-math-renderer-source "x")
      (let ((agent-shell-math-renderer-engine 'latex))
        (agent-shell-math-renderer--refresh-buffer (current-buffer)))
      (should (eq 'latex (plist-get (cdar calls) :engine)))
      (setq calls nil)
      (let ((agent-shell-math-renderer-engine 'ratex))
        (agent-shell-math-renderer--refresh-buffer (current-buffer)))
      (should calls)
      (dolist (call calls)
        (should (eq 'ratex (plist-get (cdr call) :engine)))))))

(ert-deftest agent-shell-math-renderer-wraps-display-and-inline-math ()
  ;; Display math is passed as `\[ body \]', inline math as `$body$'.
  (agent-shell-math-renderer-tests--with-backend-calls calls
    (with-temp-buffer
      (insert "xx")
      (agent-shell-math-renderer--render
       (current-buffer) (point-min) (point-max) "a+b")
      (should (equal "\\[ a+b \\]" (caar calls)))
      (setq calls nil)
      (agent-shell-math-renderer--render
       (current-buffer) (point-min) (point-max) "a+b" t)
      (should (equal "$a+b$" (caar calls))))))

(ert-deftest agent-shell-math-renderer-engine-safe-values ()
  ;; A file-local engine is safe for the three engines and nothing else.
  (let ((safe (get 'agent-shell-math-renderer-engine 'safe-local-variable)))
    (should (funcall safe 'latex))
    (should (funcall safe 'ratex))
    (should (funcall safe 'texres))
    (should-not (funcall safe nil))
    (should-not (funcall safe 'pdflatex))))

(ert-deftest agent-shell-math-renderer-text-scale-wired-to-refresh ()
  ;; A buffer zoom (`text-scale-adjust') fires `text-scale-mode-hook' but
  ;; neither display nor theme hooks, so the mode subscribes to it
  ;; buffer-locally — otherwise equations only re-size on the next buffer
  ;; switch.  Verify `agent-shell-math-renderer-mode' wires it on enable and
  ;; unwires it on disable (subscription stubbed so a plain buffer suffices).
  (cl-letf (((symbol-function 'agent-shell-subscribe-to)
             (lambda (&rest _) 'token))
            ((symbol-function 'agent-shell-unsubscribe)
             (lambda (&rest _) nil)))
    (with-temp-buffer
      (agent-shell-math-renderer-mode 1)
      (should (memq 'agent-shell-math-renderer--maybe-refresh
                    text-scale-mode-hook))
      (agent-shell-math-renderer-mode -1)
      (should-not (memq 'agent-shell-math-renderer--maybe-refresh
                        text-scale-mode-hook)))))

(ert-deftest agent-shell-math-renderer-on-appearance-change-sweeps-present-buffers ()
  ;; A *frame* font change fires neither `text-scale-mode-hook' nor the
  ;; display hooks, and is global: the opt-in handler sweeps every present
  ;; buffer, appearance-checking each one.
  (let ((refreshed nil))
    (with-temp-buffer
      (setq agent-shell-math-renderer--present t)
      (cl-letf (((symbol-function 'agent-shell-math-renderer--refresh-if-changed)
                 (lambda () (push (current-buffer) refreshed))))
        (agent-shell-math-renderer-on-appearance-change)
        (sit-for 0.1))
      (should (memq (current-buffer) refreshed)))
    ;; Not present -> not visited.
    (setq refreshed nil)
    (with-temp-buffer
      (setq agent-shell-math-renderer--present nil)
      (cl-letf (((symbol-function 'agent-shell-math-renderer--refresh-if-changed)
                 (lambda () (push (current-buffer) refreshed))))
        (agent-shell-math-renderer-on-appearance-change)
        (sit-for 0.1))
      (should-not (memq (current-buffer) refreshed)))))

(ert-deftest agent-shell-math-renderer-installs-no-global-hooks ()
  ;; Policy: theme / frame-font tracking is opt-in; loading the package or
  ;; enabling the mode must never touch a global hook.
  (cl-letf (((symbol-function 'agent-shell-subscribe-to) (lambda (&rest _) 'token))
            ((symbol-function 'agent-shell-unsubscribe) (lambda (&rest _) nil)))
    (with-temp-buffer
      (agent-shell-math-renderer-mode 1)
      (should-not (memq 'agent-shell-math-renderer-on-appearance-change
                        (default-value 'after-setting-font-hook)))
      (should-not (memq 'agent-shell-math-renderer-on-appearance-change
                        (default-value 'enable-theme-functions)))
      (agent-shell-math-renderer-mode -1))))

;;; Submitted-prompt rendering

(ert-deftest agent-shell-math-renderer-submitted-prompt-region-copies-markers ()
  ;; Copy comint's submitted-input markers before deferring, so output inserted
  ;; at the prompt end is not included in the prompt render.
  (with-temp-buffer
    (insert "prompt \\(x\\)")
    (let* ((original-end (point-max))
           (start (copy-marker (point-min)))
           (end (copy-marker (point-max)))
           (comint-last-input-start start)
           (comint-last-input-end end)
           (region (agent-shell-math-renderer--submitted-prompt-region)))
      (goto-char (point-max))
      (insert "\noutput")
      (should (= (marker-position (car region)) (point-min)))
      (should (= (marker-position (cdr region)) original-end))
      (set-marker start nil)
      (set-marker end nil)
      (set-marker (car region) nil)
      (set-marker (cdr region) nil))))

(ert-deftest agent-shell-math-renderer-input-submitted-defers-rendering ()
  ;; The scheduler snapshots the submitted prompt in the shell buffer and
  ;; defers rendering until after the submit command returns.
  (let ((shell-buffer (generate-new-buffer " *asmr-shell*"))
        scheduled)
    (unwind-protect
        (progn
          (with-current-buffer shell-buffer
            (insert "prompt \\(x\\)")
            (setq-local comint-last-input-start (copy-marker (point-min)))
            (setq-local comint-last-input-end (copy-marker (point-max)))
            (setq-local agent-shell-math-renderer-mode t)
            (setq-local agent-shell-math-renderer-render-submitted-prompts t))
          (with-temp-buffer
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (time repeat function &rest args)
                         (setq scheduled (list time repeat function args))
                         'fake-timer)))
              (agent-shell-math-renderer--schedule-submitted-prompt
               shell-buffer)))
          (should scheduled)
          (should (= (nth 0 scheduled) 0))
          (should-not (nth 1 scheduled))
          (should (eq (nth 2 scheduled)
                      #'agent-shell-math-renderer--render-submitted-prompt))
          (should (eq (car (nth 3 scheduled)) shell-buffer)))
      (when (buffer-live-p shell-buffer)
        (with-current-buffer shell-buffer
          (set-marker comint-last-input-start nil)
          (set-marker comint-last-input-end nil))
        (kill-buffer shell-buffer)))))

(ert-deftest agent-shell-math-renderer-input-submitted-subscription-uses-handler ()
  (let (args)
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest plist)
                   (setq args (append args (list plist)))
                   'fake-subscription)))
        (agent-shell-math-renderer--maybe-subscribe-prompts))
      (should (equal agent-shell-math-renderer--prompt-subscriptions
                     '(fake-subscription fake-subscription)))
      (should (equal (seq-map (lambda (plist) (plist-get plist :shell-buffer))
                              args)
                     (list (current-buffer) (current-buffer))))
      (should (equal (seq-map (lambda (plist)
                                (list (plist-get plist :event)
                                      (plist-get plist :on-event)))
                              args)
                     '((input-submitted
                        agent-shell-math-renderer--on-input-submitted)
                       (session-restored
                        agent-shell-math-renderer--on-session-restored)))))))

(ert-deftest agent-shell-math-renderer-input-submitted-handler-uses-current-buffer ()
  ;; The event handler keeps agent-shell's ordinary one-argument callback shape,
  ;; so direct subscriptions are safe across live reloads.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "prompt \\(x\\)")
      (let ((comint-last-input-start (copy-marker (point-min)))
            (comint-last-input-end (copy-marker (point-max)))
            (agent-shell-math-renderer-render-submitted-prompts t)
            scheduled)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (time repeat function &rest args)
                     (setq scheduled (list time repeat function args))
                     'fake-timer)))
          (agent-shell-math-renderer--on-input-submitted
           '((:event . input-submitted))))
        (should scheduled)
        (should (eq (car (nth 3 scheduled)) (current-buffer)))
        (set-marker comint-last-input-start nil)
        (set-marker comint-last-input-end nil)))))

(ert-deftest agent-shell-math-renderer-input-submitted-respects-option ()
  (let ((scheduled nil))
    (with-temp-buffer
      (insert "prompt \\(x\\)")
      (let ((comint-last-input-start (copy-marker (point-min)))
            (comint-last-input-end (copy-marker (point-max)))
            (agent-shell-math-renderer-mode t)
            (agent-shell-math-renderer-render-submitted-prompts nil))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (&rest _)
                     (setq scheduled t))))
          (agent-shell-math-renderer--on-input-submitted
           '((:event . input-submitted))))
        (should-not scheduled)
        (set-marker comint-last-input-start nil)
        (set-marker comint-last-input-end nil)))))

(ert-deftest agent-shell-math-renderer-render-submitted-prompt-static-region ()
  ;; Rendering a prompt should affect the submitted input, not neighbouring
  ;; buffer text, and inline math inside backtick code spans must stay literal.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "outside \\(a\\)\n")
      (let ((start (copy-marker (point))))
        (insert "inside \\(b\\) and `\\(literal\\)`")
        (let ((end (copy-marker (point)))
              (agent-shell-math-renderer-render-submitted-prompts t))
          (agent-shell-math-renderer--render-submitted-prompt
           (current-buffer) start end)
          (goto-char (point-min))
          (search-forward "\\(a\\)")
          (should-not (get-text-property (match-beginning 0)
                                         'agent-shell-math-renderer-source))
          (goto-char (point-min))
          (search-forward "\\(b\\)")
          (should (equal (get-text-property
                          (match-beginning 0)
                          'agent-shell-math-renderer-source)
                         "b"))
          (goto-char (point-min))
          (search-forward "\\(literal\\)")
          (should-not (get-text-property
                       (match-beginning 0)
                       'agent-shell-math-renderer-source)))))))

(ert-deftest agent-shell-math-renderer-render-submitted-prompt-fenced-math ()
  ;; Submitted prompts take the same fenced path, so a ```math prompt is
  ;; typeset with its fence left intact in the buffer.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "```math\nE=mc^2\n```\n")
      (let ((start (copy-marker (point-min)))
            (end (copy-marker (point-max)))
            (agent-shell-math-renderer-render-submitted-prompts t))
        (agent-shell-math-renderer--render-submitted-prompt
         (current-buffer) start end)
        (should (equal (buffer-string) "```math\nE=mc^2\n```\n"))
        (goto-char (point-min))
        (should (equal (get-text-property
                        (point)
                        'agent-shell-math-renderer-source)
                       "E=mc^2"))))))

(defun agent-shell-math-renderer-tests--insert-prompt (input &optional sent)
  "Insert a shell prompt with INPUT, as agent-shell does.
With SENT, end INPUT with shell-maker's end-of-prompt marker."
  (insert (propertize "Claude> " 'field 'output
                      'font-lock-face 'agent-shell-prompt)
          (propertize input 'font-lock-face 'agent-shell-input))
  (when sent
    (insert (propertize "<shell-maker-end-of-prompt>"
                        'invisible t 'shell-maker--marker t))))

(ert-deftest agent-shell-math-renderer-session-restored-renders-replayed-prompts ()
  ;; A restore replays each user prompt with no markdown render and no
  ;; `input-submitted'.  `session-restored' renders those prompts, without
  ;; the shell prompt before them and without the agent's text.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (agent-shell-math-renderer-tests--insert-prompt
       "\\[\nx^2\n\\]\nand \\(y\\)" t)
      (insert "\n\nagent \\(z\\)\n\n")
      (let ((agent-shell-math-renderer-render-submitted-prompts t)
            scheduled)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (push (cons function args) scheduled))))
          (agent-shell-math-renderer--on-session-restored
           '((:event . session-restored))))
        (should (= (length scheduled) 1))
        (apply (car (car scheduled)) (cdr (car scheduled)))
        (goto-char (point-min))
        (should-not (get-text-property (point)
                                       'agent-shell-math-renderer-source))
        (search-forward "\\[")
        (should (equal (get-text-property (match-beginning 0)
                                          'agent-shell-math-renderer-source)
                       "x^2"))
        (search-forward "\\(y")
        (should (equal (get-text-property (match-beginning 0)
                                          'agent-shell-math-renderer-source)
                       "y"))
        (search-forward "\\(z")
        (should-not (get-text-property (match-beginning 0)
                                       'agent-shell-math-renderer-source))))))

(ert-deftest agent-shell-math-renderer-session-restored-skips-live-prompt ()
  ;; Text typed into the live prompt during a restore is not sent yet, so
  ;; it is not rendered.  Its input starts at the process mark.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (agent-shell-math-renderer-tests--insert-prompt "\\(y\\)" t)
      (insert "\n\n")
      (agent-shell-math-renderer-tests--insert-prompt "")
      (let ((process (make-pipe-process :name "agent-shell-math-renderer-test"
                                        :buffer (current-buffer)
                                        :noquery t)))
        (unwind-protect
            (progn
              (set-marker (process-mark process) (point))
              (insert "\\(draft\\)")
              (should (equal (seq-map
                              (lambda (region)
                                (buffer-substring-no-properties
                                 (car region) (cdr region)))
                              (agent-shell-math-renderer--replayed-prompt-regions))
                             '("\\(y\\)"))))
          (delete-process process))))))

(ert-deftest agent-shell-math-renderer-session-restored-respects-option ()
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (agent-shell-math-renderer-tests--insert-prompt "\\(y\\)" t)
      (let ((agent-shell-math-renderer-render-submitted-prompts nil)
            scheduled)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (&rest _)
                     (setq scheduled t))))
          (agent-shell-math-renderer--on-session-restored
           '((:event . session-restored))))
        (should-not scheduled)))))

(ert-deftest agent-shell-math-renderer-warns-about-obsolete-options ()
  ;; Setting an obsolete option non-nil warns once per session, with what
  ;; `make-obsolete-variable' recorded; nil, and a `let', do not warn.
  (let ((agent-shell-math-renderer--obsolete-warned nil)
        (padding (default-value 'agent-shell-math-renderer-padding))
        (enabled (default-value 'agent-shell-math-renderer-enabled))
        warnings)
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _)
                 (push message warnings))))
      (unwind-protect
          (progn
            (set-default 'agent-shell-math-renderer-padding nil)
            (cl-progv '(agent-shell-math-renderer-padding) '(2)
              nil)
            (should-not warnings)
            (set-default 'agent-shell-math-renderer-padding 2)
            (set-default 'agent-shell-math-renderer-padding 3)
            (set-default 'agent-shell-math-renderer-enabled t)
            (should (equal
                     (reverse warnings)
                     '("`agent-shell-math-renderer-padding' is obsolete since \
0.12.0; set `agent-shell-math-renderer-padding-inline' and \
`agent-shell-math-renderer-padding-display'."
                       "`agent-shell-math-renderer-enabled' is obsolete since \
0.6.0; add `agent-shell-math-renderer-mode' to `agent-shell-mode-hook'."))))
        (set-default 'agent-shell-math-renderer-padding padding)
        (set-default 'agent-shell-math-renderer-enabled enabled)))))

;;; --- Versions --------------------------------------------------------------

(defconst agent-shell-math-renderer-tests--repo-root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Directory holding the package, `README.md' and `CHANGELOG.md'.")

(defun agent-shell-math-renderer-tests--read-file (file)
  "Return the contents of FILE, relative to the repository root."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name file agent-shell-math-renderer-tests--repo-root))
    (buffer-string)))

(defun agent-shell-math-renderer-tests--header (header)
  "Return HEADER of the package's source file."
  (with-temp-buffer
    (insert (agent-shell-math-renderer-tests--read-file
             "agent-shell-math-renderer.el"))
    (lm-header header)))

(defun agent-shell-math-renderer-tests--required-version (package)
  "Return the version of PACKAGE that `Package-Requires' names."
  (cadr (assq package (car (read-from-string
                            (agent-shell-math-renderer-tests--header
                             "package-requires"))))))

(ert-deftest agent-shell-math-renderer-version-constants-match-the-headers ()
  ;; Drift guard: `agent-shell-math-renderer-version' is the `Version:'
  ;; header, and `--backend-version' the backend's floor in
  ;; `Package-Requires'.
  (should (equal agent-shell-math-renderer-version
                 (agent-shell-math-renderer-tests--header "version")))
  (should (equal agent-shell-math-renderer--backend-version
                 (agent-shell-math-renderer-tests--required-version
                  'latex-to-svg-backend))))

(ert-deftest agent-shell-math-renderer-readme-requirements-match-the-header ()
  ;; Drift guard: the README's requirement lines name the floors in
  ;; `Package-Requires'.
  (let ((readme (agent-shell-math-renderer-tests--read-file "README.md")))
    (should (string-match-p
             (format "^- \\*\\*Emacs %s\\+\\*\\*$"
                     (regexp-quote
                      (agent-shell-math-renderer-tests--required-version
                       'emacs)))
             readme))
    (dolist (package '(agent-shell latex-to-svg-backend))
      (should (string-match-p
               (format "^- \\*\\*\\[`%s`\\]([^)]+)\\*\\* (?%s\n? *or newer"
                       package
                       (regexp-quote
                        (agent-shell-math-renderer-tests--required-version
                         package)))
               readme)))))

(ert-deftest agent-shell-math-renderer-changelog-not-behind-package-version ()
  ;; Drift guard: a released section never claims a version the source has
  ;; not reached.  Between releases the header may run ahead of the newest
  ;; dated section, with the entries under `[Unreleased]'.
  (let ((header (agent-shell-math-renderer-tests--header "version"))
        (changelog (with-temp-buffer
                     (insert (agent-shell-math-renderer-tests--read-file
                              "CHANGELOG.md"))
                     (goto-char (point-min))
                     (and (re-search-forward "^## \\[\\([0-9.]+\\)\\] - " nil t)
                          (match-string 1)))))
    (should (stringp changelog))
    (should (version<= changelog header))))

(ert-deftest agent-shell-math-renderer-check-backend-version ()
  "`agent-shell-math-renderer--check-backend-version' signals an error
when the loaded backend is older than the floor or has no version."
  (let ((agent-shell-math-renderer-version "0.15.0")
        (agent-shell-math-renderer--backend-version "0.16.1"))
    (let ((latex-to-svg-backend-version "0.16.1"))
      (agent-shell-math-renderer--check-backend-version))
    (let ((latex-to-svg-backend-version "0.17.0"))
      (agent-shell-math-renderer--check-backend-version))
    (let ((latex-to-svg-backend-version "0.16.0"))
      (should (string-match-p
               "\\`agent-shell-math-renderer 0\\.15\\.0 needs \
latex-to-svg-backend 0\\.16\\.1 or newer, but Emacs loaded version \
0\\.16\\.0 from .+\\.  Update latex-to-svg-backend to 0\\.16\\.1 or \
newer, then restart Emacs\\'"
               (cadr (should-error
                      (agent-shell-math-renderer--check-backend-version))))))
    (let ((latex-to-svg-backend-version nil))
      (should (string-match-p
               "loaded a version older than 0\\.16\\.1 from "
               (cadr (should-error
                      (agent-shell-math-renderer--check-backend-version))))))))

(provide 'agent-shell-math-renderer-tests)

;;; agent-shell-math-renderer-tests.el ends here
