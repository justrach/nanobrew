class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.067"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-arm64-apple-darwin.tar.gz"
      sha256 "10cb66dfe20291b5662a91f606d92572cac608b1293bd8c963b29d7bc7d5fb88"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-x86_64-apple-darwin.tar.gz"
      sha256 "2956526e96bfcac550ddc7d7225c447bd02ec005a86c7ccd7db041286793c2da"
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
