class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.203"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.203/nb-arm64-apple-darwin.tar.gz"
      sha256 "df98d1b74862609d6a94e3033f2601b7927a0bb8ff6848111d0f6f4933385183"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.203/nb-x86_64-apple-darwin.tar.gz"
      sha256 "e4f6defdb0d7c705348646930de53290828d8bb41420b75849147c4ba46cde22"
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
