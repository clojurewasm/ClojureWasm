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

        # Zig 0.15.2 binary (per-architecture URLs and hashes)
        zigArchInfo = {
          "aarch64-darwin" = {
            url = "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz";
            sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
          };
          "x86_64-darwin" = {
            url = "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz";
            sha256 = ""; # untested
          };
          "x86_64-linux" = {
            url = "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz";
            sha256 = "0skmy2qjg2z4bsxnkdzqp1hjzwwgnvqhw4qjfnsdpv6qm23p4wm0";
          };
          "aarch64-linux" = {
            url = "https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz";
            sha256 = ""; # untested
          };
        }.${system} or (throw "Unsupported system: ${system}");

        zigSrc = builtins.fetchTarball {
          url = zigArchInfo.url;
          sha256 = zigArchInfo.sha256;
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
