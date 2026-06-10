{
  description = "ClojureWasm — a Clojure runtime in Zig 0.16.0";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";

        # Cross-language benchmark runtimes (bench/compare_langs.sh). Pinned here
        # so `cljw vs <other runtime>` numbers are reproducible rather than
        # depending on whatever the host happens to have installed. compare_langs
        # auto-skips any language whose toolchain is absent, so this list is what
        # makes the C / Java / Python / Ruby / Node / Babashka / TinyGo columns
        # actually populate. `cc` for the C column comes from clang.
        benchLangs = [
          pkgs.clang     # cc — C column
          pkgs.jdk       # javac / java — Java column
          pkgs.python3   # Python column
          pkgs.ruby      # Ruby column
          pkgs.nodejs    # node — JS column
          pkgs.babashka  # bb — Babashka column (JVM-free Clojure peer)
          pkgs.go        # Go (standard; wasm fixture / tooling)
          pkgs.tinygo    # tinygo — the `tgo` column + bench/wasm TinyGo modules
        ];

        # WebAssembly tooling: building the FFI .wat fixtures and the
        # cljw vs wasmtime comparison (bench/wasm_bench.sh).
        wasmTools = [
          pkgs.wasm-tools  # wat -> wasm for bench/wasm/ffi/*.wat
          pkgs.wasmtime    # reference wasm runtime for wasm_bench.sh
        ];
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.hyperfine
            pkgs.yq-go
          ] ++ benchLangs ++ wasmTools;

          shellHook = ''
            echo "ClojureWasm dev shell"
            zig version
          '';
        };
      });
}
