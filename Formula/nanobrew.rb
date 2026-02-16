class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.06"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.06/nb-arm64-apple-darwin.tar.gz"
      sha256 "a517061b5c4812ea2f97101c732d04a7ec244581502fda25028936b8d4702c78"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.06/nb-x86_64-apple-darwin.tar.gz"
      sha256 "3c020052a98b2174452e76847acc28f59198a1d34a6f066a4d0eaaff3e301fbc"
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
