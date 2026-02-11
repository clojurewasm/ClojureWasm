class Cljw < Formula
  desc "Fast Clojure runtime with Wasm FFI, built in Zig"
  homepage "https://github.com/chaploud/ClojureWasm"
  version "0.1.0"
  license "EPL-1.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/chaploud/ClojureWasm/releases/download/v#{version}/cljw-macos-aarch64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_MACOS_AARCH64"
    else
      url "https://github.com/chaploud/ClojureWasm/releases/download/v#{version}/cljw-macos-x86_64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_MACOS_X86_64"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/chaploud/ClojureWasm/releases/download/v#{version}/cljw-linux-aarch64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_AARCH64"
    else
      url "https://github.com/chaploud/ClojureWasm/releases/download/v#{version}/cljw-linux-x86_64.tar.gz"
      sha256 "PLACEHOLDER_SHA256_LINUX_X86_64"
    end
  end

  def install
    bin.install "cljw"
  end

  test do
    assert_equal "3", shell_output("#{bin}/cljw -e '(+ 1 2)'").strip
  end
end
