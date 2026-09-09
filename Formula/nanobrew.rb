class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.209"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.209/nb-arm64-apple-darwin.tar.gz"
      sha256 "b4cc1b9331d1630e2431e51f2481a9e4dfe821d0afb0e33b18fae0723e4f1860"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.209/nb-x86_64-apple-darwin.tar.gz"
      sha256 "184240ab74a516cfbc0bc671b0b12794645da15bf0c2067d28d867da1bfc0afd"
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
