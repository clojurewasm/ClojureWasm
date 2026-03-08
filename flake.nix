{
  description = "ClojureWasm - Clojure implementation in Zig targeting Wasm and native";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    zig-overlay.url = "github:ziglang/zig/0.15.2";
    zig-overlay.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        zigArchInfo = {
          "aarch64-darwin" = {
            url = "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz";
            sha256 = "1csy5ch8aym67w06ffmlwamrzkfq8zwv4kcl6bcpc5vn1cbhd31g";
          };
          "x86_64-linux" = {
            url = "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz";
            sha256 = "0skmy2qjg2z4bsxnkdzqp1hjzwwgnvqhw4qjfnsdpv6qm23p4wm0";
          };
        }.${system} or (throw "Unsupported system: ${system}");

        zigSrc = builtins.fetchTarball {
          url = zigArchInfo.url;
          sha256 = zigArchInfo.sha256;
        };

        zigBin = pkgs.runCommand "zig-0.15.2-wrapper" {} ''
          mkdir -p $out/bin
          ln -s ${zigSrc}/zig $out/bin/zig
          ln -s ${zigSrc}/lib $out/lib
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "clojurewasm";

          buildInputs = with pkgs; [
            zigBin          # Zig 0.15.2
            yq-go           # YAML processing
            hyperfine       # Benchmarking
          ];

          shellHook = ''
            echo "ClojureWasm dev environment"
            echo "  Zig: $(zig version 2>/dev/null || echo 'loading...')"
          '';
        };
      }
    );
}
