class ClaudeDocker < Formula
  desc "Run Claude Code autonomously in Docker with git worktree isolation"
  homepage "https://github.com/hansvd/claude-docker"
  url "https://github.com/hansvd/claude-docker/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "TODO"
  license "MIT"

  depends_on "yq"
  depends_on "jq"

  def install
    bin.install "bin/claude-docker"
  end

  test do
    assert_match "claude-docker", shell_output("#{bin}/claude-docker --version")
  end
end
