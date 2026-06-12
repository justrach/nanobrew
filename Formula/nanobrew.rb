class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.198"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.198/nb-arm64-apple-darwin.tar.gz"
      sha256 "8c35b0491a5a265e261d2a6eaa63a9f70acfaf0f9b3dfb8adfb6283dbab0edba"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.198/nb-x86_64-apple-darwin.tar.gz"
      sha256 "27265ef7cbddb9edcfbdff5adef1671ba00d2cf12e5deae63fac1fe68f5cea6e"
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
