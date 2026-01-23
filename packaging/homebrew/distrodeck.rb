class Distrodeck < Formula
  desc "Export and restore packages before distro upgrades"
  homepage "https://github.com/nikolareljin/distrodeck"
  url "https://github.com/nikolareljin/distrodeck/releases/download/v0.4.0/distrodeck-0.4.0.tar.gz"
  version "0.4.0"
  sha256 "9f2a8c4a3e7b5d12a6b0b0c4e9f7f0b1c3d2e5f9a4b8c7d6e1f2a3b4c5d6e7f8"
  license "MIT"

  depends_on "python@3.12"

  def install
    bin.install "distrodeck"
    man1.install "docs/man/distrodeck.1"
  end
end
