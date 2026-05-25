class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.194"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.194/nb-arm64-apple-darwin.tar.gz"
      sha256 "05bbb3c763360cae25c34ce7844f680c6ea8ae676b353040a3333129fcddc96f"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.194/nb-x86_64-apple-darwin.tar.gz"
      sha256 "d1d589f1ce015c15cd3aa3cd3b3b61f6a028e65cd4d5767e7efa2133aad98bb5"
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
