class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.079"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.079/nb-arm64-apple-darwin.tar.gz"
      sha256 "5f9e48d31bcfcff5c04cc7e3729687e1daf4f5fc3650b87c3217c9964e57861e"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.079/nb-x86_64-apple-darwin.tar.gz"
      sha256 "3870a0f69341ca7cabe6467d0fcebfbaa619a4ccec84920fccd319625ff0d852"
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
