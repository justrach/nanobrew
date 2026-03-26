class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.075"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.075/nb-arm64-apple-darwin.tar.gz"
      sha256 "befa907fc68684e83fb4780d4cde6b5551d0874a9a73abc2772c994d2b9a7478"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.075/nb-x86_64-apple-darwin.tar.gz"
      sha256 "fa6d286668b66c8c34c67a32b9c436c97b815e47cfad943d548b3420717ba287"
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
