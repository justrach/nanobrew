class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.03"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.03/nb-arm64-apple-darwin.tar.gz"
      sha256 ""
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.03/nb-x86_64-apple-darwin.tar.gz"
      sha256 ""
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
