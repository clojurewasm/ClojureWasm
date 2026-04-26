{
  description = "ClojureWasm - Clojure implementation in Zig targeting Wasm and native";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        # Zig 0.16.0 binary (per-architecture URLs and hashes — sha256 mirrored from zwasm flake.nix)
        zigArchInfo = {
          "aarch64-darwin" = {
            url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz";
            sha256 = "0yqiq1nrjfawh1k24mf969q1w9bhwfbwqi2x8f9zklca7bsyza26";
          };
          "x86_64-darwin" = {
            url = "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz";
            sha256 = "0dibmghlqrr8qi5cqs9n0nl25qdnb5jvr542dyljfqdyy2bzzh2x";
          };
          "x86_64-linux" = {
            url = "https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz";
            sha256 = "1kgamnyy7vsw5alb5r4xk8nmgvmgbmxkza5hs7b51x6dbgags1h6";
          };
          "aarch64-linux" = {
            url = "https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz";
            sha256 = "12gf4d1rjncc8r4i32sfdmnwdl0d6hg717hb3801zxjlmzmpsns0";
          };
        }.${system} or (throw "Unsupported system: ${system}");

        zigSrc = builtins.fetchTarball {
          url = zigArchInfo.url;
          sha256 = zigArchInfo.sha256;
        };

        # Path wrapper: expose zig binary from nix store
        zigBin = pkgs.runCommand "zig-0.16.0-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "clojurewasm";

          buildInputs = with pkgs; [
            # Compiler
            zigBin                    # Zig 0.16.0

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
            nodejs_24                 # Node.js 24 LTS (cross-language benchmarks)
            tinygo                    # TinyGo 0.40 — native + wasm benchmark targets

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
            echo "  Node.js:  $(node --version 2>/dev/null || echo 'N/A')"
            echo "  TinyGo:   $(tinygo version 2>/dev/null || echo 'N/A')"
          '';
        };
      }
    );
}
