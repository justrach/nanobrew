class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.076"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.076/nb-arm64-apple-darwin.tar.gz"
      sha256 "e9b483461ca001d2d84c4d27f39352741e6df387848cae7b70515b1dc51d9eab"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.076/nb-x86_64-apple-darwin.tar.gz"
      sha256 "198cbc58fa9e8f84a340ab65c3826b151713ecdb09ade0c450e90a3cbccee874"
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
