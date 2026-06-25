class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.200"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.200/nb-arm64-apple-darwin.tar.gz"
      sha256 "cc005554a9d2da22cbf48d0d83bf6802eb6cfbf1fd7fc6770218cb62669a26f4"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.200/nb-x86_64-apple-darwin.tar.gz"
      sha256 "adb5980c51c323c5409b15a0d58d35449dea048ccdb090729a9d3eeade562fe1"
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
