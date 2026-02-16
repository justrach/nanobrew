class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.052"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.052/nb-arm64-apple-darwin.tar.gz"
      sha256 "13fa91a34c4f0ae0e0b94ce51777764e4604d27594ff0620737051c342a84d7c"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.052/nb-x86_64-apple-darwin.tar.gz"
      sha256 "82c1d722469ea45af2efdb0b2eae36f2ca7c252f194ee8543d265e4371c7951f"
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
