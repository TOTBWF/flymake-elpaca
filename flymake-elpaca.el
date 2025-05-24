;;; flymake-elpaca.el ---  A Flymake backend for elpaca-based configurations -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Reed Mullanix <reedmullanix@gmail.com>

;; Author: Reed Mullanix <reedmullanix@gmail.com>

;; URL: https://github.com/totbwf/flymake-elpaca
;; Keywords: lisp local

;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The existing `flymake' backend for `emacs-lisp-mode' is designed for package
;; authors, and invokes the byte compiler in a hermetic environment.
;; This makes it difficult to use for Emacs configurations, though this can
;; be worked around with `elisp-flymake-byte-compile-load-path'.  However,
;; what *cannot* be worked around are some alternative packaging solutions.

;; Notably, `elpaca' uses an asynchronous package installation model, which
;; means that packages are not done loading by the end of Emacs's initialization
;; process, which completely breaks the existing flymake backend.  This package
;; provides an alternative `flymake' backend that invokes `elpaca-wait' before
;; invoking the byte compiler: this ensures that all of our packages are actually
;; initialized by the time we invoke the byte compiler.

;; This package takes inspiration from `elisp-mode.el' and `flymake-straight'
;; (https://github.com/KarimAziev/flymake-straight/blob/main/flymake-straight.el).

;;; Code:

(declare-function elpaca "elpaca.el")
(declare-function elpaca-wait "elpaca.el")

(defvar flymake-elpaca--source-file
  (if load-in-progress load-file-name buffer-file-name)
  "The source file of `flymake-elpaca'.
This is passed to the Emacs subprocess when byte-compiling a file.")

(defvar-local flymake-elpaca--byte-compile-process nil
  "Buffer-local process started for byte-compiling the buffer.")

(defun flymake-elpaca--batch-compile (&optional file)
  "Helper for `flymake-elpaca--byte-compile'.
Runs in a batch-mode Emacs.  Interactively use variable
`buffer-file-name' for FILE."
  (interactive
   (list buffer-file-name))
  ;; Bootstrap basic `elpaca', and invoke `elpaca-wait' to block until
  ;; we've finished processing all elpaca queues before byte compiling.
  (require 'elpaca-log)
  (require 'elpaca)
  (elpaca-wait)
  (let* ((file (or file (car command-line-args-left)))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8)
         (diagnostics)
         ;; We dont want to actually create any destination files.
         (byte-compile-dest-file-function #'ignore)
         ;; Disable error on warn: this messes with diagnostic levels.
         (byte-compile-error-on-warn nil)
         (byte-compile-log-buffer
          (generate-new-buffer " *dummy-byte-compile-log-buffer*"))
         (byte-compile-log-warning-function
          (lambda (&rest args)
            (push args diagnostics))))
    ;; Invoke the byte compiler, and dump the output.
    (unwind-protect
        (byte-compile-file file)
      (ignore-errors
        (kill-buffer byte-compile-log-buffer)))
    (prin1 :flymake-elpaca-output-start)
    (terpri)
    (pp diagnostics)))

(defun flymake-elpaca--batch-compile-command (file)
  "Construct an Emacs command to byte-compile FILE."
  `(,(expand-file-name invocation-name invocation-directory)
	"--batch"
	,@(mapcan (lambda (path) (list "-L" path)) load-path)
        "--load" ,flymake-elpaca--source-file
        "--funcall" "flymake-elpaca--batch-compile"
	,file))

(defun flymake-elpaca--byte-compile (report-fn &rest _args)
  "A Flymake backend for elisp files with `use-package' forms with :straight.
Spawn an Emacs process, activate `straight-use-package-mode',
and byte-compiles a file representing the current buffer state and calls
REPORT-FN when done."
  ;; Restart the byte-compile process if it is already running.
  (when (process-live-p flymake-elpaca--byte-compile-process)
    (kill-process flymake-elpaca--byte-compile-process))
  ;; To avoid race conditions, we are going to invoke the byte-compiler
  ;; on a temporary file. This means that we are going to need to
  ;; do a bit of due-diligence to make sure that we use a reasonable
  ;; text encoding.
  (let* ((coding-system-for-write 'utf-8-unix)
         (coding-system-for-read 'utf-8)
	 (temp-file (make-temp-file "flymake-elpaca--byte-compile"))
	 (source-buffer (current-buffer))
	 (output-buffer (generate-new-buffer " *flymake-elpaca--byte-compile*")))
    ;; Write the contents of the current buffer to our temporary file.
    (without-restriction
      (write-region nil nil temp-file nil 'nomessage))
    ;; Start the byte compilation process. Our process sentinel
    ;; is rather borin
    (setq flymake-elpaca--byte-compile-process
       (make-process
        :name "flymake-elpaca--byte-compile"
        :buffer output-buffer
        :command (flymake-elpaca--batch-compile-command temp-file)
        :connection-type 'pipe
        :sentinel (flymake-elpaca--byte-compile-sentinel report-fn source-buffer output-buffer)
        :stderr " *stderr of flymake-elpaca--byte-compile*"
        :noquery t))))

(defun flymake-elpaca--byte-compile-sentinel (report-fn source-buffer output-buffer)
  ;; checkdoc-params: (report-fn source-buffer output-buffer)
  "Process sentinel for `flymake-elpaca--byte-compile-process'.

This sentinel only checks to see if the byte-compilation process has terminated,
and checks the exit code to see if we should panic or not.

See `flymake-elpaca--byte-compile-done' for further documentation."
  (lambda (proc _event)
    (unless (process-live-p proc)
      (cond
       ((not (buffer-live-p source-buffer))
	(flymake-log :warning
		     "flymake elpaca: byte-compile process %s obsolete, source buffer %s not live."
		     proc source-buffer))
       ((not (eq proc (buffer-local-value 'flymake-elpaca--byte-compile-process source-buffer)))
	(flymake-log :warning
		     "flymake elpaca: byte-compile process %s obsolete, source buffer %s has new byte-compile process."
		     proc source-buffer))
       ((flymake-elpaca--byte-compile-process-obsolete-p proc source-buffer)
        (flymake-log :warning "flymake elpaca: byte-compile process %s obsolete" proc))
       ((zerop (process-exit-status proc))
        (flymake-elpaca--byte-compile-done report-fn source-buffer output-buffer))
       (t
        (funcall report-fn :panic :explanation
		 (format "byte-compile process %s died: %s\n%s"
			 proc
			 (process-exit-status proc)
			 (with-current-buffer output-buffer (buffer-string)))))))))

(defun flymake-elpaca--byte-compile-process-obsolete-p (process buffer)
  "Check that the flymake byte-compilation PROCESS is live for a BUFFER."
  (not (and (buffer-live-p buffer)
       (eq process (buffer-local-value 'flymake-elpaca--byte-compile-process buffer)))))

(defun flymake-elpaca--byte-compile-done (report-fn source-buffer output-buffer)
  "Return diagnostics for a SOURCE-BUFFER based on OUTPUT-BUFFER.
OUTPUT-BUFFER should containing flymake diagnostics.
Takes three arguments - the reporting function REPORT-FN,
the SOURCE-BUFFER to get diagnostics for, and the
OUTPUT-BUFFER containing the diagnostics."
  (with-current-buffer source-buffer
    (save-excursion
      (without-restriction
      (cl-loop
       with data =
       (with-current-buffer output-buffer
	 (goto-char (point-min))
	 (search-forward ":flymake-elpaca-output-start")
	 (read (point-marker)))
       for (string pos _fill level) in data
       ;; Try to find the bounds of the error inside of the source buffer,
       ;; and clamp the bounds to the current line.
       do (goto-char pos)
       for bounds = (bounds-of-thing-at-point 'sexp)
       for beg = (max (line-beginning-position) (or (car bounds) (point-min)))
       for end = (min (line-end-position) (or (cdr bounds) (point-max)))
       ;; Adjust the beginnings if we are looking at an empty span, and pass
       ;; all the results back to flymake.
       collect
       (flymake-make-diagnostic
	source-buffer
	(if (= beg end) (1- beg) beg)
	end
        level
	string)
       into diagnostics
       finally (funcall report-fn diagnostics))))))

(defun flymake-elpaca-setup ()
  "Add `flymake-straight-elisp-flymake-byte-compile' to flymake diagnostic.

Also remove `elisp-flymake-byte-compile' from diagnostic and reactivate
`flymake-mode'."
  (if (bound-and-true-p flymake-mode)
      (flymake-mode -1)
    (require 'flymake))
  (remove-hook 'flymake-diagnostic-functions
               #'elisp-flymake-byte-compile t)
  (add-hook 'flymake-diagnostic-functions
            #'flymake-elpaca--byte-compile nil t)
  (flymake-mode 1))

(provide 'flymake-elpaca)
;;; flymake-elpaca.el ends here
