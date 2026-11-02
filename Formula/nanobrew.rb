class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.215"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.215/nb-arm64-apple-darwin.tar.gz"
      sha256 "9b378cf52e4f0f82bb06b60120cba5bbfe7d7e5d242154ab7bc86a8d6e0422e0"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.215/nb-x86_64-apple-darwin.tar.gz"
      sha256 "a228fe50a6deec36bac3e1ffbc248fa7653af683bf35897bbec01a4229c0e629"
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
