class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.067"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-arm64-apple-darwin.tar.gz"
      sha256 "66619e9f34e4a3ebec793a9d570b18560629929578d5cda4587e1067875daeb5"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.067/nb-x86_64-apple-darwin.tar.gz"
      sha256 "421b87a83afa25db98d50194b3009ccf5819cfa0f5f68c5fd9468cafb99aa910"
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
