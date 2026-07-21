class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.205"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.205/nb-arm64-apple-darwin.tar.gz"
      sha256 "48b0e32f4d4f7f82bfaf3c8f6ca5fa9ecb85504f10ca624f8ac6595ce04de94d"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.205/nb-x86_64-apple-darwin.tar.gz"
      sha256 "0a00600ca77817f579be07ffbeeded39ce5892ca70f0268bb92a228f19ce8705"
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
