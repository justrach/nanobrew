class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.211"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.211/nb-arm64-apple-darwin.tar.gz"
      sha256 "41fbd109b24966189fd3a38fd8e5e8ed4a823cd84096f857f7d18bb6b30e2ebc"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.211/nb-x86_64-apple-darwin.tar.gz"
      sha256 "faa3c76359c0f00ec86af69847386df1e53422f3bd8447c0f30a74f192fe95b1"
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
