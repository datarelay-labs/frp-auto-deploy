# Homebrew formula for the frp-auto-deploy macOS client.
#
# Apple Silicon only. The formula installs the management CLI and the project
# tree; it does not enroll anything, start a daemon, or touch the network.
# Enrollment is an explicit, separate, root-privileged step:
#
#   sudo frpctl join '<descriptor>'
#
# Release process: `sha256` below is the digest of the tagged source tarball and
# is filled in at tag time. It is intentionally left as a non-hex placeholder so
# that an unreleased tree fails loudly in `brew audit` instead of installing
# something whose integrity was never checked.
class FrpAutoDeploy < Formula
  desc "Zero-touch FRP reverse-tunnel client for Apple Silicon macOS"
  homepage "https://github.com/datarelay-labs/frp-auto-deploy"
  url "https://github.com/datarelay-labs/frp-auto-deploy/archive/refs/tags/v2.1.1.tar.gz"
  version "2.1.1"
  sha256 "REPLACE_AT_TAG_TIME_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  # Apple Silicon only. Intel Darwin is rejected by the installer as well, so a
  # bottle built for x86_64 could never enroll successfully.
  depends_on arch: :arm64
  depends_on :macos
  depends_on macos: :big_sur

  def install
    libexec.install "install-client.sh"
    libexec.install "uninstall-client.sh"
    libexec.install "VERSION"
    libexec.install "release-manifest.json"
    libexec.install "lib"
    libexec.install "tools"
    libexec.install "client"

    # bin entries are wrappers rather than symlinks so that the scripts resolve
    # their sibling lib/ tree from libexec instead of from the Homebrew bin dir.
    %w[frpctl frp-client].each do |name|
      (bin/name).write <<~SH
        #!/bin/bash
        exec "#{libexec}/tools/#{name}" "$@"
      SH
      chmod 0755, bin/name
    end
  end

  def caveats
    <<~EOS
      This formula installs the management CLI only. Nothing is enrolled and no
      daemon is started until you run an explicit join.

      Enroll this Mac with the descriptor from your FRP server
      ("create zero-touch" -> macOS):

        sudo frpctl join '<descriptor>'

      Then check status with:

        sudo frpctl status

      Enrollment requires sudo because it installs a LaunchDaemon in
      /Library/LaunchDaemons and root-owned state in
      /Library/Application Support/frp-auto-deploy.

      It does not enable Remote Login, change the firewall, or create or modify
      any macOS user account. Remove it locally with:

        sudo frpctl uninstall

      A local uninstall does not release server-side port reservations.
    EOS
  end

  test do
    # Usage must not require root, network, or an enrolled client.
    assert_match "PROJECT_VERSION=2.1.1", (libexec/"VERSION").read
    assert_predicate bin/"frpctl", :executable?
    output = shell_output("#{bin}/frpctl join --help 2>&1", 2)
    assert_match "frpctl join", output
  end
end
