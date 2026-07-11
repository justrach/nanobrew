class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.202"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.202/nb-arm64-apple-darwin.tar.gz"
      sha256 "7d22c24e021980acab6dd381becfcbbd6163bbd4c0172d5c7e77391c6fcf9d25"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.202/nb-x86_64-apple-darwin.tar.gz"
      sha256 "6ae1d9ca85cc534749b4c154a2ded38c3034f9fe7f17c305fd1655d4a51a683a"
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
