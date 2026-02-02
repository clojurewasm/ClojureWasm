{
  description = "ClojureWasm - Clojure implementation in Zig targeting Wasm and native";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Zig source pin (not used directly, just for tracking)
    zig-overlay.url = "github:ziglang/zig/0.15.2";
    zig-overlay.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Zig 0.15.2 binary (builtins.fetchTarball for sandbox-safe evaluation)
        zigSrc = builtins.fetchTarball {
          url =
            if system == "aarch64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
            else if system == "x86_64-darwin" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz"
            else if system == "x86_64-linux" then
              "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz"
            else if system == "aarch64-linux" then
              "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz"
            else throw "Unsupported system: ${system}";
          sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
        };

        # Path wrapper: expose zig binary from nix store
        zigBin = pkgs.runCommand "zig-0.15.2-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "clojurewasm";

          buildInputs = with pkgs; [
            # Compiler
            zigBin                    # Zig 0.15.2

            # Wasm runtime
            wasmtime

            # Data processing
            yq-go                     # YAML processing (mikefarah/yq)
            jq                        # JSON processing

            # Benchmarking
            hyperfine

            # Reference implementations (for compatibility testing)
            clojure
            jdk25
            babashka

            # Benchmark comparison languages
            python314
            ruby_4_0

            # Utilities
            gnused
            coreutils
          ];

          shellHook = ''
            echo "ClojureWasm dev environment"
            echo "  Zig:      $(zig version 2>/dev/null || echo 'loading...')"
            echo "  wasmtime: $(wasmtime --version 2>/dev/null || echo 'N/A')"
            echo "  Java:     $(java --version 2>&1 | head -1 || echo 'N/A')"
            echo "  Python:   $(python3 --version 2>/dev/null || echo 'N/A')"
            echo "  Ruby:     $(ruby --version 2>/dev/null || echo 'N/A')"
          '';
        };
      }
    );
}
