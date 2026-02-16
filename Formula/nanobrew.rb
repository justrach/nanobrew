class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.067"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-arm64-apple-darwin.tar.gz"
      sha256 "f2ee9997246bf224a439fead0a30a70e75e2313402e8400b37c26ac3873edbda"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-x86_64-apple-darwin.tar.gz"
      sha256 "afa01408b5bd80252633b4a304e63df18838af3815d28975389c2d7611ea157b"
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
