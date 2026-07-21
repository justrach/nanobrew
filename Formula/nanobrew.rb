class Nanobrew < Formula
  desc "The fastest macOS package manager. Written in Zig."
  homepage "https://github.com/justrach/nanobrew"
  license "Apache-2.0"
  version "0.1.204"
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.204/nb-arm64-apple-darwin.tar.gz"
      sha256 "0448fdc87be29effc0f12d6ae9fb2fe0c38ba9377d2e89273889282b54c07bbe"
    else
      url "https://github.com/justrach/nanobrew/releases/download/v0.1.204/nb-x86_64-apple-darwin.tar.gz"
      sha256 "ebb020faadc464b70684bcc3d6713eedb5dd734c02a6141f15478aaf7cea0d4e"
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
