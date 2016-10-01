;;; camcorder.el --- Record screencasts in gif or other formats.  -*- lexical-binding: t; -*-

;; Copyright (C) 2014 Artur Malabarba <bruce.connor.am@gmail.com>

;; Author: Artur Malabarba <bruce.connor.am@gmail.com>
;; URL: http://github.com/Bruce-Connor/camcorder.el
;; Keywords: multimedia screencast
;; Version: 0.2
;; Package-Requires: ((emacs "24") (cl-lib "0.5"))

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
;;
;;   Tool for capturing screencasts directly from Emacs.
;;
;;   • To use it, simply call `M-x camcorder-record'.
;;   • A new smaller frame will popup and recording starts.
;;   • When you're finished, hit `F12' and wait for the conversion to
;;     finish.
;;
;;   Screencasts can be generated in any format understood by
;;   `imagemagick''s `convert' command.  You can even pause the recording
;;   with `F11'!
;;
;;   If you want to record without a popup frame, use `M-x
;;   camcorder-mode'.
;;
;; Dependencies
;; ────────────
;;
;;   `camcorder.el' uses the [*Names*] package, so if you're installing
;;   manually you need to install that too.
;;
;;   For the recording, `camcorder.el' uses the following linux utilities.
;;   If you have these, it should work out of the box.  If you use something
;;   else, you should still be able to configure `camcorder.el' work.
;;
;;   • recordmydesktop
;;   • mplayer
;;   • imagemagick
;;
;;   Do you know of a way to make it work with less dependencies? *Open an
;;   issue and let me know!*
;;
;;
;;   [*Names*] https://github.com/Bruce-Connor/names/
;;
;; Troubleshooting
;; ───────────────
;;
;;   If camcorder.el seems to pick an incorrect window id (differing from the
;;   one that `wminfo' returns), you can change `camcorder-window-id-offset' from its
;;   default value of 0.

;;; Code:

(require 'cl-lib)


;;; Variables
(defcustom camcorder-frame-parameters
  '((name . "camcorder.el Recording - F12 to Stop - F11 to Pause/Resume")
    (height . 20)
    (width . 65)
    (top .  80))
  "Parameters used on the recording frame.
See `make-frame'."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'camcorder)

(defcustom camcorder-recording-command
  '("recordmydesktop" " --fps 20 --no-sound --windowid " window-id " -o " file)
  "Command used to start the recording.
This is a list where all elements are `concat'ed together (with no
separators) and passed to `shell-command'.  Each element must be a
string or a symbol.  The first string should be just the name of a
command (no args), so that we can identify it and SIGTERM it.

Options you may want to configure are \"--fps 10\" and \"--no-sound\".

Meaning of symbols:
   'file is the output file.
   'window-id is the window-id parameter of the recording frame.
   'temp-file and 'temp-dir are auto-generated file names in the
   temp directory."
  :type '(cons string
               (repeat
                (choice
                 string
                 (const :tag "window-id parameter of the recording frame" window-id)
                 (const :tag "Output file" file)
                 (const :tag "Temporary intermediate file" temp-file)
                 (const :tag "Temporary intermediate dir" temp-dir))))
  :group 'camcorder)

(defcustom camcorder-gif-conversion-commands
  '(("ffmpeg"
     "ffmpeg -i " input-file " -pix_fmt rgb24 -r 30 " gif-file)
    ("mplayer + imagemagick"
     "mkdir -p " temp-dir
     " && cd " temp-dir
     " && mplayer -ao null " input-file " -vo jpeg"
     " && convert " temp-dir "* " gif-file
     "; rm -r " temp-dir)
    ("mplayer + imagemagick + optimize (slow)"
     "mkdir -p " temp-dir
     " && cd " temp-dir
     " && mplayer -ao null " input-file " -vo jpeg"
     " && convert " temp-dir "* " temp-gif-file
     " && convert " temp-gif-file " -fuzz 10% -layers Optimize " gif-file
     "; rm -r " temp-dir temp-gif-file))
  "Alist of commands used to convert ogv file to a gif.
This is a list where each element has the form
    (DESCRIPTOR STRING-OR-SYMBOL STRING-OR-SYMBOL ...)

DESCRIPTOR is a human-readable string, describing the ogvcommand.
STRING-OR-SYMBOL's are all concated together (with no separators)
and passed to `shell-command'.  Strings are used literally, and
symbols are converted according to the following meanings:

   'file is the output file.
   'window-id is the window-id parameter of the recording frame.
   'temp-file, 'temp-dir, and 'temp-gif-file are auto-generated
       file names in the temp directory.

