class Meetscribe < Formula
  desc "Local meeting transcription without a bot"
  homepage "https://github.com/NChang007/meetscribe"
  url "https://github.com/NChang007/meetscribe/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"
  head do
    url "https://github.com/NChang007/meetscribe.git", branch: "main"
  end

  depends_on :macos
  depends_on :xcode => ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/meetscribe"
  end

  def caveats
    <<~EOS
      After install, download on-device models (~1GB, one-time):
        meetscribe init

      Skip model download (air-gapped):
        meetscribe init --skip-models

      Then check permissions:
        meetscribe doctor
    EOS
  end

  test do
    assert_match "meetscribe", shell_output("#{bin}/meetscribe --help")
    assert_match(/\d+\.\d+\.\d+/, shell_output("#{bin}/meetscribe --version"))
  end
end
