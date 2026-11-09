# Copyright lowRISC and contributors (COSMIC project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
{
  description = "UART 16550 Hardware IP Block is part of the COSMIC project.";
  inputs = {
    lowrisc-nix.url = "github:lowRISC/lowrisc-nix";

    nixpkgs.follows = "lowrisc-nix/nixpkgs";
    flake-utils.follows = "lowrisc-nix/flake-utils";
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };
  };

  nixConfig = {
    extra-substituters = ["https://nix-cache.lowrisc.org/public/"];
    extra-trusted-public-keys = ["nix-cache.lowrisc.org-public-1:O6JLD0yXzaJDPiQW1meVu32JIDViuaPtGDfjlOopU7o="];
  };

  outputs = {
    nixpkgs,
    flake-utils,
    lowrisc-nix,
    ...
  } @ inputs: let
    system_outputs = system: let
      pkgs = import nixpkgs {inherit system;};
      lrPkgs = lowrisc-nix.outputs.packages.${system};

      workspace = inputs.uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};
      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      pythonSet =
        (pkgs.callPackage inputs.pyproject-nix.build.packages {
          python = pkgs.python312;
        }).overrideScope
        (
          pkgs.lib.composeManyExtensions [
            inputs.pyproject-build-systems.overlays.default
            overlay
            (lowrisc-nix.lib.pyprojectOverrides {inherit pkgs;})
          ]
        );

      pythonEnv = pythonSet.mkVirtualEnv "python-env" workspace.deps.default;
    in rec {
      formatter = pkgs.alejandra;
      devShells = rec {
        default = dev;
        # Development shell, built on lowrisc-nix's generic mkEdaShell. Commercial
        # EDA tools (Xcelium, Jasper, Vivado) are declared via tool_data.json and
        # resolved at runtime from the JSON file named by $LOWRISC_EDA_CONFIG.
        # This execs a hermetic FHS sandbox and is not direnv-loadable.
        dev = lowrisc-nix.lib.mkEdaShell {
          inherit pkgs;
          name = "dev";
          tools = builtins.fromJSON (builtins.readFile ./tool_data.json);
          extraDeps =
            (with pkgs; [
              bison
              flex
              gtkwave
              uv
              pythonEnv
              autoconf
              pkg-config
              zlib
              zlib.dev
            ])
            ++ (with lrPkgs; [
              verilator_5_054
            ]);
          # Project env, appended after the EDA setup (mkEdaShell has no `env`
          # attr — buildFHSEnv takes a bash profile fragment instead).
          profile = ''
            # Prevent uv from managing Python downloads; force the nixpkgs interpreter.
            export UV_PYTHON_DOWNLOADS=never
            export UV_PYTHON=${pythonSet.python.interpreter}
          '';
        };
        # Minimal CI shell without verilator to speed up build time
        ci = lowrisc-nix.lib.mkEdaShell {
          inherit pkgs;
          name = "ci";
          tools = builtins.fromJSON (builtins.readFile ./tool_data.json);
          extraDeps =
            (with pkgs; [
              uv
              pythonEnv
            ]);
          # Project env, appended after the EDA setup (mkEdaShell has no `env`
          # attr — buildFHSEnv takes a bash profile fragment instead).
          profile = ''
            # Prevent uv from managing Python downloads; force the nixpkgs interpreter.
            export UV_PYTHON_DOWNLOADS=never
            export UV_PYTHON=${pythonSet.python.interpreter}
          '';
        };
      };

      apps = {
        # Non-interactive entry point into development shells
        dev = devShells.dev.app;
        ci = devShells.ci.app;
      };
    };
  in
    flake-utils.lib.eachDefaultSystem system_outputs;
}
