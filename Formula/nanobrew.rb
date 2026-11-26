class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.216"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.216/nb-arm64-apple-darwin.tar.gz"
      sha256 "b577bcc573c83473239a17881de404550e5c2df3fdfe6913a116a1c290993281"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.216/nb-x86_64-apple-darwin.tar.gz"
      sha256 "bf828e449493a84f0f219ba357c6371bd8f885be0d63c66a6f45c64dbb992fe3"
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
