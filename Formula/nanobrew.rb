class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "MIT"
  version "0.1.051"
  license "Apache-2.0"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.051/nb-arm64-apple-darwin.tar.gz"
      sha256 "466dd15f8b94f8df4e7d868914acd1f69772e1cdf51a953ca1bc0ad1a15f4511"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.051/nb-x86_64-apple-darwin.tar.gz"
      sha256 "15d262cf9aceed327f104e7daebae28118d933b1f658c731bac114629ea3c13c"
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
