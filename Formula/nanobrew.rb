class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.084"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.084/nb-arm64-apple-darwin.tar.gz"
      sha256 "07ab021e8bb67df558b7d4a08628aaa5ef4a56dfa4118cc0c33403f8d4f9e2fd"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.084/nb-x86_64-apple-darwin.tar.gz"
      sha256 "b0d6d2a0f8a6ab2db8fc26ba8f5a1dc52b956efac5862c1dd172c9404526276e"
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
