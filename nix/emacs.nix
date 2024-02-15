{ pkgs
}:

# See https://nixos.org/nixos/manual/#module-services-emacs

let
  myEmacs = pkgs.emacs;
  emacsWithPackages = (pkgs.emacsPackagesFor myEmacs).emacsWithPackages;
  my-config = (epkgs: pkgs.emacsPackages.trivialBuild {
    pname = "my-mode";
    version = "2022-02-25";
    src = pkgs.writeText "default.el" ''
      (package-initialize)
      (global-set-key "\C-x\C-g" 'goto-line)
      (autoload 'lsp "lsp" nil t)
      ;(setq lsp-prefer-flymake nil)
      ;(autoload 'lsp-ui "lsp-ui" nil t)
      (add-hook 'lsp-mode-hook (lambda () (progn
        (define-key lsp-mode-map (kbd "C-c C-l") lsp-command-map)
        (lsp-ui-mode)
        (lsp-lens-mode)
        )))
      (setq lsp-keymap-prefix "\C-c\C-l")
      (define-key global-map [?¥] nil)
      (define-key local-function-key-map [?¥] [?\\])
      (define-key local-function-key-map [?\C-¥] [?\C-\\])
      (define-key local-function-key-map [?\M-¥] [?\M-\\])
      (define-key local-function-key-map [?\C-\M-¥] [?\C-\M-\\])
      (menu-bar-mode 0)
      (tool-bar-mode 0)
      (scroll-bar-mode 0)
      (setq ring-bell-function 'ignore)
      (when (require 'ansi-color nil t)
        (defun my-colorize-compilation-buffer ()
          (when (eq major-mode 'compilation-mode)
            (ansi-color-apply-on-region compilation-filter-start (point-max))))
        (add-hook 'compilation-filter-hook 'my-colorize-compilation-buffer))    
      (setq-default tab-width 2)
      (setq-default tab-stop-list (number-sequence 2 120 2))
      (global-whitespace-mode 1)
      (setq whitespace-style '(face tabs empty trailing))
    '';
  });
in
  emacsWithPackages (epkgs: (with epkgs.melpaStablePackages;[
  ]) ++ (with epkgs.melpaPackages;[
    wgrep
  ]) ++ (with epkgs.elpaPackages;[
  ]) ++ [
    epkgs.flycheck
    epkgs.flycheck-haskell
    epkgs.lsp-mode
    epkgs.lsp-ui
    (my-config epkgs)
  ])
