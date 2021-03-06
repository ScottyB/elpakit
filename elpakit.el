;;; elpakit.el --- package archive builder

;; Copyright (C) 2012  Nic Ferrier

;; Author: Nic Ferrier <nferrier@ferrier.me.uk>
;; Maintainer: Nic Ferrier <nferrier@ferrier.me.uk>
;; URL: http://github.com/nicferrier/elpakit
;; Keywords: lisp
;; Package-Requires: ((anaphora "0.0.6")(dash "1.0.3"))
;; Version: 0.0.15

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package archive builder.

;; This is for building file based package archives. This is useful
;; for deploying small sets of under-development-packages in servers;
;; for example elnode packages.

;; An example:

;; (elpakit
;;  "/tmp/shoesoffsaas"
;;  '("~/work/elnode-auth"
;;    "~/work/emacs-db"
;;    "~/work/shoes-off"
;;    "~/work/rcirc-ssh"))

;; This should make a package archive in /tmp/shoesoffsaas which has
;; the 4 packages in it.

;;; Code:

(require 'package)
(require 'dash)
(require 'cl)
(require 'anaphora)
(require 'tabulated-list)
(require 'server)

(defun elpakit/file-in-dir-p (filename dir)
  "Is FILENAME in DIR?"
  (let ((file (concat
               (file-name-as-directory dir)
               filename)))
    (and
     (file-in-directory-p file dir)
     (file-exists-p file))))

(defun elpakit/find-recipe (package-dir)
  "Find the recipe in PACKAGE-DIR."
  (car (directory-files
        (concat
         (file-name-as-directory package-dir)
         "recipes") t "^[^#.]")))

(defun elpakit/absolutize-file-name (package-dir file-name)
  (expand-file-name
   (concat (file-name-as-directory package-dir) file-name)))

(defun elpakit/infer-files (package-dir)
  "Infer the important files from PACKAGE-DIR

Returns a plist with `:elisp-files', `:test-files' and
`:non-test-elisp' filename lists.

`:non-test-elisp' is absolutized, but the others are not."
  (let* ((elisp-files (directory-files package-dir nil "^[^.#].*\\.el$"))
         (test-files (elpakit/mematch
                      "\\(test.*\\|.*test[s]*\\)\\.el$"
                      elisp-files))
         (non-test-elisp
          (mapcar
           (lambda (f)
             (elpakit/absolutize-file-name package-dir f))
           (-difference elisp-files test-files))))
    (list
     :elisp-files elisp-files
     :test-files test-files
     :non-test-elisp non-test-elisp)))

(defun elpakit/infer-recipe (package-dir)
  "Infer a recipe from the PACKAGE-DIR.

We currently can't make guesses about multi-file packages so
unless we can work out if the package is a single file package
this function just errors.

Test package files are guessed at to produce the :test section of
the recipe.

Files mentioned in the recipe are all absolute file names."
  (destructuring-bind (&key elisp-files test-files non-test-elisp)
      (elpakit/infer-files package-dir)
    ;; Now choose what sort of recipe to build?
    (if (equal (length non-test-elisp) 1)
        (let ((name (car (elpakit/file->package (car non-test-elisp) :name))))
          ;; Return the recipe with optional test section
          (list* ;; FIXME replace this with dash's -cons*
           name :files non-test-elisp
           (when test-files
             (list :test
                   (list
                    :files
                    (mapcar
                     (lambda (f)
                       (elpakit/absolutize-file-name package-dir f))
                     test-files))))))
        ;; Can't infer a multi-file package right now.
        ;;
        ;; FIXME - we could infer a lot about what to put in a
        ;; package:
        ;;
        ;; ** multiple, non-test lisp files could just be packaged
        ;; ** include any README and licence file
        ;; ** include any dir file and info files?
        ;;
        ;; the blocker is where to get the :version and :requires from.
        (error
         "elpakit - cannot infer package for %s - add a recipe description"
         package-dir))))

(defun elpakit/get-recipe (package-dir)
  "Returns the recipe for the PACKAGE-DIR.

Ensure the file list is sorted and consisting of absolute file
names.

If the recipe is not found as a file then we infer it from the
PACKAGE-DIR with `elpakit/infer-recipe'."
  (if (elpakit/file-in-dir-p "recipes" package-dir)
      (let* ((recipe-filename (elpakit/find-recipe package-dir))
             (recipe (with-current-buffer (find-file-noselect recipe-filename)
                       (goto-char (point-min))
                       (read (current-buffer)))))
        (plist-put
         (cdr recipe)
         :files
         (mapcar
          (lambda (f) (elpakit/absolutize-file-name package-dir f))
          ;;(sort (plist-get (cdr recipe) :files) 'string<)
          (plist-get (cdr recipe) :files)))
        recipe)
      ;; Else infer it
      (elpakit/infer-recipe package-dir)))

(defun elpakit/package-files (recipe)
  "The list of files specified by the RECIPE.

The list is returned sorted and with absolute files."
  (plist-get (cdr recipe) :files))

(defun elpakit/mematch (pattern lst)
  "Find the PATTERN in the LST."
  (loop for elt in lst
     if (string-match pattern elt)
     collect elt))

(defun elpakit/make-pkg-lisp (dest-dir pkg-info)
  "Write the package declaration lisp for PKG-INFO into DEST-DIR."
  ;; This is ripped out of melpa pb/write-pkg-file
  (let* ((name (aref pkg-info 0))
         (filename (concat
                    (file-name-as-directory dest-dir)
                    (format "%s-pkg.el" name)))
         (lisp
          `(define-package ; add the URL to extra-properties
               ,name
               ,(aref pkg-info 3)
             ,(aref pkg-info 2)
             ',(mapcar
                (lambda (elt)
                  (list (car elt)
                        (package-version-join (cadr elt))))
                (aref pkg-info 1)))))
    (with-current-buffer
        (let (find-file-hook)
          (find-file-noselect filename))
      (erase-buffer)
      (insert (format "%S" lisp))
      (write-file filename))))

(defun elpakit/copy (source dest)
  "Copy the file."
  (when (file-exists-p dest)
    (if (file-directory-p dest)
        (delete-directory dest t)
        (delete-file dest)))
  (message "elpakit/copy %s to %s" source dest)
  (copy-file source dest))

(defun elpakit/file->package (file &rest selector)
  "Convert FILE to package-info.

Optionaly get a list of SELECTOR which is `:version', `:name',
`:requires' or `t' for everything."
  (with-current-buffer (find-file-noselect file)
    (let* ((package-info
            (save-excursion
              (package-buffer-info))))
      (if selector
          (loop for select in selector
             collect
               (case select
                 (:version (elt package-info 3))
                 (:requires (elt package-info 1))
                 (:name (intern (elt package-info 0)))
                 (t package-info)))
          ;; Else
          package-info))))

(defun elpakit/build-single (destination single-file &optional recipe)
  "Build a single file package into DESTINATION."
  (destructuring-bind
        (package-info name version)
      (condition-case nil
          (elpakit/file->package single-file t :name :version)
        (error
         (when recipe
           (let* ((recipe-plist (cdr recipe))
                  (package-name (symbol-name (car recipe)))
                  (version (plist-get recipe-plist :version)))
             (list
              (vector package-name
                      (elpakit/require-versionify
                       (plist-get recipe-plist :requires)) ;; fixme - add base
                      (concat "A package derived from " package-name)
                      version
                      "") ; commentary
                    package-name
                    version)))))
    (unless (file-exists-p destination)
      (make-directory destination t))
    ;; Copy the actual lisp file
    (elpakit/copy
     single-file
     (concat
      (file-name-as-directory destination)
      (format "%s-%s" name version) ".el"))
    ;; Return the info
    package-info))

(defun elpakit/recipe->package-decl (recipe)
  "Convert a recipe into a package declaration."
  (destructuring-bind (name
                       ;; FIXME we need all the MELPA recipe things here
                       &key version doc requires files test) recipe
    `(define-package
         ,(symbol-name name)
         ,version
       ,(if (not (equal doc ""))
            doc
            (aif (elpakit/mematch "README\\..*" files)
                (with-current-buffer (find-file-noselect (car it))
                  (buffer-substring-no-properties (point-min)(point-max)))
              "This package has no documentation."))
       ,requires)))

(defun elpakit/readme (recipe)
  "Return the README for RECIPE or an empty string."
  (let ((readme
         (elpakit/mematch
          "README\\..*"
          (plist-get (cdr recipe) :files))))
    (if (and
         (listp readme)
         (> (length readme) 0))
        (with-current-buffer (find-file-noselect (car readme))
          (buffer-substring-no-properties (point-min)(point-max)))
        "")))

(defun elpakit/require-versionify (require-list)
  (mapcar
   (lambda (elt)
     (list
      (car elt)
      (version-to-list (cadr elt))))
   require-list))

(defun elpakit/build-multi (destination recipe)
  "Build a multi-file package into DESTINATION.

RECIPE specifies the package in a plist s-expression form."
  (let* ((package-info
          (package-read-from-string
           (format "%S" (elpakit/recipe->package-decl recipe))))
         (files (elpakit/package-files recipe))
         (name (nth 1 package-info))
         (version (nth 2 package-info))
         (docstring (nth 3 package-info))
         (require-list (nth 4 package-info))
         (requires (elpakit/require-versionify require-list))
         (readme (elpakit/readme recipe))
         (qname (format "%s-%s" name version))
         (destdir (concat
                   "/tmp/" ;;(file-name-as-directory destination)
                   (file-name-as-directory qname)))
         (package-info
          (vector name requires docstring version readme)))
    ;; Now copy everything to the destination
    (unless (file-exists-p destdir)
      (make-directory destdir t))
    ;; Copy the actual package files
    (loop for file in files
       do (let ((dest-file
                 (concat destdir (file-name-nondirectory file))))
            (elpakit/copy file dest-file)))
    ;; Write the package file
    (elpakit/make-pkg-lisp destdir package-info)
    ;; Check we have the package archive destination
    (unless (file-exists-p destination)
      (make-directory destination t))
    ;; Now we make the destination tarball
    (shell-command-to-string
     (format "tar cf /tmp/%s.tar -C /tmp %s" qname qname))
    ;; Now copy to the destination
    (elpakit/copy (format "/tmp/%s.tar" qname)
                  (concat (file-name-as-directory destination)
                          (format "%s.tar" qname)))
    ;; Return the info
    package-info))

;;;###autoload
(defun elpakit-make-multi (package-dir)
  "Make a multi-package.

If the directory you are in is a package then it is built,
otherwise this asks you for a package directory.

Opens the directory the package has been built in."
  (interactive
   (list
    (if (directory-files default-directory nil "^recipes$")
        default-directory
        (read-directory-name "Package-dir: " default-directory))))
  (let* ((dir-flag t)
         (package-name
          (file-name-sans-extension
           (file-name-nondirectory package-dir)))
         (dest (make-temp-file package-name dir-flag "elpakit")))
    (elpakit/build-multi dest (elpakit/get-recipe package-dir))
    (find-file dest)))

(defun elpakit/do-eval (package-dir)
  "Just eval the elisp files in the package in PACKAGE-DIR."
  (assert (file-directory-p package-dir))
  (let ((package-name
         (file-name-sans-extension
          (file-name-nondirectory package-dir))))
    (if (elpakit/file-in-dir-p "recipes" package-dir)
        ;; Find the list of files from the recipe
        (let* ((recipe (elpakit/get-recipe package-dir))
               (files (elpakit/package-files recipe)))
          (loop for file in files
             if (equal (file-name-extension file) "el")
             do
               (with-current-buffer
                   (find-file-noselect
                    (expand-file-name file package-dir))
                 (eval-buffer))))
        ;; Else could we work out what the package file is?
        )))

(defun elpakit/build-recipe (destination recipe)
  "Build the package with the RECIPE."
  (let* ((recipe-plist (cdr recipe))
         (files (plist-get recipe-plist :files)))
    (if (>= (length files) 2)
        ;; it MUST be a multi-file package
        (cons 'tar (elpakit/build-multi destination recipe))
        ;; Else it's a single file package
        (cons 'single (elpakit/build-single
                       destination (car files) recipe)))))

(defun elpakit/test-plist->recipe (package-dir)
  "Turn the :test plist from PACKAGE-DIR into a proper recipe."
  (destructuring-bind
        (&key elisp-files test-files non-test-elisp)
      (elpakit/infer-files package-dir)
    (let* ((base-recipe (elpakit/get-recipe package-dir))
           (base-plist (cdr base-recipe))
           (test-plist (plist-get base-plist :test))
           (test-files
            (mapcar
             (lambda (f)
               (if (file-name-absolute-p f) f
                   (elpakit/absolutize-file-name package-dir f)))
             (or
              (plist-get test-plist :files)
              test-files)))
           (test-name (intern
                       (file-name-sans-extension
                        (file-name-nondirectory (car test-files)))))
           (test-require (plist-get test-plist :requires))
           (test-version
            (or (plist-get base-plist :version)
                (car (elpakit/file->package
                      (car non-test-elisp) :version)))))
      (list test-name
            :files test-files
            :version test-version
            :requires
            (append
             (list (list (car base-recipe) test-version))
             test-require)))))

(defun elpakit/do (destination package-dir &optional do-tests)
  "Put the package in PACKAGE-DIR in DESTINATION.

The PACKAGE-DIR specifies the package.  It will either have a
recipe directory in it or we'll be able to infer a recipe from
it.

If DO-TESTS is `t' also attempt to build and copy the test
package for the PACKAGE-DIR.  The test package may be inferred or
it may be detailed in a supplied recipe file.

Returns a list of the packages constructed.  A package is a cons
of the type (`single' or `tar') and a vector, the information
necessary to build the archive-contents file.

If DO-TESTS is `nil' then the list returned always has just one
element which is the package cons.  If DO-TESTS is true though
the list MAY contain the package cons AND an additional
test-package cons."
  (assert (file-directory-p package-dir))
  (let* ((recipe (elpakit/get-recipe package-dir))
         (package (elpakit/build-recipe destination recipe))
         (recipe-plist (cdr recipe)))
    ;; Make the return list
    (cons package
          (when (and do-tests
                     (plist-get recipe-plist :test))
            (list
             (elpakit/build-recipe
              destination
              (elpakit/test-plist->recipe package-dir)))))))

;;;###autoload
(defun elpakit-eval (package-list)
  "Eval all the elisp files in PACKAGE-LIST."
  (loop for package in package-list
     do (elpakit/do-eval package)))

(defun elpakit/packages-list->archive-list (packages-list)
  "Turn the list of packages into an archive list."
  (loop for (type . package) in packages-list
     collect
       (cons
        (intern (elt package 0)) ; name
        (vector (version-to-list (elt package 3)) ; version list
                (elt package 1) ; requirements
                (elt package 2) ; doc string
                type))))

;;;###autoload
(defun elpakit (destination package-list &optional do-tests)
  "Make a package archive at DESTINATION from PACKAGE-LIST.

PACKAGE-LIST is either a list of local directories to package or
a list of two items beginning with the symbol `:archive' and
specifying an existing directory archive in `packages-archives'.

If PACKAGE-LIST is not an `:archive' reference then the package
directories specified are turned into packages in the
DESTINATION.

If PACKAGE-LIST is an `:archive' reference then the specified
archive is copied to DESTINATION.

For example, if `pacckage-archives' is:

 '((\"local\" . \"/tmp/my-elpakit\")(\"gnu\" . \"http://gnu.org/elpa/\"))

and `elpakit' is called like this:

 (elpakit \"/tmp/new-elpakit\" (list :archive \"local\"))

then /tmp/my-elpakit will be copied to /tmp/new-elpakit."
  (if (eq :archive (car package-list))
      (copy-directory
       (aget package-archives (cadr package-list))
       destination
       nil t t)
      ;; Else do the package build
      (let* ((packages-list
              (loop for package in package-list
                 append
                   (elpakit/do destination package do-tests)))
             (archive-list (elpakit/packages-list->archive-list packages-list))
             (archive-dir (file-name-as-directory destination)))
        (unless (file-exists-p archive-dir)
          (make-directory archive-dir t))
        (with-current-buffer
            (find-file-noselect
             (concat archive-dir "archive-contents"))
          (erase-buffer)
          (insert (format "%S" (cons 1 archive-list)))
          (save-buffer)))))

(defconst elpakit/processes (make-hash-table :test 'equal)
  "List of elpakit processes, either emphemeral or daemons.

Each process should be a list where the first item is the name,
the second item is the process type either `:daemon' or
`:batch'.  Other items may be present.")

(defun elpakit/process-add (name type process &rest rest)
  "Add a process to the central list."
  (puthash name (append (list name type process) rest) elpakit/processes))

(defun elpakit/process-list ()
  "List all the processes."
  (let (res)
    (maphash
     (lambda (k v)
       (setq res (append (list v) res)))
     elpakit/processes)
    res))

(defun elpakit/process-del (name)
  "Remove a process from the central list."
  (remhash name elpakit/processes))

(defun elpakit/process-list-entries ()
  "List of processes in `tabulated-list-mode' format."
  (loop for (proc-name proc-type &rest rest) in (elpakit/process-list)
     collect
       (list proc-name
             (vector proc-name
                     (case proc-type
                       (:daemon "daemon")
                       (:batch "batch"))
                     (if rest (format "%S" rest) "")))))

(defun elpakit/eval-at-server (name form)
  "Evaluate FORM at server NAME for side effects only."
  (if (functionp 'server-eval-at)
      (server-eval-at name form)
      (with-temp-buffer
        (print form (current-buffer))
        (call-process-shell-command
         (format "emacsclient -s %s --eval '%s'" name (buffer-string)) nil 0))))

(defun elpakit-process-kill (process-id &optional interactive-y)
  "Kill the specified proc with PROCESS-ID."
  (interactive
   (list
    (buffer-substring-no-properties
     (line-beginning-position)
     (save-excursion
       (goto-char (line-beginning-position))
       (- (re-search-forward " " nil t) 1))) t))
  (destructuring-bind (name type process &rest other)
      (gethash process-id elpakit/processes)
    ;; Check that we're interactive and the user really wants it
    ;; ... or we're not interactive.
    (when (or
           (and
            interactive-y
            (y-or-n-p (format "elpakit: delete process %s?" name)))
           (not interactive-y))
      ;; First kill the buffer
      (let ((buf (process-buffer process)))
        (when (bufferp buf)
          (kill-buffer buf)))
      (when (process-live-p process)
        (delete-process process))
      (when (eq type :daemon)
        (condition-case err
            (elpakit/eval-at-server
             name
             '(kill-emacs))
          ((file-error error)
           (if (not
                (string-match-p "^\\(No such server\\|Make client process\\)"
                                (cadr err)))
               ;; Rethrow if anything else
               (signal (car err) (cdr err)))))
        ;; Now safely delete the process from elpakit's list
        (elpakit/process-del name))
      ;; Update the list if necessary
      (when (equal (buffer-name (current-buffer))
                   "*elpakit-processes*")
        (tabulated-list-print)))))

(defun elpakit/process-list-process-id ()
  "Get the process-id from the process-list buffer."
  (buffer-substring-no-properties
   (line-beginning-position)
   (save-excursion
     (goto-char (line-beginning-position))
     (- (re-search-forward " " nil t) 1))))

(defun elpakit-process-open-emacsd (process-id)
  "Open the .emacs.d directory for the specified PROCESS-ID."
  (interactive (list (elpakit/process-list-process-id)))
  (destructuring-bind (name type process &rest other)
      (gethash process-id elpakit/processes)
    (find-file-other-window (format "/tmp/%s.emacsd" name))))

(defun elpakit-process-open-emacs-init (process-id)
  "Open the init file for the specified PROCESS-ID."
  (interactive (list (elpakit/process-list-process-id)))
  (destructuring-bind (name type process &rest other)
      (gethash process-id elpakit/processes)
    (find-file-other-window (format "/tmp/%s.emacs-init.el" name))))

(defun elpakit-process-show-buffer (process-id)
  "Show the buffer for the proc with PROCESS-ID."
  (interactive (list (elpakit/process-list-process-id)))
  (destructuring-bind (name type process &rest other)
      (gethash process-id elpakit/processes)
    (let ((buf (process-buffer process)))
      (if (or (not (bufferp buf))
              (not (buffer-live-p buf)))
          (message "elpakit process %s has no buffer?" process-id)
          ;; Else switch to the buffer
          (switch-to-buffer buf)))))

(define-derived-mode
    elpakit-process-list-mode tabulated-list-mode "Elpakit process list"
    "Major mode for listing Elpakit processes."
    (setq tabulated-list-entries 'elpakit/process-list-entries)
    (setq tabulated-list-format
          [("Process Name" 30 nil)
           ("Batch or Daemon" 20 nil)
           ("Args" 30 nil)])
    (define-key
        elpakit-process-list-mode-map (kbd "K")
      'elpakit-process-kill)
    (define-key
        elpakit-process-list-mode-map (kbd "L")
      'elpakit-process-show-buffer)
    (define-key
        elpakit-process-list-mode-map (kbd "F")
      'elpakit-process-open-emacsd)
    (define-key
        elpakit-process-list-mode-map (kbd "f")
      'elpakit-process-open-emacs-init)
    (tabulated-list-init-header))

;;;###autoload
(defun elpakit-list-processes ()
  "List running elpakit processes.

Uses `elpakit-process-list-mode' to display the currently running
elpakit processes from batch tests and daemons."
  (interactive)
  (with-current-buffer (get-buffer-create "*elpakit-processes*")
    (elpakit-process-list-mode)
    (tabulated-list-print)
    (switch-to-buffer (current-buffer))))

(defalias 'list-elpakit-processes 'elpakit-list-processes)

(defun elpakit/sentinel (process event)
  "Sentintel to kill the elpakit process when necessary."
  (if (or (string-equal event "finished\n")
          (string-equal event "exited abnormally with code exitcode\n"))
      (elpakit/process-del (process-name process))))

(defun elpakit/emacs-process (archive-dir install test)
  "Start an Emacs test process with the ARCHIVE-DIR repository.

Install the package INSTALL and then run batch tests on TEST.

The current Emacs process' `package-archives' variable is used
with the ARCHIVE-DIR being an additional repository called
\"local\".

The ARCHIVE-DIR was presumably built with elpakit, though it
could have come from anywhere."
  (let* ((elpa-dir (make-temp-file ".emacs.elpa" t))
         (emacs-bin (concat invocation-directory invocation-name))
         (args
          `("-batch"
            "-Q"
            "--eval"
            ,(format
              (concat
               "(progn"
               "(setq package-archives (quote %S))"
               "(setq package-user-dir %S)"
               "(package-initialize)"
               "(package-refresh-contents)"
               "(package-install (quote %S))"
               "(load-library \"%S\")"
               "(ert-run-tests-batch \"%s.*\"))")
              (acons "local" archive-dir package-archives)
              elpa-dir ;; where packages will be installed to
              install
              install
              test)))
         (name (generate-new-buffer-name
                (concat "elpakit-" (symbol-name install))))
         (proc (apply 'start-process name (format "*%s*" name) emacs-bin args)))
    (elpakit/process-add name :batch proc)
    (set-process-sentinel proc 'elpakit/sentinel)
    (with-current-buffer (process-buffer proc)
      (compilation-mode))
    proc))

(defun elpakit/emacs-server (archive-dir install &optional extra-lisp pre-lisp)
  "Start an Emacs server process with the ARCHIVE-DIR repository.

The server started is a daemon.  The process that starts the
daemon should die once the initialization has finished.  The
daemon remains of course.

INSTALL is a package name symbol for a package from the
ARCHIVE-DIR that will be installed.

Optionally you can specify a quoted lisp form in EXTRA-LISP and
this will be included in the daemon initialization.  This is
useful for testing, for example running batch tests could be done
like:

 '(ert-run-tests-batch \"my-package.*\")

This function returns a cons of the initialization process and the
emacs server identifier.  The emacs server identifier can be used
to contact the emacs daemon directly, thus:

  emacsclient -s /tmp/emacs$UID/$emacs-server-identifier

presuming that you're trying to start it from the same user."
  (let* ((unique (make-temp-name "elpakit-emacs-server"))
         (emacs-dir (concat "/tmp/" unique ".emacsd/"))
         (elpa-dir (concat emacs-dir "elpa/"))
         (emacs-bin (concat invocation-directory invocation-name))
         (boot-file (concat "/tmp/" unique ".emacs-init.el"))
         (args
          (list (concat "--daemon=" unique)
                "-Q" "-l" boot-file)))
    (with-temp-file boot-file
      (insert (format
               (concat
                "(progn"
                "%s"
                "(setq package-archives (quote %S))"
                "(setq package-user-dir %S)"
                "(package-initialize)"
                "(package-refresh-contents)"
                "(package-install (quote %S))"
                "%s)")
               (if pre-lisp (format "%S" pre-lisp) "")
               (acons "local" archive-dir package-archives)
               elpa-dir ;; where packages will be installed to
               install
               (if extra-lisp
                   (mapconcat
                    (lambda (a) (format "%S" a))
                    extra-lisp "\n")
                   ""))))
    (let ((proc (apply 'start-process
                       unique (format "*%s*" unique)
                       emacs-bin args)))
      (with-current-buffer (process-buffer proc)
        (compilation-mode))
      (elpakit/process-add unique :daemon proc)
      (cons proc unique))))

;;;###autoload
(defun* elpakit-start-server (package-list
                              install
                              &key test pre-lisp extra-lisp)
  "Start a server with the PACKAGE-LIST.

If TEST is `t' then we run tests in the daemon.

If EXTRA-LISP is a list then that is passed into the daemon to be
executed as extra initialization.  If EXTRA-LISP is specified
then automatic requiring of the INSTALL is not performed.  If
EXTRA-LISP and TEST is specified then tests are done *after*
EXTRA-LISP.  EXTRA-LISP must do the require in that case.

If PRE-LISP is a list then it is passed into the daemon as Lisp
to be executed before initialization.  This is where any
customization that you need should go.

You can manage running servers with the `elpakit-list-processes'
command."
  (let ((archive-dir (make-temp-file "elpakit-archive" t)))
    ;; First build the elpakit with tests
    (elpakit archive-dir package-list t)
    (let* ((test-stuff
            (if test
                `((ert-run-tests-batch ,(format "%s.*" install)))))
           (extra
            (if extra-lisp
                (cons extra-lisp test-stuff)
                ;; else do the require automatically
                (cons
                 `(require (quote ,install))
                 test-stuff)))
           (daemon-value
            (elpakit/emacs-server archive-dir install extra pre-lisp)))
      (with-current-buffer (get-buffer-create "*elpakit-daemon*")
        (make-variable-buffer-local 'elpakit-unique-handle)
        (setq elpakit-unique-handle (cdr daemon-value))
        daemon-value))))

(defvar elpakit/test-ert-selector-history nil
  "History variable for `elpakit-test'.")

;;;###autoload
(defun elpakit-test (package-list install test)
  "Run tests on package INSTALL of the specified PACKAGE-LIST.

TEST is an ERT test selector.

You can manage running processes with the `elpakit-list-processes'
command."
  (interactive
   (let ((test-recipe (elpakit/test-plist->recipe default-directory)))
     (assert
      (listp test-recipe)
      "there's no package in the current dir?")
     (with-current-buffer (get-buffer-create "*elpakit*") (erase-buffer))
     ;; deliver the interctive args
     (list (list default-directory)
           (car test-recipe)
           (read-from-minibuffer
            "ERT selector: " nil nil nil elpakit/test-ert-selector-history))))
  (let ((archive-dir (make-temp-file "elpakit-archive" t)))
    ;; First build the elpakit with tests
    (elpakit archive-dir package-list t)
    (elpakit/emacs-process archive-dir install test)
    (when (called-interactively-p)
      (switch-to-buffer-other-window "*elpakit*"))))


;;; Other tools on top of elpakit

(defun elpakit/files-to-elisp (list-of-files)
  (-filter
   (lambda (e) (string-match-p ".*\\.el$" e)) list-of-files))

(defun elpakit-multi-occur (buffer thing)
  "Multi-occur the current symbol using the current Elpakit.

All lisp files in the current elpakit are considered.

`elpakit-isearch-hook-jack-in' can be used to connect this up to
`isearch'.  Alternately or additionally bind it to another key in
`emacs-lisp-mode'."
  (interactive
   (list
    (current-buffer)
    (thing-at-point 'symbol)))
  (let ((recipe-dir
         (file-name-as-directory
          (car
           (directory-files
            (file-name-directory
             (buffer-file-name buffer))
            t "recipes")))))
    (if (file-exists-p recipe-dir)
        (let* ((recipe-list
                (with-current-buffer
                    (find-file-noselect
                     (car (directory-files recipe-dir t "^[^.].*[^~]$")))
                  (save-excursion
                    (goto-char (point-min))
                    (read
                     (current-buffer)))))
               (files (plist-get (cdr recipe-list) :files))
               (elisp (elpakit/files-to-elisp files))
               (elisp-buffers
                (loop for filename in elisp
                   collect (find-file-noselect filename))))
          (multi-occur elisp-buffers thing)))))

(defvar elpakit/isearch-keymap nil
  "The keymap containing extra things we enable during isearch.")

(defun elpakit/isearch-hook-jack-in ()
  "To be called by the isearch hook to connect our keymap."
  (unless elpakit/isearch-keymap
    (setq elpakit/isearch-keymap (make-sparse-keymap))
    (set-keymap-parent elpakit/isearch-keymap isearch-mode-map)
    (define-key elpakit/isearch-keymap (kbd "M-o")
      'elpakit-multi-occur)
  (setq overriding-terminal-local-map elpakit/isearch-keymap)))

;;;###autoload
(defun elpakit-isearch-hook-jack-in ()
  "Jack in Elpakit to isearch. Call from `elisp-mode-hook'.

Adds `elpakit-multi-occur' to `isearch' with `M-o'.

Use something like:

 (add-hook 'emacs-lisp-mode-hook 'elpakit-isearch-hook-jack-in)

in your configuration file to make it happen."
  (add-hook 'isearch-mode-hook 'elpakit/isearch-hook-jack-in t t))

(provide 'elpakit)

;;; elpakit.el ends here
