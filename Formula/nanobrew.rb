class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.06"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.06/nb-arm64-apple-darwin.tar.gz"
      sha256 "dd5204091aab2ed95b64b1aa48a57a36667d383e6d6870e82f10dd0d81ed7cbf"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.06/nb-x86_64-apple-darwin.tar.gz"
      sha256 "ce11632f58b00c2335d6efa289d78ea8378c3719af9ec4cfcc0255be827c66a0"
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
