class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.03"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.03/nb-arm64-apple-darwin.tar.gz"
      sha256 "295815a9e83504feba72ea6e1330719ec9b08a7511c1556b58078be00100605b"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.03/nb-x86_64-apple-darwin.tar.gz"
      sha256 "11d58de9c0f6137dd4b881116e43d339ba647cc3db75865da18dd6057c75c6ba"
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
