class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.052"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.052/nb-arm64-apple-darwin.tar.gz"
      sha256 "977bc4d54fc912580e72a02ffd730d2bd6b41afb46d6cdac277dc62e7ccbb302"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.052/nb-x86_64-apple-darwin.tar.gz"
      sha256 "75dc7c800206acacaae74852573606a29c9283a566b55aa0255cb65a44b7295f"
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
