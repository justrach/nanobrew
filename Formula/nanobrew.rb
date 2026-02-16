class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.065"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.062/nb-arm64-apple-darwin.tar.gz"
      sha256 "0bdaa178eba7bc4b152723da604ed40bb39ff81254a782809f568611f9227e1b"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.062/nb-x86_64-apple-darwin.tar.gz"
      sha256 "615f6d8341ec35868644e9c09bff429d489d67b828bfcde95dcd6fb9cf7515e8"
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
