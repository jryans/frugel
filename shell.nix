{ sources ? import ./nix/sources.nix { }
, ghc ? "ghc865"
}:
let
  unstablePkgs = import sources.nixpkgs-unstable { };
  stablePkgs = import sources.nixpkgs { };
  miso = import sources.miso { };
  misoPkgs = miso.pkgs;
  base = (import ./base.nix { inherit sources ghc; }).override {
    miso = miso.miso-jsaddle; /* Overrides dependencies defined in package.yaml */
  };

  reload-script = stablePkgs.writeShellScriptBin "reload" ''
    ${stablePkgs.haskellPackages.ghcid}/bin/ghcid -c '\
        stack repl\
        --ghci-options -fno-break-on-exception\
        app/Main.hs\
        '\
        --restart=package.yaml\
        -T 'Main.main'
  '';

  floskell = unstablePkgs.haskellPackages.floskell;
  nix-pre-commit-hooks = import sources."pre-commit-hooks.nix";
  pre-commit-check = nix-pre-commit-hooks.run {
    src = ./.;
    hooks = with import ./nix/commit-hooks.nix { inherit floskell; }; {
      nixpkgs-fmt.enable = true;
      nix-linter.enable = true;
      hlint.enable = true;
      floskell = floskellHook // {
        enable = true;
      };
      build = buildHook // {
        enable = true;
      };
    };
  };
in
base.env.overrideAttrs (
  old: {
    buildInputs = old.buildInputs ++ [
      reload-script
      stablePkgs.hlint
      stablePkgs.haskellPackages.apply-refact
      floskell
      stablePkgs.ghcid
      stablePkgs.stack
      misoPkgs.haskell.packages.ghcjs.ghc
      stablePkgs.git # has to be present for pre-commit-check shell hook
    ];
    shellHook = ''
      ${pre-commit-check.shellHook}
    '';
  }
)
