;;; agent-shell-math-renderer-tests.el --- Tests for agent-shell-math-renderer -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run via:
;;
;;   emacs -batch -l ert -l tests/agent-shell-math-renderer-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)
(require 'ert)

(add-to-list 'load-path
             (expand-file-name ".." (file-name-directory
                                     (or load-file-name buffer-file-name))))

;; Loads `agent-shell-markdown' (from load path) and our renderer.
;; The math passes run through `agent-shell-markdown-convert', so the
;; tests exercise the hook integration rather than the module in
;; isolation.
;;
;; NOTE: these tests call `agent-shell-markdown--deconstruct' (a private
;; agent-shell helper that turns propertized text into (STRING . FACES)
;; runs) for their assertions.  It is the one remaining dependency on an
;; agent-shell internal, and it is deliberately test-only: the shipped
;; package uses only public agent-shell API, so if upstream renames or
;; drops `--deconstruct' it breaks *these tests*, never production.  The
;; fix is then local — adapt the assertions (or inline an equivalent).
(require 'agent-shell-markdown)
(require 'agent-shell-math-renderer)

(defmacro agent-shell-math-renderer-tests--enabled (&rest body)
  "Evaluate BODY with math rendering enabled.
`agent-shell-math-renderer-enabled' (the master switch) defaults to
nil, so every test that expects equations to render must opt in;
this binds it for the default delimiter set (`bracket')."
  (declare (indent 0) (debug t))
  `(let ((agent-shell-math-renderer-enabled t))
     ,@body))

(defmacro agent-shell-math-renderer-tests--with-dollar (&rest body)
  "Evaluate BODY with math rendering on and `$$...$$' enabled.
`agent-shell-math-renderer-delimiters' defaults to `bracket' only,
so the dollar-delimited tests opt into `dollar' (and the master
`agent-shell-math-renderer-enabled' switch) through this one binding."
  (declare (indent 0) (debug t))
  `(let ((agent-shell-math-renderer-enabled t)
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
  (let ((agent-shell-math-renderer-enabled t)
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
  ;; plain text and inner markup is processed normally.
  (let ((agent-shell-math-renderer-enabled t)
        (agent-shell-math-renderer-delimiters '()))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "x \\[ **y** \\] z"))
                   '(("x \\[ " nil)
                     ("y" (agent-shell-markdown-bold))
                     (" \\] z" nil))))))

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
  ;; than mis-rendered as a single equation).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert
                     "\\[
E=mc^2

extra
\\]"))
                   '(("\\[
E=mc^2

extra
\\]" nil))))))

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
                   '(("\\[ stray opener

" nil)
                     ("\\[ E=mc^2 \\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-math-inline-opener-ignored ()
  ;; An opener not at line start is inline, not block-level display
  ;; math: it is left as plain text and inner markup is processed.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "see \\[ **x** \\] here"))
                   '(("see \\[ " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" \\] here" nil))))))

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
  ;; A ```math fence renders as display math: the backtick fences are
  ;; dropped and the body is rewritten as `\\[...\\]' (so a copy yields
  ;; renderable LaTeX, not markdown), math-faced as one run.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "```math
E=mc^2
```"))
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-fenced-latex-renders ()
  ;; A ```latex fence is also treated as display math, rewritten to
  ;; `\\[...\\]' the same way.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "```latex
E=mc^2
```"))
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer)))))))

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
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer))
                     ("
after" nil))))))

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
  ;; becomes bold) — math rendering is fully gated.
  (let ((agent-shell-math-renderer-enabled nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "before \\[ **x** \\] after"))
                   '(("before \\[ " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" \\] after" nil))))))

(ert-deftest agent-shell-math-renderer-fenced-math-as-code-when-off ()
  ;; With the master switch off, a ```math fence is left as an ordinary
  ;; code block (source-block face), not a math equation.
  (let* ((agent-shell-math-renderer-enabled nil)
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

(ert-deftest agent-shell-math-renderer-renderable-p-honors-non-graphic-opt-in ()
  ;; Renderability requires SVG build support, and then either a
  ;; graphical frame or the non-graphic opt-in (for daemon use).
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) t)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (let ((agent-shell-math-renderer-render-on-non-graphic nil))
        (should-not (agent-shell-math-renderer--renderable-p)))
      (let ((agent-shell-math-renderer-render-on-non-graphic t))
        (should (agent-shell-math-renderer--renderable-p))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (let ((agent-shell-math-renderer-render-on-non-graphic nil))
        (should (agent-shell-math-renderer--renderable-p)))))
  ;; No SVG support in the build => never renderable, even with the opt-in.
  (cl-letf (((symbol-function 'image-type-available-p) (lambda (_) nil))
            ((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (let ((agent-shell-math-renderer-render-on-non-graphic t))
      (should-not (agent-shell-math-renderer--renderable-p)))))

(ert-deftest agent-shell-math-renderer-math-degrades-without-svg ()
  ;; On a build without SVG support, math rendering degrades gracefully:
  ;; even on a graphical frame and with the feature on, equations are still
  ;; recognized and faced (markup protected), but no image is overlaid and
  ;; conversion never errors — the raw LaTeX simply shows as faced text.
  ;; (A user who doesn't want even that sets `agent-shell-math-renderer-enabled'
  ;; to nil; there is deliberately no PNG fallback.)
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

(ert-deftest agent-shell-math-renderer-cache-key-distinguishes-inputs ()
  ;; The content key must be stable for identical inputs and differ when the
  ;; equation changes — otherwise cached SVGs collide or never hit.  (Pure
  ;; function; no TeX or graphical display needed.)  Neither display size
  ;; NOR color is part of this key: the on-disk SVG is font-independent and
  ;; color-independent (compiled with --currentcolor, tinted at display).
  (let ((base (agent-shell-math-renderer--cache-key "E=mc^2")))
    (should (equal base (agent-shell-math-renderer--cache-key "E=mc^2")))
    (should-not (equal base (agent-shell-math-renderer--cache-key "E=mc^3")))))

(ert-deftest agent-shell-math-renderer-cache-key-folds-in-preamble ()
  ;; Changing the preamble must invalidate the cache (different output).
  (let ((base (agent-shell-math-renderer--cache-key "E=mc^2")))
    (let ((agent-shell-math-renderer-preamble "\\documentclass{minimal}"))
      (should-not (equal base (agent-shell-math-renderer--cache-key "E=mc^2"))))))

(ert-deftest agent-shell-math-renderer-cache-key-folds-in-appended-preamble ()
  ;; Changing the appended preamble must also invalidate the cache.
  (let ((base (agent-shell-math-renderer--cache-key "E=mc^2")))
    (let ((agent-shell-math-renderer-appended-preamble "\\usepackage{braket}"))
      (should-not (equal base (agent-shell-math-renderer--cache-key "E=mc^2"))))))

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
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "\\(
x
\\)"))
                   '(("\\(
x
\\)" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-streaming-tail ()
  ;; An unclosed `\\(' on the buffer's last line is left raw (the closer
  ;; may still stream in); the start-of-last-line watermark re-scans it.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "text \\(E=mc^2"))
                   '(("text \\(E=mc^2" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-can-be-disabled ()
  ;; `agent-shell-math-renderer-render-inline' nil disables `\\(...\\)'
  ;; even with the master switch on: delimiters are plain and inner
  ;; markup (`**x**') is processed normally.
  (let ((agent-shell-math-renderer-enabled t)
        (agent-shell-math-renderer-render-inline nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "a \\( **x** \\) b"))
                   '(("a \\( " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" \\) b" nil))))))

(ert-deftest agent-shell-math-renderer-inline-math-master-switch-off ()
  ;; With the master switch off, inline `\\(...\\)' is plain text and
  ;; inner markup is processed (here `**x**' becomes bold).
  (let ((agent-shell-math-renderer-enabled nil))
    (should (equal (agent-shell-markdown--deconstruct
                    (agent-shell-markdown-convert "a \\( **x** \\) b"))
                   '(("a \\( " nil)
                     ("x" (agent-shell-markdown-bold))
                     (" \\) b" nil))))))

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

(ert-deftest agent-shell-math-renderer-cache-key-distinguishes-inline ()
  ;; Inline and display renders of the same source must not collide:
  ;; the inline flag changes the key, while the default (display) key is
  ;; unchanged from the no-flag form.
  (should (equal (agent-shell-math-renderer--cache-key "x")
                 (agent-shell-math-renderer--cache-key "x" nil)))
  (should-not (equal (agent-shell-math-renderer--cache-key "x")
                     (agent-shell-math-renderer--cache-key "x" t))))

(ert-deftest agent-shell-math-renderer-cache-dir-uses-agent-shell-cache ()
  ;; By default the equation cache lives under agent-shell's shared cache
  ;; directory (so SVGs persist across sessions next to other cached
  ;; assets).  Stub `agent-shell-cache-dir' to a temp dir so the test
  ;; pins a deterministic base and asserts the delegation, rather than
  ;; touching the real cache location.
  (let ((agent-shell-math-renderer-cache-directory nil)
        (tmp (make-temp-file "asm-cache" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-cache-dir)
                   (lambda (&rest components)
                     (apply #'file-name-concat tmp components))))
          (should (equal (agent-shell-math-renderer--cache-dir)
                         (file-name-concat tmp "markdown-math"))))
      (delete-directory tmp t))))

(ert-deftest agent-shell-math-renderer-cache-dir-honors-explicit-override ()
  ;; An explicit `agent-shell-math-renderer-cache-directory' wins over the
  ;; shared default and is created on demand.
  (let* ((parent (make-temp-file "asm-cache-override" t))
         (dir (file-name-concat parent "eqs"))
         (agent-shell-math-renderer-cache-directory dir))
    (unwind-protect
        (progn
          (should (equal (agent-shell-math-renderer--cache-dir) dir))
          (should (file-directory-p dir)))
      (delete-directory parent t))))

(ert-deftest agent-shell-math-renderer-display-scale-is-1-when-non-graphical ()
  ;; Off a graphical frame (batch, the daemon-prerender path) the font
  ;; height is unknown, so the image is left at natural size — this is
  ;; why the batch render paths and the rest of the suite are unaffected.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
    (should (equal (agent-shell-math-renderer--display-scale) 1.0))))

(ert-deftest agent-shell-math-renderer-svg-px-per-pt-falls-back-uncached ()
  ;; Without a graphical frame the calibration returns the 96/72 fallback
  ;; and must NOT cache it, so a later graphical frame can still measure.
  (let ((agent-shell-math-renderer--svg-px-per-pt nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should (equal (agent-shell-math-renderer--svg-px-per-pt) (/ 96.0 72.0)))
      (should-not agent-shell-math-renderer--svg-px-per-pt))))

(ert-deftest agent-shell-math-renderer-display-scale-matches-font ()
  ;; The display scale maps the LaTeX 10pt body font onto the buffer font
  ;; height: scale = target * font-scale / (10 * px-per-pt).  Stub the
  ;; graphical inputs so the arithmetic is checked deterministically.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height) (lambda (&rest _) 28))
            ((symbol-function 'agent-shell-math-renderer--svg-px-per-pt)
             (lambda () 2.0)))
    (let ((agent-shell-math-renderer-font-scale 1.0))
      (should (equal (agent-shell-math-renderer--display-scale)
                     (/ 28.0 (* 10.0 2.0)))))
    ;; Doubling font-scale doubles the displayed size.
    (let* ((agent-shell-math-renderer-font-scale 1.0)
           (base (agent-shell-math-renderer--display-scale))
           (agent-shell-math-renderer-font-scale 2.0))
      (should (equal (agent-shell-math-renderer--display-scale) (* 2 base))))))

(ert-deftest agent-shell-math-renderer-appearance-tracks-color-and-font ()
  ;; The appearance signature folds in both the colors and the buffer font
  ;; height, so the lazy refresh detects a font-size change as well as a
  ;; color change.  Stub the graphical inputs.
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'agent-shell-math-renderer--svg-color)
             (lambda (_face attr _fallback)
               (if (eq attr :foreground) "#111111" "#eeeeee"))))
    (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 20)))
      (let ((a (agent-shell-math-renderer--current-appearance)))
        (should (equal a '("#111111" "#eeeeee" 20)))
        ;; Same colors, larger font => different signature => would refresh.
        (cl-letf (((symbol-function 'default-font-height) (lambda (&rest _) 28)))
          (should-not (equal a (agent-shell-math-renderer--current-appearance))))))))

(ert-deftest agent-shell-math-renderer-refresh-if-changed-detects-font ()
  ;; `--refresh-if-changed' triggers a refresh when only the font height
  ;; moved (colors unchanged), and targets just the current buffer (the
  ;; one the hook made relevant) rather than every buffer.
  (let ((agent-shell-math-renderer-enabled t)
        (refreshed nil))
    (with-temp-buffer
      (setq agent-shell-math-renderer--present t)
      ;; Buffer was last rendered at font height 20; same colors.
      (setq agent-shell-math-renderer--rendered-appearance
            '("#000000" "#ffffff" 20))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'agent-shell-math-renderer--svg-color)
                 (lambda (_face attr _fallback)
                   (if (eq attr :foreground) "#000000" "#ffffff")))
                ((symbol-function 'default-font-height) (lambda (&rest _) 30))
                ((symbol-function 'agent-shell-math-renderer-refresh)
                 (lambda (&optional buffer) (setq refreshed (or buffer t)))))
        (agent-shell-math-renderer--refresh-if-changed))
      ;; Refreshed, and scoped to this buffer.
      (should (eq refreshed (current-buffer))))))

(ert-deftest agent-shell-math-renderer-refresh-if-changed-skips-non-present ()
  ;; In a buffer with no equations (`--present' nil), a hook firing is a
  ;; no-op even if the appearance differs — nothing to re-render.
  (let ((agent-shell-math-renderer-enabled t)
        (refreshed nil))
    (with-temp-buffer
      (setq agent-shell-math-renderer--present nil)
      (setq agent-shell-math-renderer--rendered-appearance nil)
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                ((symbol-function 'agent-shell-math-renderer--svg-color)
                 (lambda (_face attr _fallback)
                   (if (eq attr :foreground) "#000000" "#ffffff")))
                ((symbol-function 'default-font-height) (lambda (&rest _) 30))
                ((symbol-function 'agent-shell-math-renderer-refresh)
                 (lambda (&optional _buffer) (setq refreshed t))))
        (agent-shell-math-renderer--refresh-if-changed))
      (should-not refreshed))))

(ert-deftest agent-shell-math-renderer-text-scale-wired-to-refresh ()
  ;; A buffer zoom (`text-scale-adjust') fires `text-scale-mode-hook' but
  ;; neither display nor theme hooks, so the lazy refresh must subscribe to
  ;; it directly — otherwise equations only re-size on the next buffer
  ;; switch.  Verify the hook is wired at load time.
  (should (memq 'agent-shell-math-renderer--maybe-refresh
                (default-value 'text-scale-mode-hook))))

(ert-deftest agent-shell-math-renderer-image-cache-key-includes-scale-and-color ()
  ;; The in-memory image-cache key folds in BOTH the display scale and the
  ;; tint color, so the same equation at two font sizes or two themes maps
  ;; to distinct entries (the on-disk SVG is shared).
  (should (equal (agent-shell-math-renderer--image-cache-key "K" 0.8 "#fff")
                 (agent-shell-math-renderer--image-cache-key "K" 0.8 "#fff")))
  (should-not (equal (agent-shell-math-renderer--image-cache-key "K" 0.8 "#fff")
                     (agent-shell-math-renderer--image-cache-key "K" 1.5 "#fff")))
  (should-not (equal (agent-shell-math-renderer--image-cache-key "K" 0.8 "#fff")
                     (agent-shell-math-renderer--image-cache-key "K" 0.8 "#000"))))

(ert-deftest agent-shell-math-renderer-load-svg-recolors-currentcolor ()
  ;; The on-disk SVG carries `currentColor'; loading substitutes the given
  ;; foreground in, so the image is tinted without recompiling.
  (let ((tmp (make-temp-file "asm-cc" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg'>"
                    "<path fill='currentColor' d='M0 0h1v1z'/></svg>"))
          (let ((data (image-property
                       (agent-shell-math-renderer--load-svg-image tmp 1.0 "#abcdef")
                       :data)))
            (should (string-match-p "#abcdef" data))
            (should-not (string-match-p "currentColor" data))))
      (delete-file tmp))))

(ert-deftest agent-shell-math-renderer-image-cache-coexists-per-scale ()
  ;; The same on-disk SVG cached at two display scales yields two distinct
  ;; image objects that coexist: the first stays warm after the second is
  ;; created (so a sibling buffer's images survive a font change — no clear).
  (let ((tmp (make-temp-file "asm-svg" nil ".svg")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "<svg xmlns='http://www.w3.org/2000/svg' "
                    "width='10pt' height='10pt'>"
                    "<rect width='10' height='10'/></svg>"))
          (clrhash agent-shell-math-renderer--image-cache)
          (cl-letf (((symbol-function 'agent-shell-math-renderer--svg-file)
                     (lambda (_key) tmp)))
            (let (img1 img2)
              (cl-letf (((symbol-function 'agent-shell-math-renderer--display-scale)
                         (lambda () 0.8)))
                (setq img1 (agent-shell-math-renderer--cached-image "K")))
              (cl-letf (((symbol-function 'agent-shell-math-renderer--display-scale)
                         (lambda () 1.5)))
                (setq img2 (agent-shell-math-renderer--cached-image "K")))
              (should img1)
              (should img2)
              ;; Two coexisting entries, one per scale.
              (should (= 2 (hash-table-count
                            agent-shell-math-renderer--image-cache)))
              ;; The first is still served from cache (warm, not evicted).
              (cl-letf (((symbol-function 'agent-shell-math-renderer--display-scale)
                         (lambda () 0.8)))
                (should (eq img1 (agent-shell-math-renderer--cached-image "K"))))
              ;; Each image carries its own scale.
              (should (equal (image-property img1 :scale) 0.8))
              (should (equal (image-property img2 :scale) 1.5)))))
      (delete-file tmp))))

;;; Overlay-renderer bridge (`agent-shell-math-renderer-render-overlays')
;;
;; The other tests drive the in-place renderer via
;; `agent-shell-markdown-convert', which runs our render hook.  The overlay
;; renderer (`markdown-overlays-put') never runs that hook, so the bridge is
;; exercised separately here: render into a buffer with `markdown-overlays-put'
;; + the bridge, then read back the `face' runs.  `markdown-overlays-put'
;; styles via overlays (invisible to `--deconstruct', which reads the `face'
;; text property), while our math renderer uses text properties — so a run
;; faced `agent-shell-math-renderer' is unambiguously ours.

(require 'markdown-overlays)

(defun agent-shell-math-renderer-tests--overlay-deconstruct (markdown)
  "Render MARKDOWN through the overlay path and return its `face' runs.
Runs `markdown-overlays-put' then feeds its result to
`agent-shell-math-renderer-render-overlays' in a temp buffer, mirroring the
custom `agent-shell-markdown-render-function' wrapper users install for the
overlay renderer, and deconstructs the resulting buffer text."
  (with-temp-buffer
    (insert markdown)
    (let ((result (markdown-overlays-put)))
      (agent-shell-math-renderer-render-overlays result))
    (agent-shell-markdown--deconstruct (buffer-string))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-renders-bracket-math ()
  ;; Under the overlay renderer, a complete `\\[...\\]' block is still
  ;; recognized and math-faced as one run — the bridge stands in for the
  ;; render hook the overlay path never calls.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "\\[E=mc^2\\]")
                   '(("\\[E=mc^2\\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-renders-dollar-math ()
  ;; `$$...$$' likewise renders on the overlay path (dollar delimiter on).
  (agent-shell-math-renderer-tests--with-dollar
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "$$
E=mc^2
$$")
                   '(("$$
E=mc^2
$$" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-renders-inline-math ()
  ;; Inline `\\(...\\)' renders on the overlay path; surrounding prose is
  ;; left unfaced (its markdown, if any, is styled by overlays we don't read).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "see \\(x^2\\) here")
                   '(("see " nil)
                     ("\\(x^2\\)" (agent-shell-math-renderer))
                     (" here" nil))))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-renders-fenced-math ()
  ;; A ```math fence is rewritten to `\\[...\\]' and math-faced, the same as
  ;; on the in-place path — the bridge reuses `--rewrite-fenced-block'.
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "```math
E=mc^2
```")
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer)))))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-fenced-keeps-following-content ()
  ;; The fenced block's trailing newline is preserved so following prose
  ;; stays on its own line (the overlay path's block end sits on that
  ;; newline, matching the in-place convention).
  (agent-shell-math-renderer-tests--enabled
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "```math
E=mc^2
```
after")
                   '(("\\[
E=mc^2
\\]" (agent-shell-math-renderer))
                     ("
after" nil))))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-avoids-math-in-code ()
  ;; `\\(...\\)' inside a fenced code block is body text, not math: the
  ;; bridge takes the overlay renderer's `avoided-ranges' as its avoid-set,
  ;; so nothing in the code block is math-faced.
  (agent-shell-math-renderer-tests--enabled
    (let ((runs (agent-shell-math-renderer-tests--overlay-deconstruct
                 "```python
y = \\(x\\)
```")))
      (should-not (seq-some (lambda (run)
                              (memq 'agent-shell-math-renderer (cadr run)))
                            runs)))))

(ert-deftest agent-shell-math-renderer-overlay-bridge-master-switch-off ()
  ;; With the master switch off, the bridge is a no-op: `\\[...\\]' is left
  ;; plain, unfaced by us.
  (let ((agent-shell-math-renderer-enabled nil))
    (should (equal (agent-shell-math-renderer-tests--overlay-deconstruct
                    "\\[E=mc^2\\]")
                   '(("\\[E=mc^2\\]" nil))))))

(ert-deftest agent-shell-math-renderer-markdown-overlays-put-renders-and-returns ()
  ;; The ready-made drop-in renders math AND returns `markdown-overlays-put's
  ;; result alist (so it honors the overlay renderer's return contract).
  ;; Exercises the real function end to end — the lazy `require', the dynamic
  ;; binding of the `markdown-overlays-*' vars, and the bridge call.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "\\[E=mc^2\\]")
      (let ((result (agent-shell-math-renderer-markdown-overlays-put
                     :render-images t :highlight-blocks t)))
        ;; Math rendered: the block carries our source stash.
        (should (equal (get-text-property (point-min)
                                          'agent-shell-math-renderer-source)
                       "E=mc^2"))
        ;; Returned value is the overlay renderer's contract alist.
        (should (assq 'avoided-ranges result))
        (should (assq 'source-blocks result))))))

;;; Skip-guard: `--style-blocks' does not re-apply already-rendered blocks
;;
;; Under the overlay renderer the whole fragment is re-scanned on every
;; streaming chunk, so `--style-blocks' re-detects finished equations.  The
;; guard makes it skip a block already carrying `agent-shell-math-renderer-source'.
;; These tests pin both directions, because the feature is silent — a
;; regression would just quietly re-apply (guard never fires) or quietly drop
;; a real render (guard fires when it must not), neither visible in output.

(ert-deftest agent-shell-math-renderer-style-blocks-skips-rendered ()
  ;; Second `--style-blocks' pass over the same buffer must NOT re-apply a
  ;; block it already rendered — the guard fires on the `-source' stash.
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "\\[E=mc^2\\]")
      (let ((apply-count 0)
            (orig (symbol-function 'agent-shell-math-renderer--apply-region)))
        (cl-letf (((symbol-function 'agent-shell-math-renderer--apply-region)
                   (lambda (&rest args)
                     (cl-incf apply-count)
                     (apply orig args))))
          ;; First pass renders it (stashes `-source'); second must skip.
          (agent-shell-math-renderer--style-blocks :avoid-ranges [])
          (agent-shell-math-renderer--style-blocks :avoid-ranges []))
        (should (= apply-count 1))
        ;; Sanity: it really did render on the first pass.
        (should (equal (get-text-property (point-min)
                                          'agent-shell-math-renderer-source)
                       "E=mc^2"))))))

(ert-deftest agent-shell-math-renderer-style-blocks-renders-frozen-without-source ()
  ;; A block marked `agent-shell-markdown-frozen' but NOT yet rendered — the
  ;; state the hook leaves on a still-open block while it streams — must
  ;; still render once its closer arrives.  This is why the guard keys on
  ;; `agent-shell-math-renderer-source' (set only by a real render) and not
  ;; on `frozen': keying on `frozen' here would wrongly skip it and the
  ;; equation would never render (a silent break of the in-place path).
  (agent-shell-math-renderer-tests--enabled
    (with-temp-buffer
      (insert "\\[E=mc^2\\]")
      (put-text-property (point-min) (point-max)
                         'agent-shell-markdown-frozen t)
      (agent-shell-math-renderer--style-blocks :avoid-ranges [])
      (should (equal (get-text-property (point-min)
                                        'agent-shell-math-renderer-source)
                     "E=mc^2")))))

(provide 'agent-shell-math-renderer-tests)

;;; agent-shell-math-renderer-tests.el ends here
