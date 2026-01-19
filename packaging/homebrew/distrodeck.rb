class Distrodeck < Formula
  desc "Export and restore packages before distro upgrades"
  homepage "https://github.com/nikolareljin/distrodeck"
  url "https://github.com/nikolareljin/distrodeck/releases/download/v0.4.0/distrodeck-0.4.0.tar.gz"
  version "0.4.0"
  sha256 "d4e3bd5fe30b8ce1fb277d570aace14cf80d4aa0c4310a233c36138a70d966f8"
  license "MIT"

  depends_on "python@3.12"

  def install
    bin.install "distrodeck"
    man1.install "docs/man/distrodeck.1"
  end
end
