class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.01"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.01/nb-arm64-apple-darwin.tar.gz"
      sha256 "abc2da51997ea8a86a0365c30a8b44b52a9b56be00aa64bdbe111e79b4a5ebdd"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.01/nb-x86_64-apple-darwin.tar.gz"
      sha256 "39738120605ec32010dd09e920c504879cf255c830919bd447555704d0233ea0"
    end
  end

  def install
    bin.install "nb"
  end

  def post_install
    ohai "Run 'nb init' to create the nanobrew directory tree"
  end

  test do
    assert_match "nanobrew", shell_output("#{bin}/nb help")
  end
end
