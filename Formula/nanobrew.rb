class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.073"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.073/nb-arm64-apple-darwin.tar.gz"
      sha256 "aa447f88faa50ef053661c8b3ca345048a0623d9a08ef3731fda37ef5e640754"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.073/nb-x86_64-apple-darwin.tar.gz"
      sha256 "17d5d1696a12dd78d3e39768ff167245dc7e4e69b8902816b48d40a9ebae7f05"
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
