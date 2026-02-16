class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.05"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.05/nb-arm64-apple-darwin.tar.gz"
      sha256 "bfaf26b117b539298726c5db4956c1a68bb4404fd041c988cfa746db8c66675a"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.05/nb-x86_64-apple-darwin.tar.gz"
      sha256 "e19f561e13570c6c4546aa3c0437988ec3022aa75f64bf2a3528650d9a71d060"
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
