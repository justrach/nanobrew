class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.061"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.061/nb-arm64-apple-darwin.tar.gz"
      sha256 "7e87c7125b78b51780454a3b0daf09378045cd664652b419222b5ddb424598d5"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.061/nb-x86_64-apple-darwin.tar.gz"
      sha256 "44e5afc960396097c08695aed77a34bab5ba2f10d2954cf948a582e40b3a69f2"
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
