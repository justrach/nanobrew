class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.051"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.051/nb-arm64-apple-darwin.tar.gz"
      sha256 "768e63c348dc842dcd94cddb7656368e2a17aec6e9f211f4969db09f0324a71f"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.051/nb-x86_64-apple-darwin.tar.gz"
      sha256 "95bd55ebb7e5e3a5b765ec2f3d1424e224ec82e425caf6ed74445c6e2b928eb8"
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