To increase compression at the cost of slower conversion, change
\"z=1\" to \"z=9\" (or something in between).  You may also use
completely different conversion commands, if you know any."
  :type '(alist :key-type (string :tag "Description for this command")
                :value-type (repeat
                             (choice
                              string
                              (const :tag "window-id parameter of the recording frame" window-id)
                              (const :tag "Output gif file" gif-file)
                              (const :tag "Input file" input-file)
                              (const :tag "Temporary intermediate gif file" temp-gif-file)
                              (const :tag "Temporary intermediate file" temp-file)
                              (const :tag "Temporary intermediate dir" temp-dir))))
  :group 'camcorder)

(defcustom camcorder-window-id-offset 0
  "Difference between Emacs' and X's window-id.
This variable should be mostly irrelevant; it was more useful
when camcorder.el relied on `window-id' instead of
`outer-window-id'."
  :type 'integer
  :group 'camcorder)

(defcustom camcorder-output-directory (expand-file-name "~/Videos")
  "Directory where screencasts are saved."
  :type 'directory
  :group 'camcorder)

(defcustom camcorder-gif-output-directory camcorder-output-directory
  "Directory where screencasts are saved."
  :type 'directory
  :group 'camcorder)

(defvar camcorder-temp-dir
  (if (fboundp 'temp-directory)
      (temp-directory)
    (if (boundp 'temporary-file-directory)
        temporary-file-directory
      "/tmp/"))
  "Directory to store intermediate conversion files.")

(defvar camcorder-recording-frame nil
  "Frame created for recording.
Used by `camcorder--start-recording' to decide on the dimensions.")

(defvar camcorder--process nil "Recording process PID.")

(defvar camcorder--output-file-name nil
  "Bound to the filename chosen by the user.")

(defvar camcorder--gif-file-name nil
  "Gif output file.")


;;; User Functions
(defun camcorder-stop () "Stop recording." (interactive) (camcorder-mode -1))

:autoload
(defun camcorder-record ()
  "Open a new Emacs frame and start recording.
You can customize the size and properties of this frame with
`camcorder-frame-parameters'."
  (interactive)
  (select-frame
   (if (frame-live-p camcorder-recording-frame)
       camcorder-recording-frame
     (setq camcorder-recording-frame
           (make-frame camcorder-frame-parameters))))
  (camcorder-mode))

:autoload
(defalias 'camcorder-start #'camcorder-record)

:autoload
(define-minor-mode camcorder-mode
  nil nil "sc"
  '(([f12] . camcorder-stop)
    ([f11] . camcorder-pause))
  :global t
  (if camcorder-mode
      (progn
        (setq camcorder--output-file-name
              (expand-file-name
               (read-file-name "Output file (out.ogv): "
                               (file-name-as-directory camcorder-output-directory)
                               "out.ogv")
               camcorder-output-directory))
        (camcorder--start-recording)
        (add-hook 'delete-frame-functions #'camcorder--stop-recording-if-frame-deleted))
    (remove-hook 'delete-frame-functions #'camcorder--stop-recording-if-frame-deleted)
    (when (camcorder--is-running-p)
      (signal-process camcorder--process 'SIGTERM))
    (setq camcorder--process nil)
    (when (frame-live-p camcorder-recording-frame)
      (delete-frame camcorder-recording-frame))
    (setq camcorder-recording-frame nil)
    (pop-to-buffer "*camcorder output*")
    (message "OGV file saved. Use `M-x %s' to convert it to a gif."
             #'camcorder-convert-to-gif)))

(defun camcorder--clear-message ()
  (message " "))

(add-hook 'camcorder-mode-hook #'camcorder--clear-message)

(defun camcorder--is-running-p ()
  "Non-nil if the recording process is running."
  (and (integerp camcorder--process)
       (memq camcorder--process (list-system-processes))))

(defun pause ()
  "Pause or resume recording."
  (interactive)
  (when (camcorder--is-running-p)
    (signal-process camcorder--process 'SIGUSR1)))

(defvar camcorder--input-file nil)

(defun camcorder-convert-to-gif ()
  "Convert the ogv file to gif."
  (interactive)
  (let* ((camcorder--input-file
          (expand-file-name
           (read-file-name "File to convert: "
                           (or (file-name-directory (or camcorder--output-file-name ""))
                               camcorder-output-directory)
                           nil t
                           (file-name-nondirectory (or camcorder--output-file-name "")))))
         (camcorder--file-base (file-name-base (file-name-nondirectory camcorder--input-file)))
         (camcorder--gif-file-name
          (expand-file-name
           (read-file-name "Output gif: "
                           camcorder-gif-output-directory nil nil
                           (concat camcorder--file-base ".gif"))
           camcorder-output-directory))
         (command
          (cdr (assoc
                (completing-read "Command to use (TAB to see options): "
                                 (mapcar #'car camcorder-gif-conversion-commands)
                                 nil t)
                camcorder-gif-conversion-commands))))
    (setq command (mapconcat #'camcorder--convert-args command ""))
    (when (y-or-n-p (format "Execute the following command? %s" command))
      (shell-command (format "(%s) &" command)
                     "*camcorder output*")
      (pop-to-buffer "*camcorder output*"))))


;;; Internal
(defun camcorder--stop-recording-if-frame-deleted (frame)
  "Stop recording if FRAME match `camcorder-recording-frame'.
Meant for use in `delete-frame-functions'."
  (when (equal frame camcorder-recording-frame)
    (camcorder-stop)))

(defun camcorder--announce-start-recording ()
  "Countdown from 3."
  (message "Will start recording in 3..")
  (sleep-for 0.7)
  (message "Will start recording in .2.")
  (sleep-for 0.7)
  (message "Will start recording in ..1")
  (sleep-for 0.7)
  (message nil))

(defun camcorder--start-recording ()
  "Start recording process.
Used internally.  You should call `camcorder-record' or
`camcorder-mode' instead."
  (if (camcorder--is-running-p)
      (error "Recording process already running %s" camcorder--process)
    (setq camcorder--process nil)
    (camcorder--announce-start-recording)
    (let ((display-buffer-overriding-action
           (list (lambda (_x _y) t))))
      (shell-command
       (format "(%s) &"
               (mapconcat #'camcorder--convert-args camcorder-recording-command ""))
       "*camcorder output*"))
    (while (null camcorder--process)
      (sleep-for 0.1)
      (let* ((name (car camcorder-recording-command))
             (process
              (car
               (cl-member-if
                (lambda (x) (string= name (cdr (assoc 'comm (process-attributes x)))))
                (list-system-processes)))))
        (setq camcorder--process process)))))

(defun camcorder--convert-args (arg)
  "Convert recorder argument ARG into values.
Used on `camcorder-recording-command'."
  (cond
   ((stringp arg) arg)
   ((eq arg 'file) camcorder--output-file-name)
   ((eq arg 'input-file) camcorder--input-file)
   ((eq arg 'gif-file)   camcorder--gif-file-name)
   ((eq arg 'window-id)
    (camcorder--frame-window-id
     (if (frame-live-p camcorder-recording-frame)
         camcorder-recording-frame
       (selected-frame))))
   ((eq arg 'temp-dir)
    (expand-file-name "camcorder/" camcorder-temp-dir))
   ((eq arg 'temp-file)
    (expand-file-name "camcorder.ogv" camcorder-temp-dir))
   ((eq arg 'temp-gif-file)
    (expand-file-name "camcorder.gif" camcorder-temp-dir))
   (t (error "Don't know this argument: %s" arg))))

(defun camcorder--frame-window-id (frame)
  "Return FRAME's window-id in hex.
Increments the actual value by `window-id-offset'."
  (format "0x%x"
          (+ (string-to-number
              (frame-parameter frame 'outer-window-id))
             camcorder-window-id-offset)))


(provide 'camcorder)
;;; camcorder.el ends here
