class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.0/nb-arm64-apple-darwin.tar.gz"
      sha256 "85aa46a6a968cef3f05ab404106f63deb1ae565b9016ba2d2083caa9c6f2cd49"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.0/nb-x86_64-apple-darwin.tar.gz"
      sha256 "d524370ef60fb50fdbc6440f7bbad4d372bbfdcd0204c39b105a3199fd3d4bfe"
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
