class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.199"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.199/nb-arm64-apple-darwin.tar.gz"
      sha256 "965bdc208b27de84861c904bf13711e23ff8d5eafe35f640ff9b52d44a51adc7"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.199/nb-x86_64-apple-darwin.tar.gz"
      sha256 "9c79d3fa721cdbb3751f5c4e5de74a80e93b5a4992f49fcfb9e83d0e5df5507d"
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
