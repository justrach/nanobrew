class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.076"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.076/nb-arm64-apple-darwin.tar.gz"
      sha256 "693f6739ccb29f6fcd9c54ff6866ee4546e8d9046f205f42e4e60628e95ab052"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.076/nb-x86_64-apple-darwin.tar.gz"
      sha256 "68832c28be9813d4be4dd5b7a079732d44c054193131b2b724465a5d1c3add31"
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
