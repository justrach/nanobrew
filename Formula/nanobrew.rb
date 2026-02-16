class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.05"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.05/nb-arm64-apple-darwin.tar.gz"
      sha256 "b8421eabaf2de8600333021d4ee5fa3b778407ac4218fb46635f9039900f6a7f"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.05/nb-x86_64-apple-darwin.tar.gz"
      sha256 "2ab661a6174d73226339ce1c0a315f6f40135def94207eba57f076ab783b29d4"
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
