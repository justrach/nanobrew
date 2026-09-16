class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.212"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.212/nb-arm64-apple-darwin.tar.gz"
      sha256 "17d11f5f0b727db70ef6a330903085999cf50f6ac0733efaffc6615c72727b3a"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.212/nb-x86_64-apple-darwin.tar.gz"
      sha256 "fee56fd63c10799a76fb572870dcccb898cb6e90c793d2233c2d929bc14c8678"
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
