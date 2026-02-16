class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.065"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.065/nb-arm64-apple-darwin.tar.gz"
      sha256 "ffd6a8d6b1ce6785d3a4cda167a81c5e00ee14c7275b02dcbcdac03cbe6dc390"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.065/nb-x86_64-apple-darwin.tar.gz"
      sha256 "615ec51b5292e8b05aad71927bd429b7d81de41e9622be2b188e8563a8c63a8a"
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
