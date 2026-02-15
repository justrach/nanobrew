class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.02"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.02/nb-arm64-apple-darwin.tar.gz"
      sha256 "1f93a0da07b90ba64e25aa24c47e09585928608a93545f41b028aa8e78c16df7"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.02/nb-x86_64-apple-darwin.tar.gz"
      sha256 "613d75bb90a8495f89342bff6011b90306293b5f5eee8fee7b80e8a226ccd151"
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
