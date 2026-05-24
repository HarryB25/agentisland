cask "agentisland" do
  arch arm: "arm64", intel: "x86_64"

  version :latest
  sha256 :no_check

  url "https://github.com/HarryB25/agentisland/releases/latest/download/agentisland-macos-#{arch}.zip"
  name "AgentIsland"
  desc "Native macOS live activity island for AI agents"
  homepage "https://github.com/HarryB25/agentisland"

  depends_on macos: ">= :ventura"
  auto_updates true

  app "AgentIsland.app"

  zap trash: [
    "~/.agentisland",
  ]
end
