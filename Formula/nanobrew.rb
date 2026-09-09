class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.210"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.210/nb-arm64-apple-darwin.tar.gz"
      sha256 "481f0d2badf2cbf000ecc708796aa8e12ad2aabf3ba497ec906aedb0f2d734a1"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.210/nb-x86_64-apple-darwin.tar.gz"
      sha256 "72441c2612b2ea796ed8b03cb8e9d98f045d3778e51f08baccce19181d830a9d"
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
